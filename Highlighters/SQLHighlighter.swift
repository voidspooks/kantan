import AppKit

// MARK: - SQL syntax highlighter

enum SQLHighlighter {
    private static let keywords: [String] = [
        "SELECT","FROM","WHERE","INSERT","INTO","UPDATE","SET","DELETE","CREATE","DROP",
        "ALTER","TABLE","INDEX","VIEW","TRIGGER","PROCEDURE","FUNCTION","DATABASE","SCHEMA",
        "JOIN","INNER","OUTER","LEFT","RIGHT","FULL","CROSS","ON","USING","AS","AND","OR",
        "NOT","IN","EXISTS","BETWEEN","LIKE","ILIKE","IS","NULL","ORDER","BY","GROUP","HAVING",
        "LIMIT","OFFSET","UNION","INTERSECT","EXCEPT","ALL","DISTINCT","VALUES","DEFAULT",
        "PRIMARY","KEY","FOREIGN","REFERENCES","UNIQUE","CHECK","CONSTRAINT","CASCADE",
        "BEGIN","COMMIT","ROLLBACK","TRANSACTION","SAVEPOINT","RETURNING","WITH","RECURSIVE",
        "CASE","WHEN","THEN","ELSE","END","IF","WHILE","FOR","LOOP","DECLARE","CALL",
        "GRANT","REVOKE","TO","FROM","TRUE","FALSE","ASC","DESC","ADD","COLUMN","RENAME",
        "MODIFY","REPLACE","TEMPORARY","TEMP","EXPLAIN","ANALYZE",
    ]

    private static let keywordRegex: NSRegularExpression = {
        // SQL keywords are case-insensitive — match either case.
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // -- line and /* */ block comments. Single-quoted strings are SQL's literal form;
    // double-quoted identifiers vary by dialect — we still color them as strings.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"/\*[\s\S]*?\*/|--[^\n]*|'(?:''|[^'])*'|"(?:""|[^"])*""#)

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#)
    private static let constantRegex = try! NSRegularExpression(
        pattern: #"\b(?:NULL|TRUE|FALSE|CURRENT_DATE|CURRENT_TIME|CURRENT_TIMESTAMP|CURRENT_USER)\b"#,
        options: [.caseInsensitive])

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

        let commentColor = Theme.color("sql", "comment")
        let stringColor  = Theme.color("sql", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let first = nsText.character(at: r.location)
            let color: NSColor = (first == 0x2F /* '/' */ || first == 0x2D /* '-' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,   color: Theme.color("sql", "number"),   consumeMatch: false)
        apply(constantRegex, color: Theme.color("sql", "constant"), consumeMatch: false)
        apply(keywordRegex,  color: Theme.color("sql", "keyword"),  consumeMatch: false)
    }
}
