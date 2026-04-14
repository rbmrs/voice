import AppKit
import Foundation
import KeyboardShortcuts

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var permissions: PermissionSnapshot
    @Published private(set) var lastInsertedText: String?
    @Published private(set) var lastErrorMessage: String?

    let settings: AppSettings
    let modelLibrary: ModelLibrary

    private let permissionService: PermissionService
    private let audioCaptureService: AudioCaptureService
    private let transcriber: SpeechTranscribing
    private let heuristicRefiner: TextRefining
    private let llamaRefiner: TextRefining
    private let insertionService: TextInsertionService
    private let overlayController: OverlayPanelController

    private var activePipelineTask: Task<Void, Never>?
    private var escapeMonitor: Any?

    init(
        settings: AppSettings = AppSettings(),
        modelLibrary: ModelLibrary = ModelLibrary(),
        permissionService: PermissionService = PermissionService(),
        audioCaptureService: AudioCaptureService = AudioCaptureService(),
        transcriber: SpeechTranscribing = WhisperCppTranscriber(),
        heuristicRefiner: TextRefining = HeuristicTextRefiner(),
        llamaRefiner: TextRefining = LlamaCppTextRefiner(),
        insertionService: TextInsertionService = TextInsertionService(),
        overlayController: OverlayPanelController = OverlayPanelController()
    ) {
        self.settings = settings
        self.modelLibrary = modelLibrary
        self.permissionService = permissionService
        self.audioCaptureService = audioCaptureService
        self.transcriber = transcriber
        self.heuristicRefiner = heuristicRefiner
        self.llamaRefiner = llamaRefiner
        self.insertionService = insertionService
        self.overlayController = overlayController
        self.permissions = permissionService.snapshot()

        registerHotkeys()
    }

    var canStart: Bool {
        activePipelineTask == nil && !state.isRecording
    }

    func primaryAction() {
        Task { @MainActor in
            if state.isRecording {
                await stopRecordingAndProcess()
            } else {
                await startRecording()
            }
        }
    }

    func cancel() {
        guard state != .idle else { return }
        activePipelineTask?.cancel()
        activePipelineTask = nil
        if state.isRecording {
            _ = try? audioCaptureService.stopRecording()
        }
        transition(to: .cancelled)
        scheduleReset(after: .milliseconds(800), expectedState: .cancelled)
    }

    func refreshPermissions() {
        permissions = permissionService.snapshot()
    }

    func promptForAccessibilityAccess() {
        _ = permissionService.promptForAccessibilityAccess()
        refreshPermissions()
    }

    func openMicrophoneSettings() {
        permissionService.openMicrophoneSettings()
    }

    func openAccessibilitySettings() {
        permissionService.openAccessibilitySettings()
    }

    func requestMicrophoneAccess() async {
        _ = await permissionService.requestMicrophoneAccess()
        refreshPermissions()
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func registerHotkeys() {
        // Global Escape monitor — cancels any active dictation state.
        // keyCode 53 = Escape; only fires when dictation is in progress.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }

        KeyboardShortcuts.onKeyDown(for: .dictationTrigger) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch self.settings.triggerMode {
                case .holdToTalk:
                    await self.startRecording()
                case .toggle:
                    if self.state.isRecording {
                        await self.stopRecordingAndProcess()
                    } else {
                        await self.startRecording()
                    }
                }
            }
        }

        KeyboardShortcuts.onKeyUp(for: .dictationTrigger) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.settings.triggerMode == .holdToTalk else { return }
                await self.stopRecordingAndProcess()
            }
        }
    }

    private func startRecording() async {
        guard activePipelineTask == nil else { return }
        guard !state.isRecording else { return }

        let isReady = await ensureReadyForDictation()
        guard isReady else { return }

        do {
            _ = try audioCaptureService.startRecording()
            lastErrorMessage = nil
            transition(to: .listening)
        } catch {
            present(error)
        }
    }

    private func stopRecordingAndProcess() async {
        guard state.isRecording else { return }

        do {
            let audioURL = try audioCaptureService.stopRecording()
            transition(to: .transcribing)

            activePipelineTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runPipeline(audioURL: audioURL)
            }
        } catch {
            present(error)
        }
    }

    private func runPipeline(audioURL: URL) async {
        defer {
            activePipelineTask = nil
            try? FileManager.default.removeItem(at: audioURL)
        }

        do {
            let rawText = stripWhisperHallucinations(
                try await transcriber.transcribe(audioURL: audioURL, settings: settings)
            )
            try Task.checkCancellation()

            var finalText = rawText

            if settings.enableRefinement {
                transition(to: .refining)
                finalText = try await activeRefiner().refine(rawText, settings: settings)
                try Task.checkCancellation()
            }

            transition(to: .inserting)
            try await insertionService.insert(text: finalText, mode: settings.insertionMode)

            lastInsertedText = finalText
            lastErrorMessage = nil
            transition(to: .completed(finalText))
            scheduleReset(after: .seconds(1.2), expectedState: state)
        } catch is CancellationError {
            // cancel() already transitioned to .cancelled — nothing to do
        } catch {
            present(error)
            scheduleReset(after: .seconds(2), expectedState: state)
        }
    }

    private func ensureReadyForDictation() async -> Bool {
        refreshPermissions()

        if permissions.microphone == .notDetermined {
            _ = await permissionService.requestMicrophoneAccess()
            refreshPermissions()
        }

        guard permissions.microphone == .granted else {
            present(DictationServiceError.permission("Microphone access is required before recording."))
            return false
        }

        guard permissions.accessibilityTrusted else {
            present(DictationServiceError.permission("Accessibility access is required to insert text into the frontmost app."))
            return false
        }

        if let issue = settings.whisperConfigurationIssue {
            present(DictationServiceError.configuration(issue))
            return false
        }

        if settings.enableRefinement && settings.refinementBackend == .llamaCPP {
            if let issue = settings.llamaConfigurationIssue {
                present(DictationServiceError.configuration(issue))
                return false
            }
        }

        return true
    }

    private func activeRefiner() -> TextRefining {
        switch settings.refinementBackend {
        case .heuristic:
            heuristicRefiner
        case .llamaCPP:
            llamaRefiner
        }
    }

    private func transition(to newState: DictationState) {
        state = newState

        switch newState {
        case .idle:
            overlayController.hide()
        default:
            overlayController.show(state: newState)
        }
    }

    private func present(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastErrorMessage = message
        transition(to: .error(message))
    }

    /// Strips trailing phrases that whisper.cpp hallucinates at the end of short or silent recordings.
    private func stripWhisperHallucinations(_ text: String) -> String {
        // These phrases appear when whisper fills end-of-audio silence with common sentence completions.
        let hallucinations: [String] = [
            "thank you for watching",
            "thank you for listening",
            "thanks for watching",
            "thanks for listening",
            "thank you very much",
            "thank you for your attention",
            "thank you for your time",
            "thank you",
            "thanks",
        ]

        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        for phrase in hallucinations {
            // Match the phrase at the end, optionally preceded by punctuation/whitespace.
            let pattern = #"[,.\s]*\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"[.!]?\s*$"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
               match.range.location != 0 // don't strip if the entire text is just the hallucination
            {
                result = String(result[result.startIndex ..< Range(match.range, in: result)!.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        return result.isEmpty ? text : result
    }

    private func scheduleReset(after duration: Duration, expectedState: DictationState) {
        Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard self.state == expectedState else { return }
            self.transition(to: .idle)
        }
    }
}
