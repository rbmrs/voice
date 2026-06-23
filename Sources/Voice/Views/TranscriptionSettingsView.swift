import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptionSettingsView: View {
    private let controlColumnWidth: CGFloat = 360
    private let languageControlWidth: CGFloat = 174

    private static let featuredModelIDs = [
        "whisper-large-v3-turbo-q8_0",
        "whisper-small-multilingual",
        "whisper-base-en",
        "whisper-large-v3",
    ]

    @ObservedObject var settings: AppSettings
    @ObservedObject var modelLibrary: ModelLibrary

    var body: some View {
        SettingsPage(title: "Transcription") {
            languageCard

            if hasWhisperIssue {
                whisperProblemCard
            }

            VStack(alignment: .leading, spacing: 12) {
                SettingsSectionTitle(title: "Models")

                ManagedModelGrid(
                    models: modelLibrary.models(for: .whisper),
                    activePath: settings.whisperModelPath,
                    featuredModelIDs: Self.featuredModelIDs,
                    collapsedLimit: 4,
                    settings: settings,
                    modelLibrary: modelLibrary
                )
            }
        }
    }

    private var languageCard: some View {
        SettingsCard(title: "Language & Audio") {
            SettingsRow(title: "Active Language") {
                TrailingControlColumn(width: controlColumnWidth) {
                    Picker("Active Language", selection: $settings.whisperLanguage) {
                        ForEach(AppSettings.whisperLanguageOptions) { option in
                            Text(option.title).tag(option.code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            SettingsRowDivider()

            SettingsRow(title: "Switch Language Shortcut") {
                TrailingControlColumn(width: controlColumnWidth) {
                    KeyboardShortcuts.Recorder(for: .preferredWhisperLanguageCycle)
                }
            }

            SettingsRowDivider()

            SettingsRow(title: "Preferred Languages") {
                TrailingControlColumn(width: controlColumnWidth) {
                    HStack(spacing: 12) {
                        preferredLanguagePicker(
                            title: "Preferred Language 1",
                            selection: $settings.preferredWhisperLanguageOne
                        )

                        preferredLanguagePicker(
                            title: "Preferred Language 2",
                            selection: $settings.preferredWhisperLanguageTwo
                        )
                    }
                }
            }

            SettingsRowDivider()

            SettingsRow(title: "Skip Silence") {
                TrailingControlColumn(width: controlColumnWidth) {
                    skipSilenceControl
                }
            }
        }
    }

    private func preferredLanguagePicker(
        title: String,
        selection: Binding<String>
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(AppSettings.preferredWhisperLanguageOptions) { option in
                Text(option.title).tag(option.code)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: languageControlWidth)
        .accessibilityLabel(title)
    }

    private var skipSilenceControl: some View {
        let isDownloading = modelLibrary.isSkipSilenceDownloading
        let binding = Binding(
            get: { settings.enableVAD },
            set: { modelLibrary.setSkipSilence($0, in: settings) }
        )

        return VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                }

                Toggle("Skip Silence", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(isDownloading)
            }

            if isDownloading {
                Text("Downloading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let model = modelLibrary.skipSilenceModel,
               case .failed = modelLibrary.state(for: model) {
                Text("Download failed. Toggle Skip Silence to retry.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var hasWhisperIssue: Bool {
        settings.whisperExecutableValidation.needsAttention
            || settings.whisperModelValidation.needsAttention
            || showsWhisperLanguageIssue
    }

    private var showsWhisperLanguageIssue: Bool {
        !settings.whisperModelValidation.isBlocking
            && settings.whisperLanguageValidation.needsAttention
    }

    private var whisperProblemCard: some View {
        SettingsCard(title: "Whisper Needs Attention") {
            if settings.whisperExecutableValidation.needsAttention {
                SettingsProblemRow(validation: settings.whisperExecutableValidation) {
                    HStack(spacing: 8) {
                        Button("Resolve") {
                            _ = settings.resolveWhisperExecutable()
                        }

                        Button("Browse…") {
                            browseForExecutable { settings.whisperExecutablePath = $0 }
                        }
                    }
                    .controlSize(.small)
                }
            }

            if settings.whisperExecutableValidation.needsAttention,
               settings.whisperModelValidation.needsAttention {
                SettingsRowDivider()
            }

            if settings.whisperModelValidation.needsAttention {
                SettingsProblemRow(
                    validation: settings.whisperModelValidation,
                    message: whisperModelIssueMessage
                ) {
                    Button("Choose File…") {
                        browseForModel { settings.whisperModelPath = $0 }
                    }
                    .controlSize(.small)
                }
            }

            if (settings.whisperExecutableValidation.needsAttention
                || settings.whisperModelValidation.needsAttention),
               showsWhisperLanguageIssue {
                SettingsRowDivider()
            }

            if showsWhisperLanguageIssue {
                SettingsProblemRow(validation: settings.whisperLanguageValidation) {
                    EmptyView()
                }
            }
        }
    }

    private var whisperModelIssueMessage: String {
        if settings.whisperModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            "Choose or download a Whisper model."
        } else {
            settings.whisperModelValidation.message
        }
    }

    private func browseForExecutable(onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose whisper-cli"
        panel.message = "Select the installed CLI executable."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPick(url.path)
    }

    private func browseForModel(onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Whisper model"
        panel.message = "Select a local Whisper model file."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.directoryURL = modelLibrary.installDirectory(for: .whisper)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPick(url.path)
    }
}
