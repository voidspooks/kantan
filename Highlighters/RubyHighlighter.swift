import AppKit

// MARK: - Ruby syntax highlighter

enum RubyHighlighter {
    private static let keywords: [String] = [
        "BEGIN","END","alias","and","begin","break","case","class","def","do",
        "else","elsif","end","ensure","false","for","if","in","module","next",
        "nil","not","or","redo","rescue","retry","return","self","super","then",
        "true","undef","unless","until","when","while","yield",
        "require","require_relative","include","extend",
        "attr_reader","attr_writer","attr_accessor",
        "puts","print","raise","lambda","proc","loop","new"
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    // One regex covers comments AND strings so they're resolved in a single
    // left-to-right pass. The comment alternative is listed first, so a '#' at
    // any position wins immediately — quotes that appear inside a comment can
    // never open a fake string.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)
    private static let numberRegex   = try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#)
    private static let symbolRegex   = try! NSRegularExpression(pattern: #":[a-zA-Z_]\w*"#)
    private static let variableRegex = try! NSRegularExpression(pattern: #"(@@|@|\$)[a-zA-Z_]\w*"#)
    private static let constantRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#)

    static func highlight(_ storage: NSTextStorage) {
        let text = storage.string
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard fullRange.length > 0 else { return }

        // Reset foreground to default across the whole document.
        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor, value: Theme.foreground, range: fullRange)

        // Track ranges already colored by string/comment passes so later passes skip them.
        var consumed = [NSRange]()

        func intersectsConsumed(_ r: NSRange) -> Bool {
            for c in consumed where NSIntersectionRange(c, r).length > 0 {
                return true
            }
            return false
        }

        func apply(_ regex: NSRegularExpression, color: NSColor, consumeMatch: Bool, filter: ((String) -> Bool)? = nil) {
            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let m = match else { return }
                if intersectsConsumed(m.range) { return }
                if let filter = filter {
                    let s = nsText.substring(with: m.range)
                    if !filter(s) { return }
                }
                storage.addAttribute(.foregroundColor, value: color, range: m.range)
                if consumeMatch { consumed.append(m.range) }
            }
        }

        let commentColor = Theme.color("ruby", "comment")
        let stringColor  = Theme.color("ruby", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x23 /* '#' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,   color: Theme.color("ruby", "number"),   consumeMatch: false)
        apply(symbolRegex,   color: Theme.color("ruby", "symbol"),   consumeMatch: false)
        apply(variableRegex, color: Theme.color("ruby", "variable"), consumeMatch: false)
        apply(constantRegex, color: Theme.color("ruby", "constant"), consumeMatch: false)
        apply(keywordRegex,  color: Theme.color("ruby", "keyword"),  consumeMatch: false)
    }
}
