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

/// One Docker volume and the containers that use it.
///
/// A volume can hold the only copy of its data, such as a database.
/// Docker cannot download it again, so it is never regenerable.
public struct DockerVolume: Sendable, Equatable {
    public let name: String
    public let context: String
    /// Containers that refer to the volume, including stopped containers.
    public let containerCount: Int?
    /// The `com.docker.compose.project` label, when Docker Compose made the volume.
    public let composeProject: String?
    public let isAnonymous: Bool

    public init(name: String, context: String, containerCount: Int?, composeProject: String? = nil, isAnonymous: Bool = false) {
        self.name = name
        self.context = context
        self.containerCount = containerCount
        self.composeProject = composeProject
        self.isAnonymous = isAnonymous
    }

    public var isRemovalLocked: Bool { containerCount != 0 }
}

/// A Docker object that Docker removes permanently.
public enum DockerItem: Sendable, Equatable {
    case image(DockerImage)
    case volume(DockerVolume)

    public var containerCount: Int? {
        switch self {
        case .image(let image): image.containerCount
        case .volume(let volume): volume.containerCount
        }
    }

    public var isRemovalLocked: Bool { containerCount != 0 }
}

/// Docker objects from one scan of the current context.
struct DockerInventory: Sendable {
    var entries: [FileEntry]
    var unreadableCount: Int
    /// False when Docker did not report separate volumes.
    var listsVolumes: Bool
}

