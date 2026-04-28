import AppKit

// MARK: - Perl syntax highlighter

enum PerlHighlighter {
    private static let keywords: [String] = [
        "my","our","local","state","sub","if","elsif","else","unless","while","until",
        "for","foreach","do","return","last","next","redo","use","require","package","no",
        "and","or","not","xor","eq","ne","lt","gt","le","ge","cmp","defined","undef",
        "exists","delete","print","printf","say","die","warn","chomp","chop","length",
        "given","when","BEGIN","END","INIT","CHECK","UNITCHECK","__END__","__DATA__",
        "__FILE__","__LINE__","__PACKAGE__","__SUB__",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    // POD blocks (`=foo` ... `=cut`) at line start are documentation; treat them as comments.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"^=[a-zA-Z][\s\S]*?^=cut\s*$|#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#,
        options: [.anchorsMatchLines])

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F]+|0b[01]+|0[0-7]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#)
    private static let constantRegex = try! NSRegularExpression(pattern: #"\b[A-Z_][A-Z0-9_]{2,}\b"#)
    private static let variableRegex = try! NSRegularExpression(
        pattern: #"[\$@%][#$]?[a-zA-Z_][a-zA-Z0-9_]*|[\$@%]\{[^}\n]+\}"#)

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

        let commentColor = Theme.color("perl", "comment")
        let stringColor  = Theme.color("perl", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let first = nsText.character(at: r.location)
            let color: NSColor = (first == 0x23 /* '#' */ || first == 0x3D /* '=' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,   color: Theme.color("perl", "number"),   consumeMatch: false)
        apply(constantRegex, color: Theme.color("perl", "constant"), consumeMatch: false)
        apply(keywordRegex,  color: Theme.color("perl", "keyword"),  consumeMatch: false)
        apply(variableRegex, color: Theme.color("perl", "variable"), consumeMatch: false)
    }
}
