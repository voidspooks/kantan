import AppKit

// MARK: - Markdown syntax highlighter

enum MarkdownHighlighter {
    // Fenced code blocks first so `# inside code` doesn't read as a heading. Then
    // inline code so `` `*literal*` `` doesn't get an emphasis pass.
    private static let codeBlockRegex = try! NSRegularExpression(
        pattern: #"^(?:```|~~~)[^\n]*\n[\s\S]*?^(?:```|~~~)\s*$"#,
        options: [.anchorsMatchLines])
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)

    private static let headingRegex = try! NSRegularExpression(
        pattern: #"^[ ]{0,3}#{1,6}[ \t][^\n]*"#, options: [.anchorsMatchLines])
    private static let blockquoteRegex = try! NSRegularExpression(
        pattern: #"^[ ]{0,3}>[^\n]*"#, options: [.anchorsMatchLines])
    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:[-*+]|\d+[.)])[ \t]"#, options: [.anchorsMatchLines])
    private static let horizontalRuleRegex = try! NSRegularExpression(
        pattern: #"^[ ]{0,3}(?:[-*_][ \t]*){3,}\s*$"#, options: [.anchorsMatchLines])

    private static let strongRegex = try! NSRegularExpression(
        pattern: #"\*\*[^\s*][^*]*?\*\*|__[^\s_][^_]*?__"#)
    private static let emphasisRegex = try! NSRegularExpression(
        pattern: #"(?<!\*)\*[^\s*][^*\n]*?\*(?!\*)|(?<!_)_[^\s_][^_\n]*?_(?!_)"#)

    // Image first so `![alt](url)` doesn't match the link rule's brackets.
    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[[^\]\n]*\]\([^)\n]+\)"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[[^\]\n]+\]\([^)\n]+\)"#)

    static func highlight(_ storage: NSTextStorage) {
        let text = storage.string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        guard fullRange.length > 0 else { return }

        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor, value: Theme.foreground, range: fullRange)

        var consumed = [NSRange]()

        func intersectsConsumed(_ r: NSRange) -> Bool {
            for c in consumed where NSIntersectionRange(c, r).length > 0 { return true }
            return false
        }

        func apply(_ regex: NSRegularExpression, color: NSColor, consumeMatch: Bool) {
            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let m = match else { return }
                if intersectsConsumed(m.range) { return }
                storage.addAttribute(.foregroundColor, value: color, range: m.range)
                if consumeMatch { consumed.append(m.range) }
            }
        }

        apply(codeBlockRegex,      color: Theme.color("markdown", "code"),       consumeMatch: true)
        apply(inlineCodeRegex,     color: Theme.color("markdown", "code"),       consumeMatch: true)
        apply(headingRegex,        color: Theme.color("markdown", "heading"),    consumeMatch: true)
        apply(horizontalRuleRegex, color: Theme.color("markdown", "rule"),       consumeMatch: true)
        apply(blockquoteRegex,     color: Theme.color("markdown", "blockquote"), consumeMatch: false)
        apply(listMarkerRegex,     color: Theme.color("markdown", "list"),       consumeMatch: false)
        apply(imageRegex,          color: Theme.color("markdown", "link"),       consumeMatch: true)
        apply(linkRegex,           color: Theme.color("markdown", "link"),       consumeMatch: true)
        apply(strongRegex,         color: Theme.color("markdown", "strong"),     consumeMatch: false)
        apply(emphasisRegex,       color: Theme.color("markdown", "emphasis"),   consumeMatch: false)
    }
}
