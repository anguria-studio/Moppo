import Foundation

/// A Homebrew result stays separate from a move to the Trash.
public struct HomebrewUninstallOutcome: Sendable, Equatable {
    public enum Status: Sendable {
        case completed
        case notStarted
        case incomplete
    }

    public let status: Status
    public let message: String
    public var localizedMessage: String { EngineText.rule(message).localized }
    private let detailsText: EngineText?
    public var details: String? { detailsText?.english }
    public var localizedDetails: String? { detailsText?.localized }
    public let applicationRemoved: Bool
    public let relatedCleanup: CleanupOutcome

    public init(
        status: Status, message: String, details: String? = nil,
        applicationRemoved: Bool = false, relatedCleanup: CleanupOutcome = CleanupOutcome()
    ) {
        self.init(status: status, message: message, detailsText: details.map(EngineText.verbatim),
                  applicationRemoved: applicationRemoved, relatedCleanup: relatedCleanup)
    }

    init(status: Status, message: String, detailsText: EngineText?,
         applicationRemoved: Bool = false, relatedCleanup: CleanupOutcome = CleanupOutcome()) {
        self.status = status
        self.message = message
        self.detailsText = detailsText
        self.applicationRemoved = applicationRemoved
        self.relatedCleanup = relatedCleanup
    }
}

/// Homebrew removes its package. Moppo then moves the planned related data to the Trash.
public struct HomebrewUninstallService: Sendable {
    typealias Run = @Sendable (String, [String]) async throws -> Data
    private let run: Run
    private let log: RemovalLog
    private let askpassExecutable: String?
    private let cleanupService: CleanupService

    public init(log: RemovalLog = RemovalLog(), askpassExecutable: String? = nil, askpassLanguage: String? = nil) {
        self.init(log: log, askpassExecutable: askpassExecutable) { executable, arguments in
            try await ProcessRunner().run(
                executable, arguments,
                timeout: arguments.first == "uninstall" ? .seconds(300) : .seconds(20),
                environment: Self.environment(for: arguments, askpassExecutable: askpassExecutable, askpassLanguage: askpassLanguage),
                allowsInput: false
            )
        }
    }

    init(
        log: RemovalLog, askpassExecutable: String? = nil,
        cleanupService: CleanupService? = nil, run: @escaping Run
    ) {
        self.log = log
        self.run = run
        self.askpassExecutable = askpassExecutable
        self.cleanupService = cleanupService ?? CleanupService(log: log)
    }

