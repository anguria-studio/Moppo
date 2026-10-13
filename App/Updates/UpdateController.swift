import Foundation
import Observation
import Sparkle

@MainActor
protocol UpdateServicing: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var onAvailabilityChange: ((Bool) -> Void)? { get set }
    func start() throws
    func checkForUpdates()
}

/// Owns Sparkle, update preferences, and installation coordination.
@MainActor
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {
    let installation: UpdateInstallationGate
    @ObservationIgnored private let configuration: UpdateConfiguration?
    @ObservationIgnored private let makeService: (any SPUUpdaterDelegate) -> any UpdateServicing
    @ObservationIgnored private var service: (any UpdateServicing)?
    private(set) var canCheckForUpdates = false
    private(set) var statusMessage: String?
    var automaticallyChecksForUpdates = false {
        didSet { service?.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    var isAvailable: Bool { service != nil }

    init(
        operations: OperationCoordinator,
        configuration: UpdateConfiguration? = UpdateConfiguration(bundle: .main),
        makeService: @escaping (any SPUUpdaterDelegate) -> any UpdateServicing = { SparkleUpdateService(delegate: $0) }
    ) {
        installation = UpdateInstallationGate(operations: operations)
        self.configuration = configuration
        self.makeService = makeService
        super.init()
    }

    /// Starts after onboarding. An unconfigured development build makes no update requests.
    func start() {
        guard service == nil else { return }
        guard configuration != nil else {
            statusMessage = "Updates are not available in this build."
            return
        }
        let service = makeService(self)
        service.onAvailabilityChange = { [weak self] available in
            guard let self, self.service != nil else { return }
            self.canCheckForUpdates = available
        }
        self.service = service
        do {
            try service.start()
            statusMessage = nil
            automaticallyChecksForUpdates = service.automaticallyChecksForUpdates
            canCheckForUpdates = service.canCheckForUpdates
        } catch {
            self.service = nil
            canCheckForUpdates = false
            statusMessage = "Updates could not start. Contact support for help."
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        service?.checkForUpdates()
    }

    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        installation.schedule(installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installation.cancel()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        installation.cancel()
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func feedURLString(for updater: SPUUpdater) -> String? { configuration?.feedURL.absoluteString }
}

/// Uses Sparkle's standard dialogs and prevents automatic installation and system profiles.
@MainActor
private final class SparkleUpdateService: UpdateServicing {
    private let controller: SPUStandardUpdaterController
    private var availabilityObservation: NSKeyValueObservation?
    var onAvailabilityChange: ((Bool) -> Void)?

    init(delegate: any SPUUpdaterDelegate) {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        controller.updater.automaticallyDownloadsUpdates = false
        controller.updater.sendsSystemProfile = false
        availabilityObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let available = change.newValue ?? false
            Task { @MainActor [weak self] in self?.onAvailabilityChange?(available) }
        }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    func start() throws { try controller.updater.start() }
    func checkForUpdates() { controller.checkForUpdates(nil) }
}
