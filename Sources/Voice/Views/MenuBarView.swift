import SwiftUI

struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusHeader
            permissionSection
            configurationSection

            if let message = coordinator.lastErrorMessage {
                callout(text: message, tint: .orange)
            }

            if let lastInsertedText = coordinator.lastInsertedText {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last Inserted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(lastInsertedText)
                        .font(.callout)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 10) {
                Button(coordinator.state.isRecording ? "Stop" : "Start") {
                    coordinator.primaryAction()
                }
                .keyboardShortcut(.defaultAction)

                Button("Settings") {
                    openSettingsWindow()
                }
            }

            Divider()

            HStack {
                Button("Refresh") {
                    coordinator.refreshPermissions()
                }

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: coordinator.state.menuSymbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(headerTint)
                .frame(width: 32, height: 32)
                .background(headerTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(coordinator.state.overlayTitle)
                    .font(.headline)
                Text(coordinator.state.overlayDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Label("Microphone: \(coordinator.permissions.microphone.title)", systemImage: coordinator.permissions.microphone == .granted ? "checkmark.circle.fill" : "mic.slash")
                Spacer()

                if coordinator.permissions.microphone != .granted {
                    Button("Allow") {
                        Task {
                            await coordinator.requestMicrophoneAccess()
                        }
                    }
                }
            }
            .font(.callout)

            HStack {
                Label("Accessibility: \(coordinator.permissions.accessibilityTrusted ? "Granted" : "Missing")", systemImage: coordinator.permissions.accessibilityTrusted ? "checkmark.circle.fill" : "hand.raised")
                Spacer()

                if coordinator.permissions.accessibilityTrusted {
                    Button("Open") {
                        coordinator.openAccessibilitySettings()
                    }
                } else {
                    Button("Prompt") {
                        coordinator.promptForAccessibilityAccess()
                    }
                }
            }
            .font(.callout)
        }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configuration")
                .font(.caption)
                .foregroundStyle(.secondary)

            callout(
                text: coordinator.settings.isWhisperConfigured
                    ? "whisper.cpp is configured."
                    : (coordinator.settings.whisperConfigurationIssue ?? "Set the whisper-cli path and a local Whisper model file in Settings."),
                tint: coordinator.settings.isWhisperConfigured ? .green : .secondary
            )

            if coordinator.settings.enableRefinement {
                callout(
                    text: coordinator.settings.refinementBackend == .heuristic
                        ? "Refinement uses the built-in cleanup pass."
                        : (coordinator.settings.isLlamaConfigured
                            ? "Refinement uses llama.cpp."
                            : (coordinator.settings.llamaConfigurationIssue ?? "Refinement is enabled, but llama.cpp is not fully configured.")),
                    tint: coordinator.settings.refinementBackend == .llamaCPP && !coordinator.settings.isLlamaConfigured ? .orange : .secondary
                )
            } else {
                callout(text: "Second-pass refinement is disabled.", tint: .secondary)
            }
        }
    }

    private func callout(text: String, tint: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func openSettingsWindow() {
        dismiss()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            scheduleSettingsWindowRaise(after: .milliseconds(50))
            scheduleSettingsWindowRaise(after: .milliseconds(200))
        }
    }

    private func scheduleSettingsWindowRaise(after delay: Duration) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            raiseSettingsWindowIfPresent()
        }
    }

    private func raiseSettingsWindowIfPresent() {
        let settingsWindow = NSApp.windows.first(where: { window in
            guard window.isVisible else { return false }
            guard window.styleMask.contains(.titled) else { return false }
            guard !(window is NSPanel) else { return false }

            return window.title.localizedCaseInsensitiveContains("settings")
        }) ?? NSApp.windows.first(where: { window in
            window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        })

        guard let settingsWindow else { return }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
    }

    private var headerTint: Color {
        switch coordinator.state {
        case .idle:
            .secondary
        case .listening:
            .red
        case .transcribing, .refining, .inserting:
            .blue
        case .completed:
            .green
        case .cancelled:
            .secondary
        case .error:
            .orange
        }
    }
}
