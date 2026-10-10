import Foundation
import Observation
import Testing

@Suite("Operation coordinator")
@MainActor
struct OperationCoordinatorTests {
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
