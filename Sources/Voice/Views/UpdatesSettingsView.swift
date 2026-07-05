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

                statusRow

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
            // Opening the pane kicks off a check whose whole lifecycle renders inline below —
            // no Sparkle window ever appears. Gated like the button so dev builds (no feed) stay quiet.
            if updater.canCheckForUpdates {
                updater.checkForUpdates()
            }
        }
    }

    /// Inline status that mirrors Sparkle's flow (checking → available → downloading → ready)
    /// entirely within the pane. Empty in the resting `.idle` state.
    @ViewBuilder
    private var statusRow: some View {
        switch updater.phase {
        case .idle:
            EmptyView()

        case .checking:
            inlineStatus {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").foregroundStyle(.secondary)
            }

        case .upToDate:
            inlineStatus {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Voice is up to date.").foregroundStyle(.secondary)
            }

        case .available(let version):
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                Text("Version \(version) is available.")
                Spacer(minLength: 12)
                Button("Not Now") { updater.dismissUpdate() }
                Button("Install Update") { updater.installUpdate() }
                    .keyboardShortcut(.defaultAction)
            }

        case .downloading(let fraction):
            inlineProgress(title: "Downloading update…", fraction: fraction)

        case .extracting(let fraction):
            inlineProgress(title: "Preparing update…", fraction: fraction)

        case .readyToInstall:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Update ready to install.")
                Spacer(minLength: 12)
                Button("Restart & Install") { updater.installUpdate() }
                    .keyboardShortcut(.defaultAction)
            }

        case .installing:
            inlineStatus {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
            }

        case .failed(let message):
            inlineStatus {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    private func inlineStatus<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private func inlineProgress(title: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
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
