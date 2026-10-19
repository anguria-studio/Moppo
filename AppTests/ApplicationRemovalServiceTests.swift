import Foundation
import Testing
import MoppoCore

@Suite("Permanent application removal")
struct ApplicationRemovalServiceTests {
    @Test("The authorized command deletes only the reviewed application", arguments: [false, true])
    func identityAfterAuthorization(replaced: Bool) async throws {
        let folder = try TemporaryFolder()
        let source = folder.url.appendingPathComponent("A \"quoted\" app's $(name)\n.app").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let saved = folder.url.appendingPathComponent("Saved.app")
        let unrelated = try folder.write("Keep.txt")
        let service = ApplicationRemovalService(runScript: { arguments in
            #expect(Array(arguments.prefix(3)) == ["-e", ApplicationRemovalService.script, source.path])
            #expect(arguments.count == 5)
            if replaced {
                try FileManager.default.moveItem(at: source, to: saved)
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            }
            try await ProcessRunner().run("/bin/sh", ["-c", arguments[4], "--", arguments[2], arguments[3]], allowsInput: false)
            return Data("deleted\n".utf8)
        })
        if replaced {
            await #expect(throws: (any Error).self) { try await service.removePermanently(source) { true } }
            #expect(FileIdentity.of(source) != nil)
            #expect(FileIdentity.of(saved) != nil)
        } else {
            try await service.removePermanently(source) { true }
            #expect(FileIdentity.isAbsent(source))
        }
        #expect(FileIdentity.of(unrelated) != nil)
    }

    @Test("A rejected safety check never starts authorization")
    func stalePlan() async throws {
        let folder = try TemporaryFolder()
        let source = try folder.write("Reviewed.app")
        let service = ApplicationRemovalService(runScript: { _ in
            Issue.record("A rejected plan must not start authorization.")
            return Data()
        })
        await #expect(throws: CocoaError.self) { try await service.removePermanently(source) { false } }
        #expect(FileIdentity.of(source) != nil)
    }

    @Test("Cancellation and an unverified reply cannot report deletion", arguments: ["error:-128", "deleted", "error:1"])
    func failedReply(reply: String) async throws {
        let folder = try TemporaryFolder()
        let source = try folder.write("Reviewed.app").resolvingSymlinksInPath()
        let service = ApplicationRemovalService(runScript: { _ in Data(reply.utf8) })
        if reply == "error:-128" {
            await #expect(throws: ApplicationRemovalError.cancelled) { try await service.removePermanently(source) { true } }
        } else {
            await #expect(throws: CocoaError.self) { try await service.removePermanently(source) { true } }
        }
        #expect(FileIdentity.of(source) != nil)
    }

    @Test("A completed deletion survives caller cancellation")
    func cancellationAfterStart() async throws {
        let folder = try TemporaryFolder()
        let source = try folder.write("Reviewed.app").resolvingSymlinksInPath()
        let gate = TestGate()
        let service = ApplicationRemovalService(runScript: { _ in
            await gate.wait()
            try FileManager.default.removeItem(at: source)
            return Data("deleted".utf8)
        })
        let task = Task { try await service.removePermanently(source) { true } }
        try await waitUntil { await gate.isPending }
        task.cancel()
        await gate.finish()
        try await task.value
        #expect(FileIdentity.isAbsent(source))
    }

    @Test("The authorization script compiles without removing files")
    func scriptCompiles() async throws {
        let folder = try TemporaryFolder()
        try await ProcessRunner().run("/usr/bin/osacompile", [
            "-o", folder.url.appendingPathComponent("Remove.scpt").path, "-e", ApplicationRemovalService.script
        ], allowsInput: false)
    }
}
