import AppKit

// MARK: - Rust syntax highlighter

enum RustHighlighter {
    private static let keywords: [String] = [
        "as","async","await","break","const","continue","crate","dyn","else","enum",
        "extern","false","fn","for","if","impl","in","let","loop","match","mod","move",
        "mut","pub","ref","return","Self","self","static","struct","super","trait",
        "true","type","unsafe","use","where","while","box","do","final","macro","override",
        "priv","try","typeof","unsized","virtual","yield","union",
        "bool","char","f32","f64","i8","i16","i32","i64","i128","isize","str","u8","u16",
        "u32","u64","u128","usize",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    // Raw strings (`r"..."`, `r#"..."#`) handled with limited # depth — good enough
    // for the vast majority of code. Block comments support a single nesting level.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: ##"r#{0,5}"[\s\S]*?"#{0,5}|/\*(?:[^/*]|\*(?!/)|/(?!\*)|/\*[\s\S]*?\*/)*\*/|//[^\n]*|b?"(?:\\.|[^"\\])*"|b?'(?:\\.|[^'\\])*'"##)

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F][0-9a-fA-F_]*|0b[01][01_]*|0o[0-7][0-7_]*|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)(?:[iuUfF](?:8|16|32|64|128|size))?\b"#)
    private static let constantRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#)
    private static let attributeRegex = try! NSRegularExpression(pattern: #"#!?\[[^\]\n]+\]"#)
    private static let macroRegex = try! NSRegularExpression(pattern: #"\b[a-zA-Z_][a-zA-Z0-9_]*!"#)

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

        let commentColor = Theme.color("rust", "comment")
        let stringColor  = Theme.color("rust", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x2F /* '/' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(attributeRegex, color: Theme.color("rust", "attribute"), consumeMatch: true)
        apply(macroRegex,     color: Theme.color("rust", "macro"),     consumeMatch: false)
        apply(numberRegex,    color: Theme.color("rust", "number"),    consumeMatch: false)
        apply(constantRegex,  color: Theme.color("rust", "constant"),  consumeMatch: false)
        apply(keywordRegex,   color: Theme.color("rust", "keyword"),   consumeMatch: false)
    }
}
