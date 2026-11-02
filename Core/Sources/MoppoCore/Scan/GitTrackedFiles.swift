import Foundation

/// Whether Git tracks files in a folder.
///
/// Removal of a folder with tracked files can delete committed code. Thus each
/// result that is not `untracked` keeps the folder protected.
public enum GitTrackedFiles: Sendable, Equatable {
    /// Git tracks no file in the folder, or no repository contains the folder.
    case untracked
    /// Git tracks one or more files in the folder.
    case tracked
    /// Git is not available, or the check failed or timed out.
    case unknown
}

/// Runs `git ls-files` for one folder.
///
/// The reader does not call `/usr/bin/git`. On a Mac without the Command Line Tools,
/// that file opens the installer dialog. `GitWorktreeDetector.executable()` finds a
/// real Git binary.
public struct GitTrackedFilesReader: Sendable {

    private let gitExecutable: @Sendable () async throws -> String?
    private let timeout: Duration

    public init() {
        self.init(gitExecutable: { try await GitWorktreeDetector.executable() })
    }

    init(
        gitExecutable: @escaping @Sendable () async throws -> String?,
        timeout: Duration = .seconds(10)
    ) {
        self.gitExecutable = gitExecutable
        self.timeout = timeout
    }

    /// Git runs in the parent folder. If the folder is a submodule, the parent
    /// repository then reports the folder itself as a tracked entry.
    public func state(of folder: URL) async throws -> GitTrackedFiles {
        let folder = folder.standardizedFileURL
        guard let git = try await gitExecutable() else { return .unknown }
        let result: ProcessResult
        do {
            result = try await ProcessRunner().runResult(
                git, [
                    "--no-optional-locks", "--literal-pathspecs", "-C", folder.deletingLastPathComponent().path,
                    "ls-files", "-z", "--", folder.lastPathComponent
                ],
                timeout: timeout,
                environment: [
                    "GIT_TERMINAL_PROMPT": "0",
                    "GIT_OPTIONAL_LOCKS": "0",
                    // Git writes the "not a git repository" message in English.
                    "LC_ALL": "C"
                ],
                allowsInput: false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unknown
        }
        if result.completion == .cancelled { throw CancellationError() }
        guard result.completion == .exited, !result.terminatedBySignal, result.outputReadError == nil else {
            return .unknown
        }
        guard result.exitStatus == 0 else {
            // Exit status 128 is "not a git repository". Other failures are unknown.
            return result.exitStatus == 128 && result.standardError.contains("not a git repository")
                ? .untracked : .unknown
        }
        return result.output.isEmpty ? .untracked : .tracked
    }
}
