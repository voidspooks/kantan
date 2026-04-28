import AppKit

// MARK: - PHP syntax highlighter

enum PHPHighlighter {
    private static let keywords: [String] = [
        "abstract","and","array","as","break","callable","case","catch","class","clone",
        "const","continue","declare","default","do","echo","else","elseif","empty",
        "enddeclare","endfor","endforeach","endif","endswitch","endwhile","enum","extends",
        "final","finally","fn","for","foreach","function","global","goto","if","implements",
        "include","include_once","instanceof","insteadof","interface","isset","list","match",
        "namespace","new","or","print","private","protected","public","readonly","require",
        "require_once","return","self","static","switch","throw","trait","try","unset",
        "use","var","while","xor","yield","parent","true","false","null",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    // PHP supports `#`, `//`, and `/* */` comments. Listed first so the engine
    // doesn't open a fake string later.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"/\*[\s\S]*?\*/|//[^\n]*|#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F][0-9a-fA-F_]*|0b[01][01_]*|0o[0-7][0-7_]*|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)\b"#)
    private static let constantRegex = try! NSRegularExpression(pattern: #"\b[A-Z_][A-Z0-9_]{2,}\b"#)
    private static let variableRegex = try! NSRegularExpression(pattern: #"\$[a-zA-Z_][a-zA-Z0-9_]*"#)

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

        let commentColor = Theme.color("php", "comment")
        let stringColor  = Theme.color("php", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let first = nsText.character(at: r.location)
            let color: NSColor = (first == 0x2F /* '/' */ || first == 0x23 /* '#' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,   color: Theme.color("php", "number"),   consumeMatch: false)
        apply(constantRegex, color: Theme.color("php", "constant"), consumeMatch: false)
        apply(keywordRegex,  color: Theme.color("php", "keyword"),  consumeMatch: false)
        apply(variableRegex, color: Theme.color("php", "variable"), consumeMatch: false)
    }
}
