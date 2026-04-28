import AppKit

// MARK: - Java syntax highlighter

enum JavaHighlighter {
    private static let keywords: [String] = [
        "abstract","assert","boolean","break","byte","case","catch","char","class","const",
        "continue","default","do","double","else","enum","extends","final","finally","float",
        "for","goto","if","implements","import","instanceof","int","interface","long","native",
        "new","package","private","protected","public","return","short","static","strictfp",
        "super","switch","synchronized","this","throw","throws","transient","try","void",
        "volatile","while","yield","record","sealed","permits","var","true","false","null",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #""""[\s\S]*?"""|/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F][0-9a-fA-F_]*[lL]?|0b[01][01_]*[lL]?|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?[fFdDlL]?)\b"#)
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

        let commentColor = Theme.color("java", "comment")
        let stringColor  = Theme.color("java", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x2F /* '/' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,     color: Theme.color("java", "number"),     consumeMatch: false)
        apply(constantRegex,   color: Theme.color("java", "constant"),   consumeMatch: false)
        apply(keywordRegex,    color: Theme.color("java", "keyword"),    consumeMatch: false)
        apply(annotationRegex, color: Theme.color("java", "annotation"), consumeMatch: false)
    }
}
