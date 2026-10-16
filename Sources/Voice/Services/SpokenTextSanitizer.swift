import Foundation

/// Removes text that sounds wrong when read aloud (commit hashes today; URLs next)
/// from a reply's spoken form. Pure and stateless: add a new rule as a private
/// step and call it from `sanitize(_:)`.
enum SpokenTextSanitizer {
    static func sanitize(_ text: String) -> String {
        var result = text
        result = removingCommitHashes(from: result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Commit hashes

    /// 7-40 hex characters with at least one digit and one a-f letter, so ordinary
    /// words ("defaced") and plain numbers ("1234567") are left alone.
    private static let hashCore = "(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}"

    /// "commit abc1234" -> "a commit" (also with backticks or parentheses).
    private static let commitPhrase = try! NSRegularExpression(
        pattern: "\\bcommit[ \\t]+[`(\\[]?\\b\(hashCore)\\b[`)\\]]?",
        options: [.caseInsensitive]
    )

    private static let bareHash = try! NSRegularExpression(
        pattern: "[`(\\[]?\\b\(hashCore)\\b[`)\\]]?",
        options: []
    )

    private static func removingCommitHashes(from text: String) -> String {
        var result = replace(commitPhrase, in: text, with: "a commit")
        result = replace(bareHash, in: result, with: "")
        // Tidy the gaps a removed hash leaves behind.
        result = result.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " +([,.;:!?])", with: "$1", options: .regularExpression)
        return result
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: template)
        )
    }
}
