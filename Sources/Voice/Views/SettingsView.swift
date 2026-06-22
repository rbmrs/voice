import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private let settingsLabelWidth: CGFloat = 128

    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var modelLibrary: ModelLibrary

    // macOS sends no notification when an Accessibility/TCC grant changes, so the only
    // reliable way to reflect it live is to re-check while this window is on screen.
    // AXIsProcessTrusted() is a cheap in-process call; a 1s poll is negligible and lets
    // the status flip to "Granted" the moment the user toggles it in System Settings,
    // without forcing them to close and reopen the window. `isVisible` gates the work so
    // a closed/background Settings window does no polling.
    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var isVisible = false

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Dictation Shortcut", name: .dictationTrigger)

                Picker("Recording Mode", selection: $settings.triggerMode) {
                    ForEach(RecordingTriggerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                KeyboardShortcuts.Recorder("Switch Language Shortcut", name: .preferredWhisperLanguageCycle)

                Picker("Preferred Language 1", selection: $settings.preferredWhisperLanguageOne) {
                    ForEach(AppSettings.preferredWhisperLanguageOptions) { option in
                        Text(option.title).tag(option.code)
                    }
                }

                Picker("Preferred Language 2", selection: $settings.preferredWhisperLanguageTwo) {
                    ForEach(AppSettings.preferredWhisperLanguageOptions) { option in
                        Text(option.title).tag(option.code)
                    }
                }

                Text("The shortcut cycles the active language between the two above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Current Status") {
                permissionStatusRow(
                    title: "Microphone",
                    systemImage: coordinator.permissions.microphone == .granted ? "checkmark.circle.fill" : "mic.slash",
                    status: coordinator.permissions.microphone.title,
                    actionTitle: coordinator.permissions.microphone == .granted ? "Open Settings" : "Allow",
                    action: {
                        if coordinator.permissions.microphone == .granted {
                            coordinator.openMicrophoneSettings()
                        } else {
                            Task {
                                await coordinator.requestMicrophoneAccess()
                            }
                        }
                    }
                )

                permissionStatusRow(
                    title: "Accessibility",
                    systemImage: coordinator.permissions.accessibilityTrusted ? "checkmark.circle.fill" : "hand.raised",
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

                if !settings.isWhisperConfigured {
                    statusCallout(
                        text: settings.whisperConfigurationIssue ?? "Set the whisper-cli path and a local Whisper model file above.",
                        tint: .orange
                    )
                }

                if settings.enableRefinement {
                    if settings.refinementBackend == .llamaCPP && !settings.isLlamaConfigured {
                        statusCallout(
                            text: settings.llamaConfigurationIssue ?? "Refinement is enabled, but llama.cpp is not fully configured.",
                            tint: .orange
                        )
                    }
                }
            }

            Section("Transcription") {
                settingsRow(title: "Whisper CLI") {
                    compactExecutableResolver(
                        validation: settings.whisperExecutableValidation,
                        browsePrompt: "Choose whisper-cli",
                        onResolve: { _ = settings.resolveWhisperExecutable() },
                        onBrowse: { settings.whisperExecutablePath = $0 }
                    )
                }

                settingsRow(title: "Whisper Model") {
                    compactManagedModelSelector(
                        validation: settings.whisperModelValidation,
                        engine: .whisper,
                        browsePrompt: "Choose a Whisper model",
                        onBrowse: { settings.whisperModelPath = $0 }
                    )
                }

                LabeledContent("Download Catalog") {
                    managedModelCatalog(
                        models: modelLibrary.models(for: .whisper),
                        activePath: settings.whisperModelPath,
                        engine: .whisper
                    )
                }

                settingsRow(title: "Active Language") {
                    HStack(spacing: 10) {
                        ValidationMessage(validation: settings.whisperLanguageValidation)

                        Spacer(minLength: 12)

                        Picker("Language", selection: $settings.whisperLanguage) {
                            ForEach(AppSettings.whisperLanguageOptions) { option in
                                Text(option.title).tag(option.code)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                skipSilenceToggle
            }

            Section("Refinement") {
                Toggle("Enable Second Pass Cleanup", isOn: $settings.enableRefinement)

                if settings.enableRefinement {
                    Picker("Backend", selection: $settings.refinementBackend) {
                        ForEach(RefinementBackend.allCases) { backend in
                            Text(backend.title).tag(backend)
                        }
                    }

                    switch settings.refinementBackend {
                    case .heuristic:
                        Text("Cleans filler, capitalization, and punctuation without a second model.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .llamaCPP:
                        Picker("Profile", selection: $settings.refinementProfile) {
                            ForEach(RefinementProfile.allCases) { profile in
                                Text(profile.title).tag(profile)
                            }
                        }

                        Text(settings.refinementProfile.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        settingsRow(title: "Llama CLI") {
                            compactExecutableResolver(
                                validation: settings.llamaExecutableValidation,
                                browsePrompt: "Choose llama-cli",
                                onResolve: { _ = settings.resolveLlamaExecutable() },
                                onBrowse: { settings.llamaExecutablePath = $0 }
                            )
                        }

                        settingsRow(title: "Llama Model") {
                            compactManagedModelSelector(
                                validation: settings.llamaModelValidation,
                                engine: .llama,
                                browsePrompt: "Choose a GGUF refinement model",
                                onBrowse: { settings.llamaModelPath = $0 }
                            )
                        }

                        LabeledContent("Download Catalog") {
                            managedModelCatalog(
                                models: modelLibrary.models(for: .llama),
                                activePath: settings.llamaModelPath,
                                engine: .llama
                            )
                        }

                        Text("For other GGUF models, use Browse Local File.")
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

                Text(insertionModeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 760, idealWidth: 760, minHeight: 720, idealHeight: 980)
        .onReceive(permissionPoll) { _ in
            guard isVisible else { return }
            coordinator.refreshPermissions()
        }
        // Primary live-feeling trigger: the user grants/revokes in System Settings and then
        // switches back to Voice. macOS has no in-process permission-change event, but the
        // cached status is usually accurate again by the time the app reactivates, so this
        // catches the common toggle-then-return flow immediately.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.refreshPermissions()
        }
        .onAppear {
            isVisible = true
            coordinator.refreshPermissions()
        }
        .onDisappear {
            isVisible = false
        }
    }

    /// One friendly switch for the whole VAD feature. Flipping it on silently downloads the
    /// tiny (~2 MB) Silero model if needed and wires everything; off just disables it. No
    /// model picker, path, or catalog — `ModelLibrary.setSkipSilence` owns the lifecycle.
    private var skipSilenceToggle: some View {
        let isDownloading = modelLibrary.isSkipSilenceDownloading
        let binding = Binding(
            get: { settings.enableVAD },
            set: { modelLibrary.setSkipSilence($0, in: settings) }
        )

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("Skip Silence", isOn: binding)
                    .disabled(isDownloading)

                if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Trims silence for faster, cleaner transcripts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let model = modelLibrary.skipSilenceModel,
               case .failed = modelLibrary.state(for: model) {
                Text("Couldn't download the Skip Silence model. Check your connection and try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func settingsRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .frame(width: settingsLabelWidth, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var insertionModeDescription: String {
        switch settings.insertionMode {
        case .pasteboard:
            "Pastes the result and keeps it on your clipboard."
        case .keystrokes:
            "Types the result directly and keeps it on your clipboard."
        }
    }

    @ViewBuilder
    private func compactExecutableResolver(
        validation: PathValidation,
        browsePrompt: String,
        onResolve: @escaping () -> Void,
        onBrowse: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            ValidationMessage(validation: validation)

            Spacer(minLength: 12)

            if validation.status != .valid {
                Button("Resolve") {
                    onResolve()
                }
                .controlSize(.small)

                Button("Browse...") {
                    browseForExecutable(prompt: browsePrompt, onPick: onBrowse)
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionStatusRow(
        title: String,
        systemImage: String,
        status: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Label("\(title): \(status)", systemImage: systemImage)
            Spacer()
            Button(actionTitle) {
                action()
            }
        }
        .font(.callout)
    }

    private func statusCallout(text: String, tint: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func compactManagedModelSelector(
        validation: PathValidation,
        engine: ManagedModelEngine,
        browsePrompt: String,
        onBrowse: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            ValidationMessage(validation: validation)

            Spacer(minLength: 12)

            Button("Browse Local File...") {
                browseForModel(engine: engine, prompt: browsePrompt, onPick: onBrowse)
            }
            .controlSize(.small)

            Button("Open Models Folder") {
                modelLibrary.revealInstallDirectory(for: engine)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func managedModelCatalog(
        models: [ManagedModelDescriptor],
        activePath: String,
        engine: ManagedModelEngine
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(models) { descriptor in
                ManagedModelCard(
                    descriptor: descriptor,
                    downloadState: modelLibrary.state(for: descriptor),
                    isInstalled: modelLibrary.isInstalled(descriptor),
                    isActive: modelLibrary.destinationURL(for: descriptor).path == activePath,
                    onDownload: {
                        modelLibrary.download(descriptor)
                    },
                    onActivate: {
                        modelLibrary.activate(descriptor, in: settings)
                    },
                    onDelete: {
                        modelLibrary.delete(descriptor, in: settings)
                    }
                )
            }

            if engine == .llama && settings.refinementBackend == .heuristic {
                Text("Heuristic cleanup works without any second model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 470, alignment: .leading)
    }

    private func browseForExecutable(prompt: String, onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.message = "Select the installed CLI executable."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPick(url.path)
    }

    private func browseForModel(
        engine: ManagedModelEngine,
        prompt: String,
        onPick: @escaping (String) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.message = "Select a local model file."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [engine == .llama
                                     ? (UTType(filenameExtension: "gguf") ?? .data)
                                     : (UTType(filenameExtension: "bin") ?? .data)]
        panel.directoryURL = modelLibrary.installDirectory(for: engine)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPick(url.path)
    }
}

private struct ManagedModelCard: View {
    let descriptor: ManagedModelDescriptor
    let downloadState: ManagedModelDownloadState
    let isInstalled: Bool
    let isActive: Bool
    let onDownload: () -> Void
    let onActivate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(descriptor.title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 12)

                actionView
            }

            HStack(spacing: 8) {
                ModelBadge(text: descriptor.sizeLabel)
                ModelBadge(text: descriptor.languageSummary)
                ModelBadge(text: descriptor.speedSummary)
                ModelBadge(text: descriptor.qualitySummary)
            }

            switch downloadState {
            case .idle:
                EmptyView()
            case .downloading:
                // Dormant: the compact "Downloading NN%" label in actionView is the single
                // download indicator. The full progress block below is kept for easy revival.
                EmptyView()
                // VStack(alignment: .leading, spacing: 6) {
                //     HStack(spacing: 8) {
                //         if let progress {
                //             Text("\(Int((progress * 100).rounded()))%")
                //                 .font(.caption.weight(.semibold))
                //                 .monospacedDigit()
                //                 .foregroundStyle(.secondary)
                //         } else {
                //             Text("Starting download")
                //                 .font(.caption.weight(.semibold))
                //                 .foregroundStyle(.secondary)
                //         }
                //
                //         Text("Downloading into the managed model folder. This can take a while for larger models.")
                //             .font(.caption)
                //             .foregroundStyle(.secondary)
                //     }
                //
                //     if let progress {
                //         ProgressView(value: progress, total: 1)
                //             .controlSize(.small)
                //     } else {
                //         ProgressView()
                //             .controlSize(.small)
                //     }
                // }
            case .failed(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isActive ? 1.5 : 1)
        )
    }

    @ViewBuilder
    private var actionView: some View {
        switch downloadState {
        case .downloading(let progress):
            Text(progress.map { "Downloading \(Int(($0 * 100).rounded()))%" } ?? "Downloading")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .failed:
            Button("Retry") {
                onDownload()
            }
        case .idle:
            if isActive {
                HStack(spacing: 8) {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        .foregroundStyle(Color.accentColor)

                    Button("Delete") {
                        onDelete()
                    }
                }
            } else if isInstalled {
                HStack(spacing: 8) {
                    Button("Use") {
                        onActivate()
                    }

                    Button("Delete") {
                        onDelete()
                    }
                }
            } else {
                Button("Download") {
                    onDownload()
                }
            }
        }
    }
}

private struct ModelBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
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
