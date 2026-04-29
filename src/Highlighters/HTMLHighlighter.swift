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

    // Embedded blocks. Capture 1 is the inner content so we can re-run a sub-language
    // highlighter over just that range. `[\s\S]` matches newlines without enabling the
    // dotall flag, and `*?` keeps us from swallowing across multiple style/script blocks.
    private static let styleBlockRegex = try! NSRegularExpression(
        pattern: #"<style\b[^>]*>([\s\S]*?)</style>"#, options: [.caseInsensitive])

    private static let scriptBlockRegex = try! NSRegularExpression(
        pattern: #"<script\b[^>]*>([\s\S]*?)</script>"#, options: [.caseInsensitive])

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

        // Re-run sub-language highlighters over the inner content of <style> and <script>.
        // We highlight a detached NSTextStorage holding just the substring so the
        // sub-language regexes (some of which anchor on `^`) see a clean start, then
        // copy the resulting foreground attributes back to the parent at the offset.
        let nsText = text as NSString
        func applyEmbedded(_ regex: NSRegularExpression, _ run: (NSTextStorage) -> Void) {
            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let m = match else { return }
                let inner = m.range(at: 1)
                if inner.location == NSNotFound || inner.length == 0 { return }
                let snippet = nsText.substring(with: inner)
                let temp = NSTextStorage(string: snippet)
                run(temp)
                let tempRange = NSRange(location: 0, length: temp.length)
                temp.enumerateAttribute(.foregroundColor, in: tempRange, options: []) { value, r, _ in
                    guard let color = value as? NSColor else { return }
                    let target = NSRange(location: inner.location + r.location, length: r.length)
                    storage.addAttribute(.foregroundColor, value: color, range: target)
                }
            }
        }

        applyEmbedded(styleBlockRegex)  { CSSHighlighter.highlight($0) }
        applyEmbedded(scriptBlockRegex) { JavaScriptHighlighter.highlight($0) }
    }
}
