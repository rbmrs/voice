import Foundation

/// A Claude Code session considered "live" — its transcript was modified recently.
struct LiveSession: Identifiable, Equatable {
    let id: String          // session UUID (transcript filename)
    let projectPath: String // cwd read from inside the transcript
    let lastActivity: Date  // transcript file mtime
    let lastReply: String?  // last assistant text message, if any
}

/// Lists live Claude Code sessions by scanning `~/.claude/projects/*/*.jsonl` for
/// recently-modified transcripts. Read-only; no hooks or permissions needed.
///
/// ponytail: synchronous scan called from the view's 2s poll — fine for a settings pane;
/// move behind AppCoordinator when the speech pipeline needs it headless.
@MainActor
final class ClaudeSessionMonitor: ObservableObject {
    @Published private(set) var sessions: [LiveSession] = []

    /// Transcripts idle longer than this are not "live".
    private let liveWindow: TimeInterval = 5 * 60

    private let projectsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    func refresh() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-liveWindow)

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            sessions = []
            return
        }

        var found: [LiveSession] = []
        for dir in projectDirs {
            guard let transcripts = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for file in transcripts where file.pathExtension == "jsonl" {
                guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mtime > cutoff else { continue }

                let head = transcriptHead(of: file)

                // `claude -p` runs (entrypoint "sdk-cli") also write transcripts here — including
                // our own summarizer calls, which would otherwise show up as phantom sessions.
                // Only interactive sessions ("cli") are live sessions; unknown → keep (defensive).
                if let entrypoint = head.entrypoint, entrypoint != "cli" { continue }

                found.append(LiveSession(
                    id: file.deletingPathExtension().lastPathComponent,
                    projectPath: head.cwd ?? fallbackPath(fromDashedDirectory: dir.lastPathComponent),
                    lastActivity: mtime,
                    lastReply: lastAssistantText(inTranscript: file)
                ))
            }
        }

        sessions = found.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// First `cwd` and `entrypoint` values in the transcript's leading lines. The format is
    /// internal to Claude Code — parse defensively, skip anything non-JSON or oddly shaped.
    private func transcriptHead(of url: URL) -> (cwd: String?, entrypoint: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384),
              let text = String(data: data, encoding: .utf8) else { return (nil, nil) }

        var cwd: String?
        var entrypoint: String?
        for line in text.split(separator: "\n").prefix(20) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if cwd == nil, let value = obj["cwd"] as? String, !value.isEmpty {
                cwd = value
            }
            if entrypoint == nil, let value = obj["entrypoint"] as? String, !value.isEmpty {
                entrypoint = value
            }
            if cwd != nil, entrypoint != nil { break }
        }
        return (cwd, entrypoint)
    }

    /// Last assistant text message in the transcript. Reads only the file's tail —
    /// transcripts grow to several MB and a turn's final text arrives as one line.
    /// Same defensive parsing as `projectPath`.
    private func lastAssistantText(inTranscript url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let tailBytes: UInt64 = 262_144
        if let size = try? handle.seekToEnd(), size > tailBytes {
            try? handle.seek(toOffset: size - tailBytes)
        } else {
            try? handle.seek(toOffset: 0)
        }
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self) // first line may be a partial → skipped as non-JSON

        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }

            let reply = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty {
                return reply
            }
        }
        return nil
    }

    /// ponytail: lossy fallback (dashes in real path segments stay dashes) — only used
    /// when no cwd entry exists in the first 20 lines.
    private func fallbackPath(fromDashedDirectory name: String) -> String {
        name.replacingOccurrences(of: "-", with: "/")
    }
}
