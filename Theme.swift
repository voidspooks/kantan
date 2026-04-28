import AppKit

// MARK: - Theme (dark mode only)

enum Theme {
    static let background = NSColor(red: 0.118, green: 0.118, blue: 0.129, alpha: 1.0)
    static let foreground = NSColor(red: 0.831, green: 0.831, blue: 0.831, alpha: 1.0)
    static let cursor     = NSColor.white
    static let selection  = NSColor(red: 0.16,  green: 0.31,  blue: 0.50,  alpha: 1.0)

    static let gutterBackground = NSColor(red: 0.165, green: 0.165, blue: 0.180, alpha: 1.0)
    static let gutterText       = NSColor(red: 0.490, green: 0.490, blue: 0.510, alpha: 1.0)
    static let gutterBorder     = NSColor(red: 0.235, green: 0.235, blue: 0.255, alpha: 1.0)

    static let sidebarBackground = NSColor(red: 0.108, green: 0.108, blue: 0.118, alpha: 1.0)
    static let sidebarText       = NSColor(red: 0.831, green: 0.831, blue: 0.831, alpha: 1.0)
    static let sidebarSelection  = NSColor(red: 0.16,  green: 0.31,  blue: 0.50,  alpha: 1.0)

    // Token defaults shared across languages.
    private static let dKeyword  = NSColor(red: 0.776, green: 0.522, blue: 0.753, alpha: 1.0)
    private static let dString   = NSColor(red: 0.808, green: 0.569, blue: 0.471, alpha: 1.0)
    private static let dComment  = NSColor(red: 0.420, green: 0.600, blue: 0.333, alpha: 1.0)
    private static let dNumber   = NSColor(red: 0.710, green: 0.808, blue: 0.659, alpha: 1.0)
    private static let dConstant = NSColor(red: 0.306, green: 0.788, blue: 0.690, alpha: 1.0)
    private static let dSymbol   = NSColor(red: 0.337, green: 0.612, blue: 0.839, alpha: 1.0)
    private static let dVariable = NSColor(red: 0.612, green: 0.863, blue: 0.996, alpha: 1.0)

    /// Per-language token palette. Highlighters look colors up by (language, tokenName).
    /// Adding a new language = add an entry here + a highlighter + a Syntax case.
    static var palette: [String: [String: NSColor]] = [
        "ruby": [
            "keyword":  dKeyword,
            "string":   dString,
            "comment":  dComment,
            "number":   dNumber,
            "constant": dConstant,
            "symbol":   dSymbol,
            "variable": dVariable,
        ],
        "yaml": [
            "key":      dSymbol,
            "string":   dString,
            "comment":  dComment,
            "number":   dNumber,
            "constant": dConstant,
        ],
        "swift": [
            "keyword":   dKeyword,
            "string":    dString,
            "comment":   dComment,
            "number":    dNumber,
            "constant":  dConstant,
            "attribute": dVariable,
        ],
        "javascript": [
            "keyword":  dKeyword,
            "string":   dString,
            "comment":  dComment,
            "number":   dNumber,
            "constant": dConstant,
        ],
        "html": [
            "tag":       dKeyword,
            "attribute": dVariable,
            "string":    dString,
            "comment":   dComment,
            "constant":  dConstant,
        ],
        "python": [
            "keyword":   dKeyword,
            "string":    dString,
            "comment":   dComment,
            "number":    dNumber,
            "constant":  dConstant,
            "decorator": dVariable,
        ],
        "typescript": [
            "keyword":  dKeyword,
            "string":   dString,
            "comment":  dComment,
            "number":   dNumber,
            "constant": dConstant,
        ],
        "java": [
            "keyword":    dKeyword,
            "string":     dString,
            "comment":    dComment,
            "number":     dNumber,
            "constant":   dConstant,
            "annotation": dVariable,
        ],
        "c": [
            "keyword":      dKeyword,
            "string":       dString,
            "comment":      dComment,
            "number":       dNumber,
            "constant":     dConstant,
            "preprocessor": dVariable,
        ],
        "cpp": [
            "keyword":      dKeyword,
            "string":       dString,
            "comment":      dComment,
            "number":       dNumber,
            "constant":     dConstant,
            "preprocessor": dVariable,
        ],
        "csharp": [
            "keyword":   dKeyword,
            "string":    dString,
            "comment":   dComment,
            "number":    dNumber,
            "constant":  dConstant,
            "attribute": dVariable,
        ],
        "php": [
            "keyword":  dKeyword,
            "string":   dString,
            "comment":  dComment,
            "number":   dNumber,
            "constant": dConstant,
            "variable": dVariable,
        ],
        "go": [
            "keyword":  dKeyword,
            "string":   dString,
            "comment":  dComment,
            "number":   dNumber,
            "constant": dConstant,
        ],
        "rust": [
            "keyword":   dKeyword,
            "string":    dString,
            "comment":   dComment,
            "number":    dNumber,
            "constant":  dConstant,
            "attribute": dVariable,
            "macro":     dSymbol,
        ],
        "kotlin": [
            "keyword":    dKeyword,
            "string":     dString,
            "comment":    dComment,
            "number":     dNumber,
            "constant":   dConstant,
            "annotation": dVariable,
        ],
        "sql": [
            "keyword":  dKeyword,
            "string":   dString,
            "comment":  dComment,
            "number":   dNumber,
            "constant": dConstant,
        ],
        "r": [
            "keyword":  dKeyword,
            "string":   dString,
            "comment":  dComment,
            "number":   dNumber,
            "constant": dConstant,
        ],
        "dart": [
            "keyword":    dKeyword,
            "string":     dString,
            "comment":    dComment,
            "number":     dNumber,
            "constant":   dConstant,
            "annotation": dVariable,
        ],
        "scala": [
            "keyword":    dKeyword,
            "string":     dString,
            "comment":    dComment,
            "number":     dNumber,
            "constant":   dConstant,
            "annotation": dVariable,
        ],
        "perl": [
            "keyword":  dKeyword,
            "string":   dString,
            "comment":  dComment,
            "number":   dNumber,
            "constant": dConstant,
            "variable": dVariable,
        ],
        "lua": [
            "keyword":  dKeyword,
            "string":   dString,
            "comment":  dComment,
            "number":   dNumber,
            "constant": dConstant,
        ],
        "bash": [
            "keyword":  dKeyword,
            "string":   dString,
            "comment":  dComment,
            "number":   dNumber,
            "variable": dVariable,
        ],
        "markdown": [
            "heading":    dKeyword,
            "strong":     dConstant,
            "emphasis":   dVariable,
            "code":       dString,
            "link":       dSymbol,
            "list":       dKeyword,
            "blockquote": dComment,
            "rule":       dComment,
        ],
    ]

    static func color(_ language: String, _ token: String) -> NSColor {
        return palette[language]?[token] ?? foreground
    }

    /// Merge a parsed color map into the language's existing entries.
    /// Unknown languages and unknown tokens are accepted — highlighters simply ignore tokens they don't use.
    static func apply(_ language: String, _ colors: [String: NSColor]) {
        var existing = palette[language] ?? [:]
        for (k, v) in colors { existing[k] = v }
        palette[language] = existing
    }
}
