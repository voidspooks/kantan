import AppKit

// MARK: - R syntax highlighter

enum RHighlighter {
    private static let keywords: [String] = [
        "if","else","for","while","repeat","function","return","break","next","in",
        "TRUE","FALSE","NULL","NA","NA_integer_","NA_real_","NA_complex_","NA_character_",
        "Inf","NaN","library","require",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"#[^\n]*|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"#)

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?[Li]?)\b"#)
    private static let constantRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9_.]*\b"#)

    static func highlight(_ storage: NSTextStorage) {
        let text = storage.string
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
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

        let commentColor = Theme.color("r", "comment")
        let stringColor  = Theme.color("r", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x23 /* '#' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,   color: Theme.color("r", "number"),   consumeMatch: false)
        apply(constantRegex, color: Theme.color("r", "constant"), consumeMatch: false)
        apply(keywordRegex,  color: Theme.color("r", "keyword"),  consumeMatch: false)
    }
}
