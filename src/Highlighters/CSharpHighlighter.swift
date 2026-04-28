import AppKit

// MARK: - C# syntax highlighter

enum CSharpHighlighter {
    private static let keywords: [String] = [
        "abstract","as","base","bool","break","byte","case","catch","char","checked",
        "class","const","continue","decimal","default","delegate","do","double","else",
        "enum","event","explicit","extern","false","finally","fixed","float","for","foreach",
        "goto","if","implicit","in","int","interface","internal","is","lock","long",
        "namespace","new","null","object","operator","out","override","params","private",
        "protected","public","readonly","ref","return","sbyte","sealed","short","sizeof",
        "stackalloc","static","string","struct","switch","this","throw","true","try",
        "typeof","uint","ulong","unchecked","unsafe","ushort","using","virtual","void",
        "volatile","while","add","alias","ascending","async","await","by","descending",
        "dynamic","equals","from","get","global","group","init","into","join","let",
        "nameof","on","orderby","partial","record","remove","select","set","value","var",
        "when","where","with","yield","required","scoped","file",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    // Verbatim and interpolated strings handled as plain strings — content within
    // `$"..."` interpolations is not parsed (matches the JS template-literal stance).
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"@"(?:""|[^"])*"|\$@"(?:""|[^"])*"|@\$"(?:""|[^"])*"|/\*[\s\S]*?\*/|//[^\n]*|\$?"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F][0-9a-fA-F_]*[uUlL]*|0b[01][01_]*[uUlL]*|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?[fFdDmMuUlL]*)\b"#)
    private static let constantRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#)
    private static let attributeRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*\[[^\]\n]+\]"#, options: [.anchorsMatchLines])

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

        let commentColor = Theme.color("csharp", "comment")
        let stringColor  = Theme.color("csharp", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let first = nsText.character(at: r.location)
            let color: NSColor = (first == 0x2F /* '/' */) ? commentColor : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(attributeRegex, color: Theme.color("csharp", "attribute"), consumeMatch: false)
        apply(numberRegex,    color: Theme.color("csharp", "number"),    consumeMatch: false)
        apply(constantRegex,  color: Theme.color("csharp", "constant"),  consumeMatch: false)
        apply(keywordRegex,   color: Theme.color("csharp", "keyword"),   consumeMatch: false)
    }
}