    static func environment(
        for arguments: [String], askpassExecutable: String?, askpassLanguage: String? = nil
    ) -> [String: String] {
        var environment = [
            "NONINTERACTIVE": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_AUTOREMOVE": "1",
            "HOMEBREW_NO_COLOR": "1",
            "SUDO_ASKPASS": "/usr/bin/false",
            // Homebrew removes custom variables unless their names start with HOMEBREW_.
            "HOMEBREW_MOPPO_APP_PID": "",
            "HOMEBREW_MOPPO_CASK": "",
            "HOMEBREW_MOPPO_LANGUAGE": "",
            "HOMEBREW_MOPPO_AUTH_DEADLINE": "",
        ]
        if arguments.count == 3, arguments[0] == "uninstall", arguments[1] == "--cask",
           let askpassExecutable {
            environment["SUDO_ASKPASS"] = askpassExecutable
            environment["HOMEBREW_MOPPO_APP_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            environment["HOMEBREW_MOPPO_CASK"] = arguments[2]
            environment["HOMEBREW_MOPPO_LANGUAGE"] = askpassLanguage ?? ""
            // Close an unanswered prompt before the command reaches its time limit.
            environment["HOMEBREW_MOPPO_AUTH_DEADLINE"] = String(Date().addingTimeInterval(290).timeIntervalSince1970)
        }
        return environment
    }

    public func uninstall(
        _ plan: AppUninstallPlan, keepReceipt: Bool = true, runID: UUID = UUID()
    ) async -> HomebrewUninstallOutcome {
        guard let package = plan.managedPackage,
              ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains(package.executable)
        else {
            return .init(status: .notStarted, message: "Review this application again before removal.")
        }

        if let askpassExecutable, !FileManager.default.isExecutableFile(atPath: askpassExecutable) {
            return .init(status: .notStarted, message: "The Homebrew password helper is missing. Install Moppo again before removal.")
        }

        do {
            try Task.checkCancellation()
            let catalog = try await run(package.executable, ["info", "--json=v2", "--installed"])
            guard try AppUninstallPlanner.homebrewPackage(
                in: catalog, managing: plan.applicationURL, executable: package.executable
            ) == package,
                let identity = plan.applicationItem.plannedIdentity,
                FileIdentity.of(plan.applicationURL) == identity,
                AppUninstallPlanner.removalIsStillSafe(plan.applicationItem, in: plan, exclusiveBundleIdentifiers: [])
            else {
                return .init(status: .notStarted, message: "The application or Homebrew ownership changed. Review the application again.")
            }
            try Task.checkCancellation()
        } catch {
            return .init(
                status: .notStarted,
                message: "Moppo could not verify Homebrew ownership. No removal command was run.",
                detailsText: Self.errorDetail(error)
            )
        }

        var commandError: EngineText?
        do {
            _ = try await run(package.executable, ["uninstall", "--cask", package.name])
        } catch {
            commandError = Self.errorDetail(error)
        }

        // Verification must finish even if the caller was cancelled during removal.
        let run = self.run
        let verification = await Task.detached { () -> Result<Bool, Error> in
            do {
                let data = try await run(package.executable, ["info", "--json=v2", "--installed"])
                struct Catalog: Decodable {
                    struct Cask: Decodable { let token: String }
                    let casks: [Cask]
                }
                let catalog = try JSONDecoder().decode(Catalog.self, from: data)
                return .success(!catalog.casks.contains { $0.token == package.name })
            } catch {
                return .failure(error)
            }
        }.value

        // An inaccessible path does not prove that the application was removed.
        let removed: Bool
        do {
            _ = try plan.applicationURL.resourceValues(forKeys: [.isDirectoryKey])
            removed = false
        } catch let error as NSError {
            removed = error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        }

        if keepReceipt {
            try? log.append([RemovalRecord(
                timestamp: .now, originalPath: plan.applicationURL.path,
                bytes: plan.applicationItem.allocatedBytes, disposition: removed ? .deleted : .failed
            )], runID: runID)
        }

        switch verification {
        case .success(true) where removed && commandError == nil:
            let related = await cleanupService.removeRelatedFilesAfterHomebrew(
                plan, keepReceipt: keepReceipt, runID: runID
            )
            return .init(
                status: .completed,
                message: related.failed.isEmpty
                    ? "Homebrew removed the package. Related data cleanup is complete."
                    : "Homebrew removed the package. Moppo could not move some related data to the Trash.",
                applicationRemoved: true, relatedCleanup: related
            )
        case .success(let packageRemoved):
            let state: String
            if commandError?.english == Self.authenticationCancelled {
                state = "Administrator authentication was cancelled. Homebrew removal may be incomplete."
            } else if removed {
                state = "The application was removed. Homebrew removal is incomplete."
            } else if packageRemoved {
                state = "Homebrew removed its package record, but the application remains."
            } else {
                state = "Homebrew could not finish removal. Some files may have changed."
            }
            return .init(
                status: .incomplete, message: state, detailsText: commandError,
                applicationRemoved: removed
            )
        case .failure(let error):
            let details = [commandError, Self.errorDetail(error)].compactMap { $0 }
            let english = details.map(\.english).joined(separator: "\n")
            let localized = details.map(\.localized).joined(separator: "\n")
            return .init(
                status: .incomplete,
                message: "Moppo could not verify the Homebrew result. Some files may have changed.",
                detailsText: EngineText(english: english, display: "\(localized)"),
                applicationRemoved: removed
            )
        }
    }

    private static func errorDetail(_ error: Error) -> EngineText {
        if error is CancellationError { return "The Homebrew command was interrupted." }
        if let error = error as? ProcessError {
            switch error {
            case .executableMissing:
                return "The Homebrew executable is unavailable."
            case .timedOut:
                return "The Homebrew command exceeded its time limit."
            case .failed(_, let status, let stderr):
                if stderr.contains(Self.authenticationCancelled) { return .rule(Self.authenticationCancelled) }
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "Homebrew exited with status \(status)." : .verbatim(String(detail.suffix(4_000)))
            }
        }
        return .verbatim(error.localizedDescription)
    }

    private static let authenticationCancelled = "Moppo: administrator authentication was cancelled."
}
