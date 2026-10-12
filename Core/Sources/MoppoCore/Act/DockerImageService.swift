import Foundation

/// One Docker image and the tags that identify it.
public struct DockerImage: Sendable, Equatable {
    public let imageID: String
    public let context: String
    public let tags: [String]
    public let containerCount: Int?

    public init(imageID: String, context: String, tags: [String], containerCount: Int?) {
        self.imageID = imageID
        self.context = context
        self.tags = tags.sorted()
        self.containerCount = containerCount
    }

    public var isRemovalLocked: Bool { containerCount != 0 }
}

/// Reads and removes images through Docker in the scanned context.
public struct DockerImageService: Sendable {
    private let run: @Sendable ([String]) async throws -> Data
    private static let inspectFormat = #"{"Id":{{json .Id}},"RepoTags":{{json .RepoTags}},"Size":{{.Size}}}"#

    public init(
        runner: ProcessRunner = ProcessRunner(),
        timeout: Duration = .seconds(60),
        resolveExecutable: @escaping @Sendable () -> String? = { SystemExecutable.resolveDocker() }
    ) {
        run = { arguments in
            guard let executable = resolveExecutable() else {
                throw ProcessError.executableMissing("Docker")
            }
            return try await runner.run(executable, arguments, timeout: timeout, allowsInput: false)
        }
    }

    init(run: @escaping @Sendable ([String]) async throws -> Data) {
        self.run = run
    }

    func currentContext() async throws -> String {
        let output = try await read(["context", "show"])
        let context = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else { throw DockerImageError.invalidInventory }
        return context
    }

    func diskUsage(context: String) async throws -> Data {
        try await read(["--context", context, "system", "df", "--format", "{{json .}}"])
    }

    func images(context: String) async throws -> (entries: [FileEntry], unreadableCount: Int) {
        let prefix = ["--context", context]
        let usageData = try await read(prefix + ["system", "df", "--verbose", "--format", "{{json .}}"])
        let usage = try JSONDecoder().decode(ImageUsage.self, from: usageData)
        var counts: [String: Int] = [:]
        for row in usage.Images {
            if let count = Int(row.Containers), count >= 0 { counts[row.ID] = count }
        }
        let idsData = try await read(prefix + ["image", "ls", "--all", "--no-trunc", "--format", "{{.ID}}"])
        let ids = Array(Set(String(decoding: idsData, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init))).sorted()
        guard ids.allSatisfy(Self.isImageID) else { throw DockerImageError.invalidInventory }
        var entries: [FileEntry] = []
        var unreadable = 0
        for start in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            let data = try await read(prefix + ["image", "inspect", "--format", Self.inspectFormat, "--"] + batch)
            let inspected = try Self.parseInspections(data)
            guard inspected.count == batch.count, Set(inspected.map(\.Id)) == Set(batch) else {
                throw DockerImageError.invalidInventory
            }
            for image in inspected {
                guard image.Size >= 0 else { throw DockerImageError.invalidInventory }
                let count = counts[image.Id]
                if count == nil { unreadable += 1 }
                let metadata = DockerImage(
                    imageID: image.Id, context: context,
                    tags: Self.tags(in: image), containerCount: count
                )
                var components = URLComponents()
                components.scheme = "docker"
                components.host = "images"
                components.path = "/\(context)/\(image.Id)"
                guard let url = components.url else { throw DockerImageError.invalidInventory }
                entries.append(FileEntry(
                    url: url,
                    displayName: metadata.tags.isEmpty
                        ? "Untagged image \(image.Id.dropFirst(7).prefix(12))"
                        : metadata.tags.joined(separator: ", "),
                    parentDisplay: "Docker",
                    kind: .diskImage,
                    allocatedBytes: image.Size,
                    dockerImage: metadata
                ))
            }
        }
        return (entries, unreadable)
    }

    private func read(_ arguments: [String]) async throws -> Data {
        do {
            return try await run(arguments)
        } catch let error as ProcessError {
            switch error {
            case .timedOut:
                break
            case .failed(_, _, let stderr)
                where Self.isConnectionFailure(error)
                    || stderr.lowercased().contains("a disk usage operation is already running"):
                break
            default:
                throw error
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        return try await run(arguments)
    }

    static func isConnectionFailure(_ error: ProcessError) -> Bool {
        guard case .failed(_, _, let stderr) = error else { return false }
        let message = stderr.lowercased()
        return message.contains("cannot connect to the docker daemon")
            || message.contains("is the docker daemon running")
            || message.contains("error during connect")
    }

    /// Rechecks tags and container use before permanent removal.
    func remove(_ image: DockerImage) async throws -> Int64 {
        guard !image.context.isEmpty, Self.isImageID(image.imageID), !image.isRemovalLocked else {
            throw DockerImageError.imageInUse
        }
        let prefix = ["--context", image.context]
        let inspectArguments = ["image", "inspect", "--format", Self.inspectFormat, "--", image.imageID]
        let data = try await run(prefix + inspectArguments)
        let current = try Self.parseInspections(data)
        guard current.count == 1, let inspected = current.first,
              inspected.Id == image.imageID, Self.tags(in: inspected) == image.tags,
              inspected.Size >= 0 else { throw DockerImageError.imageChanged }
        let containers = try await run(prefix + [
            "container", "ls", "--all", "--quiet", "--filter", "ancestor=\(image.imageID)"
        ])
        guard String(decoding: containers, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw DockerImageError.imageInUse }
        try Task.checkCancellation()
        let targets = image.tags.isEmpty ? [image.imageID] : image.tags
        // Preserve unselected parent images and let Docker refuse dependencies.
        _ = try await run(prefix + ["image", "rm", "--no-prune", "--"] + targets)
        let remaining = try await run(prefix + ["image", "ls", "--all", "--no-trunc", "--format", "{{.ID}}"])
        guard !String(decoding: remaining, as: UTF8.self).split(whereSeparator: \.isNewline)
            .contains(Substring(image.imageID)) else { throw DockerImageError.imageStillPresent }
        return inspected.Size
    }

    private struct ImageUsage: Decodable {
        let Images: [UsageRow]
    }

    private struct UsageRow: Decodable {
        let ID: String
        let Containers: String
    }

    private struct Inspection: Decodable {
        let Id: String
        let RepoTags: [String]?
        let Size: Int64
    }

    private static func parseInspections(_ data: Data) throws -> [Inspection] {
        try String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode(Inspection.self, from: Data($0.utf8))
        }
    }

    private static func tags(in image: Inspection) -> [String] {
        Array(Set((image.RepoTags ?? []).filter { $0 != "<none>:<none>" })).sorted()
    }

    private static func isImageID(_ id: String) -> Bool {
        id.hasPrefix("sha256:") && id.count == 71
            && id.dropFirst(7).allSatisfy { "0123456789abcdef".contains($0) }
    }
}

enum DockerImageError: Error {
    case invalidInventory, imageChanged, imageInUse, imageStillPresent
}
