import AppKit
import SwiftUI

struct SpeechSettingsView: View {
    private let controlColumnWidth: CGFloat = 260

    /// The speech sandbox offers its own lightweight local models, independent of Refinement.
    private static let localModelIDs = ["gemma-3-1b-it-q4", "qwen2-5-0-5b-instruct-q4"]

    @ObservedObject var settings: AppSettings
    @ObservedObject var modelLibrary: ModelLibrary
    // Shared with SessionSpeechService (single TTS owner) — the app-level service polls
    // and auto-speaks; this pane just renders and drives the same instances.
    @ObservedObject var monitor: ClaudeSessionMonitor
    @ObservedObject var player: SpeechPlayer

    @State private var editorMode: ProfileEditorMode?
    @State private var summarizingSessionID: String?

    private let summarizer = ReplySummarizer()

    var body: some View {
        SettingsPage(title: "Speech") {
            masterToggleCard

            liveSessionsCard

            configurationCard
        }
        .sheet(item: $editorMode) { mode in
            CustomProfileEditor(
                mode: mode,
                caption: "Describe how replies should be summarized for speech, e.g. \"Summarize in two spoken sentences; expand code identifiers and abbreviations into plain words.\"",
                onSave: { settings.upsertSpeechProfile(id: $0, name: $1, prompt: $2) },
                onDelete: { settings.deleteSpeechProfile($0) }
            )
        }
    }

