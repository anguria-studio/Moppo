import Foundation

/// Measured storage for known Apple Intelligence model locations.
public struct AppleIntelligenceStorage: Sendable, Equatable, Codable {
    public enum Coverage: String, Sendable, Codable {
        case complete, partial, unavailable, unsupported
    }

    public let allocatedBytes: Int64
    public let coverage: Coverage
    public let macOSMajorVersion: Int

    static let systemRoot = URL(fileURLWithPath: DiskInfoService.dataVolumeMountPoint + "/System")
    static let assetsRelativePath = "Library/AssetsV2"
    static let assetsRoot = systemRoot.appendingPathComponent(assetsRelativePath)

    // Apple asset manifests identify language models and image diffusion models in these stores.
    // The stores exist in macOS 15, 26, and 27. Other asset types remain outside this category.
    // CodeLM, Siri, shared staging folders, and unknown FM stores are not included.
    static let modelDirectoryNames = [
        "com_apple_MobileAsset_UAF_FM_GenerativeModels",
        "com_apple_MobileAsset_UAF_FM_Visual"
    ]

    public var sizeLabel: String {
        switch coverage {
        case .complete: ByteFormatting.string(allocatedBytes)
        case .partial: "At least \(ByteFormatting.string(allocatedBytes))"
        case .unavailable, .unsupported: "Size unavailable"
        }
    }

    public var explanation: String {
        let scope = "This category includes known Apple Intelligence model locations. "
            + "macOS manages these files. Moppo does not offer them for removal."
        switch coverage {
        case .complete where allocatedBytes == 0:
            return scope + " No verified assets were found in the checked locations."
        case .complete:
            return scope + " Other Apple assets remain in their existing categories."
        case .partial:
            return scope + " Moppo could not measure all model files. The size includes only measured files."
        case .unavailable:
            return scope + " Moppo could not measure the model locations. Unreadable files have no separate size."
        case .unsupported:
            return "Storage identification is not supported for this macOS version. "
                + "Apple assets remain in their existing categories."
        }
    }

    func isComparable(to other: Self) -> Bool {
        coverage == .complete && other.coverage == .complete
            && macOSMajorVersion == other.macOSMajorVersion
    }

    /// Read child totals from the same traversal that measured the system root.
    static func classify(
        systemTree: [URL: SizeMeasurement],
        systemRoot: URL = Self.systemRoot,
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Self {
        let supported = (version.majorVersion == 15 && version.minorVersion >= 1)
            || version.majorVersion == 26 || version.majorVersion == 27
        guard supported else {
            return Self(allocatedBytes: 0, coverage: .unsupported, macOSMajorVersion: version.majorVersion)
        }

        // Compare paths without URL directory hints or filesystem lookups after the measurement.
        let paths = Dictionary(systemTree.map { ($0.key.standardizedFileURL.path, $0.value) }, uniquingKeysWith: { first, _ in first })
        let root = systemRoot.standardizedFileURL.path
        let assets = root + "/" + assetsRelativePath
        var bytes: Int64 = 0
        var incomplete = false
        for name in modelDirectoryNames {
            let location = assets + "/" + name
            if let measured = paths[location] {
                bytes += measured.allocatedBytes
                incomplete = incomplete || measured.unreadableCount > 0
            } else {
                // A missing location means zero only when its nearest measured parent was readable.
                var parent = assets
                while paths[parent] == nil && parent != root {
                    parent = (parent as NSString).deletingLastPathComponent
                }
                incomplete = incomplete || paths[parent] == nil
                    || (paths[parent]?.unreadableCount ?? 0) > 0
            }
        }
        let coverage: Coverage = incomplete ? (bytes > 0 ? .partial : .unavailable) : .complete
        return Self(allocatedBytes: bytes, coverage: coverage, macOSMajorVersion: version.majorVersion)
    }
}
