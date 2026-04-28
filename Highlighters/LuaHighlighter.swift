import AppKit

// MARK: - Lua syntax highlighter

enum LuaHighlighter {
    private static let keywords: [String] = [
        "and","break","do","else","elseif","end","false","for","function","goto","if",
        "in","local","nil","not","or","repeat","return","then","true","until","while",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    // Long brackets (`[[...]]`) and long comments (`--[[...]]`) supported up to 5 levels.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: ##"--\[(=*)\[[\s\S]*?\]\1\]|--[^\n]*|\[(=*)\[[\s\S]*?\]\2\]|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"##)

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F]+(?:\.[0-9a-fA-F]+)?(?:[pP][+-]?\d+)?|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#)
    private static let constantRegex = try! NSRegularExpression(pattern: #"\b[A-Z_][A-Z0-9_]{2,}\b"#)

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

        let commentColor = Theme.color("lua", "comment")
        let stringColor  = Theme.color("lua", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            // First char `-` → comment (line or long); anything else → string.
            let color: NSColor = (nsText.character(at: r.location) == 0x2D /* '-' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,   color: Theme.color("lua", "number"),   consumeMatch: false)
        apply(constantRegex, color: Theme.color("lua", "constant"), consumeMatch: false)
        apply(keywordRegex,  color: Theme.color("lua", "keyword"),  consumeMatch: false)
    }
}
