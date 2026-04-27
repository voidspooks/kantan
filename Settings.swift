import AppKit

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
