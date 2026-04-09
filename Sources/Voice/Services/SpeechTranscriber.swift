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
        ]

        arguments.append(contentsOf: ["--language", settings.effectiveWhisperLanguage])

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
