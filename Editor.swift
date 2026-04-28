import AppKit

// MARK: - Editor

final class Editor: NSObject, NSTextStorageDelegate, NSTextViewDelegate, NSWindowDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    var gutterView: GutterView!
    var workspaceView: WorkspaceView!
    var currentURL: URL? {
        didSet { AppState.lastFile = currentURL }
    }
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
    weak var lineNumbersMenuItem: NSMenuItem?
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
        textView.delegate = self

        scrollView.documentView = textView

        gutterView = GutterView(textView: textView, scrollView: scrollView)
        gutterView.gutterFont = editorFont
        let container = GutterContainerView(gutter: gutterView, scrollView: scrollView)
        container.translatesAutoresizingMaskIntoConstraints = false

        workspaceView = WorkspaceView(gutterContainer: container)
        workspaceView.frame = frame
        workspaceView.autoresizingMask = [.width, .height]
        workspaceView.sidebar.onSelect = { [weak self] url in
            self?.loadFile(url: url)
        }

        gutterView.refresh()
        workspaceView.sidebar.setRowFont(editorFont)
        applyLineNumbersVisibility()

        window.contentView = workspaceView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)

        restoreLastSession()
        updateTitle()
    }

    private func restoreLastSession() {
        let fm = FileManager.default
        if let folder = AppState.lastFolder, fm.fileExists(atPath: folder.path) {
            setRootFolder(folder)
        }
        if let file = AppState.lastFile, fm.fileExists(atPath: file.path) {
            loadFile(url: file)
        }
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            insertNewlineWithIndent(in: textView)
            return true
        }
        return false
    }

    private static let autoPairs: [Character: Character] = [
        "{": "}", "[": "]", "(": ")",
        "`": "`", "\"": "\"", "'": "'"
    ]

    func textView(_ textView: NSTextView,
                  shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        guard let str = replacementString, str.count == 1,
              let opener = str.first,
              let closer = Editor.autoPairs[opener] else { return true }

        let nsText = textView.string as NSString

        // Quotes: skip pairing when the cursor is touching a word character.
        // Keeps things like `don't` and `it's` from becoming `don''t`.
        if opener == "\"" || opener == "'" {
            if affectedCharRange.location > 0 {
                let prev = nsText.character(at: affectedCharRange.location - 1)
                if let scalar = UnicodeScalar(prev),
                   CharacterSet.alphanumerics.contains(scalar) || prev == 0x5F {
                    return true
                }
            }
        }

        let middle = affectedCharRange.length > 0
            ? nsText.substring(with: affectedCharRange)
            : ""

        let insertion = "\(opener)\(middle)\(closer)"
        textView.insertText(insertion, replacementRange: affectedCharRange)

        // Empty selection → cursor between the pair.
        // Non-empty selection → re-select the wrapped text so further typing replaces it.
        let selStart = affectedCharRange.location + 1
        let selLength = (middle as NSString).length
        textView.setSelectedRange(NSRange(location: selStart, length: selLength))

        return false
    }

    private func insertNewlineWithIndent(in textView: NSTextView) {
        let nsText = textView.string as NSString
        let selRange = textView.selectedRange()
        let cursor = selRange.location
        let lineStart = nsText.lineRange(for: NSRange(location: cursor, length: 0)).location

        let beforeCursor = cursor > lineStart
            ? nsText.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
            : ""

        var leading = ""
        for ch in beforeCursor {
            if ch == " " || ch == "\t" { leading.append(ch) } else { break }
        }

        let trimmed = beforeCursor.trimmingCharacters(in: .whitespaces)
        let opensBlock: Bool
        switch trimmed.last {
        case "{", "[", "(": opensBlock = true
        default:            opensBlock = false
        }

        var insertion = "\n" + leading
        if opensBlock {
            let key = activeSyntax?.displayName.lowercased() ?? ""
            let cfg = SettingsStore.indentByLanguage[key] ?? IndentConfig.fallback
            insertion += cfg.unitString
        }

        textView.insertText(insertion, replacementRange: selRange)
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

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            setRootFolder(url)
        }
    }

    private func setRootFolder(_ url: URL?) {
        workspaceView.setRootFolder(url)
        AppState.lastFolder = url
    }

    @objc func toggleSidebar(_ sender: Any?) {
        workspaceView.toggleSidebar()
    }

    @objc func refreshSidebar(_ sender: Any?) {
        workspaceView.refreshSidebar()
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
                applyLineNumbersVisibility()
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
        workspaceView?.sidebar.setRowFont(editorFont)
    }

    // MARK: Syntax highlighting toggle

    @objc func toggleSyntaxHighlighting(_ sender: Any?) {
        setSyntaxHighlighting(!syntaxHighlightingEnabled)
    }

    @objc func toggleLineNumbers(_ sender: Any?) {
        let next = !SettingsStore.showLineNumbers
        if currentURL == SettingsStore.fileURL {
            SettingsStore.showLineNumbers = next
        } else {
            SettingsStore.setLineNumbers(next)
        }
        applyLineNumbersVisibility()
    }

    private func applyLineNumbersVisibility() {
        workspaceView?.gutterContainer.setGutterVisible(SettingsStore.showLineNumbers)
        lineNumbersMenuItem?.state = SettingsStore.showLineNumbers ? .on : .off
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
