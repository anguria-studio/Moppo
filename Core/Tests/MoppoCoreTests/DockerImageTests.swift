import Foundation
import Testing
@testable import MoppoCore

@Suite("Docker images")
struct DockerImageTests {
    @Test("Empty Docker categories follow Desktop installation", arguments: [false, true])
    func desktopPresence(installed: Bool) async throws {
        let scanner = DockerScanner(resolveExecutable: { nil }, resolveDesktopApplication: {
            installed ? URL(fileURLWithPath: "/Applications/Docker.app") : nil
        })
        let result = try await scanner.scan(context: ScanContext())
        #expect(result.availability == (installed
            ? .unavailable(reason: "Open Docker Desktop to finish setup, then scan again.") : .notInstalled))
        #expect(result.entries.isEmpty)
        #expect(result.totalBytes == 0)
        let emptyImages = DockerImageService(run: { arguments in
            if arguments == ["context", "show"] { return Data("fixture-context\n".utf8) }
            if arguments.contains("--verbose") { return Data("{\"Images\":[]}".utf8) }
            return Data()
        })
        let empty = try await DockerScanner(images: emptyImages, resolveDesktopApplication: {
            installed ? URL(fileURLWithPath: "/Applications/Docker.app") : nil
        }).scan(context: ScanContext())
        #expect(empty.availability == (installed ? .empty : .notInstalled))
    }

    @Test("A command without Docker Desktop keeps real results but has no setup card", arguments: [false, true])
    func commandOnly(unreachable: Bool) async throws {
        let fixture = DockerFixture(readFailure: unreachable ? Self.temporaryReadFailures[1] : nil,
            repeatedReadFailure: unreachable)
        let scanner = DockerScanner(images: DockerImageService(run: { try await fixture.run($0) }),
            resolveDesktopApplication: { nil })
        let result = try await scanner.scan(context: ScanContext())
        #expect(result.availability == (unreachable ? .notInstalled : .available))
        #expect(result.entries.isEmpty == unreachable)
    }

    @Test("An empty Docker context gets one retry", arguments: [1, 2])
    func emptyContext(emptyResponses: Int) async throws {
        let fixture = DockerFixture(emptyContexts: emptyResponses)
        let scanner = DockerScanner(images: DockerImageService(run: { try await fixture.run($0) }))
        let result = try await scanner.scan(context: ScanContext())
        #expect(await fixture.calls.filter { $0 == ["context", "show"] }.count == 2)
        if emptyResponses == 1 {
            #expect(result.availability == .available)
        } else {
            #expect(result.availability == .unavailable(reason: "Docker did not return its current context. Try scanning again."))
            #expect(result.entries.isEmpty)
        }
    }

    static let temporaryReadFailures: [ProcessError] = [
        .timedOut("docker system df"),
        .failed(command: "docker", status: 1, stderr: "Cannot connect to the Docker daemon. Is the docker daemon running?"),
        .failed(command: "docker", status: 1, stderr: "a disk usage operation is already running")
    ]

    @Test("The scan recovers from one temporary storage failure", arguments: temporaryReadFailures, [false, true])
    func firstReadFailure(error: ProcessError, verbose: Bool) async throws {
        let fixture = DockerFixture(readFailure: error, verboseReadFailure: verbose)
        let scanner = DockerScanner(images: DockerImageService(run: { try await fixture.run($0) }))
        let result = try await scanner.scan(context: ScanContext())
        #expect(result.availability == .available)
        #expect(result.entries.filter { $0.dockerImage != nil }.count == 3)
        #expect(await fixture.readAttempts == 2)
    }

    @Test("Repeated storage failures stop with an accurate reason", arguments: temporaryReadFailures + [
        .failed(command: "docker", status: 1, stderr: "unknown flag: --verbose")
    ])
    func repeatedReadFailure(error: ProcessError) async throws {
        let fixture = DockerFixture(readFailure: error, repeatedReadFailure: true)
        let result = try await DockerScanner(images: DockerImageService(run: { try await fixture.run($0) }))
            .scan(context: ScanContext())
        let reason: String
        switch error {
        case .timedOut:
            reason = "Docker did not finish the scan in time. Try scanning again."
        case .failed(_, _, let stderr) where stderr.contains("Cannot connect"):
            reason = "Start Docker Desktop, then scan again to see results."
        default:
            reason = "Docker could not read its storage information. Try scanning again."
        }
        #expect(result.availability == .unavailable(reason: reason))
        #expect(result.entries.isEmpty)
        #expect(await fixture.readAttempts == (Self.temporaryReadFailures.contains(error) ? 2 : 1))
    }

    @Test("The first storage request can take more than five seconds")
    func slowFirstRead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-docker-slow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("docker")
        try """
        #!/bin/sh
        if [ "$1" = "context" ]; then
            printf 'fixture-context\\n'
        elif [ "$3" = "system" ]; then
            if [ "$5" = "--verbose" ]; then
                printf '{"Images":[]}\\n'
            else
                /bin/sleep 6
                printf '{"Type":"Local Volumes","Reclaimable":"100B"}\\n'
            fi
        fi
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let result = try await DockerScanner(resolveExecutable: { executable.path }).scan(context: ScanContext())
        #expect(result.availability == .available)
        #expect(result.entries.map(\.displayName) == ["Local Volumes"])
        #expect(result.totalBytes == 100)
    }

    @Test("The scanner lists each image once and preserves manual storage rows")
    func imageInventory() async throws {
        let fixture = DockerFixture()
        let result = try await DockerScanner(images: DockerImageService(run: { try await fixture.run($0) })).scan(context: ScanContext())
        let images = result.entries.filter { $0.dockerImage != nil }
        #expect(images.count == 3)
        let unused = try #require(images.first { $0.dockerImage?.imageID == DockerFixture.firstID })
        #expect(unused.displayName == "fixture:latest, fixture:stable")
        #expect(unused.allocatedBytes == 200)
        #expect(unused.dockerImage?.context == "fixture-context")
        #expect(!unused.isRemovalLocked)
        #expect(unused.id == unused.url.absoluteString)
        #expect(unused.lastOpened == nil)
        #expect(unused.manualRemoval == nil)
        #expect(FileEntryPresentation(entry: unused).summary == "Docker image · Unused")
        let used = try #require(images.first { $0.dockerImage?.imageID == DockerFixture.secondID })
        #expect(used.isRemovalLocked)
        #expect(used.displayBytes == 300)
        #expect(FileEntryPresentation(entry: used).summary == "Docker image · Used by 2 containers")
        let unknown = try #require(images.first { $0.dockerImage?.imageID == DockerFixture.thirdID })
        #expect(unknown.displayName.hasPrefix("Untagged image"))
        #expect(unknown.isRemovalLocked)
        #expect(result.unreadableCount == 1)
        #expect(result.entries.filter { $0.manualRemoval != nil }.map(\.displayName) == ["Local Volumes"])
        #expect(result.totalBytes == 604)
        #expect(result.safeToRemoveBytes == 0)
        #expect(result.needsReviewBytes == result.totalBytes)
        #expect(await fixture.calls.filter { $0.contains("inspect") }.count == 1)
    }

    @Test("Docker removal bypasses files and records a permanent result", arguments: [false, true])
    func imageRemoval(keepReceipt: Bool) async throws {
        let fixture = DockerFixture()
        let service = DockerImageService(run: { try await fixture.run($0) })
        let inventory = try await service.images(context: "fixture-context")
        let image = try #require(inventory.entries.first { $0.dockerImage?.imageID == DockerFixture.firstID })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-docker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = RemovalLog(directory: folder)
        let cleanup = CleanupService(measureSize: { _ in
            Issue.record("Docker removal must not measure a filesystem path.")
            return SizeMeasurement(allocatedBytes: 0)
        }, log: log, dockerImages: service)
        let result = try await cleanup.remove(entries: [image], trashFirst: true, keepReceipt: keepReceipt)
        #expect(result.removedCount == 1)
        #expect(result.deletedCount == 1)
        #expect(result.trashedCount == 0)
        #expect(result.removedBytes == 200)
        #expect(result.freedBytes == 0)
        #expect(result.unreportedFreedCount == 1)
        #expect(result.failed.isEmpty)
        let removal = try #require(await fixture.calls.first { $0.contains("rm") })
        #expect(removal == ["--context", "fixture-context", "image", "rm", "--no-prune", "--", "fixture:latest", "fixture:stable"])
        let records = log.recentEntries()
        #expect(records.count == (keepReceipt ? 1 : 0))
        if keepReceipt {
            #expect(records.first?.disposition == .deleted)
            #expect(records.first?.trashedPath == nil)
            let history = CleanupHistoryService(log: log).summary()
            #expect(history.items.first?.name == image.displayName)
            #expect(history.items.first?.originalURL.scheme == "docker")
            #expect(history.items.first?.state == .removedPermanently)
            #expect(history.availableInTrashCount == 0)
            #expect(history.freedBytes == 0)
        }
    }

    @Test("Removal rechecks dependencies and tags and reports Docker failures", arguments: DockerFixture.Failure.allCases)
    fileprivate func failedRemoval(failure: DockerFixture.Failure) async throws {
        let fixture = DockerFixture(failure: failure)
        let image = FileEntry(
            url: URL(string: "docker://images/fixture-context/\(DockerFixture.firstID)")!,
            kind: .diskImage, allocatedBytes: 200,
            dockerImage: DockerImage(
                imageID: DockerFixture.firstID, context: "fixture-context",
                tags: ["fixture:latest", "fixture:stable"], containerCount: 0
            )
        )
        let result = try await CleanupService(dockerImages: DockerImageService(run: { try await fixture.run($0) }))
            .remove(entries: [image], trashFirst: true, keepReceipt: false)
        #expect(result.failed == [image.id])
        #expect(result.removedCount == 0)
        #expect(result.deletedCount == 0)
        let commands = await fixture.calls
        if failure == .containerAppeared || failure == .tagsChanged {
            #expect(!commands.contains { $0.contains("rm") })
        }
        if failure == .daemonFailure {
            #expect(commands.filter { $0.contains("rm") }.count == 1)
        }
        #expect(!commands.contains { $0.contains("--force") || $0.contains("prune") })
    }

    @Test("An untagged image is removed by its full identifier")
    func untaggedImage() async throws {
        let fixture = DockerFixture(untagged: true)
        let metadata = DockerImage(imageID: DockerFixture.firstID, context: "fixture-context", tags: [], containerCount: 0)
        _ = try await DockerImageService(run: { try await fixture.run($0) }).remove(metadata)
        #expect(await fixture.calls.contains([
            "--context", "fixture-context", "image", "rm", "--no-prune", "--", DockerFixture.firstID
        ]))
    }

    @Test("Images with known or unknown container use cannot bypass the service gate", arguments: [2, nil] as [Int?])
    func lockedImages(containerCount: Int?) async throws {
        let fixture = DockerFixture()
        let entry = FileEntry(
            url: URL(string: "docker://images/fixture-context/\(DockerFixture.firstID)")!,
            kind: .diskImage, allocatedBytes: 200,
            dockerImage: DockerImage(imageID: DockerFixture.firstID, context: "fixture-context", tags: [], containerCount: containerCount)
        )
        let result = try await CleanupService(dockerImages: DockerImageService(run: { try await fixture.run($0) }))
            .remove(entries: [entry], trashFirst: true, keepReceipt: false, userDataRemovalOverrides: [entry.id])
        #expect(result.failed == [entry.id])
        #expect(await fixture.calls.isEmpty)
    }
}

private actor DockerFixture {
    enum Failure: CaseIterable { case containerAppeared, tagsChanged, daemonFailure, imageStillPresent }
    static let firstID = "sha256:" + String(repeating: "a", count: 64)
    static let secondID = "sha256:" + String(repeating: "b", count: 64)
    static let thirdID = "sha256:" + String(repeating: "c", count: 64)
    private let failure: Failure?
    private let untagged: Bool
    private let readFailure: ProcessError?
    private let repeatedReadFailure: Bool
    private let verboseReadFailure: Bool
    private var emptyContexts: Int
    private var removed = false
    private(set) var calls: [[String]] = []
    private(set) var readAttempts = 0

    init(
        failure: Failure? = nil, untagged: Bool = false, readFailure: ProcessError? = nil,
        repeatedReadFailure: Bool = false, verboseReadFailure: Bool = false, emptyContexts: Int = 0
    ) {
        self.failure = failure
        self.untagged = untagged
        self.readFailure = readFailure
        self.repeatedReadFailure = repeatedReadFailure
        self.verboseReadFailure = verboseReadFailure
        self.emptyContexts = emptyContexts
    }

    func run(_ arguments: [String]) throws -> Data {
        calls.append(arguments)
        if arguments == ["context", "show"] {
            if emptyContexts > 0 { emptyContexts -= 1; return Data(" \n".utf8) }
            return Data("fixture-context\n".utf8)
        }
        #expect(Array(arguments.prefix(2)) == ["--context", "fixture-context"])
        let command = Array(arguments.dropFirst(2))
        if command.starts(with: ["system", "df"]) {
            if let readFailure, command.contains("--verbose") == verboseReadFailure {
                readAttempts += 1
                if readAttempts == 1 || repeatedReadFailure { throw readFailure }
            }
            if command.contains("--verbose") {
                return try JSONSerialization.data(withJSONObject: ["Images": [
                    ["ID": Self.firstID, "Containers": "0"], ["ID": Self.secondID, "Containers": "2"]
                ]])
            }
            return Data("{\"Type\":\"Images\",\"Reclaimable\":\"999GB\"}\n{\"Type\":\"Local Volumes\",\"Reclaimable\":\"100B\"}\n".utf8)
        }
        if command.starts(with: ["image", "ls"]) {
            return Data(((removed ? [] : [Self.firstID, Self.firstID]) + [Self.secondID, Self.thirdID])
                .joined(separator: "\n").utf8)
        }
        if command.starts(with: ["image", "inspect"]) {
            let ids = command.drop { $0 != "--" }.dropFirst()
            let rows = try ids.map { id in
                let tags = id == Self.firstID ? (untagged ? [] : failure == .tagsChanged
                    ? ["changed:latest"] : ["fixture:stable", "fixture:latest"]) : []
                return String(decoding: try JSONSerialization.data(withJSONObject: [
                    "Id": id, "RepoTags": tags, "Size": id == Self.firstID ? 200 : id == Self.secondID ? 300 : 4
                ] as [String: Any]), as: UTF8.self)
            }
            return Data(rows.joined(separator: "\n").utf8)
        }
        if command.starts(with: ["container", "ls"]) {
            #expect(command.last == "ancestor=\(Self.firstID)")
            return Data((failure == .containerAppeared ? "new-container\n" : "").utf8)
        }
        if command.starts(with: ["image", "rm"]) {
            if failure == .daemonFailure {
                throw ProcessError.failed(command: "docker", status: 1, stderr: "Docker stopped")
            }
            if failure != .imageStillPresent { removed = true }
            return Data()
        }
        Issue.record("Unexpected Docker command: \(arguments)")
        throw DockerImageError.invalidInventory
    }
}