    private var masterToggleCard: some View {
        SettingsCard(title: "Speak Claude Code Replies") {
            SettingsRow(title: "Enabled") {
                TrailingControlColumn(width: controlColumnWidth) {
                    Toggle("", isOn: $settings.speakSessionReplies)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            Text("While on, Voice announces a spoken version of each reply from tracked live Claude Code sessions. Turn individual sessions on or off below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var configurationCard: some View {
        SettingsCard(title: "Configuration") {
            SettingsRow(title: "Read Style") {
                TrailingControlColumn(width: controlColumnWidth) {
                    Picker("Read Style", selection: $settings.speechReplyStyle) {
                        ForEach(SpeechReplyStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            if settings.speechReplyStyle == .summary {
                Text("Short replies are spoken as-is; longer ones are condensed to one or two spoken sentences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsRowDivider()

                SettingsRow(title: "Summary Model") {
                    TrailingControlColumn(width: controlColumnWidth) {
                        Picker("Summary Model", selection: $settings.speechSummaryModel) {
                            ForEach(SpeechSummaryModel.allCases) { model in
                                Text(model.title).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }

                if settings.speechSummaryModel == .local {
                    SettingsRow(title: "Local Model") {
                        TrailingControlColumn(width: controlColumnWidth) {
                            localModelMenu
                        }
                    }

                    Text(localModelCaption)
                        .font(.caption)
                        .foregroundStyle(settings.isSpeechLlamaConfigured || isDownloadingLocalModel ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsRowDivider()

                SettingsRow(title: "Summary Profile") {
                    TrailingControlColumn(width: controlColumnWidth) {
                        profileMenu
                    }
                }
            }

            SettingsRowDivider()

            SettingsRow(title: "System Voice") {
                TrailingControlColumn(width: controlColumnWidth) {
                    Button("Open Voice Settings…") { openSystemVoiceSettings() }
                }
            }
        }
    }

    private var profileMenu: some View {
        Menu {
            Button {
                settings.selectedSpeechProfileID = nil
            } label: {
                profileLabel("Default", selected: settings.selectedSpeechProfileID == nil)
            }

            if !settings.speechProfiles.isEmpty {
                Divider()

                ForEach(settings.speechProfiles) { profile in
                    Button {
                        settings.selectedSpeechProfileID = profile.id
                    } label: {
                        profileLabel(profile.name, selected: settings.selectedSpeechProfileID == profile.id)
                    }
                }
            }

            Divider()

            Button("New Profile…") { editorMode = .new }

            if let profile = settings.selectedSpeechProfile {
                Button("Edit “\(profile.name)”…") { editorMode = .edit(profile) }
            }
        } label: {
            Text(settings.selectedSpeechProfileTitle)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func profileLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var liveSessionsCard: some View {
        SettingsCard(title: "Live Sessions") {
            if monitor.sessions.isEmpty {
                Text("No live sessions. Sessions appear here while Claude Code is working.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(monitor.sessions) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: session.projectPath).lastPathComponent)
                                    .font(.callout.weight(.semibold))
                                Text(session.projectPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(session.lastActivity, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(session.id.prefix(8))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }

                            Toggle("", isOn: trackingBinding(for: session.id))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(!settings.speakSessionReplies)
                                .help("Track this session — replies are only spoken for tracked sessions")
                        }

                        if let reply = session.lastReply {
                            HStack(alignment: .top, spacing: 8) {
                                Text(reply)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)

                                Spacer(minLength: 8)

                                if summarizingSessionID == session.id {
                                    ProgressView()
                                        .controlSize(.small)
                                } else if player.speakingID == session.id {
                                    Button {
                                        player.stop()
                                    } label: {
                                        // Spinning ring with a stop square in the middle —
                                        // "playing, click to stop".
                                        ZStack {
                                            ProgressView()
                                                .controlSize(.small)
                                                .allowsHitTesting(false)
                                            Image(systemName: "stop.fill")
                                                .font(.system(size: 7))
                                                .foregroundStyle(.secondary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Stop speaking")
                                } else {
                                    Button {
                                        speak(reply, sessionID: session.id)
                                    } label: {
                                        Image(systemName: "speaker.wave.2.fill")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(settings.speechReplyStyle == .summary ? "Speak a summary of this reply" : "Speak this reply")
                                }
                            }
                        }
                    }

                    if session != monitor.sessions.last {
                        SettingsRowDivider()
                    }
                }
            }
        }
    }

    // MARK: - Local model selection

    private var localModelOptions: [ManagedModelDescriptor] {
        modelLibrary.models(for: .llama).filter { Self.localModelIDs.contains($0.id) }
    }

    private var selectedLocalModel: ManagedModelDescriptor? {
        localModelOptions.first { modelLibrary.destinationURL(for: $0).path == settings.speechLlamaModelPath }
    }

    private var isDownloadingLocalModel: Bool {
        guard let selected = selectedLocalModel else { return false }
        if case .downloading = modelLibrary.state(for: selected) { return true }
        return false
    }

    private var localModelMenu: some View {
        Menu {
            ForEach(localModelOptions) { model in
                Button {
                    selectLocalModel(model)
                } label: {
                    let title = modelLibrary.isInstalled(model)
                        ? model.title
                        : "\(model.title) (\(model.sizeLabel) download)"
                    profileLabel(title, selected: selectedLocalModel?.id == model.id)
                }
            }
        } label: {
            Text(selectedLocalModel?.title ?? "Choose Model")
        }
        .fixedSize()
    }

    /// Selecting an uninstalled model kicks off its download; the path is wired
    /// immediately so validation flips to valid the moment the file lands.
    private func selectLocalModel(_ model: ManagedModelDescriptor) {
        settings.speechLlamaModelPath = modelLibrary.destinationURL(for: model).path
        if !modelLibrary.isInstalled(model) {
            modelLibrary.download(model)
        }
    }

    private var localModelCaption: String {
        guard let selected = selectedLocalModel else {
            return "Choose a local model, or long replies will be truncated instead of summarized."
        }
        if case .downloading(let progress) = modelLibrary.state(for: selected) {
            if let progress {
                return "Downloading \(selected.title)… \(Int(progress * 100))%"
            }
            return "Downloading \(selected.title)…"
        }
        if case .failed(let message) = modelLibrary.state(for: selected) {
            return "Download failed: \(message)"
        }
        if settings.isSpeechLlamaConfigured {
            return "Summaries run fully on-device with \(selected.title)."
        }
        return "The selected model isn't ready — long replies will be truncated instead of summarized."
    }

    private func trackingBinding(for sessionID: String) -> Binding<Bool> {
        Binding(
            get: { settings.isSessionTracked(sessionID) },
            set: { settings.setSessionTracked(sessionID, $0) }
        )
    }

    private func speak(_ reply: String, sessionID: String) {
        guard settings.speechReplyStyle == .summary else {
            player.speak(reply, id: sessionID)
            return
        }

        summarizingSessionID = sessionID
        let model = settings.speechSummaryModel
        let prompt = settings.resolvedSpeechSummaryPrompt
        let llama = ReplySummarizer.LlamaConfiguration(
            executablePath: settings.llamaExecutablePath,
            modelPath: settings.speechLlamaModelPath,
            isConfigured: settings.isSpeechLlamaConfigured
        )
        Task {
            let spoken = await summarizer.spokenForm(of: reply, model: model, prompt: prompt, llama: llama)
            summarizingSessionID = nil
            player.speak(spoken, id: sessionID)
        }
    }

    private func openSystemVoiceSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_FEATURE_SPOKENCONTENT") else { return }
        NSWorkspace.shared.open(url)
    }
}
