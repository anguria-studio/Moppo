import Foundation
import Testing
@testable import MoppoCore

/// Runs Git for a test fixture and expects success.
func runGit(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

extension DocumentsFilesScanner {
    /// Reads project dates one day after the idle period, so new fixture files count as idle.
    ///
    /// Without `readsGit`, the scanner does not start Git. Tests that run in parallel then
    /// cannot get an unknown project state from a slow Git process.
    static func afterIdlePeriod(home: URL, readsGit: Bool = false) -> DocumentsFilesScanner {
        let clock: @Sendable () -> Date = { Date().addingTimeInterval(ProjectActivity.idlePeriod + 24 * 60 * 60) }
        let reader = readsGit
            ? ProjectActivityReader(clock: clock)
            : ProjectActivityReader(clock: clock, gitExecutable: { nil })
        return DocumentsFilesScanner(home: home, projectActivity: reader)
    }
}

/// Writes a launchd job file with only the keys that connect it to an application.
/// `associated` is a `String` or a `[String]`, as both forms occur.
@discardableResult
func writeLaunchItem(at url: URL, program: String, associated: Any? = nil) throws -> URL {
    var plist: [String: Any] = [
        "Label": url.deletingPathExtension().lastPathComponent,
        "ProgramArguments": [program, "--service"],
    ]
    if let associated { plist["AssociatedBundleIdentifiers"] = associated }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    return url
}
