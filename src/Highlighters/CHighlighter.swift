import AppKit

// MARK: - C syntax highlighter

enum CHighlighter {
    private static let keywords: [String] = [
        "auto","break","case","char","const","continue","default","do","double","else",
        "enum","extern","float","for","goto","if","inline","int","long","register",
        "restrict","return","short","signed","sizeof","static","struct","switch","typedef",
        "union","unsigned","void","volatile","while","_Alignas","_Alignof","_Atomic","_Bool",
        "_Complex","_Generic","_Imaginary","_Noreturn","_Static_assert","_Thread_local",
        "true","false","NULL",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F][0-9a-fA-F']*(?:[uUlL]|ll|LL)*|0b[01][01']*(?:[uUlL]|ll|LL)*|\d[\d']*(?:\.[\d']+)?(?:[eE][+-]?\d+)?(?:[uUlLfF]|ll|LL)*)\b"#)
    private static let constantRegex = try! NSRegularExpression(pattern: #"\b[A-Z_][A-Z0-9_]{2,}\b"#)
    private static let preprocessorRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*#[ \t]*[a-zA-Z_]+"#, options: [.anchorsMatchLines])

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

        let commentColor = Theme.color("c", "comment")
        let stringColor  = Theme.color("c", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x2F /* '/' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(preprocessorRegex, color: Theme.color("c", "preprocessor"), consumeMatch: false)
        apply(numberRegex,       color: Theme.color("c", "number"),       consumeMatch: false)
        apply(constantRegex,     color: Theme.color("c", "constant"),     consumeMatch: false)
        apply(keywordRegex,      color: Theme.color("c", "keyword"),      consumeMatch: false)
    }
}
