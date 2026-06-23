import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RefinementSettingsView: View {
    private let controlColumnWidth: CGFloat = 360

    @ObservedObject var settings: AppSettings
    @ObservedObject var modelLibrary: ModelLibrary

    var body: some View {
        SettingsPage(title: "Refinement") {
            cleanupCard

            if showsLlamaControls {
                if hasLlamaIssue {
                    llamaProblemCard
                }

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionTitle(title: "Models")

                    ManagedModelGrid(
                        models: modelLibrary.models(for: .llama),
                        activePath: settings.llamaModelPath,
                        settings: settings,
                        modelLibrary: modelLibrary
                    )
                }
            }
        }
    }

    private var cleanupCard: some View {
        SettingsCard(title: "Cleanup") {
            SettingsRow(title: "Second Pass Cleanup") {
                TrailingControlColumn(width: controlColumnWidth) {
                    Toggle("Second Pass Cleanup", isOn: $settings.enableRefinement)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            if settings.enableRefinement {
                SettingsRowDivider()

                SettingsRow(title: "Backend") {
                    TrailingControlColumn(width: controlColumnWidth) {
                        Picker("Backend", selection: $settings.refinementBackend) {
                            ForEach(RefinementBackend.allCases) { backend in
                                Text(backend.title).tag(backend)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }

                if settings.refinementBackend == .llamaCPP {
                    SettingsRowDivider()

                    SettingsRow(title: "Profile") {
                        TrailingControlColumn(width: controlColumnWidth) {
                            Picker("Profile", selection: $settings.refinementProfile) {
                                ForEach(RefinementProfile.allCases) { profile in
                                    Text(profile.title).tag(profile)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                }
            }
        }
    }

    private var showsLlamaControls: Bool {
        settings.enableRefinement && settings.refinementBackend == .llamaCPP
    }

    private var hasLlamaIssue: Bool {
        settings.llamaExecutableValidation.needsAttention
            || settings.llamaModelValidation.needsAttention
    }

    private var llamaProblemCard: some View {
        SettingsCard(title: "llama.cpp Needs Attention") {
            if settings.llamaExecutableValidation.needsAttention {
                SettingsProblemRow(validation: settings.llamaExecutableValidation) {
                    HStack(spacing: 8) {
                        Button("Resolve") {
                            _ = settings.resolveLlamaExecutable()
                        }

                        Button("Browse…") {
                            browseForExecutable { settings.llamaExecutablePath = $0 }
                        }
                    }
                    .controlSize(.small)
                }
            }

            if settings.llamaExecutableValidation.needsAttention,
               settings.llamaModelValidation.needsAttention {
                SettingsRowDivider()
            }

            if settings.llamaModelValidation.needsAttention {
                SettingsProblemRow(
                    validation: settings.llamaModelValidation,
                    message: llamaModelIssueMessage
                ) {
                    Button("Choose File…") {
                        browseForModel { settings.llamaModelPath = $0 }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var llamaModelIssueMessage: String {
        if settings.llamaModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            "Choose or download a refinement model."
        } else {
            settings.llamaModelValidation.message
        }
    }

    private func browseForExecutable(onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose llama-cli"
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
        panel.title = "Choose a refinement model"
        panel.message = "Select a local GGUF model file."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.directoryURL = modelLibrary.installDirectory(for: .llama)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPick(url.path)
    }
}
