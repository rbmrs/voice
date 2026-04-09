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
            let rawText = try await transcriber.transcribe(audioURL: audioURL, settings: settings)
            var finalText = rawText

            if settings.enableRefinement {
                transition(to: .refining)
                finalText = try await activeRefiner().refine(rawText, settings: settings)
            }

            transition(to: .inserting)
            try await insertionService.insert(text: finalText, mode: settings.insertionMode)

            lastInsertedText = finalText
            lastErrorMessage = nil
            transition(to: .completed(finalText))
            scheduleReset(after: .seconds(1.2), expectedState: state)
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

    private func scheduleReset(after duration: Duration, expectedState: DictationState) {
        Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard self.state == expectedState else { return }
            self.transition(to: .idle)
        }
    }
}
