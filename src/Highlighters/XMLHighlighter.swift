import AppKit

// MARK: - XML syntax highlighter
//
// Same shape as HTMLHighlighter — comments, then declarations (processing
// instructions and CDATA in XML's case), then tags + attributes + strings.
// XML is case-sensitive but the regexes are already, so no special handling is
// needed there.

enum XMLHighlighter {
    private static let commentRegex = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->"#)

    /// `<?xml version="1.0"?>` and any other processing instruction.
    private static let processingInstructionRegex = try! NSRegularExpression(
        pattern: #"<\?[\s\S]*?\?>"#)

    /// `<!DOCTYPE …>`, `<!ELEMENT …>`, `<!ATTLIST …>`, etc.
    private static let declarationRegex = try! NSRegularExpression(
        pattern: #"<![A-Z][^>]*>"#)

    /// `<![CDATA[ … ]]>`. Treated as a literal block (string color).
    private static let cdataRegex = try! NSRegularExpression(
        pattern: #"<!\[CDATA\[[\s\S]*?\]\]>"#)

    private static let tagRegex = try! NSRegularExpression(
        pattern: #"</?([a-zA-Z_][a-zA-Z0-9._:-]*)\b[^>]*/?>"#)

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

        let commentColor  = Theme.color("xml", "comment")
        let tagColor      = Theme.color("xml", "tag")
        let attrColor     = Theme.color("xml", "attribute")
        let stringColor   = Theme.color("xml", "string")
        let constantColor = Theme.color("xml", "constant")

        // Comments first so a `<` inside `<!-- -->` doesn't open a fake tag.
        commentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            storage.addAttribute(.foregroundColor, value: commentColor, range: m.range)
            consumed.append(m.range)
        }

        // CDATA next — its contents are literal text, color it like a string
        // and prevent later passes from re-tokenizing inside it.
        cdataRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            if intersectsConsumed(m.range) { return }
            storage.addAttribute(.foregroundColor, value: stringColor, range: m.range)
            consumed.append(m.range)
        }

        processingInstructionRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            if intersectsConsumed(m.range) { return }
            storage.addAttribute(.foregroundColor, value: constantColor, range: m.range)
            consumed.append(m.range)
        }

        declarationRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
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
