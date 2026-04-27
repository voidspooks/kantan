import AppKit

// MARK: - App metadata

enum App {
    static let version = "0.1.0"
    static let nameJapanese = "簡単"
}

// MARK: - Default settings.yaml (written to disk on first launch)

let defaultSettingsYAML = """
syntax_highlighting:
  ruby:
    keyword:  "#c685c0"
    string:   "#ce9178"
    comment:  "#6b9955"
    number:   "#b5cea8"
    constant: "#4ec9b0"
    symbol:   "#569cd6"
    variable: "#9cdcfe"
  yaml:
    key:      "#569cd6"
    string:   "#ce9178"
    comment:  "#6b9955"
    number:   "#b5cea8"
    constant: "#4ec9b0"
  swift:
    keyword:   "#c685c0"
    string:    "#ce9178"
    comment:   "#6b9955"
    number:    "#b5cea8"
    constant:  "#4ec9b0"
    attribute: "#9cdcfe"
"""

// MARK: - Theme (dark mode only)

enum Theme {
    static let background = NSColor(red: 0.118, green: 0.118, blue: 0.129, alpha: 1.0)
    static let foreground = NSColor(red: 0.831, green: 0.831, blue: 0.831, alpha: 1.0)
    static let cursor     = NSColor.white
    static let selection  = NSColor(red: 0.16,  green: 0.31,  blue: 0.50,  alpha: 1.0)

