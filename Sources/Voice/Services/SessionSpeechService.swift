import Foundation

/// App-level auto-speak for live Claude Code sessions: polls transcripts, and when a
/// *tracked* session's last reply changes while the master toggle is on, speaks the
/// summarized reply — the polling equivalent of the Stop-hook design, with dedupe via
/// a per-session tail of the last spoken reply (guard 3 of the handoff design).
///
/// Owns the one `SpeechPlayer` (single TTS owner — guard 5) and the one monitor; the
/// Speech settings pane observes these same instances so manual playback and autoplay
/// can never overlap audio.
///
/// ponytail: app-lifetime object owned by AppCoordinator — the poll task never needs
/// cancelling, so it captures self strongly.
@MainActor
final class SessionSpeechService: ObservableObject {
    let monitor = ClaudeSessionMonitor()
    let player = SpeechPlayer()

    private let settings: AppSettings
    private let summarizer = ReplySummarizer()

    /// Last spoken (or seeded) reply tail per session id — the dedupe memory.
    private var lastSpokenTail: [String: String] = [:]
    /// Replies present when the toggle comes on are history, not news — seed, don't speak.
    private var seeded = false

    init(settings: AppSettings) {
        self.settings = settings

        Task {
            while true {
                await tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func tick() async {
        monitor.refresh()

        guard settings.speakSessionReplies else {
            seeded = false
            return
        }

        let sessions = monitor.sessions

        if !seeded {
            for session in sessions {
                if let reply = session.lastReply {
                    lastSpokenTail[session.id] = String(reply.suffix(120))
                }
            }
            seeded = true
            return
        }

        for session in sessions {
            guard let reply = session.lastReply, !reply.isEmpty else { continue }
            let tail = String(reply.suffix(120))
            guard lastSpokenTail[session.id] != tail else { continue }

            // Muted sessions advance their tail silently, so un-muting doesn't
            // dump a stale reply.
            guard settings.isSessionTracked(session.id) else {
                lastSpokenTail[session.id] = tail
                continue
            }

            // A turn in progress appends to the transcript continuously (tool calls,
            // interleaved text). Announce only after a few seconds of quiet — the
            // polling equivalent of the Stop hook firing at turn end. Don't advance
            // the tail yet: the reply gets announced on a later tick once quiet.
            guard Date().timeIntervalSince(session.lastActivity) > 4 else { continue }
            lastSpokenTail[session.id] = tail

            let llama = ReplySummarizer.LlamaConfiguration(
                executablePath: settings.llamaExecutablePath,
                modelPath: settings.speechLlamaModelPath,
                isConfigured: settings.isSpeechLlamaConfigured
            )
            let spoken: String
            if settings.speechReplyStyle == .summary {
                spoken = await summarizer.spokenForm(
                    of: reply,
                    model: settings.speechSummaryModel,
                    prompt: settings.resolvedSpeechSummaryPrompt,
                    llama: llama
                )
            } else {
                spoken = reply
            }

            player.speak(spoken, id: session.id)
            // Serialize audio: wait for this announcement to finish before the next.
            while player.speakingID == session.id {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
