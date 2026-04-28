import AppKit

// MARK: - Bash / shell syntax highlighter

enum BashHighlighter {
    private static let keywords: [String] = [
        "if","then","else","elif","fi","case","esac","for","while","until","do","done",
        "in","function","select","time","return","exit","break","continue","true","false",
        "echo","export","local","readonly","declare","typeset","source","alias","unalias",
        "set","unset","shift","trap","read","let","eval","exec","test","cd","pwd","pushd",
        "popd","dirs","jobs","bg","fg","kill","wait",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    // Heredocs aren't tracked — close enough for the typical script.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"#[^\n]*|"(?:\\.|[^"\\])*"|'[^'\n]*'"#)

    private static let numberRegex = try! NSRegularExpression(pattern: #"\b\d+\b"#)
    private static let variableRegex = try! NSRegularExpression(
        pattern: #"\$(?:\{[^}\n]+\}|\([^)\n]+\)|[a-zA-Z_][a-zA-Z0-9_]*|[0-9]+|[#@*?$!_-])"#)

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

        let commentColor = Theme.color("bash", "comment")
        let stringColor  = Theme.color("bash", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x23 /* '#' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,   color: Theme.color("bash", "number"),   consumeMatch: false)
        apply(keywordRegex,  color: Theme.color("bash", "keyword"),  consumeMatch: false)
        apply(variableRegex, color: Theme.color("bash", "variable"), consumeMatch: false)
    }
}
