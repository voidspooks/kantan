import AppKit

// MARK: - Python syntax highlighter

enum PythonHighlighter {
    private static let keywords: [String] = [
        "False","None","True","and","as","assert","async","await","break","class",
        "continue","def","del","elif","else","except","finally","for","from","global",
        "if","import","in","is","lambda","nonlocal","not","or","pass","raise","return",
        "try","while","with","yield","match","case",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    // Triple-quoted strings first so a `"""` doesn't get truncated to `""`.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"""([uUbBrRfF]{0,3})"{3}[\s\S]*?"{3}|([uUbBrRfF]{0,3})'{3}[\s\S]*?'{3}|#[^\n]*|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"""#)

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F][0-9a-fA-F_]*|0o[0-7][0-7_]*|0b[01][01_]*|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?j?)\b"#)
    private static let constantRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#)
    private static let decoratorRegex = try! NSRegularExpression(
        pattern: #"^\s*@[A-Za-z_][A-Za-z0-9_.]*"#, options: [.anchorsMatchLines])

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

        let commentColor = Theme.color("python", "comment")
        let stringColor  = Theme.color("python", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x23 /* '#' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,    color: Theme.color("python", "number"),    consumeMatch: false)
        apply(constantRegex,  color: Theme.color("python", "constant"),  consumeMatch: false)
        apply(keywordRegex,   color: Theme.color("python", "keyword"),   consumeMatch: false)
        apply(decoratorRegex, color: Theme.color("python", "decorator"), consumeMatch: false)
    }
}
