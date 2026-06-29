import Combine
import Foundation
import Sparkle

/// Thin wrapper around Sparkle's updater. Sparkle owns the persisted preferences and the
/// download/verify/install/relaunch machinery; this just surfaces the bits the Updates
/// settings pane needs (current state + a single automatic/manual switch + a manual check).
@MainActor
final class UpdaterService: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// True once Sparkle is idle and able to start a check — drives the button's enabled state.
    @Published private(set) var canCheckForUpdates = false

    private var updater: SPUUpdater { controller.updater }

    init() {
        // Only auto-start when the bundle is actually configured for updates (SUFeedURL +
        // SUPublicEDKey). A bare `swift run` executable has neither, and starting Sparkle there
        // pops a modal "no feed URL" error — so in dev we create it stopped and the UI degrades
        // to a disabled button.
        let isConfigured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    /// One switch for the user: on = check on a schedule AND download+install automatically;
    /// off = manual checks only. Bound directly to Sparkle's own persisted prefs (no duplicate
    /// state in AppSettings).
    var automaticallyUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// When Sparkle last checked — shown as reassurance next to the manual button.
    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
