import SwiftUI

struct UpdatesSettingsView: View {
    @ObservedObject var updater: UpdaterService

    private let controlColumnWidth: CGFloat = 260

    var body: some View {
        SettingsPage(title: "Updates") {
            SettingsCard(title: "Software Update") {
                SettingsRow(title: "Current Version", labelWidth: 150) {
                    TrailingControlColumn(width: controlColumnWidth) {
                        Text(versionText)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsRowDivider()

                SettingsRow(title: "Automatic Updates", labelWidth: 150) {
                    TrailingControlColumn(width: controlColumnWidth) {
                        Toggle("", isOn: automaticBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }

                Text("When on, Voice checks for updates daily and installs them automatically when you quit. When off, check manually below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsRowDivider()

                HStack(spacing: 12) {
                    if let lastChecked {
                        Text("Last checked \(lastChecked)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .onAppear {
            // Opening the Updates pane fake-clicks "Check for Updates…" so the interactive update
            // window shows right away when a new version exists. The background check used at launch
            // runs in silent auto-download mode and never surfaces that window. Gated like the button
            // (canCheckForUpdates) so dev builds with no feed don't pop Sparkle's error dialog.
            if updater.canCheckForUpdates {
                updater.checkForUpdates()
            }
        }
    }

    private var automaticBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyUpdates },
            set: { updater.automaticallyUpdates = $0 }
        )
    }

    private var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var lastChecked: String? {
        updater.lastUpdateCheckDate?.formatted(date: .abbreviated, time: .shortened)
    }
}
