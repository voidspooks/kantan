import AppKit

// MARK: - Default settings.yaml (written to disk on first launch)

let defaultSettingsYAML = """
line_numbers: true

indent:
  ruby:
    style: space
    width: 2
  yaml:
    style: space
    width: 2
  swift:
    style: space
    width: 4
  javascript:
    style: space
    width: 2
  html:
    style: space
    width: 2
  python:
    style: space
    width: 4
  typescript:
    style: space
    width: 2
  java:
    style: space
    width: 4
  c:
    style: space
    width: 4
  cpp:
    style: space
    width: 4
  csharp:
    style: space
    width: 4
  php:
    style: space
    width: 4
  go:
    style: tab
    width: 1
  rust:
    style: space
    width: 4
  kotlin:
    style: space
    width: 4
  sql:
    style: space
    width: 2
  r:
    style: space
    width: 2
  dart:
    style: space
    width: 2
  scala:
    style: space
    width: 2
  perl:
    style: space
    width: 4
  lua:
    style: space
    width: 2
  bash:
    style: space
    width: 2
  markdown:
    style: space
    width: 2
  css:
    style: space
    width: 2
  makefile:
    style: tab
    width: 1

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
  javascript:
    keyword:  "#c685c0"
    string:   "#ce9178"
    comment:  "#6b9955"
    number:   "#b5cea8"
    constant: "#4ec9b0"
  html:
    tag:       "#c685c0"
    attribute: "#9cdcfe"
    string:    "#ce9178"
    comment:   "#6b9955"
    constant:  "#4ec9b0"
  python:
    keyword:   "#c685c0"
    string:    "#ce9178"
    comment:   "#6b9955"
    number:    "#b5cea8"
    constant:  "#4ec9b0"
    decorator: "#9cdcfe"
  typescript:
    keyword:  "#c685c0"
    string:   "#ce9178"
    comment:  "#6b9955"
    number:   "#b5cea8"
    constant: "#4ec9b0"
  java:
    keyword:    "#c685c0"
    string:     "#ce9178"
    comment:    "#6b9955"
    number:     "#b5cea8"
    constant:   "#4ec9b0"
    annotation: "#9cdcfe"
  c:
    keyword:      "#c685c0"
    string:       "#ce9178"
    comment:      "#6b9955"
    number:       "#b5cea8"
    constant:     "#4ec9b0"
    preprocessor: "#9cdcfe"
  cpp:
    keyword:      "#c685c0"
    string:       "#ce9178"
    comment:      "#6b9955"
    number:       "#b5cea8"
    constant:     "#4ec9b0"
    preprocessor: "#9cdcfe"
  csharp:
    keyword:   "#c685c0"
    string:    "#ce9178"
    comment:   "#6b9955"
    number:    "#b5cea8"
    constant:  "#4ec9b0"
    attribute: "#9cdcfe"
  php:
    keyword:  "#c685c0"
    string:   "#ce9178"
    comment:  "#6b9955"
    number:   "#b5cea8"
    constant: "#4ec9b0"
    variable: "#9cdcfe"
  go:
    keyword:  "#c685c0"
    string:   "#ce9178"
    comment:  "#6b9955"
    number:   "#b5cea8"
    constant: "#4ec9b0"
  rust:
    keyword:   "#c685c0"
    string:    "#ce9178"
    comment:   "#6b9955"
    number:    "#b5cea8"
    constant:  "#4ec9b0"
    attribute: "#9cdcfe"
    macro:     "#569cd6"
  kotlin:
    keyword:    "#c685c0"
    string:     "#ce9178"
    comment:    "#6b9955"
    number:     "#b5cea8"
    constant:   "#4ec9b0"
    annotation: "#9cdcfe"
  sql:
    keyword:  "#c685c0"
    string:   "#ce9178"
    comment:  "#6b9955"
    number:   "#b5cea8"
    constant: "#4ec9b0"
  r:
    keyword:  "#c685c0"
    string:   "#ce9178"
    comment:  "#6b9955"
    number:   "#b5cea8"
    constant: "#4ec9b0"
  dart:
    keyword:    "#c685c0"
    string:     "#ce9178"
    comment:    "#6b9955"
    number:     "#b5cea8"
    constant:   "#4ec9b0"
    annotation: "#9cdcfe"
  scala:
    keyword:    "#c685c0"
    string:     "#ce9178"
    comment:    "#6b9955"
    number:     "#b5cea8"
    constant:   "#4ec9b0"
    annotation: "#9cdcfe"
  perl:
    keyword:  "#c685c0"
    string:   "#ce9178"
    comment:  "#6b9955"
    number:   "#b5cea8"
    constant: "#4ec9b0"
    variable: "#9cdcfe"
  lua:
    keyword:  "#c685c0"
    string:   "#ce9178"
    comment:  "#6b9955"
    number:   "#b5cea8"
    constant: "#4ec9b0"
  bash:
    keyword:  "#c685c0"
    string:   "#ce9178"
    comment:  "#6b9955"
    number:   "#b5cea8"
    variable: "#9cdcfe"
  markdown:
    heading:    "#c685c0"
    strong:     "#4ec9b0"
    emphasis:   "#9cdcfe"
    code:       "#ce9178"
    link:       "#569cd6"
    list:       "#c685c0"
    blockquote: "#6b9955"
    rule:       "#6b9955"
  css:
    selector: "#569cd6"
    property: "#9cdcfe"
    string:   "#ce9178"
    comment:  "#6b9955"
    number:   "#b5cea8"
    constant: "#4ec9b0"
    keyword:  "#c685c0"
  makefile:
    comment:  "#6b9955"
    string:   "#ce9178"
    keyword:  "#c685c0"
    variable: "#9cdcfe"
    target:   "#569cd6"
"""

