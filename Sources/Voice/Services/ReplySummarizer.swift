import Foundation

/// Turns a session reply into its spoken form using the hybrid policy from the
/// session-speech handoff design: short replies verbatim, long ones summarized —
/// via `claude -p` (haiku/sonnet, uses the Claude Code login) or the local
/// llama.cpp model shared with the refinement feature.
///
/// Never throws — on any failure it falls back to a truncated verbatim read,
/// because truncation beats silence.
struct ReplySummarizer: Sendable {
    /// Replies at or under this length are spoken verbatim — already one breath long.
    static let verbatimMaxLength = 250

    /// Cap the reply text sent to the summarizer to bound latency and cost.
    private static let summarizerInputMaxLength = 8_000

    /// llama.cpp paths (the refinement feature's active executable + GGUF model).
    struct LlamaConfiguration: Sendable {
        let executablePath: String
        let modelPath: String
        let isConfigured: Bool
    }

    private let runner = ShellCommandRunner()

    func spokenForm(
        of reply: String,
        model: SpeechSummaryModel,
        prompt: String,
        llama: LlamaConfiguration
    ) async -> String {
        guard reply.count > Self.verbatimMaxLength else { return reply }

        let fallback = String(reply.prefix(Self.verbatimMaxLength)) + "…"

        switch model {
        case .haiku, .sonnet:
            return await summarizeWithClaude(reply, model: model, prompt: prompt) ?? fallback
        case .local:
            return await summarizeLocally(reply, prompt: prompt, llama: llama) ?? fallback
        }
    }

    // MARK: - Cloud (claude -p)

    private func summarizeWithClaude(_ reply: String, model: SpeechSummaryModel, prompt: String) async -> String? {
        guard let claude = ToolDiscovery.findExecutable(named: "claude") else { return nil }

        let input = "\(reply.prefix(Self.summarizerInputMaxLength))\n\n\(prompt)"
        var arguments = ["-p", input, "--model", model.rawValue]
        if model == .haiku {
            arguments += ["--effort", "low"]
        }

        do {
            let result = try await runner.run(
                executable: claude,
                arguments: arguments,
                timeout: 60,
                // Marker for the future Stop hook's self-trigger guard: our own claude
                // subprocesses must never re-enter the speech pipeline.
                environment: ["VOICE_SELF": "1"]
            )
            let summary = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode == 0, !summary.isEmpty {
                return summary
            }
        } catch {}
        return nil
    }

    // MARK: - Local (llama.cpp)

    private func summarizeLocally(_ reply: String, prompt: String, llama: LlamaConfiguration) async -> String? {
        guard llama.isConfigured else { return nil }

        let fullPrompt = """
        You are a spoken-summary engine. \(prompt)

        Assistant reply:
        \(reply.prefix(Self.summarizerInputMaxLength))

        Spoken summary:
        """

        // Refinement's proven greedy one-shot args, with generation (-n) capped so a
        // rambling small model can't stretch latency unbounded.
        var llamaArguments = RefinementContract.llamaArguments
        if let nIndex = llamaArguments.firstIndex(of: "-n"), nIndex + 1 < llamaArguments.count {
            llamaArguments[nIndex + 1] = "160"
        }
        let arguments = ["-m", llama.modelPath] + llamaArguments + ["-p", fullPrompt]

        do {
            let result = try await runner.run(
                // Same preference as the refiner: modern llama.cpp ships llama-completion
                // for raw one-shot prompts; llama-cli (chat-oriented) spins on these args.
                executable: LlamaCppTextRefiner.refinementExecutable(from: llama.executablePath),
                arguments: arguments,
                timeout: 120
            )
            guard result.exitCode == 0 else { return nil }
            let summary = cleanLlamaOutput(result.standardOutput, prompt: fullPrompt)
            return summary.isEmpty ? nil : summary
        } catch {
            return nil
        }
    }

    /// llama-completion echoes the prompt and may append end-of-text sentinels — strip both.
    /// Small models also tend to continue the document pattern past the summary (inventing
    /// a new "Assistant reply:" section), so keep only the first paragraph.
    private func cleanLlamaOutput(_ output: String, prompt: String) -> String {
        var text = output.replacingOccurrences(of: prompt, with: "")
        for sentinel in RefinementContract.sentinelLines {
            text = text.replacingOccurrences(of: sentinel, with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paragraphBreak = text.range(of: "\n\n") {
            text = String(text[..<paragraphBreak.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
