import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController: NSObject {
    private let minimumPanelHeight: CGFloat = 92
    private let delayedRefreshDuration: Duration = .milliseconds(200)

    private var panel: NSPanel?
    private var hostingController: NSHostingController<OverlayView>?
    private var currentState: DictationState = .idle
    private var isPresented = false
    private var refreshGeneration: UInt64 = 0
    private var delayedRefreshTask: Task<Void, Never>?

    override init() {
        super.init()
        registerObservers()
    }

    deinit {
        delayedRefreshTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func show(state: DictationState) {
        ensurePanel()
        currentState = state
        isPresented = true
        scheduleRefresh(reason: "show")
    }

    func hide() {
        refreshGeneration &+= 1
        delayedRefreshTask?.cancel()
        delayedRefreshTask = nil
        isPresented = false
        currentState = .idle
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let rootView = OverlayView(state: .idle)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.wantsLayer = true

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: OverlayView.fullWidth, height: minimumPanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentViewController = hostingController
        configurePanel(panel)

        self.panel = panel
        self.hostingController = hostingController
    }

    private func configurePanel(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.isReleasedWhenClosed = false
    }

    private func registerObservers() {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter

        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(handleOverlayRefreshNotification(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(handleOverlayRefreshNotification(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(handleOverlayRefreshNotification(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOverlayRefreshNotification(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc
    private nonisolated func handleOverlayRefreshNotification(_ notification: Notification) {
        let reason = Self.refreshReason(for: notification.name)

        Task { @MainActor [weak self] in
            self?.scheduleRefresh(reason: reason)
        }
    }

    private nonisolated static func refreshReason(for name: Notification.Name) -> String {
        switch name {
        case NSWorkspace.activeSpaceDidChangeNotification:
            "active-space-changed"
        case NSWorkspace.didWakeNotification:
            "did-wake"
        case NSWorkspace.screensDidWakeNotification:
            "screens-did-wake"
        case NSApplication.didChangeScreenParametersNotification:
            "screen-parameters-changed"
        default:
            "overlay-refresh"
        }
    }

    private func scheduleRefresh(reason: String) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let delayedRefreshDelay = delayedRefreshDuration

        delayedRefreshTask?.cancel()
        delayedRefreshTask = nil

        refreshPresentedOverlay(reason: reason)

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.refreshPresentedOverlayIfCurrent(reason: "\(reason)-next-runloop", generation: generation)
        }

        delayedRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delayedRefreshDelay)
            guard !Task.isCancelled, let self else { return }
            self.refreshPresentedOverlayIfCurrent(reason: "\(reason)-delayed", generation: generation)
        }
    }

    private func refreshPresentedOverlayIfCurrent(reason: String, generation: UInt64) {
        guard generation == refreshGeneration else { return }
        refreshPresentedOverlay(reason: reason)
    }

    private func refreshPresentedOverlay(reason _: String) {
        guard isPresented else { return }

        ensurePanel()

        guard let panel, let hostingController else { return }

        hostingController.rootView = OverlayView(state: currentState)
        configurePanel(panel)
        resizePanel()

        let targetScreen = preferredScreen(for: panel)
        let targetFrame = targetFrame(for: panel, on: targetScreen)

        panel.setFrame(targetFrame, display: false)
        panel.orderFrontRegardless()
    }

    private func resizePanel() {
        guard let panel, let hostingController else { return }

        if currentState.isMinimalOverlay {
            // Unconstrained measure so SwiftUI reports the natural one-line size.
            hostingController.view.frame = NSRect(x: 0, y: 0, width: 1000, height: minimumPanelHeight)
            hostingController.view.layoutSubtreeIfNeeded()
            panel.contentView?.layoutSubtreeIfNeeded()

            let fitting = hostingController.view.fittingSize
            panel.setContentSize(NSSize(width: max(fitting.width, 80),
                                        height: max(fitting.height, minimumPanelHeight)))
        } else {
            let targetWidth = OverlayView.fullWidth
            hostingController.view.frame = NSRect(x: 0, y: 0, width: targetWidth, height: minimumPanelHeight)
            hostingController.view.layoutSubtreeIfNeeded()
            panel.contentView?.layoutSubtreeIfNeeded()

            let fittingHeight = max(hostingController.view.fittingSize.height, minimumPanelHeight)
            let targetHeight  = min(fittingHeight, currentState.overlayMaxHeight)
            panel.setContentSize(NSSize(width: targetWidth, height: targetHeight))
        }
    }

    private func targetFrame(for panel: NSPanel, on screen: NSScreen?) -> NSRect {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = targetScreen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = targetScreen?.visibleFrame ?? screenFrame
        let menuBarInset = max(screenFrame.maxY - visibleFrame.maxY, 0)
        let topPadding: CGFloat = 12
        let horizontalInset: CGFloat = 12

        let centeredFrame = NSRect(
            x: max(
                visibleFrame.minX + horizontalInset,
                min(
                    screenFrame.midX - (panel.frame.width / 2),
                    visibleFrame.maxX - panel.frame.width - horizontalInset
                )
            ),
            y: max(
                visibleFrame.minY,
                screenFrame.maxY - menuBarInset - panel.frame.height - topPadding
            ),
            width: panel.frame.width,
            height: panel.frame.height
        )

        return centeredFrame
    }

    private func preferredScreen(for panel: NSPanel) -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation

        if let mouseScreen = NSScreen.screens.first(where: { screen in
            screen.frame.contains(mouseLocation)
        }) {
            return mouseScreen
        }

        if let panelScreen = connectedScreen(matching: panel.screen) {
            return panelScreen
        }

        if let mainScreen = NSScreen.main {
            return mainScreen
        }

        return NSScreen.screens.first
    }

    private func connectedScreen(matching candidate: NSScreen?) -> NSScreen? {
        guard let candidate else { return nil }

        let candidateNumber = candidate.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber

        return NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == candidateNumber
        }
    }

}
