import AppKit

// MARK: - Makefile syntax highlighter

enum MakefileHighlighter {
    private static let commentRegex = try! NSRegularExpression(
        pattern: #"#[^\n]*"#)

    private static let stringRegex = try! NSRegularExpression(
        pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)

    // Variable references: $(NAME), ${NAME}, or $X (single char incl. automatic vars
    // like $@, $<, $%, $^, $?, $+, $*).
    private static let variableRegex = try! NSRegularExpression(
        pattern: #"\$\([^()]*\)|\$\{[^{}]*\}|\$[a-zA-Z_@<%^?+*]"#)

    // Directives and conditionals at line start.
    private static let keywordRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(include|-include|sinclude|export|unexport|override|define|endef|ifeq|ifneq|ifdef|ifndef|else|endif|vpath|undefine)\b"#,
        options: [.anchorsMatchLines])

    // Target line: the run of text from line start (not tab-indented, not a comment)
    // up to a `:` not followed by `=`. Captures the run before the colon.
    private static let targetRegex = try! NSRegularExpression(
        pattern: #"^([^\t#:\n][^:#\n]*?)(?=:(?!=))"#,
        options: [.anchorsMatchLines])

    // Variable assignment: identifier at line start followed by =, :=, ?=, +=, ::=
    private static let assignmentRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*([a-zA-Z_][a-zA-Z0-9_]*)[ \t]*(?::?:?|\?|\+)?="#,
        options: [.anchorsMatchLines])

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

        let commentColor  = Theme.color("makefile", "comment")
        let stringColor   = Theme.color("makefile", "string")
        let keywordColor  = Theme.color("makefile", "keyword")
        let variableColor = Theme.color("makefile", "variable")
        let targetColor   = Theme.color("makefile", "target")

        // Comments and strings — fully consumed so subsequent regexes ignore them.
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

        // Targets — color the run before `:`. Variable references inside that run
        // get re-colored later.
        targetRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range(at: 1)
            if r.location == NSNotFound { return }
            if intersectsConsumed(r) { return }
            storage.addAttribute(.foregroundColor, value: targetColor, range: r)
        }

        // Variable assignment LHS.
        assignmentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range(at: 1)
            if r.location == NSNotFound { return }
            if intersectsConsumed(r) { return }
            storage.addAttribute(.foregroundColor, value: variableColor, range: r)
        }

        // Directives — these win over the target run when they happen to start a line.
        keywordRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range(at: 1)
            if r.location == NSNotFound { return }
            if intersectsConsumed(r) { return }
            storage.addAttribute(.foregroundColor, value: keywordColor, range: r)
        }

        // Variable references everywhere — last so they win inside target/recipe text.
        variableRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            if intersectsConsumed(m.range) { return }
            storage.addAttribute(.foregroundColor, value: variableColor, range: m.range)
        }
    }
}
