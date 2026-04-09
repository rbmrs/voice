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

    init(runner: ShellCommandRunner = ShellCommandRunner()) {
        self.runner = runner
    }

    func refine(_ text: String, settings: AppSettings) async throws -> String {
        let prompt = Self.buildPrompt(rawText: text, profile: settings.refinementProfile)

        let result = try await runner.run(
            executable: settings.llamaExecutablePath,
            arguments: [
                "-m", settings.llamaModelPath,
                "-n", "256",
                "-p", prompt,
            ]
        )

        guard result.exitCode == 0 else {
            throw DictationServiceError.processFailure(
                tool: "llama-cli",
                details: result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
        }

        let cleaned = Self.extractRefinedText(from: result.standardOutput, prompt: prompt)

        guard !cleaned.isEmpty else {
            throw DictationServiceError.emptyResult("The local LLM returned an empty refinement.")
        }

        return cleaned
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
        - Return only the final cleaned text inside the result block.

        Tone profile:
        \(profile.instructions)

        Raw dictation:
        \(rawText)

        <result>
        """
    }

    nonisolated static func extractRefinedText(from output: String, prompt: String) -> String {
        var cleaned = output.replacingOccurrences(of: prompt, with: "")

        if let resultTag = cleaned.range(of: "<result>") {
            cleaned = String(cleaned[resultTag.upperBound...])
        }

        if let endTag = cleaned.range(of: "</result>") {
            cleaned = String(cleaned[..<endTag.lowerBound])
        }

        cleaned = cleaned
            .replacingOccurrences(of: #"(?m)^Refined text:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("\""), cleaned.hasSuffix("\""), cleaned.count > 1 {
            cleaned.removeFirst()
            cleaned.removeLast()
        }

        return cleaned
    }
}

private extension Character {
    var isSentenceTerminator: Bool {
        self == "." || self == "!" || self == "?"
    }
}
