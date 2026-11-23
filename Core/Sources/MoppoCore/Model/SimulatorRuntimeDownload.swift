import Foundation

extension FileEntry {
    static func simulatorRuntimeDownload(url: URL, version: String?, build: String?, allocatedBytes: Int64,
                                         runtimeRegistrationKnown: Bool, removalGuidance: EngineText? = nil) -> FileEntry {
        let explanation: EngineText = runtimeRegistrationKnown
            ? "macOS stores this download without an installed runtime. Moppo cannot remove it safely."
            : "macOS manages this download. Moppo cannot verify whether an installed runtime uses it."
        let versionText: EngineText = version.map(EngineText.verbatim) ?? "Unknown version"
        let buildText: EngineText = build.map(EngineText.verbatim) ?? "Unknown build"
        let name = EngineText(english: "Simulator Runtime Download \(versionText.english) (\(buildText.english))",
                              display: "Simulator Runtime Download \(versionText.localized) (\(buildText.localized))")
        let protection: EngineText
        if runtimeRegistrationKnown, let removalGuidance {
            protection = EngineText(english: "\(explanation.english) \(removalGuidance.english)",
                                    display: "\(explanation.localized) \(removalGuidance.localized)")
        } else {
            protection = explanation
        }
        return FileEntry(url: url, nameText: name,
            kind: .diskImage, allocatedBytes: allocatedBytes, protectionReason: .inventory,
            protectionText: protection, caveatText: "macOS manages this download.")
    }

    /// Keeps retained download storage visible after successful runtime removal.
    public func retainedSimulatorDownload(after result: ToolCommandRemovalResult) -> FileEntry? {
        guard result.targetID == id, result.status == .completed,
              let bytes = result.afterBytes, bytes > 0,
              let review = toolCommand?.simulatorRuntime else { return nil }
        let runtime = review.runtime
        return .simulatorRuntimeDownload(url: url, version: runtime.version, build: runtime.build,
            allocatedBytes: bytes, runtimeRegistrationKnown: true,
            removalGuidance: SimulatorRuntimeService.retainedImageGuidanceText(developerDirectory: review.developerDirectory))
    }
}
