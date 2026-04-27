import AppKit

// MARK: - Swift syntax highlighter

enum SwiftHighlighter {
    private static let keywords: [String] = [
        // Declarations
        "associatedtype","class","deinit","enum","extension","fileprivate",
        "func","import","init","inout","internal","let","open","operator",
        "private","protocol","public","static","struct","subscript",
        "typealias","var",
        // Modifiers
        "convenience","dynamic","final","indirect","lazy","mutating",
        "nonmutating","optional","override","required","weak","unowned",
        // Statements
        "break","case","continue","default","defer","do","else","fallthrough",
        "for","guard","if","in","repeat","return","switch","where","while",
        // Expressions
        "as","catch","is","rethrows","throw","throws","try","async","await",
        "some","any",
        // Constants and self/Self/super
        "false","nil","self","Self","super","true","Any","AnyObject",
        // Property accessors
        "get","set","willSet","didSet",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    // Triple-quoted (multi-line) strings must come first so the engine doesn't
    // greedily match a single `"` and stop early. Block comments are likewise
    // listed before line comments so `/*` isn't truncated to `/`.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #""""[\s\S]*?"""|/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*""#)

    private static let numberRegex    = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F][0-9a-fA-F_]*|0b[01][01_]*|0o[0-7][0-7_]*|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)\b"#)
    private static let constantRegex  = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#)
    private static let attributeRegex = try! NSRegularExpression(pattern: #"@[a-zA-Z_]\w*"#)

    static func highlight(_ storage: NSTextStorage) {
        let text = storage.string
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard fullRange.length > 0 else { return }

        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor, value: Theme.foreground, range: fullRange)

        var consumed = [NSRange]()

        func intersectsConsumed(_ r: NSRange) -> Bool {
            for c in consumed where NSIntersectionRange(c, r).length > 0 {
                return true
            }
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

        let commentColor = Theme.color("swift", "comment")
        let stringColor  = Theme.color("swift", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            // First char of the match: '/' → comment, '"' → string.
            let color: NSColor = (nsText.character(at: r.location) == 0x2F /* '/' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,    color: Theme.color("swift", "number"),    consumeMatch: false)
        apply(attributeRegex, color: Theme.color("swift", "attribute"), consumeMatch: false)
        // constant runs before keyword so Self/Any/AnyObject get repainted as keywords (the latter pass wins).
        apply(constantRegex,  color: Theme.color("swift", "constant"),  consumeMatch: false)
        apply(keywordRegex,   color: Theme.color("swift", "keyword"),   consumeMatch: false)
    }
}
