import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private let settingsLabelWidth: CGFloat = 128

    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var modelLibrary: ModelLibrary

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Dictation Shortcut", name: .dictationTrigger)

                Picker("Recording Mode", selection: $settings.triggerMode) {
                    ForEach(RecordingTriggerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
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

                settingsRow(title: "Language") {
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

                        Text("For other GGUF models, download them manually and use Browse Local File.")
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

            Section("Expected Setup") {
                Text("The app is a menu-bar utility. Accessibility and Microphone permissions must both be granted for end-to-end dictation into other apps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Managed model downloads are stored in your Library/Application Support folder under Voice/Models so users do not need to manage terminal paths themselves.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("If you package this into an Xcode app target for distribution, add an `NSMicrophoneUsageDescription` entry to the app Info.plist.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 760, idealWidth: 760, minHeight: 720, idealHeight: 980)
        .onAppear {
            coordinator.refreshPermissions()
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
            "Pastes the result, then restores your clipboard."
        case .keystrokes:
            "Types the result directly without using the clipboard."
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

    @ViewBuilder
    private func executableResolver(
        path: String,
        validation: PathValidation,
        resolveButtonTitle: String,
        browsePrompt: String,
        onResolve: @escaping () -> Void,
        onBrowse: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if validation.status == .valid {
                Text(path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ValidationMessage(validation: validation)
            } else {
                HStack(spacing: 10) {
                    Button(resolveButtonTitle) {
                        onResolve()
                    }

                    Button("Browse...") {
                        browseForExecutable(prompt: browsePrompt, onPick: onBrowse)
                    }
                }

                if !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ValidationMessage(validation: validation)
            }
        }
        .frame(minWidth: 470, alignment: .leading)
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
    private func managedModelSelector(
        activePath: Binding<String>,
        validation: PathValidation,
        installedModels: [InstalledManagedModel],
        engine: ManagedModelEngine,
        browsePrompt: String,
        onBrowse: @escaping (String) -> Void
    ) -> some View {
        let options = selectionOptions(installedModels: installedModels, currentPath: activePath.wrappedValue)

        VStack(alignment: .leading, spacing: 8) {
            if options.isEmpty {
                Text("No downloaded \(engine.displayName.lowercased()) models yet. Download one below or browse for a local file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Active Model", selection: activePath) {
                    ForEach(options) { option in
                        Text(option.title).tag(option.path)
                    }
                }
                .labelsHidden()
                .frame(width: 470)
            }

            HStack(spacing: 10) {
                Button("Browse Local File...") {
                    browseForModel(engine: engine, prompt: browsePrompt, onPick: onBrowse)
                }

                Button("Open Models Folder") {
                    modelLibrary.revealInstallDirectory(for: engine)
                }
            }

            if !activePath.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(activePath.wrappedValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ValidationMessage(validation: validation)
        }
        .frame(minWidth: 470, alignment: .leading)
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
                        modelLibrary.delete(descriptor)
                    }
                )
            }

            if engine == .llama && settings.refinementBackend == .heuristic {
                Text("The curated refinement list is intentionally small. Heuristic cleanup works without any second model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 470, alignment: .leading)
    }

    private func selectionOptions(
        installedModels: [InstalledManagedModel],
        currentPath: String
    ) -> [ModelSelectionOption] {
        var options = installedModels.map { installedModel in
            ModelSelectionOption(
                path: installedModel.localURL.path,
                title: installedModel.descriptor.title
            )
        }

        let trimmedPath = currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPath.isEmpty && !options.contains(where: { $0.path == trimmedPath }) {
            let customTitle = URL(fileURLWithPath: trimmedPath).lastPathComponent
            options.insert(ModelSelectionOption(path: trimmedPath, title: "Custom: \(customTitle)"), at: 0)
        }

        return options
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
        panel.allowedContentTypes = [engine == .whisper
                                     ? (UTType(filenameExtension: "bin") ?? .data)
                                     : (UTType(filenameExtension: "gguf") ?? .data)]
        panel.directoryURL = modelLibrary.installDirectory(for: engine)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPick(url.path)
    }
}

private struct ModelSelectionOption: Identifiable, Hashable {
    let path: String
    let title: String

    var id: String { path }
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
                VStack(alignment: .leading, spacing: 4) {
                    Text(descriptor.title)
                        .font(.headline)

                    Text(descriptor.recommendedUse)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                actionView
            }

            HStack(spacing: 8) {
                ModelBadge(text: descriptor.sizeLabel)
                ModelBadge(text: descriptor.languageSummary)
                ModelBadge(text: descriptor.speedSummary)
                ModelBadge(text: descriptor.qualitySummary)
            }

            if let notes = descriptor.notes {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch downloadState {
            case .idle:
                EmptyView()
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if let progress {
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Starting download")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text("Downloading into the managed model folder. This can take a while for larger models.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let progress {
                        ProgressView(value: progress, total: 1)
                            .controlSize(.small)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        case .failed:
            Button("Retry") {
                onDownload()
            }
        case .idle:
            if isActive {
                Text("Active")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
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
