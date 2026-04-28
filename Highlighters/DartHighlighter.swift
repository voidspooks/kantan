import AppKit

// MARK: - Dart syntax highlighter

enum DartHighlighter {
    private static let keywords: [String] = [
        "abstract","as","assert","async","await","break","case","catch","class","const",
        "continue","covariant","default","deferred","do","dynamic","else","enum","export",
        "extends","extension","external","factory","false","final","finally","for","Function",
        "get","hide","if","implements","import","in","interface","is","late","library",
        "mixin","new","null","of","on","operator","part","required","rethrow","return",
        "sealed","set","show","static","super","switch","sync","this","throw","true","try",
        "typedef","var","void","while","with","yield","base",
        "bool","double","int","num","String","List","Map","Set","Object","Never","Null",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    // Triple-quoted strings first.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #""""[\s\S]*?"""|'''[\s\S]*?'''|/\*[\s\S]*?\*/|//[^\n]*|r?"(?:\\.|[^"\\\n])*"|r?'(?:\\.|[^'\\\n])*'"#)

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#)
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

        let commentColor = Theme.color("dart", "comment")
        let stringColor  = Theme.color("dart", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x2F /* '/' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,     color: Theme.color("dart", "number"),     consumeMatch: false)
        apply(constantRegex,   color: Theme.color("dart", "constant"),   consumeMatch: false)
        apply(keywordRegex,    color: Theme.color("dart", "keyword"),    consumeMatch: false)
        apply(annotationRegex, color: Theme.color("dart", "annotation"), consumeMatch: false)
    }
}