    static let gutterBackground = NSColor(red: 0.165, green: 0.165, blue: 0.180, alpha: 1.0)
    static let gutterText       = NSColor(red: 0.490, green: 0.490, blue: 0.510, alpha: 1.0)
    static let gutterBorder     = NSColor(red: 0.235, green: 0.235, blue: 0.255, alpha: 1.0)

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

// MARK: - Ruby syntax highlighter

enum RubyHighlighter {
    private static let keywords: [String] = [
        "BEGIN","END","alias","and","begin","break","case","class","def","do",
        "else","elsif","end","ensure","false","for","if","in","module","next",
        "nil","not","or","redo","rescue","retry","return","self","super","then",
        "true","undef","unless","until","when","while","yield",
        "require","require_relative","include","extend",
        "attr_reader","attr_writer","attr_accessor",
        "puts","print","raise","lambda","proc","loop","new"
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    // One regex covers comments AND strings so they're resolved in a single
    // left-to-right pass. The comment alternative is listed first, so a '#' at
    // any position wins immediately — quotes that appear inside a comment can
    // never open a fake string.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)
    private static let numberRegex   = try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#)
    private static let symbolRegex   = try! NSRegularExpression(pattern: #":[a-zA-Z_]\w*"#)
    private static let variableRegex = try! NSRegularExpression(pattern: #"(@@|@|\$)[a-zA-Z_]\w*"#)
    private static let constantRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#)

    static func highlight(_ storage: NSTextStorage) {
        let text = storage.string
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard fullRange.length > 0 else { return }

        // Reset foreground to default across the whole document.
        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor, value: Theme.foreground, range: fullRange)

        // Track ranges already colored by string/comment passes so later passes skip them.
        var consumed = [NSRange]()

        func intersectsConsumed(_ r: NSRange) -> Bool {
            for c in consumed where NSIntersectionRange(c, r).length > 0 {
                return true
            }
            return false
        }

        func apply(_ regex: NSRegularExpression, color: NSColor, consumeMatch: Bool, filter: ((String) -> Bool)? = nil) {
            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let m = match else { return }
                if intersectsConsumed(m.range) { return }
                if let filter = filter {
                    let s = nsText.substring(with: m.range)
                    if !filter(s) { return }
                }
                storage.addAttribute(.foregroundColor, value: color, range: m.range)
                if consumeMatch { consumed.append(m.range) }
            }
        }

        let commentColor = Theme.color("ruby", "comment")
        let stringColor  = Theme.color("ruby", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x23 /* '#' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,   color: Theme.color("ruby", "number"),   consumeMatch: false)
        apply(symbolRegex,   color: Theme.color("ruby", "symbol"),   consumeMatch: false)
        apply(variableRegex, color: Theme.color("ruby", "variable"), consumeMatch: false)
        apply(constantRegex, color: Theme.color("ruby", "constant"), consumeMatch: false)
        apply(keywordRegex,  color: Theme.color("ruby", "keyword"),  consumeMatch: false)
    }
}

// MARK: - YAML syntax highlighter

enum YAMLHighlighter {
    // Single pass for comments + strings — comment alternative listed first so
    // any '#' wins before a quote could open a fake string.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #"#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)
    // Key at line start, optional indent, optional list marker '- ', plain identifier, then ':'.
    // Group 1 captures just the identifier so we color the key without the colon.
    private static let keyRegex      = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:-[ \t]+)?([A-Za-z_][\w-]*)\s*:"#,
        options: [.anchorsMatchLines])
    private static let numberRegex   = try! NSRegularExpression(pattern: #"\b-?\d+(?:\.\d+)?\b"#)
    private static let constantRegex = try! NSRegularExpression(
        pattern: #"\b(?:[Tt]rue|TRUE|[Ff]alse|FALSE|[Yy]es|YES|[Nn]o|NO|[Oo]n|ON|[Oo]ff|OFF|[Nn]ull|NULL|~)\b"#)

    static func highlight(_ storage: NSTextStorage) {
        let text = storage.string
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
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

        func apply(_ regex: NSRegularExpression, color: NSColor, consumeMatch: Bool, captureGroup: Int = 0) {
            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let m = match else { return }
                let range = m.range(at: captureGroup)
                if range.location == NSNotFound { return }
                if intersectsConsumed(range) { return }
                storage.addAttribute(.foregroundColor, value: color, range: range)
                if consumeMatch { consumed.append(range) }
            }
        }

        let commentColor = Theme.color("yaml", "comment")
        let stringColor  = Theme.color("yaml", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            let color: NSColor = (nsText.character(at: r.location) == 0x23 /* '#' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(keyRegex,      color: Theme.color("yaml", "key"),      consumeMatch: false, captureGroup: 1)
        apply(numberRegex,   color: Theme.color("yaml", "number"),   consumeMatch: false)
        apply(constantRegex, color: Theme.color("yaml", "constant"), consumeMatch: false)
    }
}

// MARK: - Swift syntax highlighter

enum SwiftHighlighter {
    private static let keywords: [String] = [
        // Declarations
        "associatedtype","class","deinit","enum","extension","fileprivate",
        "func","import","init","inout","internal","let","open","operator",
        "private","protocol","public","static","struct","subscript",
        "typealias","var",
        // Modifiers
        "convenience","dynamic","final","indirect","lazy","mutating",
        "nonmutating","optional","override","required","weak","unowned",
        // Statements
        "break","case","continue","default","defer","do","else","fallthrough",
        "for","guard","if","in","repeat","return","switch","where","while",
        // Expressions
        "as","catch","is","rethrows","throw","throws","try","async","await",
        "some","any",
        // Constants and self/Self/super
        "false","nil","self","Self","super","true","Any","AnyObject",
        // Property accessors
        "get","set","willSet","didSet",
    ]

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern)
    }()

    // Triple-quoted (multi-line) strings must come first so the engine doesn't
    // greedily match a single `"` and stop early. Block comments are likewise
    // listed before line comments so `/*` isn't truncated to `/`.
    private static let stringOrCommentRegex = try! NSRegularExpression(
        pattern: #""""[\s\S]*?"""|/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*""#)

    private static let numberRegex    = try! NSRegularExpression(
        pattern: #"\b(?:0x[0-9a-fA-F][0-9a-fA-F_]*|0b[01][01_]*|0o[0-7][0-7_]*|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)\b"#)
    private static let constantRegex  = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#)
    private static let attributeRegex = try! NSRegularExpression(pattern: #"@[a-zA-Z_]\w*"#)

    static func highlight(_ storage: NSTextStorage) {
        let text = storage.string
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
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

        func apply(_ regex: NSRegularExpression, color: NSColor, consumeMatch: Bool) {
            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let m = match else { return }
                if intersectsConsumed(m.range) { return }
                storage.addAttribute(.foregroundColor, value: color, range: m.range)
                if consumeMatch { consumed.append(m.range) }
            }
        }

        let commentColor = Theme.color("swift", "comment")
        let stringColor  = Theme.color("swift", "string")
        stringOrCommentRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let r = m.range
            // First char of the match: '/' → comment, '"' → string.
            let color: NSColor = (nsText.character(at: r.location) == 0x2F /* '/' */)
                ? commentColor
                : stringColor
            storage.addAttribute(.foregroundColor, value: color, range: r)
            consumed.append(r)
        }

        apply(numberRegex,    color: Theme.color("swift", "number"),    consumeMatch: false)
        apply(attributeRegex, color: Theme.color("swift", "attribute"), consumeMatch: false)
        // constant runs before keyword so Self/Any/AnyObject get repainted as keywords (the latter pass wins).
        apply(constantRegex,  color: Theme.color("swift", "constant"),  consumeMatch: false)
        apply(keywordRegex,   color: Theme.color("swift", "keyword"),   consumeMatch: false)
    }
}

// MARK: - Syntax dispatch

enum Syntax: Int, CaseIterable {
    case ruby  = 0
    case yaml  = 1
    case swift = 2

