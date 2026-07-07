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
    let updater: UpdaterService

    private let permissionService: PermissionService
    private let audioCaptureService: AudioCaptureService
    private let transcriber: SpeechTranscribing
    private let heuristicRefiner: TextRefining
    private let llamaRefiner: TextRefining
    private let insertionService: TextInsertionService
    private let overlayController: OverlayPanelController

    private var activePipelineTask: Task<Void, Never>?
    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?

    init(
        settings: AppSettings = AppSettings(),
        modelLibrary: ModelLibrary = ModelLibrary(),
        updater: UpdaterService = UpdaterService(),
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
        self.updater = updater
        self.permissionService = permissionService
        self.audioCaptureService = audioCaptureService
        self.transcriber = transcriber
        self.heuristicRefiner = heuristicRefiner
        self.llamaRefiner = llamaRefiner
        self.insertionService = insertionService
        self.overlayController = overlayController
        self.permissions = permissionService.snapshot()

        settings.autoHealToolPaths()
        registerHotkeys()

        // Industry-standard launch check: if the user opted into automatic updates, quietly look
        // for a new version on every launch and prompt only when one is available.
        if updater.automaticallyUpdates {
            updater.checkForUpdatesInBackground()
        }

        #if DEBUG
        assertRepetitionCollapseWorks()
        #endif
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
        // Listen for Escape both inside Voice windows and while another app is focused.
        // keyCode 53 = Escape.
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }

        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor [weak self] in
                self?.cancel()
            }
            return event
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

        KeyboardShortcuts.onKeyUp(for: .preferredWhisperLanguageCycle) { [weak self] in
            Task { @MainActor [weak self] in
                self?.cyclePreferredWhisperLanguage()
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
                collapseRepeatedRuns(
                    try await transcriber.transcribe(audioURL: audioURL, settings: settings)
                )
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

    private func cyclePreferredWhisperLanguage() {
        guard activePipelineTask == nil else { return }
        guard !state.isRecording else { return }

        switch settings.cyclePreferredWhisperLanguage() {
        case .switched(let title):
            lastErrorMessage = nil
            transition(to: .languageSwitched(title))
            scheduleReset(after: .seconds(1.2), expectedState: state)
        case .unavailable(let message):
            present(DictationServiceError.configuration(message))
        }
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
        // Error copy is long enough to need a few seconds of read time before auto-dismissing.
        scheduleReset(after: .seconds(4), expectedState: state)
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

// MARK: - Repetition collapse

/// Collapses *consecutive* repeated tokens and phrases that whisper.cpp emits as runaway loops
/// (e.g. "it it it it" or "the way we're getting the way we're getting"). Only adjacent repeats
/// are collapsed, so legitimate non-adjacent repetition is left untouched. This is the
/// deterministic safety net for loops the decoder's own guards (entropy-thold + temperature
/// fallback) miss — whisper.cpp has no compression-ratio check, so long loops still slip through.
func collapseRepeatedRuns(_ text: String) -> String {
    // Intra-token hyphen loops first ("a-it-it-it-it" -> "a-it"): whisper sometimes joins a
    // repeated token with hyphens, hiding it inside one whitespace token. >=3 occurrences
    // required, so legit hyphenated words ("well-being", "state-of-the-art") are untouched.
    var input = text
    if let hyphenLoop = try? NSRegularExpression(pattern: #"\b(\w+)(?:[-–]\1){2,}\b"#, options: [.caseInsensitive]) {
        input = hyphenLoop.stringByReplacingMatches(
            in: input, range: NSRange(input.startIndex..., in: input), withTemplate: "$1")
    }
    var tokens = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard tokens.count > 1 else { return input }

    // Comparison key only: lowercase and strip surrounding punctuation so "three." == "three".
    // Output always keeps the first occurrence's original token (casing + punctuation).
    func key(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }
    var keys = tokens.map(key)

    func collapse(blockSize n: Int, minRepeats: Int) {
        guard tokens.count >= n * minRepeats else { return }
        var outTokens: [String] = []
        var outKeys: [String] = []
        var i = 0
        while i < tokens.count {
            if i + n <= tokens.count {
                let blockKeys = Array(keys[i ..< i + n])
                var reps = 1
                var j = i + n
                while j + n <= tokens.count, Array(keys[j ..< j + n]) == blockKeys {
                    reps += 1
                    j += n
                }
                if reps >= minRepeats {
                    outTokens.append(contentsOf: tokens[i ..< i + n])
                    outKeys.append(contentsOf: keys[i ..< i + n])
                    i = j
                    continue
                }
            }
            outTokens.append(tokens[i])
            outKeys.append(keys[i])
            i += 1
        }
        tokens = outTokens
        keys = outKeys
    }

    // Single-token loops first (threshold 3 keeps legit doubles like "no no" / "had had").
    collapse(blockSize: 1, minRepeats: 3)
    // Then phrase loops, longest first. n>=3 collapses at 2 repeats; a 2-word phrase needs 3
    // repeats so emphatic "come on come on" survives.
    var n = min(30, tokens.count / 2)
    while n >= 2 {
        collapse(blockSize: n, minRepeats: n >= 3 ? 2 : 3)
        n -= 1
    }

    let collapsed = tokens.joined(separator: " ")
    return collapsed.isEmpty ? input : collapsed
}

#if DEBUG
/// One runnable check for collapseRepeatedRuns — runs on every debug launch (AppCoordinator.init).
func assertRepetitionCollapseWorks() {
    assert(collapseRepeatedRuns("it it it it it it") == "it")
    assert(collapseRepeatedRuns("the way that we're getting the way that we're getting right now")
        == "the way that we're getting right now")
    assert(collapseRepeatedRuns("no no it's fine") == "no no it's fine")
    assert(collapseRepeatedRuns("I had had enough") == "I had had enough")
    assert(collapseRepeatedRuns("a-it-it-it-it-it") == "a-it")
    assert(collapseRepeatedRuns("well-being state-of-the-art") == "well-being state-of-the-art")
    assert(collapseRepeatedRuns("hello world") == "hello world")
}
#endif
