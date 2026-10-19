import Foundation
import MoppoCore

/// Runs only after the user confirms permanent application removal.
struct ApplicationRemovalService: Sendable {
    var runScript: @Sendable ([String]) async throws -> Data = { arguments in
        try await ProcessRunner().run("/usr/bin/osascript", arguments, timeout: .seconds(310), allowsInput: false)
    }

    func removePermanently(_ url: URL, stillMatches: @escaping @Sendable () -> Bool) async throws {
        try Task.checkCancellation()
        let source = url.standardizedFileURL
        guard source.pathExtension.lowercased() == "app", stillMatches(),
              source.resolvingSymlinksInPath() == source,
              let identity = FileIdentity.of(source) else { throw CocoaError(.fileWriteUnknown) }
        // Keep the result after authorization starts so cancellation cannot discard a deletion receipt.
        let output = try await Task.detached {
            try await runScript(["-e", Self.script, source.path, identity, Self.removalCommand])
        }.value
        let reply = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
        if reply == "error:-128" { throw ApplicationRemovalError.cancelled }
        guard reply == "deleted", FileIdentity.isAbsent(URL(fileURLWithPath: source.path)) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // Authorization precedes these checks. Paths are positional arguments, never executable shell text.
    static let removalCommand = """
    target="$1"
    expected="$2"
    case "$target" in /*.[aA][pP][pP]) ;; *) exit 64 ;; esac
    [ -d "$target" ] && [ ! -L "$target" ] || exit 64
    parent=$(/usr/bin/dirname "$target") || exit 64
    leaf=$(/usr/bin/basename "$target") || exit 64
    cd -P "$parent" || exit 64
    actual=$(/usr/bin/stat -f '%d:%i' "$leaf") || exit 66
    [ "$actual" = "$expected" ] || exit 66
    /bin/rm -rf -- "./$leaf"
    """

    static let script = """
    on run arguments
        try
            set targetPath to item 1 of arguments
            set expectedIdentity to item 2 of arguments
            set removalCommand to item 3 of arguments
            set commandText to "/bin/sh -c " & quoted form of removalCommand & " -- " & quoted form of targetPath & " " & quoted form of expectedIdentity
            with timeout of 300 seconds
                do shell script commandText with administrator privileges
            end timeout
            return "deleted"
        on error errorMessage number errorNumber
            return "error:" & (errorNumber as text)
        end try
    end run
    """
}
