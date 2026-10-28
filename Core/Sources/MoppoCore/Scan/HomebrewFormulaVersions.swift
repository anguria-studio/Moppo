import Foundation

/// A version that Homebrew identifies as obsolete and safe for its cleanup method.
struct HomebrewFormulaVersion: Sendable, Decodable {
    let name: String
    let version: String
    let path: String
    let token: String
}

/// Reads Homebrew eligibility without including downloads or other package storage.
public struct HomebrewFormulaVersions: Sendable {
    struct Inventory: Sendable, Decodable {
        let versions: [HomebrewFormulaVersion]
        let unreadableCount: Int
    }

    typealias Run = @Sendable (String, [String]) async throws -> Data
    private let executables: @Sendable () -> [String]
    private let run: Run

    static var scriptURL: URL { Bundle.module.url(forResource: "homebrew-versions", withExtension: "rb")! }
    static let environment = HomebrewUninstallService.environment(for: [], askpassExecutable: nil).merging([
        "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_INSTALL_FROM_API": "", "HOMEBREW_DEVELOPER": "1",
    ]) { _, value in value }

    public init() {
        self.init(executables: {
            ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].filter { FileManager.default.isExecutableFile(atPath: $0) }
        }) { executable, arguments in
            try await ProcessRunner().run(executable, arguments, timeout: .seconds(30),
                environment: Self.environment, allowsInput: false)
        }
    }

    init(executables: @escaping @Sendable () -> [String], run: @escaping Run) {
        self.executables = executables
        self.run = run
    }

    func entries(context: ScanContext) async throws -> (entries: [FileEntry], unreadableCount: Int) {
        var entries: [FileEntry] = []
        var unreadable = 0
        var seen: Set<String> = []
        for executable in executables() {
            try Task.checkCancellation()
            do {
                let data = try await run(executable, ["ruby", Self.scriptURL.path, "inventory"])
                let inventory = try JSONDecoder().decode(Inventory.self, from: data)
                guard inventory.unreadableCount >= 0 else { throw CocoaError(.fileReadCorruptFile) }
                unreadable += inventory.unreadableCount
                for version in inventory.versions {
                    try Task.checkCancellation()
                    let url = URL(fileURLWithPath: version.path)
                    guard version.path.hasPrefix("/"), url.standardizedFileURL.path == version.path,
                          url.lastPathComponent == version.version,
                          url.deletingLastPathComponent().lastPathComponent == version.name,
                          version.token.count == 64, version.token.allSatisfy({ $0.isHexDigit }) else {
                        unreadable += 1
                        continue
                    }
                    guard seen.insert(FileIdentity.physicalPath(version.path)).inserted,
                          !context.isExcluded(url) else { continue }
                    let measured = try await context.measurer.measure(url)
                    unreadable += measured.unreadableCount
                    guard measured.allocatedBytes > 0, !measured.containsProtectedPattern else { continue }
                    let command = ToolCommandRemoval.homebrewVersion(version, executable: executable,
                        protectedPatterns: context.measurer.protectedPatterns)
                    entries.append(FileEntry(url: url, displayName: "\(version.name) \(version.version)", kind: .cache,
                        allocatedBytes: measured.allocatedBytes, isRegenerable: false,
                        protectionReason: measured.unreadableCount > 0 || measured.containsCloudOnlyItem ? .inventory : nil,
                        protectionExplanation: measured.unreadableCount > 0 || measured.containsCloudOnlyItem
                            ? "Moppo could not check some formula files. Scan again before removal." : command.lockReason,
                        removalMethod: .toolCommand(command)))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                unreadable += 1
            }
        }
        return (entries, unreadable)
    }
}
