# Changelog

All notable changes to Kantan are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-04-28

Initial pre-release. A minimal, native macOS code editor.

### Editor

- Undo / redo with per-document history
- Cut, copy, paste, select all
- Find and replace with incremental search
- Indent-aware newline insertion (auto-dedent, indent after openers)
- Bracket and quote auto-closing, with selection wrapping
- HTML / XML tag auto-close (with void-element awareness in HTML)
- Bracket-pair and tag-pair splitting on Enter
- Word-under-caret highlighting
- Current-line highlighting
- Adjustable text size via `Cmd+=` / `Cmd+-` (8–32 pt)
- Per-language indent style (spaces or tabs) and indent width
- Per-language default line spacing

### Syntax Highlighting

- 26 languages: Ruby, YAML, Swift, JavaScript, HTML, Python, TypeScript,
  Java, C, C++, C#, PHP, Go, Rust, Kotlin, SQL, R, Dart, Scala, Perl,
  Lua, Bash, Markdown, CSS, Makefile, XML
- Embedded CSS and JavaScript highlighting inside HTML `<style>` and
  `<script>` blocks
- Per-language token color palettes (keyword, string, comment, number,
  constant, etc.)
- Auto-detect from file extension or filename, with manual override via
  the language menu
- Toggle highlighting on/off

### Tabs and Documents

- Multiple tabs per pane, reorderable by drag
- Dirty-file indicator on unsaved tabs
- Tab cycling (`Cmd+Shift+]` / `Cmd+Shift+[`)
- Untitled documents with Save As
- Duplicate-file detection within a pane
- Empty untitled tab replaced when opening a file

### Split Panes

- Vertical or horizontal split (`Cmd+T`)
- Drag tabs between panes
- Right-click a tab to move it into a split
- Resize panes via divider drag

### File Tree Sidebar

- Collapsible folder tree rooted at the open project
- Click to open files, double-click to toggle folders
- Images open in the default app
- Inline create / rename / delete (delete moves to Trash with confirmation)
- Copy / paste files between directories
- Tree expansion state preserved across refreshes
- External file-change detection with auto-refresh

### Git Integration

- Per-file status in the sidebar (untracked = green, modified = yellow)
- Untracked status cascades up to parent directories
- Current branch displayed in the sidebar footer
- Per-line diff strips in the gutter (added vs. modified)
- Diff state refreshes on file open and after save

### Gutter

- Toggleable line numbers (`Cmd+Shift+L`)
- Auto-sizing gutter width
- Inline diff indicators alongside line numbers

### Theming

- Dark theme
- Customizable editor and sidebar backgrounds, word highlight, line
  highlight, and git status colors
- Configurable per-language token color palettes
- Live theme reload on saving `settings.yaml`

### Settings

- `settings.yaml` at `~/Library/Application Support/Kantan/`
- Editable from within Kantan via File → Settings
- Bootstrapped with sensible defaults on first launch
- Configurable: line-number visibility, split orientation, per-language
  indent style and width, theme colors

### Session Persistence

- Last opened file and folder restored on launch
- Cursor position, selection, and scroll position preserved per document
- Window title reflects current file and dirty state

### File Icons

- SF Symbols for folders and select languages
- Devicon SVGs for 20+ languages, fetched once and cached locally
- Generic document fallback for unrecognized extensions
- Icon size scales with editor font size

### UI

- Monospace font (Menlo with system fallback)
- Minimal overlay scrollbar (hover to reveal)
- Cursor line / column shown in the sidebar footer
- Smooth tab and scroller animations

[0.1.0]: https://github.com/voidspooks/kantan/releases/tag/v0.1.0
