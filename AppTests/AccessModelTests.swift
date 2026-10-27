import Foundation
import Photos
import Testing
import UserNotifications
import UniformTypeIdentifiers
import MoppoCore

@Suite("Permission setup")
@MainActor
struct AccessModelTests {
    @Test("Status refresh does not request permissions and observes revoked access")
    func refreshOnly() async {
        let fixture = AccessFixture()
        fixture.disk = true
        fixture.photos = .allowed
        fixture.notifications = .allowed
        let model = fixture.model()
        await model.refresh()
        #expect(model.disk == .allowed)
        #expect(model.photos == .allowed)
        #expect(model.notifications == .allowed)
        fixture.disk = false
        fixture.photos = .limited
        fixture.notifications = .denied
        await model.refresh()
        #expect(model.disk == .denied)
        #expect(model.photos == .limited)
        #expect(model.notifications == .denied)
        #expect(fixture.requests.isEmpty)
        #expect(fixture.opened.isEmpty)
    }

    @Test("An older status read cannot replace a newer permission result")
    func staleRefresh() async throws {
        let gate = TestGate()
        var current = AccessModel.Status.undecided
        var isFirstRead = true
        let model = AccessModel(client: .init(
            diskStatus: { false }, photoStatus: { .undecided },
            notificationStatus: {
                let value = current
                if isFirstRead {
                    isFirstRead = false
                    await gate.wait()
                }
                return value
            },
            requestPhotos: {}, requestNotifications: {}, openSettings: { _ in }
        ))
        let oldRead = Task { await model.refresh() }
        try await waitUntil { await gate.isPending }
        current = .allowed
        await model.refresh()
        await gate.finish()
        await oldRead.value
        #expect(model.notifications == .allowed)
    }

    @Test("Enable requests only the selected permission", arguments: [AccessModel.Permission.photos, .notifications])
    func selectedPermission(permission: AccessModel.Permission) async {
        let fixture = AccessFixture()
        let model = fixture.model()
        await model.performAction(for: permission)
        #expect(fixture.requests == [permission])
        #expect(model.status(for: permission) == .allowed)
        #expect(fixture.opened.isEmpty)
        await model.performAction(for: permission)
        #expect(fixture.requests == [permission])
        #expect(fixture.opened == [permission])
    }

    @Test("Denied permission opens settings and restricted permission makes no request")
    func deniedAndRestricted() async {
        let fixture = AccessFixture()
        fixture.photos = .denied
        fixture.notifications = .restricted
        let model = fixture.model()
        await model.performAction(for: .photos)
        await model.performAction(for: .notifications)
        await model.performAction(for: .disk)
        #expect(fixture.requests.isEmpty)
        #expect(fixture.opened == [.photos, .disk])
        #expect(model.openedDiskSettings)
    }

    @Test("An active request blocks another permission request")
    func concurrentRequests() async throws {
        let fixture = AccessFixture()
        let gate = TestGate()
        fixture.requestGate = gate
        let model = fixture.model()
        let request = Task { await model.performAction(for: .photos) }
        try await waitUntil { await gate.isPending }
        await model.performAction(for: .notifications)
        #expect(fixture.requests == [.photos])
        await gate.finish()
        await request.value
        #expect(model.requesting == nil)
    }

    @Test("Notification errors leave a retry available")
    func requestFailure() async {
        let fixture = AccessFixture()
        fixture.failNotifications = true
        let model = fixture.model()
        await model.performAction(for: .notifications)
        #expect(model.error != nil)
        #expect(model.notifications == .undecided)
        #expect(model.requesting == nil)
        fixture.failNotifications = false
        await model.performAction(for: .notifications)
        #expect(model.notifications == .allowed)
        #expect(model.error == nil)
    }

    @Test("System states retain limited and restricted access")
    func systemStates() {
        #expect(AccessModel.Status(PHAuthorizationStatus.limited) == .limited)
        #expect(AccessModel.Status(PHAuthorizationStatus.restricted) == .restricted)
        #expect(AccessModel.Status(PHAuthorizationStatus.notDetermined) == .undecided)
        #expect(AccessModel.Status(UNAuthorizationStatus.provisional) == .limited)
        #expect(AccessModel.Status(UNAuthorizationStatus.denied) == .denied)
    }

    @Test("The drag item uses the original app URL")
    func diskAccessDragItem() async throws {
        let appURL = URL(fileURLWithPath: "/Applications/Moppo Test/Moppo.app", isDirectory: true)
        let item = FullDiskAccessGuideView.dragItem(for: appURL)
        #expect(item.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            item.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        #expect(URL(dataRepresentation: data, relativeTo: nil) == appURL)
    }

    @Test("Basic preferences survive reopening Settings and reset to defaults")
    func preferencesPersist() throws {
        let suite = "moppo-tests.onboarding.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, managesLoginItem: false)
        #expect(settings.lowSpaceAlertsEnabled)
        #expect(settings.showICloudOnDashboard)
        settings.showICloudOnDashboard = false
        settings.lowSpaceAlertsEnabled = false
        settings.showInMenuBar = false
        settings.scanSchedule = .daily
        let reopened = SettingsStore(defaults: defaults, managesLoginItem: false)
        #expect(!reopened.lowSpaceAlertsEnabled)
        #expect(!reopened.showInMenuBar)
        #expect(!reopened.showICloudOnDashboard)
        #expect(reopened.scanSchedule == .daily)
        reopened.hasPendingICloudSetup = true
        reopened.resetToDefaults()
        #expect(reopened.lowSpaceAlertsEnabled)
        #expect(reopened.showICloudOnDashboard)
        #expect(!reopened.hasPendingICloudSetup)
        #expect(!SettingsStore(defaults: defaults, managesLoginItem: false).hasPendingICloudSetup)
        #expect(SettingsStore(defaults: defaults, managesLoginItem: false).showICloudOnDashboard)
    }

    @Test("Finishing without disk access opens Cleanup and allows only manual scans")
    func limitedStart() {
        let model = AppModel(launchAccess: .welcome, hasFullDiskAccess: { false })
        model.finishWelcomeGuide()
        #expect(model.launchAccess == .limited)
        #expect(model.view == .scanner)
        #expect(model.checkDiskAccess())
        #expect(!model.checkDiskAccess(automatic: true))
    }
}

@MainActor
private final class AccessFixture {
    var disk = false
    var photos = AccessModel.Status.undecided
    var notifications = AccessModel.Status.undecided
    var requests: [AccessModel.Permission] = []
    var opened: [AccessModel.Permission] = []
    var requestGate: TestGate?
    var failNotifications = false

    func model() -> AccessModel {
        AccessModel(client: .init(
            diskStatus: { self.disk },
            photoStatus: { self.photos },
            notificationStatus: { self.notifications },
            requestPhotos: {
                self.requests.append(.photos)
                await self.requestGate?.wait()
                self.photos = .allowed
            },
            requestNotifications: {
                self.requests.append(.notifications)
                if self.failNotifications { throw CancellationError() }
                self.notifications = .allowed
            },
            openSettings: { self.opened.append($0) }
        ))
    }
}
