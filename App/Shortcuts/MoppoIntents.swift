import AppIntents
import MoppoCore

struct GetFreeSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Free Space"
    static let description = IntentDescription("Returns the free bytes and names the startup disk.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let volume = try await DiskInfoService().volumeInfo()
        let free = ByteFormatting.string(volume.freeBytes)
        return .result(value: Int(volume.freeBytes), dialog: "\(free) free on \(volume.name).")
    }
}

struct GetTrashSizeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Trash Size"
    static let description = IntentDescription("Returns the bytes in the Trash and reports the item count.")
    static let openAppWhenRun = false

    var trashService: any TrashServicing = TrashService()

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let summary: TrashSummary
        do {
            summary = try await trashService.summary(limit: 0)
        } catch TrashError.unreadable {
            throw MoppoOperationError.trashAccessRequired
        }
        let size = ByteFormatting.string(summary.totalBytes)
        return .result(value: Int(summary.totalBytes), dialog: "\(summary.itemCount) items use \(size) in the Trash.")
    }
}

struct GetSafeToRemoveSizeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Safe to Remove Size"
    static let description = IntentDescription("Returns the Safe to Remove bytes and reports the Cleanup scan date. It does not start a scan.")
    static let openAppWhenRun = false

    @Dependency var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let results = model.cleanup.scanResults else { throw MoppoOperationError.scanRequired }
        let size = ByteFormatting.string(results.safeToRemoveBytes)
        let date = results.finishedAt.formatted(date: .abbreviated, time: .shortened)
        return .result(value: Int(results.safeToRemoveBytes), dialog: "\(size) Safe to Remove. Scanned on \(date).")
    }
}

struct ScanForCleanupItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan for Cleanup Items"
    static let description = IntentDescription("Opens Moppo and finds items to review. It removes nothing.")
    static let openAppWhenRun = true

    @Dependency var model: AppModel
    var presentMainWindow: @MainActor @Sendable () -> Void = { MainWindowRequestCenter.cleanupScan.present() }

    @MainActor
    func perform() async throws -> some IntentResult {
        try model.startCleanup(removeSafeToRemove: false, presentMainWindow: presentMainWindow)
        return .result()
    }
}

struct DeleteSafeToRemoveIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Safe to Remove"
    static let description = IntentDescription("Scans in the background and removes Safe to Remove items without confirmation. Requires Full Disk Access. Moppo uses its normal removal methods.")
    static let openAppWhenRun = false

    @Dependency var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        try model.startCleanup(removeSafeToRemove: true)
        return .result()
    }
}
