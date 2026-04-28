import AppKit

// MARK: - TypeScript syntax highlighter

enum TypeScriptHighlighter {
    private static let keywords: [String] = [
        // Declarations
        "var","let","const","function","class","extends","static",
        // TS-specific declarations and modifiers
        "interface","type","enum","namespace","module","declare","abstract","implements",
        "public","private","protected","readonly","override",
        // Modules
        "import","export","from","as","default",
        // Control flow
        "if","else","for","while","do","switch","case","break","continue",
        "return","try","catch","finally","throw",
        // Async / generators
        "async","await","yield",
        // Operators that read as keywords
        "new","typeof","instanceof","in","of","delete","void","keyof",
        // Property accessors
        "get","set",
        // Constants and self-references
        "this","super","null","undefined","true","false","NaN","Infinity",
        // TS primitive types
        "any","unknown","never","string","number","boolean","object","symbol","bigint",
        // Other
        "debugger","with","is","satisfies",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"`(?:\\.|[^`\\])*`|/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F][0-9a-fA-F_]*n?|0b[01][01_]*n?|0o[0-7][0-7_]*n?|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?n?)\b"#)
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

        let commentColor = Theme.color("typescript", "comment")
        let stringColor  = Theme.color("typescript", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x2F /* '/' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,   color: Theme.color("typescript", "number"),   consumeMatch: false)
        apply(constantRegex, color: Theme.color("typescript", "constant"), consumeMatch: false)
        apply(keywordRegex,  color: Theme.color("typescript", "keyword"),  consumeMatch: false)
    }
}
