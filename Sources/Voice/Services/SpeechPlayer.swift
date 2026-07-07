import Foundation

/// Speaks text aloud through `/usr/bin/say`, which uses the system voice the user picks in
/// Accessibility → Read & Speak (the pane our "Open Voice Settings…" button links to).
///
/// Publishes which item is currently speaking (`speakingID`) so the UI can swap its
/// play button for a stop button and flip back when speech ends naturally.
@MainActor
final class SpeechPlayer: ObservableObject {
    /// Caller-supplied identifier for what's being spoken (e.g. a session id); nil when silent.
    @Published private(set) var speakingID: String?

    private var process: Process?

    func speak(_ text: String, id: String) {
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = [text]
        p.terminationHandler = { proc in
            let pid = proc.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, self.process?.processIdentifier == pid else { return }
                self.process = nil
                self.speakingID = nil
            }
        }
        guard (try? p.run()) != nil else { return }
        process = p
        speakingID = id
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        speakingID = nil
    }
}
