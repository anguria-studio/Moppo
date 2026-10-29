import Foundation
import MoppoCore

/// Requests macOS approval for one restorable sound library move.
struct AdministratorTrashService: Sendable {
    var helperURL: URL? = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MoppoAdministratorTrash")
    var runScript: @Sendable ([String]) async throws -> Data = { arguments in
        try await ProcessRunner().run("/usr/bin/osascript", arguments, timeout: .seconds(310), allowsInput: false)
    }

    func trash(_ inventory: AppleSoundLibrary.Inventory) async throws -> URL {
        guard AdministratorTrashRequest.canRetry(inventory), let identity = FileIdentity.of(inventory.url) else {
            throw AdministratorTrashError.invalidRequest
        }
        let trash = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().appendingPathComponent(".Trash")
        let destination = trash.appendingPathComponent(inventory.url.lastPathComponent + " " + UUID().uuidString)
        let request = try AdministratorTrashRequest(source: inventory.url, destination: destination,
                                                    identity: identity, inventory: inventory)
        try await perform(request)
        return destination
    }

    func restore(_ source: URL, to destination: URL, identity: String) async throws {
        guard AdministratorTrashRequest.canRestore(to: destination) else { throw CocoaError(.fileWriteNoPermission) }
        try await perform(AdministratorTrashRequest(source: source, destination: destination, identity: identity))
    }

    func perform(_ request: AdministratorTrashRequest) async throws {
        try Task.checkCancellation()
        guard let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw AdministratorTrashError.invalidRequest
        }
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("moppo-administrator-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // Keep the result after approval starts so caller cancellation cannot discard a completed move.
        let reply = await Task.detached {
            try await runScript(["-e", Self.script, helperURL.path, file.path])
        }.result
        if FileIdentity.isAbsent(request.source), FileIdentity.of(request.destination) == request.identity { return }
        if case .success(let output) = reply,
           String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "error:-128" {
            throw AdministratorTrashError.cancelled
        }
        throw AdministratorTrashError.invalidRequest
    }

    static let script = """
    on run arguments
        try
            set helperPath to item 1 of arguments
            set requestPath to item 2 of arguments
            set commandText to quoted form of helperPath & " " & quoted form of requestPath
            with timeout of 300 seconds
                do shell script commandText with administrator privileges
            end timeout
            return "moved"
        on error errorMessage number errorNumber
            return "error:" & (errorNumber as text)
        end try
    end run
    """
}
