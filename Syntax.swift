import AppKit

// MARK: - Syntax dispatch

enum Syntax: Int, CaseIterable {
    case ruby       = 0
    case yaml       = 1
    case swift      = 2
    case javascript = 3
    case html       = 4

    var displayName: String {
        switch self {
        case .ruby:       return "Ruby"
        case .yaml:       return "YAML"
        case .swift:      return "Swift"
        case .javascript: return "JavaScript"
        case .html:       return "HTML"
        }
    }

    static func from(extension ext: String) -> Syntax? {
        switch ext.lowercased() {
        case "rb":                 return .ruby
        case "yaml", "yml":        return .yaml
        case "swift":              return .swift
        case "js", "mjs", "cjs":   return .javascript
        case "html", "htm":        return .html
        default:                   return nil
        }
    }

    func highlight(_ storage: NSTextStorage) {
        switch self {
        case .ruby:       RubyHighlighter.highlight(storage)
        case .yaml:       YAMLHighlighter.highlight(storage)
        case .swift:      SwiftHighlighter.highlight(storage)
        case .javascript: JavaScriptHighlighter.highlight(storage)
        case .html:       HTMLHighlighter.highlight(storage)
        }
    }
}
