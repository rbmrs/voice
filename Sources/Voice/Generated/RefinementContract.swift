// Generated from Resources/refinement-contract.json — do not edit.
// Regenerate with: swift scripts/gen-refinement-contract.swift

import Foundation

enum RefinementProfile: String, CaseIterable, Identifiable {
    case balanced
    case professional
    case literal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: "Balanced"
        case .professional: "Professional"
        case .literal: "Literal"
        }
    }

    var description: String {
        switch self {
        case .balanced: "Cleans up dictation while keeping the original wording and meaning close to what you said."
        case .professional: "Turns dictation into polished, professional prose suitable for email drafts."
        case .literal: "Makes only the smallest edits needed for punctuation and capitalization, leaving wording untouched."
        }
    }

    var instructions: String {
        switch self {
        case .balanced: "Make the text read naturally and clearly without changing the meaning."
        case .professional: "Shape the text into polished, professional prose that feels ready for an email draft."
        case .literal: "Make the smallest edits necessary for punctuation and capitalization."
        }
    }

    var contentRule: String {
        switch self {
        case .balanced: "- Do not add explanations, lists, or extra content."
        case .professional: "- Do not add explanations, lists, or extra content."
        case .literal: "- Do not add explanations, lists, or extra content."
        }
    }
}

enum RefinementContract {
    static let defaultProfile = RefinementProfile.balanced
    static let promptTemplate = "You are a local dictation refinement engine.\nFollow every rule exactly:\n- Preserve the speaker's meaning.\n- Keep the original language.\n- Fix punctuation and capitalization.\n- Remove filler words and obvious false starts.\n{contentRule}\n- Return only the cleaned dictation as plain text.\n- Do not repeat the instructions or raw dictation.\n\nTone profile:\n{instructions}\n\nRaw dictation:\n{rawText}\n\nCleaned dictation:\n"
    static let llamaArguments: [String] = ["-n", "128", "-no-cnv", "--simple-io", "--no-warmup", "--temp", "0", "--top-k", "1"]
    static let sentinelLines: [String] = ["[end of text]", "<|endoftext|>", "<end_of_turn>", "</s>"]
    static let headerSkipPrefixes: [String] = ["### ", "You are a local dictation", "Tone profile:", "Raw dictation:"]

    static func prompt(rawText: String, profile: RefinementProfile) -> String {
        promptTemplate
            .replacingOccurrences(of: "{contentRule}", with: profile.contentRule)
            .replacingOccurrences(of: "{instructions}", with: profile.instructions)
            .replacingOccurrences(of: "{rawText}", with: rawText)
    }
}