    var displayName: String {
        switch self {
        case .ruby:  return "Ruby"
        case .yaml:  return "YAML"
        case .swift: return "Swift"
        }
    }

    static func from(extension ext: String) -> Syntax? {
        switch ext.lowercased() {
        case "rb":             return .ruby
        case "yaml", "yml":    return .yaml
        case "swift":          return .swift
        default:               return nil
        }
    }

    func highlight(_ storage: NSTextStorage) {
        switch self {
        case .ruby:  RubyHighlighter.highlight(storage)
        case .yaml:  YAMLHighlighter.highlight(storage)
        case .swift: SwiftHighlighter.highlight(storage)
        }
    }
}

// MARK: - Settings (settings.yaml on disk)

enum SettingsStore {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kantan/settings.yaml")
    }

    /// Ensure the settings directory and file exist on disk; then load and apply the colors.
    static func bootstrap() {
        let url = fileURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try defaultSettingsYAML.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            FileHandle.standardError.write(Data("Kantan: settings bootstrap failed: \(error.localizedDescription)\n".utf8))
        }
        loadAndApply()
    }

    /// Read settings.yaml from disk and push parsed colors into the Theme palette.
    static func loadAndApply() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let parsed = parseSyntax(text)
        for (language, colors) in parsed {
            Theme.apply(language, colors)
        }
    }

    /// Tiny YAML reader for our fixed shape:
    ///   syntax_highlighting:
    ///     <language>:
    ///       <token>: "#RRGGBB"
    /// Returns a [language: [token: NSColor]] map. Anything outside that shape is ignored.
    static func parseSyntax(_ text: String) -> [String: [String: NSColor]] {
        var result: [String: [String: NSColor]] = [:]
        var inSyntax = false
        var currentLanguage: String? = nil

        for rawLine in text.components(separatedBy: "\n") {
            // Strip trailing comments. Our values are quoted hex like "#c685c0",
            // so a '#' that appears outside any quote on the line is a YAML comment.
            var line = rawLine
            if let hash = line.firstIndex(of: "#"), hash != line.startIndex {
                let beforeHash = line[..<hash]
                if !beforeHash.contains("\"") {
                    line = String(beforeHash)
                }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let indent = line.prefix { $0 == " " }.count

            if indent == 0 {
                inSyntax = trimmed.hasPrefix("syntax_highlighting:")
                currentLanguage = nil
                continue
            }
            if indent == 2, inSyntax {
                if let colon = trimmed.firstIndex(of: ":") {
                    let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                    currentLanguage = String(key)
                }
                continue
            }
            if indent >= 4, inSyntax, let language = currentLanguage {
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                if let color = parseHex(String(value)) {
                    var lookup = result[language] ?? [:]
                    lookup[String(key)] = color
                    result[language] = lookup
                }
            }
        }
        return result
    }

    /// Parse "#RRGGBB" into an NSColor. Returns nil for anything else.
    static func parseHex(_ s: String) -> NSColor? {
        guard s.hasPrefix("#"), s.count == 7 else { return nil }
        let hex = s.dropFirst()
        guard let value = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255.0
        let g = CGFloat((value >>  8) & 0xff) / 255.0
        let b = CGFloat( value        & 0xff) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - Line number gutter

final class GutterView: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    var gutterFont: NSFont = NSFont(name: "Menlo", size: 13)
        ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func viewDidChange(_ note: Notification) { needsDisplay = true }

    override var isFlipped: Bool { return true }

    func refresh() {
        sizeToFitContent()
        needsDisplay = true
    }

    /// Compute the ideal width based on the largest line number we'll need to draw,
    /// then ask whoever owns our layout to grow us. Returns the new width.
    @discardableResult
    func sizeToFitContent() -> CGFloat {
        let lineCount = lineCountInTextView()
        let digits = max(2, String(lineCount).count)
        let sample = String(repeating: "9", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: [.font: gutterFont]).width) + 18
        if abs(width - frame.width) > 0.5 {
            (superview as? GutterContainerView)?.gutterDidRequestWidth(width)
        }
        return width
    }

    private func lineCountInTextView() -> Int {
        guard let text = textView?.string else { return 1 }
        if text.isEmpty { return 1 }
        let nsText = text as NSString
        var count = 1
        for i in 0..<nsText.length where nsText.character(at: i) == 0x0A {
            count += 1
        }
        return count
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gutterBackground.setFill()
        bounds.fill()

        // Right-edge separator (1px, drawn at integer x for crisp line)
        Theme.gutterBorder.setStroke()
        let border = NSBezierPath()
        border.lineWidth = 1
        border.move(to: NSPoint(x: bounds.maxX - 0.5, y: dirtyRect.minY))
        border.line(to: NSPoint(x: bounds.maxX - 0.5, y: dirtyRect.maxY))
        border.stroke()

        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = scrollView else { return }

        let nsText = textView.string as NSString
        let length = nsText.length
        let inset = textView.textContainerInset

        // textView's visible rect (in textView coords) tells us what's currently on screen.
        let docVisibleRect = scrollView.documentVisibleRect
        // Convert: textView coord y -> our (gutter) coord y
        // gutter y = (textView y) + inset.height - docVisibleRect.origin.y
        let yOffset = inset.height - docVisibleRect.origin.y

        let attrs: [NSAttributedString.Key: Any] = [
            .font: gutterFont,
            .foregroundColor: Theme.gutterText
        ]

        func fragmentRect(forCharIndex idx: Int) -> NSRect? {
            if idx >= length {
                if layoutManager.extraLineFragmentTextContainer != nil {
                    return layoutManager.extraLineFragmentRect
                }
                return nil
            }
            // Make sure layout exists for the glyph we're about to query.
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: idx)
            return layoutManager.lineFragmentRect(
                forGlyphAt: glyphIdx,
                effectiveRange: nil,
                withoutAdditionalLayout: false)
        }

        func draw(_ number: Int, in fragment: NSRect) {
            let y = fragment.origin.y + yOffset
            if y + fragment.height < bounds.minY { return }
            if y > bounds.maxY { return }
            let label = "\(number)" as NSString
            let labelSize = label.size(withAttributes: attrs)
            let x = bounds.width - labelSize.width - 8
            label.draw(at: NSPoint(x: x, y: y + (fragment.height - labelSize.height) / 2),
                       withAttributes: attrs)
        }

        // Force layout of the visible portion before we query line fragment rects.
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: docVisibleRect, in: textContainer)
        layoutManager.ensureLayout(forGlyphRange: visibleGlyphRange)

        var lineNumber = 1
        if let r = fragmentRect(forCharIndex: 0) { draw(lineNumber, in: r) }

        for i in 0..<length where nsText.character(at: i) == 0x0A {
            lineNumber += 1
            if let r = fragmentRect(forCharIndex: i + 1) { draw(lineNumber, in: r) }
        }
    }
}

