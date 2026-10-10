import AppKit
import Observation
import Photos
import UserNotifications

/// Reads permission status and requests only the permission the user selects.
@MainActor
@Observable
final class AccessModel {
    enum Permission: CaseIterable { case disk, photos, notifications }
    enum Status: Equatable {
        case checking, undecided, allowed, limited, denied, restricted, unavailable

        var label: String {
            switch self {
            case .checking: "Checking"
            case .undecided: "Not Set"
            case .allowed: "On"
            case .limited: "Limited"
            case .denied: "Off"
            case .restricted: "Restricted"
            case .unavailable: "Unavailable"
            }
        }

        var permitsAccess: Bool { self == .allowed || self == .limited }
    }

    struct Client {
        var diskStatus: () -> Bool
        var photoStatus: () -> Status
        var notificationStatus: () async -> Status
        var requestPhotos: () async -> Void
        var requestNotifications: () async throws -> Void
        var openSettings: @MainActor (Permission) -> Void

        static var live: Self {
            Self(
                diskStatus: { FullDiskAccess.isGranted },
                photoStatus: { Status(PHPhotoLibrary.authorizationStatus(for: .readWrite)) },
                notificationStatus: {
                    Status(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
                },
                requestPhotos: { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite) },
                requestNotifications: {
                    _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                },
                openSettings: { permission in
                    let address = switch permission {
                    case .disk: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                    case .photos: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
                    case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
                    }
                    if let url = URL(string: address) { NSWorkspace.shared.open(url) }
                    if permission == .disk, !FullDiskAccess.isGranted {
                        FullDiskAccessGuide.shared.show()
                    }
                }
            )
        }
    }

    @ObservationIgnored private let client: Client
    @ObservationIgnored private var refreshRevision = 0
    private(set) var disk: Status = .checking
    private(set) var photos: Status = .checking
    private(set) var notifications: Status = .checking
    private(set) var requesting: Permission?
    private(set) var openedDiskSettings = false
    private(set) var error: String?
    let isPreview: Bool

    init(client: Client = .live, isPreview: Bool = false) {
        self.client = client
        self.isPreview = isPreview
        disk = client.diskStatus() ? .allowed : .denied
        photos = client.photoStatus()
    }

    func status(for permission: Permission) -> Status {
        switch permission {
        case .disk: disk
        case .photos: photos
        case .notifications: notifications
        }
    }

    func refresh() async {
        refreshRevision += 1
        let revision = refreshRevision
        disk = client.diskStatus() ? .allowed : .denied
        photos = client.photoStatus()
        let status = await client.notificationStatus()
        guard revision == refreshRevision else { return }
        notifications = status
    }

    func performAction(for permission: Permission) async {
        guard requesting == nil else { return }
        requesting = permission
        defer { requesting = nil }
        error = nil
        await refresh()
        let status = status(for: permission)
        guard status != .restricted, status != .unavailable, status != .checking else { return }
        if permission == .disk {
            openedDiskSettings = true
            client.openSettings(.disk)
        } else if status == .undecided {
            do {
                if permission == .photos { await client.requestPhotos() }
                else { try await client.requestNotifications() }
            } catch {
                self.error = "Moppo could not request notification access. Try again or open System Settings."
            }
            await refresh()
        } else {
            client.openSettings(permission)
        }
    }

    static func preview(disk: Bool = false, photos: Status = .undecided, notifications: Status = .undecided) -> AccessModel {
        let model = AccessModel(client: Client(
            diskStatus: { disk }, photoStatus: { photos }, notificationStatus: { notifications },
            requestPhotos: {}, requestNotifications: {}, openSettings: { _ in }
        ), isPreview: true)
        model.notifications = notifications
        return model
    }
}

extension AccessModel.Status {
    init(_ status: PHAuthorizationStatus) {
        self = switch status {
        case .notDetermined: .undecided
        case .authorized: .allowed
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unavailable
        }
    }

    init(_ status: UNAuthorizationStatus) {
        self = switch status {
        case .notDetermined: .undecided
        case .authorized: .allowed
        case .provisional, .ephemeral: .limited
        case .denied: .denied
        @unknown default: .unavailable
        }
    }
}
