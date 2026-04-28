import AppKit

// MARK: - YAML syntax highlighter

enum YAMLHighlighter {
    // Single pass for comments + strings — comment alternative listed first so
    // any '#' wins before a quote could open a fake string.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)
    // Key at line start, optional indent, optional list marker '- ', plain identifier, then ':'.
    // Group 1 captures just the identifier so we color the key without the colon.
    private static let keyRegex      = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:-[ \t]+)?([A-Za-z_][\w-]*)\s*:"#,
        options: [.anchorsMatchLines])
    private static let numberRegex   = try! NSRegularExpression(pattern: #"\b-?\d+(?:\.\d+)?\b"#)
    private static let constantRegex = try! NSRegularExpression(
        pattern: #"\b(?:[Tt]rue|TRUE|[Ff]alse|FALSE|[Yy]es|YES|[Nn]o|NO|[Oo]n|ON|[Oo]ff|OFF|[Nn]ull|NULL|~)\b"#)

    static func highlight(_ storage: NSTextStorage) {
        let text = storage.string
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard fullRange.length > 0 else { return }

        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor, value: Theme.foreground, range: fullRange)

        var consumed = [NSRange]()

        func intersectsConsumed(_ r: NSRange) -> Bool {
            for c in consumed where NSIntersectionRange(c, r).length > 0 {
                return true
            }
            return false
        }

        func apply(_ regex: NSRegularExpression, color: NSColor, consumeMatch: Bool, captureGroup: Int = 0) {
            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let m = match else { return }
                let range = m.range(at: captureGroup)
                if range.location == NSNotFound { return }
                if intersectsConsumed(range) { return }
                storage.addAttribute(.foregroundColor, value: color, range: range)
                if consumeMatch { consumed.append(range) }
            }
        }

        let commentColor = Theme.color("yaml", "comment")
        let stringColor  = Theme.color("yaml", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x23 /* '#' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(keyRegex,      color: Theme.color("yaml", "key"),      consumeMatch: false, captureGroup: 1)
        apply(numberRegex,   color: Theme.color("yaml", "number"),   consumeMatch: false)
        apply(constantRegex, color: Theme.color("yaml", "constant"), consumeMatch: false)
    }
}
