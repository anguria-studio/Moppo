import Foundation

/// Executes reviewed tool commands without a shell or a file removal fallback.
public struct ToolCommandRemovalService: Sendable {
    typealias Run = @Sendable (ToolCommandRemoval) async throws -> ProcessResult
    private let run: Run

    public init() {
        self.init { review in
            guard let executable = review.executable else { throw ProcessError.executableMissing("go") }
            return try await ProcessRunner().runResult(executable, review.arguments, timeout: review.timeout,
                environment: review.environment, allowsInput: false)
        }
    }

    init(run: @escaping Run) { self.run = run }

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
            result.failureReason = review.lockReason ?? "The cache or removal tool changed. Scan again before removal."
            return result
        }
        let measurer = AllocatedSizeMeasurer(protectedPatterns: review.protectedPatterns)
        let before: SizeMeasurement
        let privateSize: PrivateSizeMeasurement?
        do {
            before = try await measurer.measure(review.targetURL)
            privateSize = try await PrivateSizeMeasurer().measure([review.targetURL])
            try Task.checkCancellation()
        } catch {
            result.status = Task.isCancelled ? .cancelled : .notStarted
            result.failureReason = "Removal stopped before the command ran."
            return result
        }
        guard before.unreadableCount == 0, !before.containsProtectedPattern, !before.containsCloudOnlyItem,
              review.isStillValid() else {
            result.failureReason = "The cache changed or contains protected files. Scan again before removal."
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
        let after = await Task.detached { () -> SizeMeasurement? in
            if review.targetIsAbsentAfterRemoval() { return .zero }
            guard review.targetIsUnchangedAfterRemoval(),
                  let measured = try? await measurer.measure(review.targetURL), measured.unreadableCount == 0,
                  !measured.containsProtectedPattern, !measured.containsCloudOnlyItem,
                  review.targetIsUnchangedAfterRemoval() else { return nil }
            return measured
        }.value
        result.afterBytes = after?.allocatedBytes
        if review.targetIsAbsentAfterRemoval(), let privateSize, privateSize.unreportedCount == 0 {
            result.freedBytes = privateSize.privateBytes
        }
        if result.status == .completed, !review.removalIsVerified() {
            result.status = .failed
            result.failureReason = "The cache is still present or could not be checked. Scan again before removal."
        }
        return result
    }
}
