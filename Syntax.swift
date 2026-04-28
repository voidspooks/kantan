import AppKit

// MARK: - Syntax dispatch

enum Syntax: Int, CaseIterable {
    case ruby       = 0
    case yaml       = 1
    case swift      = 2
    case javascript = 3
    case html       = 4
    case python     = 5
    case typescript = 6
    case java       = 7
    case c          = 8
    case cpp        = 9
    case csharp     = 10
    case php        = 11
    case go         = 12
    case rust       = 13
    case kotlin     = 14
    case sql        = 15
    case r          = 16
    case dart       = 17
    case scala      = 18
    case perl       = 19
    case lua        = 20
    case bash       = 21
    case markdown   = 22

    var displayName: String {
        switch self {
        case .ruby:       return "Ruby"
        case .yaml:       return "YAML"
        case .swift:      return "Swift"
        case .javascript: return "JavaScript"
        case .html:       return "HTML"
        case .python:     return "Python"
        case .typescript: return "TypeScript"
        case .java:       return "Java"
        case .c:          return "C"
        case .cpp:        return "C++"
        case .csharp:     return "C#"
        case .php:        return "PHP"
        case .go:         return "Go"
        case .rust:       return "Rust"
        case .kotlin:     return "Kotlin"
        case .sql:        return "SQL"
        case .r:          return "R"
        case .dart:       return "Dart"
        case .scala:      return "Scala"
        case .perl:       return "Perl"
        case .lua:        return "Lua"
        case .bash:       return "Bash"
        case .markdown:   return "Markdown"
        }
    }

    /// Stable identifier used as a settings/palette key. Matches displayName.lowercased()
    /// for most languages, but skips characters that would break YAML keys (`+`, `#`).
    var key: String {
        switch self {
        case .cpp:    return "cpp"
        case .csharp: return "csharp"
        default:      return displayName.lowercased()
        }
    }

    static func from(extension ext: String) -> Syntax? {
        switch ext.lowercased() {
        case "rb":                                              return .ruby
        case "yaml", "yml":                                     return .yaml
        case "swift":                                           return .swift
        case "js", "mjs", "cjs", "jsx":                         return .javascript
        case "html", "htm":                                     return .html
        case "py", "pyw", "pyi":                                return .python
        case "ts", "tsx", "mts", "cts":                         return .typescript
        case "java":                                            return .java
        case "c", "h":                                          return .c
        case "cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx":     return .cpp
        case "cs":                                              return .csharp
        case "php", "phtml":                                    return .php
        case "go":                                              return .go
        case "rs":                                              return .rust
        case "kt", "kts":                                       return .kotlin
        case "sql":                                             return .sql
        case "r":                                               return .r
        case "dart":                                            return .dart
        case "scala", "sc":                                     return .scala
        case "pl", "pm":                                        return .perl
        case "lua":                                             return .lua
        case "sh", "bash", "zsh":                               return .bash
        case "md", "markdown", "mdown", "mkd":                  return .markdown
        default:                                                return nil
        }
    }

    func highlight(_ storage: NSTextStorage) {
        switch self {
        case .ruby:       RubyHighlighter.highlight(storage)
        case .yaml:       YAMLHighlighter.highlight(storage)
        case .swift:      SwiftHighlighter.highlight(storage)
        case .javascript: JavaScriptHighlighter.highlight(storage)
        case .html:       HTMLHighlighter.highlight(storage)
        case .python:     PythonHighlighter.highlight(storage)
        case .typescript: TypeScriptHighlighter.highlight(storage)
        case .java:       JavaHighlighter.highlight(storage)
        case .c:          CHighlighter.highlight(storage)
        case .cpp:        CPlusPlusHighlighter.highlight(storage)
        case .csharp:     CSharpHighlighter.highlight(storage)
        case .php:        PHPHighlighter.highlight(storage)
        case .go:         GoHighlighter.highlight(storage)
        case .rust:       RustHighlighter.highlight(storage)
        case .kotlin:     KotlinHighlighter.highlight(storage)
        case .sql:        SQLHighlighter.highlight(storage)
        case .r:          RHighlighter.highlight(storage)
        case .dart:       DartHighlighter.highlight(storage)
        case .scala:      ScalaHighlighter.highlight(storage)
        case .perl:       PerlHighlighter.highlight(storage)
        case .lua:        LuaHighlighter.highlight(storage)
        case .bash:       BashHighlighter.highlight(storage)
        case .markdown:   MarkdownHighlighter.highlight(storage)
        }
    }
}