/// Container that lays out the gutter and scroll view side-by-side via Auto Layout.
final class GutterContainerView: NSView {
    private let gutter: GutterView
    private let scroll: NSScrollView
    private let widthConstraint: NSLayoutConstraint

    init(gutter: GutterView, scrollView: NSScrollView) {
        self.gutter = gutter
        self.scroll = scrollView
        self.widthConstraint = gutter.widthAnchor.constraint(equalToConstant: 44)
        super.init(frame: .zero)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addSubview(gutter)

        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func gutterDidRequestWidth(_ width: CGFloat) {
        if abs(width - widthConstraint.constant) > 0.5 {
            widthConstraint.constant = width
        }
    }
}

// MARK: - Editor

final class Editor: NSObject, NSTextStorageDelegate, NSWindowDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    var gutterView: GutterView!
    var currentURL: URL?
    var dirty = false

    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 32

    private var currentFontSize: CGFloat = 13
    private var editorFont: NSFont
    var syntaxHighlightingEnabled = false
    var activeSyntax: Syntax? {
        didSet { refreshLanguageMenuChecks() }
    }
    weak var syntaxHighlightingMenuItem: NSMenuItem?
    weak var languageMenu: NSMenu?

    override init() {
        self.editorFont = Editor.makeFont(size: 13)
        super.init()
    }

