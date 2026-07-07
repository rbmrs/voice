import Foundation

@MainActor
protocol SpeechTranscribing {
    func transcribe(audioURL: URL, settings: AppSettings) async throws -> String
}

final class WhisperCppTranscriber: SpeechTranscribing {
    private let runner: ShellCommandRunner

    init(runner: ShellCommandRunner = ShellCommandRunner()) {
        self.runner = runner
    }

    func transcribe(audioURL: URL, settings: AppSettings) async throws -> String {
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent("voice-transcript-\(UUID().uuidString)")
        let outputTextURL = URL(fileURLWithPath: outputBase.path + ".txt")

        defer {
            try? FileManager.default.removeItem(at: outputTextURL)
        }

        var arguments = [
            "--model", settings.whisperModelPath,
            "--file", audioURL.path,
            "--output-txt",
            "--output-file", outputBase.path,
            "--no-prints",
            "--no-timestamps",
            // Anti-hallucination decoder settings (whisper.cpp 1.9.x). beam-size/best-of
            // match the binary defaults but are explicit so a future build can't silently
            // drop to greedy. suppress-nst drops non-speech tokens whisper otherwise emits
            // as filler. max-context 0 stops a degraded 30s window from poisoning the next
            // via prompt carry-over — the cause of cross-window phrase loops and semantic
            // drift. Temperature fallback stays on (default) as the built-in loop escape.
            "--beam-size", "5",
            "--best-of", "5",
            "--suppress-nst",
            "--max-context", "0",
        ]

        arguments.append(contentsOf: ["--language", settings.effectiveWhisperLanguage])

        // Voice activity detection: trims silence before decoding, which speeds up short
        // clips and suppresses Whisper's tendency to hallucinate text on leading/trailing
        // silence. Only added when the user enabled it and a Silero model is present.
        if settings.isVADActive {
            // whisper.cpp's VAD defaults target long-form audio and clip dictation: they drop
            // sub-250ms words, discard quiet speech (thold 0.5), and pad only 30ms so word edges
            // get chopped. Bias toward keeping speech.
            // ponytail: calibration knobs — surface in Settings only if per-voice tuning is needed.
            arguments.append(contentsOf: [
                "--vad", "--vad-model", settings.vadModelPath,
                "--vad-threshold", "0.30",
                "--vad-min-speech-duration-ms", "100",
                "--vad-speech-pad-ms", "200",
            ])
        }

        let result = try await runner.run(
            executable: settings.whisperExecutablePath,
            arguments: arguments
        )

        guard result.exitCode == 0 else {
            throw DictationServiceError.processFailure(
                tool: "whisper-cli",
                details: result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
        }

        let rawOutput: String
        if FileManager.default.fileExists(atPath: outputTextURL.path) {
            rawOutput = try String(contentsOf: outputTextURL, encoding: .utf8)
        } else {
            rawOutput = result.standardOutput
        }

        let cleaned = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            throw DictationServiceError.emptyResult("Whisper produced an empty transcript.")
        }

        return cleaned
    }
}
