import SwiftUI

struct MenuBarView: View {
    private let lastInsertedMinimumHeight: CGFloat = 76

    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var didCopyLastInserted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            appTitleHeader
            lastInsertedSection(text: coordinator.lastInsertedText)

            HStack(spacing: 10) {
                Button("Settings") {
                    openSettingsWindow()
                }

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .onChange(of: coordinator.lastInsertedText) { _, _ in
            didCopyLastInserted = false
        }
        .onDisappear {
            didCopyLastInserted = false
        }
    }

    private var appTitleHeader: some View {
        Text("Voice")
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lastInsertedSection(text: String?) -> some View {
        let hasText = !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last Inserted")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    guard let text else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    didCopyLastInserted = true
                } label: {
                    Label(didCopyLastInserted ? "Copied" : "Copy",
                          systemImage: didCopyLastInserted ? "doc.on.doc.fill" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(didCopyLastInserted ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!hasText)
            }

            ScrollView {
                Group {
                    if let text, hasText {
                        Text(text)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    } else {
                        Text("Your most recent inserted text will appear here.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: lastInsertedMinimumHeight - 20, alignment: .topLeading)
                .padding(10)
            }
            .frame(minHeight: lastInsertedMinimumHeight, maxHeight: 108, alignment: .top)
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
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

        settingsWindow.title = "Voice Settings"
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
    }
}
