import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController {
    private let minimumPanelHeight: CGFloat = 92
    private var panel: NSPanel?
    private var hostingController: NSHostingController<OverlayView>?
    private var currentState: DictationState = .idle

    func show(state: DictationState) {
        ensurePanel()
        currentState = state
        hostingController?.rootView = OverlayView(state: state)
        resizePanel()
        panel?.orderFrontRegardless()
        positionPanel()

        // The first time a non-activating panel is shown, AppKit can resolve its
        // screen assignment and final fitting size one tick later.
        DispatchQueue.main.async { [weak self] in
            self?.resizePanel()
            self?.positionPanel()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let rootView = OverlayView(state: .idle)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.wantsLayer = true

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: OverlayView.preferredWidth, height: minimumPanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentViewController = hostingController
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow

        self.panel = panel
        self.hostingController = hostingController
    }

    private func resizePanel() {
        guard let panel, let hostingController else { return }

        let targetWidth = OverlayView.preferredWidth
        hostingController.view.frame = NSRect(x: 0, y: 0, width: targetWidth, height: minimumPanelHeight)
        hostingController.view.layoutSubtreeIfNeeded()
        panel.contentView?.layoutSubtreeIfNeeded()

        let fittingHeight = max(hostingController.view.fittingSize.height, minimumPanelHeight)
        let targetHeight = min(fittingHeight, currentState.overlayMaxHeight)
        panel.setContentSize(NSSize(width: targetWidth, height: targetHeight))
    }

    private func positionPanel() {
        guard let panel else { return }

        let screen = activeScreen(for: panel) ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = screen?.visibleFrame ?? screenFrame
        let menuBarInset = max(screenFrame.maxY - visibleFrame.maxY, 0)
        let topPadding: CGFloat = 12
        let horizontalInset: CGFloat = 12

        let origin = NSPoint(
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
            )
        )

        panel.setFrameOrigin(origin)
    }

    private func activeScreen(for panel: NSPanel) -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation

        return NSScreen.screens.first(where: { screen in
            screen.frame.contains(mouseLocation)
        }) ?? panel.screen
    }
}