// MARK: - Indent config

struct IndentConfig {
    enum Style { case tab, space }
    var style: Style
    var width: Int

    static let fallback = IndentConfig(style: .space, width: 4)

    var unitString: String {
        switch style {
        case .tab:   return String(repeating: "\t", count: width)
        case .space: return String(repeating: " ", count: width)
        }
    }
}

// MARK: - Session state (UserDefaults)

/// Tracks what the user had open at last quit so we can restore it on launch.
/// Lives in UserDefaults rather than settings.yaml because it's app state, not config.
enum AppState {
    private static let lastFileKey   = "kantan.lastFilePath"
    private static let lastFolderKey = "kantan.lastFolderPath"

    static var lastFile: URL? {
        get { url(forKey: lastFileKey) }
        set { setURL(newValue, forKey: lastFileKey) }
    }

    static var lastFolder: URL? {
        get { url(forKey: lastFolderKey) }
        set { setURL(newValue, forKey: lastFolderKey) }
    }

    private static func url(forKey key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func setURL(_ url: URL?, forKey key: String) {
        if let url = url {
            UserDefaults.standard.set(url.path, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - Settings (settings.yaml on disk)

enum SettingsStore {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kantan/settings.yaml")
    }

    static var showLineNumbers: Bool = true

    static let defaultIndents: [String: IndentConfig] = [
        "ruby":       IndentConfig(style: .space, width: 2),
        "yaml":       IndentConfig(style: .space, width: 2),
        "swift":      IndentConfig(style: .space, width: 4),
        "javascript": IndentConfig(style: .space, width: 2),
        "html":       IndentConfig(style: .space, width: 2),
        "python":     IndentConfig(style: .space, width: 4),
        "typescript": IndentConfig(style: .space, width: 2),
        "java":       IndentConfig(style: .space, width: 4),
        "c":          IndentConfig(style: .space, width: 4),
        "cpp":        IndentConfig(style: .space, width: 4),
        "csharp":     IndentConfig(style: .space, width: 4),
        "php":        IndentConfig(style: .space, width: 4),
        "go":         IndentConfig(style: .tab,   width: 1),
        "rust":       IndentConfig(style: .space, width: 4),
        "kotlin":     IndentConfig(style: .space, width: 4),
        "sql":        IndentConfig(style: .space, width: 2),
        "r":          IndentConfig(style: .space, width: 2),
        "dart":       IndentConfig(style: .space, width: 2),
        "scala":      IndentConfig(style: .space, width: 2),
        "perl":       IndentConfig(style: .space, width: 4),
        "lua":        IndentConfig(style: .space, width: 2),
        "bash":       IndentConfig(style: .space, width: 2),
        "markdown":   IndentConfig(style: .space, width: 2),
        "css":        IndentConfig(style: .space, width: 2),
        "makefile":   IndentConfig(style: .tab,   width: 1),
    ]
    static var indentByLanguage: [String: IndentConfig] = defaultIndents

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
        showLineNumbers = parseTopLevelBool("line_numbers", in: text) ?? true

        var merged = defaultIndents
        for (lang, cfg) in parseIndent(text) {
            merged[lang] = cfg
        }
        indentByLanguage = merged
    }

    /// Parse the `indent:` block. Each language has a `style: tab|space` and `width: <int>`.
    /// Anything outside that shape is ignored.
    static func parseIndent(_ text: String) -> [String: IndentConfig] {
        var result: [String: IndentConfig] = [:]
        var inIndent = false
        var currentLanguage: String? = nil
        var currentStyle: IndentConfig.Style = .space
        var currentWidth: Int = 4

        func commit() {
            if let lang = currentLanguage {
                result[lang] = IndentConfig(style: currentStyle, width: currentWidth)
            }
            currentLanguage = nil
        }

        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = line.prefix { $0 == " " }.count

            if indent == 0 {
                commit()
                inIndent = trimmed.hasPrefix("indent:")
                continue
            }
            if !inIndent { continue }
            if indent == 2 {
                commit()
                if let colon = trimmed.firstIndex(of: ":") {
                    currentLanguage = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                    currentStyle = .space
                    currentWidth = 4
                }
                continue
            }
            if indent >= 4, currentLanguage != nil {
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                switch key {
                case "style":
                    if value == "tab" || value == "tabs" { currentStyle = .tab }
                    else if value == "space" || value == "spaces" { currentStyle = .space }
                case "width":
                    if let n = Int(value), n >= 0 { currentWidth = n }
                default:
                    break
                }
            }
        }
        commit()
        return result
    }

    /// Update `showLineNumbers` and persist the new value to settings.yaml.
    /// Replaces an existing top-level `line_numbers:` line (preserving any trailing comment),
    /// or inserts one at the top of the file if absent.
    static func setLineNumbers(_ value: Bool) {
        showLineNumbers = value
        let url = fileURL
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = rewriteTopLevelBool("line_numbers", value: value, in: existing)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("Kantan: settings persist failed: \(error.localizedDescription)\n".utf8))
        }
    }

