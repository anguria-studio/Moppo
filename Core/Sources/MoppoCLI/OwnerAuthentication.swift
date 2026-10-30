import Foundation
import LocalAuthentication

/// Asks macOS to authenticate the Mac user with Touch ID, a watch, or the login password.
/// A shell process cannot answer this system dialog.
public enum OwnerAuthentication {
    public static let unavailable = CLIError(79, "authentication_unavailable",
        "Permanent removal requires authentication by the Mac user. Run this command in a local session. No targets were removed.")

    private final class Context: @unchecked Sendable {
        let value = LAContext()
    }

    /// Returns false when the user cancels or authentication fails.
    public static func authenticate(_ reason: String) async throws -> Bool {
        let context = Context()
        var failure: NSError?
        guard context.value.canEvaluatePolicy(.deviceOwnerAuthentication, error: &failure) else { throw unavailable }
        do {
            return try await withTaskCancellationHandler {
                try await context.value.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } onCancel: {
                context.value.invalidate()
            }
        } catch let error as LAError {
            try Task.checkCancellation()
            switch error.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback, .authenticationFailed: return false
            default: throw unavailable
            }
        }
    }
}
