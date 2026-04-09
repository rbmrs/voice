import AppKit
import AVFoundation
import ApplicationServices
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

    func promptForAccessibilityAccess() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
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
