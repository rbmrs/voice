import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Dictation Shortcut", name: .dictationTrigger)

                Picker("Recording Mode", selection: $settings.triggerMode) {
                    ForEach(RecordingTriggerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Text("Hold-to-talk feels closer to SuperWhisper. Toggle mode is useful for longer dictation bursts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                LabeledContent("Whisper CLI") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("/opt/homebrew/bin/whisper-cli", text: $settings.whisperExecutablePath)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 420)
                        ValidationMessage(validation: settings.whisperExecutableValidation)
                    }
                }

                LabeledContent("Whisper Model") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("/path/to/ggml-large-v3-turbo.bin", text: $settings.whisperModelPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 420)
                        ValidationMessage(validation: settings.whisperModelValidation)
                    }
                }

                LabeledContent("Language") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Language", selection: $settings.whisperLanguage) {
                            ForEach(AppSettings.whisperLanguageOptions) { option in
                                Text(option.title).tag(option.code)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)

                        ValidationMessage(validation: settings.whisperLanguageValidation)
                    }
                }

                Text("Use the picker instead of typing raw language codes. If the selected model is an English-only `.en` model, Auto Detect will be treated as English.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Refinement") {
                Toggle("Enable Second Pass Cleanup", isOn: $settings.enableRefinement)

                if settings.enableRefinement {
                    Picker("Backend", selection: $settings.refinementBackend) {
                        ForEach(RefinementBackend.allCases) { backend in
                            Text(backend.title).tag(backend)
                        }
                    }

                    Picker("Profile", selection: $settings.refinementProfile) {
                        ForEach(RefinementProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }

                    switch settings.refinementBackend {
                    case .heuristic:
                        Text("Heuristic mode removes filler words, fixes capitalization, and closes punctuation without loading a second model.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .llamaCPP:
                        LabeledContent("Llama CLI") {
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("/opt/homebrew/bin/llama-cli", text: $settings.llamaExecutablePath)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: 420)
                                ValidationMessage(validation: settings.llamaExecutableValidation)
                            }
                        }

                        LabeledContent("Llama Model") {
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("/path/to/model.gguf", text: $settings.llamaModelPath)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: 420)
                                ValidationMessage(validation: settings.llamaModelValidation)
                            }
                        }

                        Text("For the best local polish pass, point llama.cpp at a small instruct-tuned GGUF model such as Phi-3 Mini, Llama 3.2 3B Instruct, or Mistral 7B Instruct.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Insertion") {
                Picker("Insert Using", selection: $settings.insertionMode) {
                    ForEach(TextInsertionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Text("Pasteboard mode is faster and feels closer to commercial dictation tools. Keystrokes mode avoids replacing the clipboard, but is slower.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Expected Setup") {
                Text("The app is a menu-bar utility. Accessibility and Microphone permissions must both be granted for end-to-end dictation into other apps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("If you package this into an Xcode app target for distribution, add an `NSMicrophoneUsageDescription` entry to the app Info.plist.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 720)
    }
}

private struct ValidationMessage: View {
    let validation: PathValidation

    var body: some View {
        Label(validation.message, systemImage: iconName)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var tint: Color {
        switch validation.status {
        case .valid:
            .green
        case .warning:
            .orange
        case .invalid:
            .red
        }
    }

    private var iconName: String {
        switch validation.status {
        case .valid:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .invalid:
            "xmark.circle.fill"
        }
    }
}