    private static func makeFont(size: CGFloat) -> NSFont {
        return NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func setup() {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.background

        let contentSize = scrollView.contentSize
        textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)

        textView.font = editorFont
        textView.backgroundColor = Theme.background
        textView.textColor = Theme.foreground
        textView.insertionPointColor = Theme.cursor
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.typingAttributes = [
            .font: editorFont,
            .foregroundColor: Theme.foreground
        ]

        textView.textStorage?.delegate = self

        scrollView.documentView = textView

        gutterView = GutterView(textView: textView, scrollView: scrollView)
        gutterView.gutterFont = editorFont
        let container = GutterContainerView(gutter: gutterView, scrollView: scrollView)
        container.frame = frame
        container.autoresizingMask = [.width, .height]

        gutterView.refresh()

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)

        updateTitle()
    }

    // MARK: NSTextStorageDelegate

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        dirty = true
        updateTitle()
        if syntaxHighlightingEnabled, let syntax = activeSyntax {
            syntax.highlight(textStorage)
        }
        gutterView?.refresh()
    }

    // MARK: Title

    func updateTitle() {
        let name = currentURL?.lastPathComponent ?? "Untitled"
        window.title = "\(dirty ? "● " : "")\(name) — Kantan"
    }

    // MARK: File actions

    @objc func newDocument(_ sender: Any?) {
        guard confirmDiscardIfDirty() else { return }
        replaceContent(with: "")
        currentURL = nil
        dirty = false
        updateTitle()
    }

    @objc func openDocument(_ sender: Any?) {
        guard confirmDiscardIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            loadFile(url: url)
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        if let url = currentURL {
            saveTo(url: url)
        } else {
            _ = saveAs()
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        _ = saveAs()
    }

    private func loadFile(url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            // Pick the syntax BEFORE the storage delegate fires, so the very first
            // didProcessEditing pass already paints with the right highlighter.
            activeSyntax = Syntax.from(extension: url.pathExtension.lowercased())
            replaceContent(with: content)
            currentURL = url
            dirty = false
            updateTitle()
            if activeSyntax != nil && !syntaxHighlightingEnabled {
                setSyntaxHighlighting(true)
            }
        } catch {
            showError("Couldn't open file: \(error.localizedDescription)")
        }
    }

    private func replaceContent(with content: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: editorFont,
            .foregroundColor: Theme.foreground
        ]
        let attributed = NSAttributedString(string: content, attributes: attrs)
        textView.textStorage?.setAttributedString(attributed)
        textView.typingAttributes = attrs
    }

    @discardableResult
    private func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = currentURL?.lastPathComponent ?? "untitled.rb"
        if panel.runModal() == .OK, let url = panel.url {
            currentURL = url
            saveTo(url: url)
            return true
        }
        return false
    }

    private func saveTo(url: URL) {
        do {
            try textView.string.write(to: url, atomically: true, encoding: .utf8)
            dirty = false
            updateTitle()
            selectSyntax(for: url)
            if url == SettingsStore.fileURL {
                SettingsStore.loadAndApply()
                if syntaxHighlightingEnabled, let storage = textView.textStorage {
                    activeSyntax?.highlight(storage)
                }
            }
        } catch {
            showError("Couldn't save file: \(error.localizedDescription)")
        }
    }

    // MARK: Font sizing

    @objc func increaseTextSize(_ sender: Any?) {
        let next = min(currentFontSize + 1, Editor.maxFontSize)
        if next == currentFontSize { return }
        currentFontSize = next
        applyEditorFont()
    }

    @objc func decreaseTextSize(_ sender: Any?) {
        let next = max(currentFontSize - 1, Editor.minFontSize)
        if next == currentFontSize { return }
        currentFontSize = next
        applyEditorFont()
    }

    private func applyEditorFont() {
        editorFont = Editor.makeFont(size: currentFontSize)
        textView.font = editorFont
        textView.typingAttributes = [
            .font: editorFont,
            .foregroundColor: Theme.foreground
        ]
        if let storage = textView.textStorage {
            let full = NSRange(location: 0, length: storage.length)
            storage.addAttribute(.font, value: editorFont, range: full)
            if syntaxHighlightingEnabled, let syntax = activeSyntax {
                syntax.highlight(storage)
            }
        }
        gutterView?.gutterFont = editorFont
        gutterView?.refresh()
    }

    // MARK: Syntax highlighting toggle

    @objc func toggleSyntaxHighlighting(_ sender: Any?) {
        setSyntaxHighlighting(!syntaxHighlightingEnabled)
    }

    private func setSyntaxHighlighting(_ on: Bool) {
        syntaxHighlightingEnabled = on
        syntaxHighlightingMenuItem?.state = on ? .on : .off
        guard let storage = textView?.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.foregroundColor, range: full)
        storage.addAttribute(.foregroundColor, value: Theme.foreground, range: full)
        if on, let syntax = activeSyntax {
            syntax.highlight(storage)
        }
    }

    /// Adjust activeSyntax to match the file's extension.
    /// If the extension is recognized and highlighting was off, turn it on.
    /// If highlighting was already on, repaint under the new (or no) syntax.
    private func selectSyntax(for url: URL) {
        let next = Syntax.from(extension: url.pathExtension.lowercased())
        let changed = next != activeSyntax
        activeSyntax = next
        if next != nil && !syntaxHighlightingEnabled {
            setSyntaxHighlighting(true)
            return
        }
        if changed && syntaxHighlightingEnabled, let storage = textView?.textStorage {
            let full = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.foregroundColor, range: full)
            storage.addAttribute(.foregroundColor, value: Theme.foreground, range: full)
            next?.highlight(storage)
        }
    }

    // MARK: Language selection

    @objc func selectLanguage(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let syntax = Syntax(rawValue: item.tag) else { return }
        if syntax == activeSyntax && syntaxHighlightingEnabled { return }
        activeSyntax = syntax
        if !syntaxHighlightingEnabled {
            setSyntaxHighlighting(true)
        } else if let storage = textView?.textStorage {
            let full = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.foregroundColor, range: full)
            storage.addAttribute(.foregroundColor, value: Theme.foreground, range: full)
            syntax.highlight(storage)
        }
    }

    private func refreshLanguageMenuChecks() {
        guard let menu = languageMenu else { return }
        let activeRaw = activeSyntax?.rawValue ?? -1
        for item in menu.items {
            item.state = (item.tag == activeRaw) ? .on : .off
        }
    }

    // MARK: Settings

    @objc func openSettings(_ sender: Any?) {
        guard confirmDiscardIfDirty() else { return }
        loadFile(url: SettingsStore.fileURL)
    }

    private func confirmDiscardIfDirty() -> Bool {
        if !dirty { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Your changes will be lost if you continue."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return promptSaveBeforeClose()
    }

    func promptSaveBeforeClose() -> Bool {
        if !dirty { return true }
        let alert = NSAlert()
        let name = currentURL?.lastPathComponent ?? "Untitled"
        alert.messageText = "Save changes to \(name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = currentURL {
                saveTo(url: url)
                return !dirty
            } else {
                return saveAs()
            }
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let editor = Editor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsStore.bootstrap()
        buildMenu()
        editor.setup()
        NSApp.activate()
    }

    @objc func showAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Kantan",
            .applicationVersion: App.nameJapanese,
            .version: App.version,
        ])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return editor.promptSaveBeforeClose() ? .terminateNow : .terminateCancel
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: "About Kantan",
            action: #selector(AppDelegate.showAboutPanel(_:)),
            keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide Kantan",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit Kantan",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File menu
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newItem = NSMenuItem(title: "New", action: #selector(Editor.newDocument(_:)), keyEquivalent: "n")
        newItem.target = editor
        fileMenu.addItem(newItem)
        let openItem = NSMenuItem(title: "Open…", action: #selector(Editor.openDocument(_:)), keyEquivalent: "o")
        openItem.target = editor
        fileMenu.addItem(openItem)
        fileMenu.addItem(.separator())
        let saveItem = NSMenuItem(title: "Save", action: #selector(Editor.saveDocument(_:)), keyEquivalent: "s")
        saveItem.target = editor
        fileMenu.addItem(saveItem)
        let saveAsItem = NSMenuItem(title: "Save As…", action: #selector(Editor.saveDocumentAs(_:)), keyEquivalent: "S")
        saveAsItem.target = editor
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAsItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit menu (so standard shortcuts work via responder chain)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        findItem.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        editMenu.addItem(findItem)
        editMenu.addItem(.separator())
        let increaseItem = NSMenuItem(title: "Increase Text Size",
                                      action: #selector(Editor.increaseTextSize(_:)),
                                      keyEquivalent: "+")
        increaseItem.target = editor
        editMenu.addItem(increaseItem)
        let decreaseItem = NSMenuItem(title: "Decrease Text Size",
                                      action: #selector(Editor.decreaseTextSize(_:)),
                                      keyEquivalent: "-")
        decreaseItem.target = editor
        editMenu.addItem(decreaseItem)
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Configuration menu
        let configItem = NSMenuItem()
        let configMenu = NSMenu(title: "Configuration")
        let highlightItem = NSMenuItem(title: "Syntax Highlighting",
                                       action: #selector(Editor.toggleSyntaxHighlighting(_:)),
                                       keyEquivalent: "")
        highlightItem.target = editor
        highlightItem.state = editor.syntaxHighlightingEnabled ? .on : .off
        editor.syntaxHighlightingMenuItem = highlightItem
        configMenu.addItem(highlightItem)

        // Language submenu — populated from Syntax.allCases so adding a new
        // language only requires editing the Syntax enum.
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageSubmenu = NSMenu(title: "Language")
        let activeRaw = editor.activeSyntax?.rawValue ?? -1
        for syntax in Syntax.allCases {
            let item = NSMenuItem(title: syntax.displayName,
                                  action: #selector(Editor.selectLanguage(_:)),
                                  keyEquivalent: "")
            item.target = editor
            item.tag = syntax.rawValue
            item.state = (syntax.rawValue == activeRaw) ? .on : .off
            languageSubmenu.addItem(item)
        }
        languageItem.submenu = languageSubmenu
        editor.languageMenu = languageSubmenu
        configMenu.addItem(languageItem)

        let settingsItem = NSMenuItem(title: "Settings",
                                      action: #selector(Editor.openSettings(_:)),
                                      keyEquivalent: "")
        settingsItem.target = editor
        configMenu.addItem(settingsItem)
        configItem.submenu = configMenu
        mainMenu.addItem(configItem)

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
