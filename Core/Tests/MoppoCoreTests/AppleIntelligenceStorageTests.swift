import Foundation
import Testing
@testable import MoppoCore

@Suite("Apple Intelligence storage")
struct AppleIntelligenceStorageTests {
    private typealias Sandbox = AllocatedSizeMeasurerTests.Sandbox
    private let version = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
    private let models = "Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels"
    private let images = "Library/AssetsV2/com_apple_MobileAsset_UAF_FM_Visual"

    private func read(_ root: URL) async throws -> (AppleIntelligenceStorage, [URL: SizeMeasurement]) {
        let tree = try await AllocatedSizeMeasurer().measureSubtrees(
            of: root, depth: 3, reportSkippedEntries: true
        )
        return (AppleIntelligenceStorage.classify(systemTree: tree, systemRoot: root, version: version), tree)
    }

    @Test("Only the identified model stores contribute bytes")
    func identifiedStores() async throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile(models + "/model.bin", bytes: 1_048_576)
        try sandbox.writeFile(images + "/image.bin", bytes: 2_097_152)
        for name in ["Font8", "DictionaryServices_dictionary3macOS", "UAF_FM_CodeLM", "UAF_FM_Unknown", "UAF_Siri_Understanding"] {
            try sandbox.writeFile("Library/AssetsV2/com_apple_MobileAsset_\(name)/other.bin", bytes: 1_048_576)
        }
        try sandbox.writeFile("Library/AssetsV2/staging/other.bin", bytes: 1_048_576)
        let (result, tree) = try await read(sandbox.root)
        let expected = try #require(tree[sandbox.root.appendingPathComponent(models)]?.allocatedBytes)
            + #require(tree[sandbox.root.appendingPathComponent(images)]?.allocatedBytes)
        #expect(result.coverage == .complete)
        #expect(result.allocatedBytes == expected)
        #expect(result.allocatedBytes < (tree[sandbox.root]?.allocatedBytes ?? 0))
    }

    @Test("An empty readable store differs from an unreadable store")
    func emptyAndUnreadable() async throws {
        let sandbox = try Sandbox()
        let empty = try sandbox.directory(models)
        let locked = try sandbox.directory(images)
        let (before, tree) = try await read(sandbox.root)
        #expect(tree.first { $0.key.path == empty.path }?.value.unreadableCount == 0)
        #expect(before.coverage == .complete)
        #expect(before.sizeLabel == "0 B")
        #expect(before.explanation.contains("No verified assets"))

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let (after, unreadableTree) = try await read(sandbox.root)
        #expect(unreadableTree.first { $0.key.path == locked.path }?.value.unreadableCount == 1)
        #expect(unreadableTree[sandbox.root]?.unreadableCount == 1)
        #expect(after.coverage == .unavailable)
        #expect(after.sizeLabel == "Size unavailable")
    }

    @Test("Partial access reports a lower bound")
    func partialAccess() async throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile(models + "/readable.bin", bytes: 1_048_576)
        let locked = try sandbox.directory(models + "/restricted")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let (result, _) = try await read(sandbox.root)
        #expect(result.coverage == .partial)
        #expect(result.allocatedBytes > 0)
        #expect(result.sizeLabel.hasPrefix("At least "))
    }

    @Test("An unreadable parent cannot establish absent model stores")
    func unreadableParent() {
        let root = AppleIntelligenceStorage.systemRoot
        let result = AppleIntelligenceStorage.classify(
            systemTree: [root: SizeMeasurement(unreadableCount: 1)], version: version
        )
        #expect(result.coverage == .unavailable)
        let missing = AppleIntelligenceStorage.classify(systemTree: [root: .zero], version: version)
        #expect(missing.coverage == .complete)
        #expect(missing.allocatedBytes == 0)
    }

    @Test("A skipped model link is not reported as an empty store")
    func skippedLink() async throws {
        let sandbox = try Sandbox()
        let target = try sandbox.directory("linked-models")
        _ = try sandbox.directory("Library/AssetsV2")
        try FileManager.default.createSymbolicLink(at: sandbox.root.appendingPathComponent(models), withDestinationURL: target)
        let (result, _) = try await read(sandbox.root)
        #expect(result.coverage == .unavailable)
    }

    @Test("Shared hard links count once across both model stores")
    func sharedHardLinks() async throws {
        let sandbox = try Sandbox()
        let original = try sandbox.writeFile(models + "/original.bin", bytes: 1_048_576)
        _ = try sandbox.directory(images)
        try FileManager.default.linkItem(at: original, to: sandbox.root.appendingPathComponent(images + "/linked.bin"))
        let (result, tree) = try await read(sandbox.root)
        #expect(result.allocatedBytes == tree[sandbox.root]?.allocatedBytes)
        #expect(tree[sandbox.root]?.fileCount == 1)
        #expect(result.coverage == .complete)
    }

    @Test("Unsupported macOS versions do not claim model storage", arguments: [14, 15, 16, 28])
    func unsupportedVersion(_ major: Int) {
        let model = AppleIntelligenceStorage.assetsRoot.appendingPathComponent(AppleIntelligenceStorage.modelDirectoryNames[0])
        let result = AppleIntelligenceStorage.classify(
            systemTree: [model: SizeMeasurement(allocatedBytes: 1_000_000)],
            version: OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0)
        )
        #expect(result.coverage == .unsupported)
        #expect(result.allocatedBytes == 0)
    }

    @Test("Missing model stores are safe to measure", arguments: ["", "Library", "Library/AssetsV2"])
    func missingStores(_ existingParent: String) async throws {
        let sandbox = try Sandbox()
        if !existingParent.isEmpty {
            _ = try sandbox.directory(existingParent)
        }
        let (result, _) = try await read(sandbox.root)
        #expect(result.coverage == .complete)
        #expect(result.allocatedBytes == 0)
    }

    @Test("A missing system root leaves model storage unavailable")
    func missingSystemRoot() async throws {
        let sandbox = try Sandbox()
        let (result, _) = try await read(sandbox.root.appendingPathComponent("missing-system"))
        #expect(result.coverage == .unavailable)
        #expect(result.allocatedBytes == 0)
    }

    @Test("Size limits survive storage and volume refreshes")
    func persistenceAndReconciliation() throws {
        let measurement = AppleIntelligenceStorage(allocatedBytes: 100, coverage: .partial, macOSMajorVersion: 27)
        let original = StorageBreakdown.make(
            capacityBytes: 1_000_000,
            rawSegments: [.macOSSystem: 700_000, .appleIntelligence: 100, .free: 299_900],
            unreadableCount: 1,
            appleIntelligence: measurement
        )
        let decoded = try JSONDecoder().decode(StorageBreakdown.self, from: JSONEncoder().encode(original))
        let refreshed = decoded.reconcilingVolume(capacityBytes: 1_000_000, freeBytes: 200_000)
        #expect(refreshed.appleIntelligence == measurement)
        #expect(refreshed.segments.contains { $0.id == .appleIntelligence && $0.bytes == 100 })
        #expect(refreshed.isConsistent)
    }

    @Test("Zero measured model bytes have no legend row or bar allocation", arguments: [AppleIntelligenceStorage.Coverage.complete, .partial, .unavailable, .unsupported])
    func hiddenCategory(_ coverage: AppleIntelligenceStorage.Coverage) throws {
        let measurement = AppleIntelligenceStorage(allocatedBytes: 0, coverage: coverage, macOSMajorVersion: 27)
        let breakdown = StorageBreakdown.make(
            capacityBytes: 1_000, rawSegments: [.macOSSystem: 700, .appleIntelligence: 0, .free: 300],
            unreadableCount: 1, appleIntelligence: measurement
        )
        let cached = try JSONDecoder().decode(StorageBreakdown.self, from: JSONEncoder().encode(breakdown))
        for result in [breakdown, cached, cached.reconcilingVolume(capacityBytes: 1_000, freeBytes: 200)] {
            #expect(!result.legendEntries.contains { $0.id == .appleIntelligence })
            #expect(!result.segments.contains { $0.id == .appleIntelligence })
            #expect(result.appleIntelligence == measurement)
            #expect(result.isConsistent)
        }
    }

    @Test("Older cached breakdowns remain readable")
    func olderCache() throws {
        let data = Data(#"{"capacityBytes":1000,"segments":[{"id":"free","bytes":1000}],"unreadableCount":0}"#.utf8)
        let decoded = try JSONDecoder().decode(StorageBreakdown.self, from: data)
        #expect(decoded.appleIntelligence == nil)
        #expect(decoded.isConsistent)
    }
}
