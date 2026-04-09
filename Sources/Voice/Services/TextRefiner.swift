import Foundation

@MainActor
protocol TextRefining {
    func refine(_ text: String, settings: AppSettings) async throws -> String
}

final class HeuristicTextRefiner: TextRefining {
    func refine(_ text: String, settings: AppSettings) async throws -> String {
        let withoutFillers = text.replacingOccurrences(
            of: #"(?i)(^|[\s,.;!?])(?:um+|uh+|ah+|er+)(?=$|[\s,.;!?])"#,
            with: " ",
            options: .regularExpression
        )

        let collapsedWhitespace = withoutFillers
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsedWhitespace.isEmpty else {
            throw DictationServiceError.emptyResult("The refinement step removed the entire transcript.")
        }

        let capitalized = collapsedWhitespace.prefix(1).uppercased() + collapsedWhitespace.dropFirst()

        if capitalized.last?.isSentenceTerminator == true {
            return capitalized
        }

        return capitalized + "."
    }
}

final class LlamaCppTextRefiner: TextRefining {
    private let runner: ShellCommandRunner
    private static let timeoutSeconds: TimeInterval = 45

    init(runner: ShellCommandRunner = ShellCommandRunner()) {
        self.runner = runner
    }

    func refine(_ text: String, settings: AppSettings) async throws -> String {
        let prompt = Self.buildPrompt(rawText: text, profile: settings.refinementProfile)
        let executable = Self.refinementExecutable(from: settings.llamaExecutablePath)

        let result = try await runner.run(
            executable: executable,
            arguments: [
                "-m", settings.llamaModelPath,
                "-n", "128",
                "-no-cnv",
                "--simple-io",
                "--no-warmup",
                "--temp", "0",
                "--top-k", "1",
                "-p", prompt,
            ],
            timeout: Self.timeoutSeconds
        )

        guard result.exitCode == 0 else {
            throw DictationServiceError.processFailure(
                tool: URL(fileURLWithPath: executable).lastPathComponent,
                details: result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
        }

        let cleaned = Self.extractRefinedText(from: result.standardOutput, prompt: prompt)

        guard !cleaned.isEmpty else {
            throw DictationServiceError.emptyResult("The local LLM returned an empty refinement.")
        }

        return cleaned
    }

    nonisolated static func refinementExecutable(from configuredPath: String) -> String {
        let trimmedPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: trimmedPath)

        guard url.lastPathComponent == "llama-cli" else {
            return trimmedPath
        }

        let completionURL = url.deletingLastPathComponent().appendingPathComponent("llama-completion")
        if FileManager.default.isExecutableFile(atPath: completionURL.path) {
            return completionURL.path
        }

        return trimmedPath
    }

    nonisolated static func buildPrompt(rawText: String, profile: RefinementProfile) -> String {
        """
        You are a local dictation refinement engine.
        Follow every rule exactly:
        - Preserve the speaker's meaning.
        - Keep the original language.
        - Fix punctuation and capitalization.
        - Remove filler words and obvious false starts.
        - Do not add explanations, lists, or extra content.
        - Return only the cleaned dictation as plain text.
        - Do not repeat the instructions or raw dictation.

        Tone profile:
        \(profile.instructions)

        Raw dictation:
        \(rawText)

        Cleaned dictation:
        """
    }

    nonisolated static func extractRefinedText(from output: String, prompt: String) -> String {
        var cleaned = output.replacingOccurrences(of: prompt, with: "")

        cleaned = cleaned.replacingOccurrences(of: "<br>", with: "\n")
        cleaned = cleaned
            .replacingOccurrences(of: #"(?m)^Refined text:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^Cleaned dictation:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("\""), cleaned.hasSuffix("\""), cleaned.count > 1 {
            cleaned.removeFirst()
            cleaned.removeLast()
        }

        let lines = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var collected: [String] = []

        for line in lines {
            guard !line.isEmpty else {
                if !collected.isEmpty { break }
                continue
            }

            if line.hasPrefix("### ") || line.hasPrefix("You are a local dictation") || line.hasPrefix("Tone profile:") || line.hasPrefix("Raw dictation:") {
                if !collected.isEmpty { break }
                continue
            }

            if line == "Cleaned dictation:" {
                continue
            }

            if line == "<result>" || line == "</result>" {
                continue
            }

            if isSentinelLine(line) {
                if !collected.isEmpty { break }
                continue
            }

            collected.append(line)
        }

        var finalText = collected.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        finalText = stripTrailingSentinels(from: finalText)
        return finalText
    }

    nonisolated static func isSentinelLine(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "[end of text]"
            || normalized == "<|endoftext|>"
            || normalized == "<end_of_turn>"
            || normalized == "</s>"
    }

    nonisolated static func stripTrailingSentinels(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"\s*\[end of text\]\s*$"#,
            #"\s*<\|endoftext\|>\s*$"#,
            #"\s*<end_of_turn>\s*$"#,
            #"\s*</s>\s*$"#,
        ]

        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Character {
    var isSentenceTerminator: Bool {
        self == "." || self == "!" || self == "?"
    }
}
