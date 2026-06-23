import KeyboardShortcuts
import SwiftUI

struct GeneralSettingsView: View {
    private let controlColumnWidth: CGFloat = 220

    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(title: "General") {
            HStack(alignment: .top, spacing: 20) {
                dictationCard
                permissionsCard
            }
        }
    }

    private var dictationCard: some View {
        SettingsCard(title: "Dictation") {
            SettingsRow(title: "Dictation Shortcut", labelWidth: 132) {
                TrailingControlColumn(width: controlColumnWidth) {
                    KeyboardShortcuts.Recorder(for: .dictationTrigger)
                }
            }

            SettingsRowDivider()

            SettingsRow(title: "Recording Mode", labelWidth: 132) {
                TrailingControlColumn(width: controlColumnWidth) {
                    Picker("Recording Mode", selection: $settings.triggerMode) {
                        ForEach(RecordingTriggerMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            SettingsRowDivider()

            SettingsRow(title: "Insert Using", labelWidth: 132) {
                TrailingControlColumn(width: controlColumnWidth) {
                    Picker("Insert Using", selection: $settings.insertionMode) {
                        ForEach(TextInsertionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var permissionsCard: some View {
        SettingsCard(title: "Permissions") {
            permissionRow(
                title: "Microphone",
                isGranted: coordinator.permissions.microphone == .granted,
                status: coordinator.permissions.microphone.title,
                actionTitle: microphoneActionTitle,
                action: microphoneAction
            )

            SettingsRowDivider()

            permissionRow(
                title: "Accessibility",
                isGranted: coordinator.permissions.accessibilityTrusted,
                status: coordinator.permissions.accessibilityTrusted ? "Granted" : "Missing",
                actionTitle: coordinator.permissions.accessibilityTrusted ? "Open Settings" : "Prompt",
                action: {
                    if coordinator.permissions.accessibilityTrusted {
                        coordinator.openAccessibilitySettings()
                    } else {
                        coordinator.promptForAccessibilityAccess()
                    }
                }
            )
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func permissionRow(
        title: String,
        isGranted: Bool,
        status: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(actionTitle, action: action)
                .controlSize(.small)
        }
        .frame(minHeight: 34)
    }

    private var microphoneActionTitle: String {
        switch coordinator.permissions.microphone {
        case .notDetermined:
            "Allow"
        case .granted, .denied:
            "Open Settings"
        }
    }

    private func microphoneAction() {
        switch coordinator.permissions.microphone {
        case .notDetermined:
            Task {
                await coordinator.requestMicrophoneAccess()
            }
        case .granted, .denied:
            coordinator.openMicrophoneSettings()
        }
    }
}
