import AppKit

// MARK: - HTML syntax highlighter

enum HTMLHighlighter {
    // Comments first so a `<` inside `<!-- -->` doesn't open a fake tag.
    private static let commentRegex = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->"#)

    private static let doctypeRegex = try! NSRegularExpression(
        pattern: #"<!DOCTYPE[^>]*>"#, options: [.caseInsensitive])

    // Opening, closing, or self-closing tag. Capture 1 is the tag name so we can
    // color it without recoloring it when the attribute pass runs over the same range.
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"</?([a-zA-Z][a-zA-Z0-9:-]*)\b[^>]*/?>"#)

    // Attribute name followed by `=`. Capture 1 is the name; we ignore matches whose
    // range equals the tag-name range to avoid stomping the tag color.
    private static let attributeNameRegex = try! NSRegularExpression(
        pattern: #"\b([a-zA-Z_:][a-zA-Z0-9_.:-]*)\s*="#)

    private static let stringRegex = try! NSRegularExpression(
        pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)

    static func highlight(_ storage: NSTextStorage) {
        let text = storage.string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
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

        let commentColor  = Theme.color("html", "comment")
        let tagColor      = Theme.color("html", "tag")
        let attrColor     = Theme.color("html", "attribute")
        let stringColor   = Theme.color("html", "string")
        let constantColor = Theme.color("html", "constant")

        commentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            storage.addAttribute(.foregroundColor, value: commentColor, range: m.range)
            consumed.append(m.range)
        }

        doctypeRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            if intersectsConsumed(m.range) { return }
            storage.addAttribute(.foregroundColor, value: constantColor, range: m.range)
            consumed.append(m.range)
        }

        tagRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            if intersectsConsumed(m.range) { return }
            let nameRange = m.range(at: 1)
            if nameRange.location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: tagColor, range: nameRange)
            }
            let tagRange = m.range
            attributeNameRegex.enumerateMatches(in: text, range: tagRange) { am, _, _ in
                guard let am = am else { return }
                let nr = am.range(at: 1)
                if nr.location == NSNotFound { return }
                if NSEqualRanges(nr, nameRange) { return }
                storage.addAttribute(.foregroundColor, value: attrColor, range: nr)
            }
            stringRegex.enumerateMatches(in: text, range: tagRange) { sm, _, _ in
                guard let sm = sm else { return }
                storage.addAttribute(.foregroundColor, value: stringColor, range: sm.range)
            }
        }
    }
}
