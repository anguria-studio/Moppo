import Foundation

extension FileEntry {
    static func simulatorRuntimeDownload(url: URL, version: String?, build: String?, allocatedBytes: Int64,
                                         runtimeRegistrationKnown: Bool, removalGuidance: String? = nil) -> FileEntry {
        let explanation = runtimeRegistrationKnown
            ? "macOS stores this download without an installed runtime. Moppo cannot remove it safely."
            : "macOS manages this download. Moppo cannot verify whether an installed runtime uses it."
        return FileEntry(url: url,
            displayName: "Simulator Runtime Download \(version ?? "Unknown version") (\(build ?? "Unknown build"))",
            kind: .diskImage, allocatedBytes: allocatedBytes, protectionReason: .inventory,
            protectionExplanation: [explanation, runtimeRegistrationKnown ? removalGuidance : nil]
                .compactMap { $0 }.joined(separator: " "), safetyCaveat: "macOS manages this download.")
    }

    /// Keeps retained download storage visible after successful runtime removal.
    public func retainedSimulatorDownload(after result: ToolCommandRemovalResult) -> FileEntry? {
        guard result.targetID == id, result.status == .completed,
              let bytes = result.afterBytes, bytes > 0,
              let review = toolCommand?.simulatorRuntime else { return nil }
        let runtime = review.runtime
        return .simulatorRuntimeDownload(url: url, version: runtime.version, build: runtime.build,
            allocatedBytes: bytes, runtimeRegistrationKnown: true,
            removalGuidance: SimulatorRuntimeService.retainedImageGuidance(developerDirectory: review.developerDirectory))
    }
}