    static func rewriteTopLevelBool(_ key: String, value: Bool, in text: String) -> String {
        let prefix = "\(key):"
        let newLine = "\(key): \(value)"
        var lines = text.components(separatedBy: "\n")
        for i in 0..<lines.count {
            let raw = lines[i]
            var stripped = raw
            if let hash = stripped.firstIndex(of: "#") {
                stripped = String(stripped[..<hash])
            }
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " }.count
            guard indent == 0, trimmed.hasPrefix(prefix) else { continue }
            if let hash = raw.firstIndex(of: "#") {
                lines[i] = "\(newLine) \(raw[hash...])"
            } else {
                lines[i] = newLine
            }
            return lines.joined(separator: "\n")
        }
        // Not present: insert at the top, with a blank line before existing non-empty content.
        var prefixLines = [newLine]
        if let first = lines.first, !first.trimmingCharacters(in: .whitespaces).isEmpty {
            prefixLines.append("")
        }
        return (prefixLines + lines).joined(separator: "\n")
    }

    /// Read a top-level `key: <bool>` line. Accepts true/false/yes/no (case-insensitive).
    /// Returns nil if the key is absent or the value is unrecognized.
    static func parseTopLevelBool(_ key: String, in text: String) -> Bool? {
        let prefix = "\(key):"
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = line.prefix { $0 == " " }.count
            guard indent == 0, trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed
                .dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            switch value {
            case "true", "yes":  return true
            case "false", "no":  return false
            default:             return nil
            }
        }
        return nil
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
