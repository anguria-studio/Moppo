import Foundation

/// Executes reviewed tool commands without a shell or a file removal fallback.
public struct ToolCommandRemovalService: Sendable {
    typealias Run = @Sendable (ToolCommandRemoval) async throws -> ProcessResult
    private let run: Run
    private let runtimes: SimulatorRuntimeService

    public init() {
        self.init { review in
            guard let executable = review.executable else { throw ProcessError.executableMissing("removal tool") }
            return try await ProcessRunner().runResult(executable, review.arguments, timeout: review.timeout,
                environment: review.environment, allowsInput: false)
        }
    }

    init(run: @escaping Run, runtimes: SimulatorRuntimeService = SimulatorRuntimeService()) {
        self.run = run
        self.runtimes = runtimes
    }

    func remove(_ entry: FileEntry, review: ToolCommandRemoval, confirmed: ToolCommandRemoval?) async -> ToolCommandRemovalResult {
        var result = ToolCommandRemovalResult(targetID: entry.id, name: entry.displayName, command: review.command)
        if let reason = review.lockReason {
            result.failureReason = reason
            return result
        }
        guard confirmed == review, entry.url.standardizedFileURL == review.targetURL else {
            result.failureReason = "Review and confirm this command before removal."
            return result
        }
        guard review.isStillValid() else {
            result.failureReason = review.lockReason ?? "The item or removal tool changed. Scan again before removal."
            return result
        }
        let measurer = AllocatedSizeMeasurer(protectedPatterns: review.protectedPatterns)
        let before: SizeMeasurement
        let privateSize: PrivateSizeMeasurement?
        do {
            before = try await measurer.measure(review.targetURL)
            privateSize = try await PrivateSizeMeasurer().measure([review.targetURL])
            if let runtime = review.simulatorRuntime, try await !runtimes.isStillSafe(runtime) {
                result.failureReason = "The runtime or its Xcode use changed. Scan again before removal."
                return result
            }
            try Task.checkCancellation()
        } catch {
            result.status = Task.isCancelled ? .cancelled : .notStarted
            result.failureReason = "Removal stopped before the command ran."
            result.standardError = String(String(describing: error).prefix(4096))
            return result
        }
        guard before.unreadableCount == 0, !before.containsProtectedPattern, !before.containsCloudOnlyItem,
              review.isStillValid() else {
            result.failureReason = "The item changed or contains protected files. Scan again before removal."
            return result
        }
        result.beforeBytes = before.allocatedBytes
        do {
            let process = try await run(review)
            if process.terminatedBySignal { result.terminationSignal = process.exitStatus }
            else { result.exitStatus = process.exitStatus }
            result.standardError = String(process.standardError.prefix(4096))
            switch process.completion {
            case .cancelled:
                result.status = .cancelled
                result.failureReason = "The command was stopped. Some files may have been removed."
            case .timedOut:
                result.status = .timedOut
                result.failureReason = "The command reached its time limit. Some files may have been removed."
            case .exited:
                result.status = process.succeeded ? .completed : .failed
                if !process.succeeded {
                    if process.outputReadError != nil {
                        result.failureReason = "Command output could not be read. Some files may have been removed."
                    } else {
                        result.failureReason = process.terminatedBySignal
                            ? "The command stopped after a signal. Some files may have been removed."
                            : "The command failed. Some files may have been removed."
                    }
                }
            }
        } catch {
            result.status = Task.isCancelled ? .cancelled : .failed
            result.failureReason = "The command could not finish. Some files may have been removed."
            result.standardError = String(String(describing: error).prefix(4096))
        }

        // Verification finishes after cancellation so completed removals retain their results.
        let verification = await Task.detached { () -> (measurement: SizeMeasurement?, removed: Bool, failureReason: String?, error: String?) in
            let verified: Bool
            var reason: String?
            var error: String?
            if let runtime = review.simulatorRuntime {
                let state = await runtimes.verifyRemoval(runtime)
                if case .removed = state { verified = true } else { verified = false }
                reason = state.failureReason
                if case .unavailable(let detail) = state { error = detail }
            } else { verified = review.removalIsVerified() }
            if review.targetIsAbsentAfterRemoval() { return (.zero, verified, reason, error) }
            guard review.targetIsUnchangedAfterRemoval(),
                  let measured = try? await measurer.measure(review.targetURL), measured.unreadableCount == 0,
                  !measured.containsProtectedPattern, !measured.containsCloudOnlyItem,
                  review.targetIsUnchangedAfterRemoval() else { return (nil, verified, reason, error) }
            return (measured, verified, reason, error)
        }.value
        result.afterBytes = verification.measurement?.allocatedBytes
        if let runtime = review.simulatorRuntime, let bytes = result.afterBytes, bytes > 0 {
            let guidance = verification.removed
                ? SimulatorRuntimeService.retainedImageGuidance(developerDirectory: runtime.developerDirectory) : nil
            result.remainingStorageReason = ["macOS still stores the downloaded image (\(ByteFormatting.string(bytes))).", guidance]
                .compactMap { $0 }.joined(separator: "\n")
        }
        if verification.removed, review.targetIsAbsentAfterRemoval(), let privateSize, privateSize.unreportedCount == 0 {
            result.freedBytes = privateSize.privateBytes
        }
        if result.status == .completed, !verification.removed {
            result.status = .failed
            result.failureReason = verification.failureReason
                ?? "The item is still present, or Moppo could not check it. Scan again before removal."
            if let error = verification.error {
                result.standardError = String([result.standardError, error].filter { !$0.isEmpty }
                    .joined(separator: "\n").prefix(4096))
            }
        }
        return result
    }
}
