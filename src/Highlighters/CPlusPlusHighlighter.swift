import AppKit

// MARK: - C++ syntax highlighter

enum CPlusPlusHighlighter {
    private static let keywords: [String] = [
        "alignas","alignof","and","and_eq","asm","auto","bitand","bitor","bool","break",
        "case","catch","char","char8_t","char16_t","char32_t","class","co_await","co_return",
        "co_yield","compl","concept","const","consteval","constexpr","constinit","const_cast",
        "continue","decltype","default","delete","do","double","dynamic_cast","else","enum",
        "explicit","export","extern","false","float","for","friend","goto","if","inline",
        "int","long","mutable","namespace","new","noexcept","not","not_eq","nullptr",
        "operator","or","or_eq","private","protected","public","register","reinterpret_cast",
        "requires","return","short","signed","sizeof","static","static_assert","static_cast",
        "struct","switch","template","this","thread_local","throw","true","try","typedef",
        "typeid","typename","union","unsigned","using","virtual","void","volatile","wchar_t",
        "while","xor","xor_eq","final","override",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"R"\(([\s\S]*?)\)"|/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)

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

        let commentColor = Theme.color("cpp", "comment")
        let stringColor  = Theme.color("cpp", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x2F /* '/' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(preprocessorRegex, color: Theme.color("cpp", "preprocessor"), consumeMatch: false)
        apply(numberRegex,       color: Theme.color("cpp", "number"),       consumeMatch: false)
        apply(constantRegex,     color: Theme.color("cpp", "constant"),     consumeMatch: false)
        apply(keywordRegex,      color: Theme.color("cpp", "keyword"),      consumeMatch: false)
    }
}
