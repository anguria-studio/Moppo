import Foundation
import Observation
import Testing

@Suite("Operation coordinator")
@MainActor
struct OperationCoordinatorTests {
    @Test("Page and duplicate tab changes dismiss feedback without releasing the operation")
    func navigationDismissesFeedback() throws {
        let app = AppModel(launchAccess: .limited, hasFullDiskAccess: { false })
        let operation = try #require(app.operations.begin(.cleanupScan))
        #expect(app.operations.explainBlockedAction())
        let first = try #require(app.operations.blockedAction)
        app.view = .trash
        #expect(app.operations.blockedAction == nil)
        #expect(app.operations.activeOperation == operation)
        #expect(app.operations.explainBlockedAction())
        let second = try #require(app.operations.blockedAction)
        app.operations.dismissBlockedAction(first.id)
        #expect(app.operations.blockedAction == second)
        app.view = .trash
        #expect(app.operations.blockedAction == second)
        app.duplicateKind = .photos
        #expect(app.operations.blockedAction == nil)
        #expect(app.operations.activeOperation == operation)
        app.operations.finish(operation)
    }

    @Test("Blocked attempts reuse feedback until it expires and cannot affect a later operation")
    func blockedFeedbackLifetime() throws {
        var now = ContinuousClock.now
        let operations = OperationCoordinator(now: { now })
        #expect(!operations.explainBlockedAction())
        #expect(operations.blockedAction == nil)
        let scan = try #require(operations.begin(.cleanupScan))
        #expect(operations.explainBlockedAction())
        let first = try #require(operations.blockedAction)
        #expect(first.message == "Cleanup scan is running. Wait for it to finish, or stop the scan.")
        for _ in 0..<20 { #expect(operations.explainBlockedAction()) }
        #expect(operations.blockedAction == first)
        #expect(operations.activeOperation == scan)
        now += .seconds(8)
        #expect(operations.explainBlockedAction())
        let replacement = try #require(operations.blockedAction)
        #expect(replacement.id != first.id)
        operations.dismissBlockedAction(first.id)
        #expect(operations.blockedAction == replacement)
        operations.finish(scan)
        #expect(operations.blockedAction == nil)
        let removal = try #require(operations.begin(.fileRemoval))
        #expect(operations.explainBlockedAction())
        let current = try #require(operations.blockedAction)
        #expect(current.message == "Moppo is removing files. Wait for it to finish.")
        operations.finish(scan)
        operations.dismissBlockedAction(replacement.id)
        #expect(operations.activeOperation == removal)
        #expect(operations.blockedAction == current)
        operations.dismissBlockedAction(current.id)
        #expect(operations.blockedAction == nil)
        operations.finish(removal)
        #expect(!operations.explainBlockedAction())
    }

    @Test("An earlier operation cannot release the current operation")
    func operationIdentity() throws {
        let operations = OperationCoordinator()
        let first = try #require(operations.begin(.photoScan))
        #expect(operations.begin(.photoDeletion) == nil)
        operations.finish(first)
        let second = try #require(operations.begin(.photoDeletion))
        operations.finish(first)
        #expect(operations.activeOperation == second)
        #expect(operations.isBusy)
        operations.finish(second)
        #expect(!operations.isBusy)
    }

    @Test("Feature models observe changes to the shared busy state")
    func busyObservation() throws {
        let app = AppModel()
        let featureChanged = ObservationFlag()
        withObservationTracking {
            _ = app.photoDuplicates.isBusyWithDisk
        } onChange: {
            featureChanged.mark()
        }
        let operation = try #require(app.operations.begin(.storageMeasurement))
        #expect(featureChanged.changed)
        app.operations.finish(operation)

        let appChanged = ObservationFlag()
        withObservationTracking {
            _ = app.isBusyWithDisk
        } onChange: {
            appChanged.mark()
        }
        let next = try #require(app.operations.begin(.photoScan))
        #expect(appChanged.changed)
        app.operations.finish(next)
    }
}

private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var changed: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}
