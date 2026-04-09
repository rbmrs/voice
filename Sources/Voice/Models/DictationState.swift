import Foundation
import CoreGraphics

enum DictationState: Equatable {
    case idle
    case listening
    case transcribing
    case refining
    case inserting
    case completed(String)
    case error(String)

    var menuTitle: String {
        switch self {
        case .idle:
            "Voice"
        case .listening:
            "Listening"
        case .transcribing:
            "Transcribing"
        case .refining:
            "Refining"
        case .inserting:
            "Typing"
        case .completed:
            "Inserted"
        case .error:
            "Attention"
        }
    }

    var menuSymbol: String {
        switch self {
        case .idle:
            "waveform"
        case .listening:
            "mic.fill"
        case .transcribing:
            "waveform.and.magnifyingglass"
        case .refining:
            "text.badge.checkmark"
        case .inserting:
            "keyboard"
        case .completed:
            "checkmark.circle.fill"
        case .error:
            "exclamationmark.triangle.fill"
        }
    }

    var overlayTitle: String {
        switch self {
        case .idle:
            "Ready"
        case .listening:
            "Listening"
        case .transcribing:
            "Running Whisper"
        case .refining:
            "Polishing Text"
        case .inserting:
            "Inserting"
        case .completed:
            "Inserted"
        case .error:
            "Setup Needed"
        }
    }

    var overlayDetail: String {
        switch self {
        case .idle:
            "Press your dictation shortcut to begin."
        case .listening:
            "Release the shortcut or press it again to stop."
        case .transcribing:
            "Converting the local audio buffer into text."
        case .refining:
            "Applying punctuation, cleanup, and tone adjustments."
        case .inserting:
            "Sending the final text to the focused app."
        case .completed(let text):
            text
        case .error(let message):
            message
        }
    }

    var isRecording: Bool {
        if case .listening = self {
            return true
        }

        return false
    }

    var overlayDetailLineLimit: Int {
        switch self {
        case .completed, .error:
            5
        default:
            2
        }
    }

    var overlayMaxHeight: CGFloat {
        switch self {
        case .completed, .error:
            220
        default:
            128
        }
    }
}
