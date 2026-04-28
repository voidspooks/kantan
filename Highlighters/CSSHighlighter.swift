import AppKit

// MARK: - CSS syntax highlighter

enum CSSHighlighter {
    private static let commentRegex = try! NSRegularExpression(
        pattern: #"/\*[\s\S]*?\*/"#)

    private static let stringRegex = try! NSRegularExpression(
        pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)

    // At-rules like @media, @import, @keyframes, @supports.
    private static let atRuleRegex = try! NSRegularExpression(
        pattern: #"@[a-zA-Z-]+\b"#)

    // Selector text: from start-of-string or after `}` up to (but not including) `{`.
    // Capture 1 is the selector body. We don't add this to `consumed` so at-rules can
    // still re-color their `@foo` token over the top.
    private static let selectorRegex = try! NSRegularExpression(
        pattern: #"(?:^|[}])([^{}]*?)(?=\{)"#)

    // Property name: word followed by colon, immediately preceded by `{` or `;`
    // (so that pseudo-class selectors like `a:hover` don't get misclassified).
    private static let propertyRegex = try! NSRegularExpression(
        pattern: #"[{;]\s*([a-zA-Z-]+)(?=\s*:)"#)

    private static let hexColorRegex = try! NSRegularExpression(
        pattern: #"#[0-9a-fA-F]{3,8}\b"#)

    // Numbers, optionally followed by a CSS unit.
    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|vmin|vmax|s|ms|deg|rad|turn|fr|ch|ex|cm|mm|in|pt|pc|Q)?"#)

    private static let importantRegex = try! NSRegularExpression(
        pattern: #"!important\b"#)

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

        let commentColor  = Theme.color("css", "comment")
        let stringColor   = Theme.color("css", "string")
        let keywordColor  = Theme.color("css", "keyword")
        let selectorColor = Theme.color("css", "selector")
        let propertyColor = Theme.color("css", "property")
        let numberColor   = Theme.color("css", "number")
        let constantColor = Theme.color("css", "constant")

        // 1. Comments and strings — fully consumed so subsequent regexes ignore them.
        commentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            storage.addAttribute(.foregroundColor, value: commentColor, range: m.range)
            consumed.append(m.range)
        }
        stringRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            if intersectsConsumed(m.range) { return }
            storage.addAttribute(.foregroundColor, value: stringColor, range: m.range)
            consumed.append(m.range)
        }

        // 2. Selectors first, then at-rules over the top — so `@media (max-width: 600px)`
        //    paints the whole condition as selector text and just `@media` as keyword.
        selectorRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let group = m.range(at: 1)
            if group.location == NSNotFound { return }
            if intersectsConsumed(group) { return }
            storage.addAttribute(.foregroundColor, value: selectorColor, range: group)
        }
        atRuleRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            if intersectsConsumed(m.range) { return }
            storage.addAttribute(.foregroundColor, value: keywordColor, range: m.range)
        }

        // 3. Property names inside `{...}`.
        propertyRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let nameRange = m.range(at: 1)
            if nameRange.location == NSNotFound { return }
            if intersectsConsumed(nameRange) { return }
            storage.addAttribute(.foregroundColor, value: propertyColor, range: nameRange)
        }

        // 4. Numbers, hex colors, !important.
        numberRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            if intersectsConsumed(m.range) { return }
            storage.addAttribute(.foregroundColor, value: numberColor, range: m.range)
        }
        hexColorRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            if intersectsConsumed(m.range) { return }
            storage.addAttribute(.foregroundColor, value: constantColor, range: m.range)
        }
        importantRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            if intersectsConsumed(m.range) { return }
            storage.addAttribute(.foregroundColor, value: constantColor, range: m.range)
        }
    }
}
