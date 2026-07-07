import Combine
import Foundation
import Sparkle

/// Drives Sparkle with a **custom in-app user driver** instead of `SPUStandardUpdaterController`,
/// so the whole update experience (checking / available / downloading / ready) renders inline in
/// the Updates settings pane — no Sparkle windows or modal dialogs ever pop up.
///
/// This object *is* the `SPUUserDriver`: Sparkle calls the protocol methods below, and each one
/// just maps to a published `phase` the pane observes. The two reply closures Sparkle hands us
/// (choose-to-install, ready-to-relaunch) are stored and fired when the user taps the inline button.
///
/// ponytail: app-lifetime singleton (owned by AppCoordinator). SPUUpdater retains its user driver,
/// so self ↔ updater is a deliberate retain cycle that lives for the whole process — fine here.
@MainActor
final class UpdaterService: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String?)
        case downloading(fraction: Double?)
        case extracting(fraction: Double)
        case readyToInstall
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var canCheckForUpdates = false

    private var updater: SPUUpdater!
    private let isConfigured: Bool

    /// Reply Sparkle gave us for the current choice point (install-this-update or restart-now).
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    /// Cancellation Sparkle gave us for the in-flight check/download.
    private var cancellation: (() -> Void)?

    private var expectedDownloadBytes: UInt64 = 0
    private var receivedDownloadBytes: UInt64 = 0

    override init() {
        // Only start when the bundle has a real feed (SUFeedURL). A bare `swift run` executable has
        // none, so we leave the updater created-but-unstarted and the pane degrades to a disabled
        // button — same guard as the old standard-controller path.
        let isConfigured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        self.isConfigured = isConfigured
        super.init()

        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: self,
            delegate: nil
        )
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)

        if isConfigured {
            do {
                try updater.start()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// One switch: on = scheduled checks + auto-download; off = manual checks only. Bound directly
    /// to Sparkle's persisted prefs (no duplicate state in AppSettings).
    var automaticallyUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    /// User-initiated check (the pane's button / opening the pane). Surfaces a spinner then either
    /// "up to date" or the inline update card — never a window.
    func checkForUpdates() {
        guard isConfigured else { return }
        updater.checkForUpdates()
    }

    /// Silent scheduled-style check used on launch. Only advances `phase` if something's found.
    func checkForUpdatesInBackground() {
        guard isConfigured else { return }
        updater.checkForUpdatesInBackground()
    }

    // MARK: - Inline actions (called from the Updates pane)

    /// Accept the current update — begins download, or restarts to install once downloaded.
    func installUpdate() {
        installReply?(.install)
        installReply = nil
    }

    /// Dismiss the current update card without installing.
    func dismissUpdate() {
        if let installReply {
            installReply(.dismiss)
            self.installReply = nil
        } else {
            cancellation?()
        }
        cancellation = nil
        phase = .idle
    }
}

// MARK: - SPUUserDriver

extension UpdaterService: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        SUUpdatePermissionResponse(automaticUpdateChecks: automaticallyUpdates, sendSystemProfile: false)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        phase = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installReply = reply
        phase = .available(version: appcastItem.displayVersionString, notes: appcastItem.itemDescription)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error) async {
        phase = .upToDate
    }

    func showUpdaterError(_ error: any Error) async {
        phase = .failed(error.localizedDescription)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        expectedDownloadBytes = 0
        receivedDownloadBytes = 0
        phase = .downloading(fraction: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedDownloadBytes += length
        let fraction = expectedDownloadBytes > 0
            ? min(Double(receivedDownloadBytes) / Double(expectedDownloadBytes), 1)
            : nil
        phase = .downloading(fraction: fraction)
    }

    func showDownloadDidStartExtractingUpdate() {
        phase = .extracting(fraction: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        phase = .extracting(fraction: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installReply = reply
        phase = .readyToInstall
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        phase = .idle
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        // Session ended. Clear transient in-flight phases; leave a resolved terminal state
        // (upToDate / failed) visible so the pane keeps showing the outcome.
        switch phase {
        case .checking, .downloading, .extracting, .available, .readyToInstall, .installing:
            phase = .idle
        case .idle, .upToDate, .failed:
            break
        }
        installReply = nil
        cancellation = nil
    }
}