/// Reads and removes images and volumes through Docker in the scanned context.
public struct DockerService: Sendable {
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
        for attempt in 1...2 {
            let output = try await read(["context", "show"])
            let context = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !context.isEmpty { return context }
            ScanDiagnostics.current?.record("docker_context_empty", details: ["attempt": "\(attempt)"])
            if attempt == 1 { try await Task.sleep(for: .milliseconds(300)) }
        }
        throw DockerError.emptyContext
    }

    func diskUsage(context: String) async throws -> Data {
        try await read(["--context", context, "system", "df", "--format", "{{json .}}"])
    }

    func inventory(context: String) async throws -> DockerInventory {
        let prefix = ["--context", context]
        let usageData = try await read(prefix + ["system", "df", "--verbose", "--format", "{{json .}}"])
        let usage = try JSONDecoder().decode(Usage.self, from: usageData)
        var counts: [String: Int] = [:]
        for row in usage.Images {
            if let count = Int(row.Containers), count >= 0 { counts[row.ID] = count }
        }
        let idsData = try await read(prefix + ["image", "ls", "--all", "--no-trunc", "--format", "{{.ID}}"])
        let ids = Array(Set(String(decoding: idsData, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init))).sorted()
        guard ids.allSatisfy(Self.isImageID) else { throw DockerError.invalidInventory }
        var entries: [FileEntry] = []
        var unreadable = 0
        for start in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            let data = try await read(prefix + ["image", "inspect", "--format", Self.inspectFormat, "--"] + batch)
            let inspected = try Self.parseInspections(data)
            guard inspected.count == batch.count, Set(inspected.map(\.Id)) == Set(batch) else {
                throw DockerError.invalidInventory
            }
            for image in inspected {
                guard image.Size >= 0 else { throw DockerError.invalidInventory }
                let count = counts[image.Id]
                if count == nil { unreadable += 1 }
                let metadata = DockerImage(
                    imageID: image.Id, context: context,
                    tags: Self.tags(in: image), containerCount: count
                )
                entries.append(FileEntry(
                    url: try Self.itemURL(kind: "images", context: context, name: image.Id),
                    displayName: metadata.tags.isEmpty
                        ? "Untagged image \(image.Id.dropFirst(7).prefix(12))"
                        : metadata.tags.joined(separator: ", "),
                    parentDisplay: "Docker",
                    kind: .diskImage,
                    allocatedBytes: image.Size,
                    docker: .image(metadata)
                ))
            }
        }
        let volumes = try Self.volumeEntries(usage.Volumes ?? [], context: context)
        return DockerInventory(
            entries: entries + volumes.entries,
            unreadableCount: unreadable + volumes.unreadableCount,
            listsVolumes: usage.Volumes != nil
        )
    }

    private static func volumeEntries(_ rows: [VolumeRow], context: String) throws -> (entries: [FileEntry], unreadableCount: Int) {
        var entries: [FileEntry] = []
        var unreadable = 0
        for row in rows {
            guard isVolumeName(row.Name), let bytes = DockerScanner.parseSize(row.Size) else {
                unreadable += 1
                continue
            }
            let count = Int(row.Links).flatMap { $0 >= 0 ? $0 : nil }
            if count == nil { unreadable += 1 }
            let labels = volumeLabels(row.Labels ?? "")
            let volume = DockerVolume(
                name: row.Name, context: context, containerCount: count,
                composeProject: labels.composeProject, isAnonymous: labels.isAnonymous
            )
            entries.append(FileEntry(
                url: try itemURL(kind: "volumes", context: context, name: row.Name),
                displayName: volume.isAnonymous ? "Anonymous volume \(row.Name.prefix(12))" : row.Name,
                parentDisplay: "Docker",
                kind: .diskImage,
                allocatedBytes: bytes,
                notRegenerable: Self.volumeData,
                docker: .volume(volume)
            ))
        }
        return (entries, unreadable)
    }

    /// Docker cannot download a volume again, as it can for an image.
    static let volumeData = FileEntry.NotRegenerable(
        reason: "This volume can hold the only copy of its data, such as a database."
    )

    /// The row identity, such as `docker://volumes/<context>/<name>`. It is never a file path.
    private static func itemURL(kind: String, context: String, name: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "docker"
        components.host = kind
        components.path = "/\(context)/\(name)"
        guard let url = components.url else { throw DockerError.invalidInventory }
        return url
    }

    /// Reads the labels that `system df` prints as `key=value` pairs separated by commas.
    private static func volumeLabels(_ text: String) -> (composeProject: String?, isAnonymous: Bool) {
        var project: String?
        var anonymous = false
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first else { continue }
            if key == "com.docker.compose.project", parts.count == 2, !parts[1].isEmpty { project = String(parts[1]) }
            if key == "com.docker.volume.anonymous" { anonymous = true }
        }
        return (project, anonymous)
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
            throw DockerError.inUse
        }
        let prefix = ["--context", image.context]
        let inspectArguments = ["image", "inspect", "--format", Self.inspectFormat, "--", image.imageID]
        let data = try await run(prefix + inspectArguments)
        let current = try Self.parseInspections(data)
        guard current.count == 1, let inspected = current.first,
              inspected.Id == image.imageID, Self.tags(in: inspected) == image.tags,
              inspected.Size >= 0 else { throw DockerError.changed }
        try await requireNoContainers(prefix, filter: "ancestor=\(image.imageID)")
        let targets = image.tags.isEmpty ? [image.imageID] : image.tags
        // Preserve unselected parent images and let Docker refuse dependencies.
        _ = try await run(prefix + ["image", "rm", "--no-prune", "--"] + targets)
        try await requireAbsent(image.imageID, from: prefix + ["image", "ls", "--all", "--no-trunc", "--format", "{{.ID}}"])
        return inspected.Size
    }

    /// Rechecks the volume and its container use before permanent removal.
    func remove(_ volume: DockerVolume) async throws {
        guard !volume.context.isEmpty, Self.isVolumeName(volume.name), !volume.isRemovalLocked else {
            throw DockerError.inUse
        }
        let prefix = ["--context", volume.context]
        let data = try await run(prefix + [
            "volume", "inspect", "--format", #"{"Name":{{json .Name}},"Labels":{{json .Labels}}}"#, "--", volume.name
        ])
        let current = try String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode(VolumeInspection.self, from: Data($0.utf8))
        }
        guard current.count == 1, let inspected = current.first, inspected.Name == volume.name,
              inspected.Labels?["com.docker.compose.project"] == volume.composeProject,
              (inspected.Labels?["com.docker.volume.anonymous"] != nil) == volume.isAnonymous
        else { throw DockerError.changed }
        try await requireNoContainers(prefix, filter: "volume=\(volume.name)")
        // Without `--force`, Docker refuses a volume that a container started to use.
        _ = try await run(prefix + ["volume", "rm", "--", volume.name])
        try await requireAbsent(volume.name, from: prefix + ["volume", "ls", "--quiet"])
    }

    /// Stopped containers count too, because Docker refuses removal while any container refers to the object.
    private func requireNoContainers(_ prefix: [String], filter: String) async throws {
        let containers = try await run(prefix + ["container", "ls", "--all", "--quiet", "--filter", filter])
        guard String(decoding: containers, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw DockerError.inUse }
        try Task.checkCancellation()
    }

    private func requireAbsent(_ identifier: String, from listing: [String]) async throws {
        let remaining = try await run(listing)
        guard !String(decoding: remaining, as: UTF8.self).split(whereSeparator: \.isNewline)
            .contains(Substring(identifier)) else { throw DockerError.stillPresent }
    }

    private struct Usage: Decodable {
        let Images: [UsageRow]
        /// Absent in Docker output that does not list volumes separately.
        let Volumes: [VolumeRow]?
    }

    private struct VolumeRow: Decodable {
        let Name: String
        let Links: String
        let Size: String
        let Labels: String?
    }

    private struct VolumeInspection: Decodable {
        let Name: String
        let Labels: [String: String]?
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

    /// Docker accepts volume names that match `[a-zA-Z0-9][a-zA-Z0-9_.-]+`.
    private static func isVolumeName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }

    private static func isImageID(_ id: String) -> Bool {
        id.hasPrefix("sha256:") && id.count == 71
            && id.dropFirst(7).allSatisfy { "0123456789abcdef".contains($0) }
    }
}

enum DockerError: Error {
    case invalidInventory, emptyContext, changed, inUse, stillPresent
}
