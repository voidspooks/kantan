import AppKit

// MARK: - Kotlin syntax highlighter

enum KotlinHighlighter {
    private static let keywords: [String] = [
        "abstract","actual","annotation","as","break","by","catch","class","companion",
        "const","constructor","continue","crossinline","data","do","dynamic","else","enum",
        "expect","external","false","field","file","final","finally","for","fun","get",
        "if","import","in","infix","init","inline","inner","interface","internal","is",
        "lateinit","noinline","null","object","open","operator","out","override","package",
        "param","private","property","protected","public","reified","return","sealed","set",
        "setparam","super","suspend","tailrec","this","throw","true","try","typealias",
        "typeof","val","value","var","vararg","when","where","while",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    // Triple-quoted raw strings first.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #""""[\s\S]*?"""|/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"#)

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F][0-9a-fA-F_]*[uUlL]*|0b[01][01_]*[uUlL]*|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?[fFLuU]?)\b"#)
    private static let constantRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#)
    private static let annotationRegex = try! NSRegularExpression(pattern: #"@[A-Za-z_][A-Za-z0-9_.]*"#)

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

        let commentColor = Theme.color("kotlin", "comment")
        let stringColor  = Theme.color("kotlin", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x2F /* '/' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,     color: Theme.color("kotlin", "number"),     consumeMatch: false)
        apply(constantRegex,   color: Theme.color("kotlin", "constant"),   consumeMatch: false)
        apply(keywordRegex,    color: Theme.color("kotlin", "keyword"),    consumeMatch: false)
        apply(annotationRegex, color: Theme.color("kotlin", "annotation"), consumeMatch: false)
    }
}
