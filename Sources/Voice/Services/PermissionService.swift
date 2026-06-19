import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation

enum MicrophoneAccessState: Equatable {
    case notDetermined
    case granted
    case denied

    var title: String {
        switch self {
        case .notDetermined:
            "Not Requested"
        case .granted:
            "Granted"
        case .denied:
            "Denied"
        }
    }
}

struct PermissionSnapshot: Equatable {
    let microphone: MicrophoneAccessState
    let accessibilityTrusted: Bool

    var isReady: Bool {
        microphone == .granted && accessibilityTrusted
    }
}

@MainActor
final class PermissionService {
    /// Reads current permission state. NOTE: macOS exposes no API that reports permission
    /// changes live within a running process — `AXIsProcessTrusted()` and
    /// `AVCaptureDevice.authorizationStatus(for:)` both read a per-process cache that `tccd`
    /// never invalidates mid-run. The UI compensates by re-snapshotting on app re-activation
    /// (the user returns to Voice right after toggling in System Settings) and on a short
    /// poll while the Settings window is visible. A `CGEvent` tap probe was tried and removed:
    /// once a tap succeeds it keeps succeeding after revocation, so it is not actually live.
    func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: microphoneState(),
            accessibilityTrusted: AXIsProcessTrusted()
        )
    }

    func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Clears any stale TCC entry for this app, then prompts for fresh Accessibility access.
    ///
    /// Voice is ad-hoc signed, so every release carries a new code-signature hash.
    /// macOS caches Accessibility grants against that hash — after an update the stored
    /// grant no longer matches and `AXIsProcessTrusted()` silently returns false without
    /// re-prompting. Resetting the TCC entry first ensures the system prompt always fires.
    func promptForAccessibilityAccess() -> Bool {
        resetAccessibilityTCCEntry()
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Private

    private func resetAccessibilityTCCEntry() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        guard let tccutil = resolveTCCUtil() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tccutil)
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try? process.run()
        process.waitUntilExit()
    }

    private func resolveTCCUtil() -> String? {
        let candidates = ["/usr/bin/tccutil", "/usr/local/bin/tccutil"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func openMicrophoneSettings() {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func microphoneState() -> MicrophoneAccessState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            .notDetermined
        case .authorized:
            .granted
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }

    private func openSettingsURL(_ rawValue: String) {
        guard let url = URL(string: rawValue) else { return }
        NSWorkspace.shared.open(url)
    }
}
