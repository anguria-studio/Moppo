import Foundation
import Testing
import MoppoCore

@Suite("Administrator sound library approval")
struct AdministratorTrashServiceTests {
    @Test("Cancellation leaves content in place and reports no completed move")
    func cancellation() async throws {
        let folder = try TemporaryFolder()
        let source = try folder.write("Source")
        let request = try AdministratorTrashRequest(source: source, destination: folder.url.appendingPathComponent("Trash"),
                                                    identity: #require(FileIdentity.of(source)))
        let service = AdministratorTrashService(helperURL: URL(fileURLWithPath: "/usr/bin/true"),
                                               runScript: { _ in Data("error:-128\n".utf8) })
        await #expect(throws: AdministratorTrashError.cancelled) { try await service.perform(request) }
        #expect(!FileIdentity.isAbsent(source))
        #expect(FileIdentity.isAbsent(request.destination))
    }

    @Test("Completed moves survive caller cancellation and an interrupted reply")
    func completedMove() async throws {
        let folder = try TemporaryFolder()
        let source = try folder.write("Source ' \"quoted\" $(name)\n")
        let request = try AdministratorTrashRequest(source: source, destination: folder.url.appendingPathComponent("Trash"),
                                                    identity: #require(FileIdentity.of(source)))
        let gate = TestGate()
        let service = AdministratorTrashService(helperURL: URL(fileURLWithPath: "/usr/bin/true"), runScript: { arguments in
            #expect(Array(arguments.prefix(3)) == ["-e", AdministratorTrashService.script, "/usr/bin/true"])
            let received = try AdministratorTrashRequest.read(from: arguments[3])
            #expect(received.source == source)
            await gate.wait()
            try FileManager.default.moveItem(at: received.source, to: received.destination)
            throw CocoaError(.fileReadUnknown)
        })
        let task = Task { try await service.perform(request) }
        try await waitUntil { await gate.isPending }
        task.cancel()
        await gate.finish()
        try await task.value
        #expect(FileIdentity.of(request.destination) == request.identity)
    }

    @Test("A success reply without a matching move cannot report success")
    func falseReply() async throws {
        let folder = try TemporaryFolder()
        let source = try folder.write("Source")
        let request = try AdministratorTrashRequest(source: source, destination: folder.url.appendingPathComponent("Trash"),
                                                    identity: #require(FileIdentity.of(source)))
        let service = AdministratorTrashService(helperURL: URL(fileURLWithPath: "/usr/bin/true"),
                                               runScript: { _ in Data("moved".utf8) })
        await #expect(throws: AdministratorTrashError.invalidRequest) { try await service.perform(request) }
        #expect(!FileIdentity.isAbsent(source))
    }

    @Test("The approval script compiles without requesting privileges")
    func scriptCompiles() async throws {
        let folder = try TemporaryFolder()
        try await ProcessRunner().run("/usr/bin/osacompile", ["-o", folder.url.appendingPathComponent("Approve.scpt").path,
                                     "-e", AdministratorTrashService.script], allowsInput: false)
    }
}
