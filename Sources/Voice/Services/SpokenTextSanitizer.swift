import Foundation

/// Removes text that sounds wrong when read aloud (commit hashes and URLs)
/// from a reply's spoken form. Pure and stateless: add a new rule as a private
/// step and call it from `sanitize(_:)`.
enum SpokenTextSanitizer {
    static func sanitize(_ text: String) -> String {
        var result = text
        result = speakingURLs(in: result)
        result = removingCommitHashes(from: result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - URLs

    /// [text](url) -> "text": speak the label, never the address.
    private static let markdownLink = try! NSRegularExpression(
        pattern: "\\[([^\\]]+)\\]\\((?:https?://|www\\.)[^\\s)]+\\)",
        options: [.caseInsensitive]
    )

    private static let bareURL = try! NSRegularExpression(
        pattern: "<?(?:https?://|www\\.)[^\\s<>\"'`]+>?",
        options: [.caseInsensitive]
    )

    /// Hosts with a well-known spoken name. Anything else is "a link to host dot tld".
    private static let knownHosts: [String: String] = [
        "github.com": "a GitHub link",
        "youtube.com": "a YouTube link",
        "youtu.be": "a YouTube link",
        "stackoverflow.com": "a Stack Overflow link",
    ]

    /// Replaces every URL with a short phrase; paths, queries and symbols are never read.
    private static func speakingURLs(in text: String) -> String {
        var result = markdownLink.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1"
        )
        let matches = bareURL.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            var url = String(result[range])
            if url.hasPrefix("<") { url.removeFirst() }
            if url.hasSuffix(">") { url.removeLast() }
            // Sentence punctuation after the URL stays in the text, not in the link.
            var trailing = ""
            while let last = url.last {
                let isClosing = ")]}".contains(last)
                let isPunctuation = ".,;:!?".contains(last)
                let opener: Character = last == ")" ? "(" : last == "]" ? "[" : "{"
                if isPunctuation || (isClosing && url.filter({ $0 == last }).count > url.filter({ $0 == opener }).count) {
                    trailing.insert(last, at: trailing.startIndex)
                    url.removeLast()
                } else {
                    break
                }
            }
            result.replaceSubrange(range, with: spokenPhrase(forURL: url) + trailing)
        }
        return result
    }

    private static func spokenPhrase(forURL url: String) -> String {
        var rest = url
        if let schemeEnd = rest.range(of: "://") { rest = String(rest[schemeEnd.upperBound...]) }
        if let slash = rest.firstIndex(where: { "/?#".contains($0) }) { rest = String(rest[..<slash]) }
        if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        if let colon = rest.firstIndex(of: ":") { rest = String(rest[..<colon]) }
        var host = rest.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty else { return "a link" }
        if let known = knownHosts[host] { return known }
        return "a link to " + host.replacingOccurrences(of: ".", with: " dot ")
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
