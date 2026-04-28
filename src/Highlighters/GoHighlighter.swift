import AppKit

// MARK: - Go syntax highlighter

enum GoHighlighter {
    private static let keywords: [String] = [
        "break","case","chan","const","continue","default","defer","else","fallthrough",
        "for","func","go","goto","if","import","interface","map","package","range",
        "return","select","struct","switch","type","var",
        "true","false","nil","iota",
        "any","bool","byte","comparable","complex64","complex128","error","float32","float64",
        "int","int8","int16","int32","int64","rune","string","uint","uint8","uint16","uint32",
        "uint64","uintptr",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"`[^`]*`|/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F][0-9a-fA-F_]*|0b[01][01_]*|0o?[0-7][0-7_]*|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?i?)\b"#)
    private static let constantRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#)

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

        let commentColor = Theme.color("go", "comment")
        let stringColor  = Theme.color("go", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x2F /* '/' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,   color: Theme.color("go", "number"),   consumeMatch: false)
        apply(constantRegex, color: Theme.color("go", "constant"), consumeMatch: false)
        apply(keywordRegex,  color: Theme.color("go", "keyword"),  consumeMatch: false)
    }
}
