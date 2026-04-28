import AppKit

// MARK: - Document tab
//
// One open document. Holds its own NSTextStorage, syntax, dirty flag, undo
// manager, and per-view state (selection, scroll). The Editor owns a list of
// these and swaps the active one in/out of the single shared NSTextView.

final class DocumentTab {
    let id = UUID()
    var url: URL?
    var dirty = false
    let textStorage: NSTextStorage
    var activeSyntax: Syntax?
    var selectedRange = NSRange(location: 0, length: 0)
    var scrollY: CGFloat = 0
    let undoManager = UndoManager()
    /// Lines that differ from HEAD according to git, used by the gutter to draw
    /// added/modified strips. Recomputed on file open and on save.
    var lineChanges: [LineChange] = []

    init(url: URL?, content: String, syntax: Syntax?, font: NSFont) {
        self.url = url
        self.activeSyntax = syntax
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.foreground
        ]
        self.textStorage = NSTextStorage(string: content, attributes: attrs)
    }

    var displayName: String { url?.lastPathComponent ?? "Untitled" }
}

// MARK: - Editor

final class Editor: NSObject, NSTextStorageDelegate, NSTextViewDelegate, NSWindowDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    var gutterView: GutterView!
    var workspaceView: WorkspaceView!

    private(set) var tabs: [DocumentTab] = []
    private(set) var activeTabIndex: Int? = nil
    var activeTab: DocumentTab? {
        guard let i = activeTabIndex, i >= 0, i < tabs.count else { return nil }
        return tabs[i]
    }

    /// Current URL — backed by the active tab.
    var currentURL: URL? { activeTab?.url }
    var dirty: Bool { activeTab?.dirty ?? false }
    var activeSyntax: Syntax? { activeTab?.activeSyntax }

    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 32

    private var currentFontSize: CGFloat = 13
    private var editorFont: NSFont
    var syntaxHighlightingEnabled = false
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
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.background
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
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller = MinimalScroller()

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

        textView.delegate = self

        scrollView.documentView = textView

        gutterView = GutterView(textView: textView, scrollView: scrollView)
        gutterView.gutterFont = editorFont
        let container = GutterContainerView(gutter: gutterView, scrollView: scrollView)
        container.translatesAutoresizingMaskIntoConstraints = false

        let tabBar = TabBarView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] index in self?.switchToTab(at: index) }
        tabBar.onClose  = { [weak self] index in self?.closeTab(at: index) }

        let editorPane = EditorPaneView(tabBar: tabBar, gutterContainer: container)
        editorPane.translatesAutoresizingMaskIntoConstraints = false

        workspaceView = WorkspaceView(editorPane: editorPane)
        workspaceView.frame = frame
        workspaceView.autoresizingMask = [.width, .height]
        workspaceView.sidebar.onSelect = { [weak self] url in
            self?.openOrFocus(url: url)
        }
        workspaceView.sidebar.onRename = { [weak self] oldURL, newURL in
            self?.handleSidebarRename(from: oldURL, to: newURL)
        }
        workspaceView.sidebar.onExternalChange = { [weak self] in
            guard let self = self, let tab = self.activeTab, let url = tab.url else { return }
            DispatchQueue.global(qos: .utility).async {
                let changes = GitDiff.changes(for: url)
                DispatchQueue.main.async { [weak self] in
                    tab.lineChanges = changes
                    self?.gutterView?.setLineChanges(changes)
                }
            }
        }

        gutterView.refresh()
        workspaceView.sidebar.setRowFont(editorFont)
        workspaceView.tabBar.setFont(editorFont)
        applyLineNumbersVisibility()

        window.contentView = workspaceView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)

        restoreLastSession()
        updateTitle()
        rebuildTabBar()
    }

    private func restoreLastSession() {
        let fm = FileManager.default
        if let folder = AppState.lastFolder, fm.fileExists(atPath: folder.path) {
            setRootFolder(folder)
        }
        if let file = AppState.lastFile, fm.fileExists(atPath: file.path) {
            openOrFocus(url: file)
        } else {
            newUntitledTab()
        }
    }

    // MARK: - Tab management

    private func newUntitledTab() {
        let tab = DocumentTab(url: nil, content: "", syntax: nil, font: editorFont)
        tab.textStorage.delegate = self
        tabs.append(tab)
        switchToTab(at: tabs.count - 1)
    }

    /// If a tab already exists for this URL, focus it. Otherwise create a new tab,
    /// load the file from disk, and switch to it.
    private func openOrFocus(url: URL) {
        if let i = tabs.firstIndex(where: { $0.url == url }) {
            switchToTab(at: i)
            return
        }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let syntax = Syntax.from(url: url)
            let tab = DocumentTab(url: url, content: content, syntax: syntax, font: editorFont)
            tab.textStorage.delegate = self
            tab.lineChanges = GitDiff.changes(for: url)
            // Replace empty Untitled tab if user just opened the app to an empty buffer.
            if let i = activeTabIndex,
               let active = activeTab,
               active.url == nil, !active.dirty, active.textStorage.length == 0 {
                tabs[i] = tab
                switchToTab(at: i, force: true)
            } else {
                tabs.append(tab)
                switchToTab(at: tabs.count - 1)
            }
            if syntax != nil && !syntaxHighlightingEnabled {
                setSyntaxHighlighting(true)
            } else if syntaxHighlightingEnabled {
                syntax?.highlight(tab.textStorage)
            }
        } catch {
            showError("Couldn't open file: \(error.localizedDescription)")
        }
    }

    @objc func closeActiveTab(_ sender: Any?) {
        guard let i = activeTabIndex else { return }
        closeTab(at: i)
    }

    func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let tab = tabs[index]
        if tab.dirty && !confirmDiscardTab(tab) { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            activeTabIndex = nil
            newUntitledTab()
            return
        }
        // Prefer staying on the same index (now pointing at the next tab),
        // clamp to last if we removed the rightmost.
        let next = min(index, tabs.count - 1)
        activeTabIndex = nil  // force switchToTab to swap storage even if next == old
        switchToTab(at: next, force: true)
    }

    @objc func nextTab(_ sender: Any?) { cycleTab(by: +1) }
    @objc func prevTab(_ sender: Any?) { cycleTab(by: -1) }

    private func cycleTab(by delta: Int) {
        guard !tabs.isEmpty, let i = activeTabIndex else { return }
        let n = tabs.count
        let next = ((i + delta) % n + n) % n
        switchToTab(at: next)
    }

    private func switchToTab(at index: Int, force: Bool = false) {
        guard index >= 0, index < tabs.count else { return }
        if !force, activeTabIndex == index { return }

        // Save current tab's view state.
        if let active = activeTab {
            active.selectedRange = textView.selectedRange()
            active.scrollY = textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0
        }

        activeTabIndex = index
        let tab = tabs[index]

        if let lm = textView.layoutManager,
           lm.textStorage !== tab.textStorage {
            lm.textStorage?.removeLayoutManager(lm)
            tab.textStorage.addLayoutManager(lm)
        }
        tab.textStorage.delegate = self

        textView.setSelectedRange(tab.selectedRange)
        if let scrollView = textView.enclosingScrollView {
            var origin = scrollView.contentView.bounds.origin
            origin.y = tab.scrollY
            scrollView.contentView.bounds.origin = origin
        }

        if syntaxHighlightingEnabled, let syntax = tab.activeSyntax {
            syntax.highlight(tab.textStorage)
        }

        AppState.lastFile = tab.url
        updateTitle()
        gutterView?.setLineChanges(tab.lineChanges)
        gutterView?.refresh()
        refreshLanguageMenuChecks()
        rebuildTabBar()
    }

    private func rebuildTabBar() {
        let items = tabs.map { TabBarItem(title: $0.displayName, dirty: $0.dirty) }
        workspaceView?.tabBar.update(items: items, activeIndex: activeTabIndex ?? -1)
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            insertNewlineWithIndent(in: textView)
            return true
        }
        return false
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        return activeTab?.undoManager
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
            let key = activeSyntax?.key ?? ""
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
        guard let tab = tabs.first(where: { $0.textStorage === textStorage }) else { return }
        if !tab.dirty {
            tab.dirty = true
            rebuildTabBar()
            if tab === activeTab { updateTitle() }
        }
        if syntaxHighlightingEnabled, let syntax = tab.activeSyntax {
            syntax.highlight(textStorage)
        }
        if tab === activeTab {
            gutterView?.refresh()
        }
    }

    // MARK: Title

    func updateTitle() {
        let name = currentURL?.lastPathComponent ?? "Untitled"
        window.title = "\(dirty ? "● " : "")\(name) — Kantan"
    }

    // MARK: File actions

    @objc func newDocument(_ sender: Any?) {
        newUntitledTab()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            openOrFocus(url: url)
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
        if let url = activeTab?.url {
            saveTo(url: url)
        } else {
            _ = saveAs()
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        _ = saveAs()
    }

    private func handleSidebarRename(from oldURL: URL, to newURL: URL) {
        for tab in tabs where tab.url == oldURL {
            tab.url = newURL
            let next = Syntax.from(url: newURL)
            if next != tab.activeSyntax {
                tab.activeSyntax = next
                if syntaxHighlightingEnabled {
                    let full = NSRange(location: 0, length: tab.textStorage.length)
                    tab.textStorage.removeAttribute(.foregroundColor, range: full)
                    tab.textStorage.addAttribute(.foregroundColor, value: Theme.foreground, range: full)
                    next?.highlight(tab.textStorage)
                }
            }
        }
        if activeTab?.url == newURL {
            updateTitle()
            refreshLanguageMenuChecks()
            AppState.lastFile = newURL
        }
        rebuildTabBar()
    }

    @discardableResult
    private func saveAs() -> Bool {
        guard let tab = activeTab else { return false }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = tab.url?.lastPathComponent ?? "untitled.rb"
        if panel.runModal() == .OK, let url = panel.url {
            tab.url = url
            saveTo(url: url)
            workspaceView?.sidebar.refreshDirectory(containing: url)
            return true
        }
        return false
    }

    private func saveTo(url: URL) {
        guard let tab = activeTab else { return }
        do {
            try textView.string.write(to: url, atomically: true, encoding: .utf8)
            tab.dirty = false
            tab.url = url
            updateTitle()
            selectSyntax(for: url)
            AppState.lastFile = url
            tab.lineChanges = GitDiff.changes(for: url)
            gutterView?.setLineChanges(tab.lineChanges)
            workspaceView?.sidebar.markFile(url, hasChanges: !tab.lineChanges.isEmpty)
            rebuildTabBar()
            if url == SettingsStore.fileURL {
                SettingsStore.loadAndApply()
                if syntaxHighlightingEnabled, let syntax = tab.activeSyntax {
                    syntax.highlight(tab.textStorage)
                }
                applyLineNumbersVisibility()
                applyWorkspaceTheme()
            }
            // The sidebar filename color was already updated via markFile above.
            // The async file-system watcher will do a full git status refresh later.
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
        // Push the new font into every tab's storage so inactive tabs don't snap
        // to the old size when the user switches to them.
        for tab in tabs {
            let full = NSRange(location: 0, length: tab.textStorage.length)
            tab.textStorage.addAttribute(.font, value: editorFont, range: full)
        }
        if syntaxHighlightingEnabled, let tab = activeTab, let syntax = tab.activeSyntax {
            syntax.highlight(tab.textStorage)
        }
        gutterView?.gutterFont = editorFont
        gutterView?.refresh()
        workspaceView?.sidebar.setRowFont(editorFont)
        workspaceView?.tabBar.setFont(editorFont)
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

    private func applyWorkspaceTheme() {
        window.backgroundColor = Theme.background
        textView.backgroundColor = Theme.background
        textView.enclosingScrollView?.backgroundColor = Theme.background
        workspaceView?.sidebar.applyTheme()
        workspaceView?.tabBar.needsDisplay = true
    }

    private func applyLineNumbersVisibility() {
        workspaceView?.gutterContainer.setGutterVisible(SettingsStore.showLineNumbers)
        lineNumbersMenuItem?.state = SettingsStore.showLineNumbers ? .on : .off
    }

    private func setSyntaxHighlighting(_ on: Bool) {
        syntaxHighlightingEnabled = on
        syntaxHighlightingMenuItem?.state = on ? .on : .off
        guard let tab = activeTab else { return }
        let full = NSRange(location: 0, length: tab.textStorage.length)
        tab.textStorage.removeAttribute(.foregroundColor, range: full)
        tab.textStorage.addAttribute(.foregroundColor, value: Theme.foreground, range: full)
        if on, let syntax = tab.activeSyntax {
            syntax.highlight(tab.textStorage)
        }
    }

    /// Adjust the active tab's syntax to match the file's extension.
    private func selectSyntax(for url: URL) {
        guard let tab = activeTab else { return }
        let next = Syntax.from(url: url)
        let changed = next != tab.activeSyntax
        tab.activeSyntax = next
        refreshLanguageMenuChecks()
        if next != nil && !syntaxHighlightingEnabled {
            setSyntaxHighlighting(true)
            return
        }
        if changed && syntaxHighlightingEnabled {
            let full = NSRange(location: 0, length: tab.textStorage.length)
            tab.textStorage.removeAttribute(.foregroundColor, range: full)
            tab.textStorage.addAttribute(.foregroundColor, value: Theme.foreground, range: full)
            next?.highlight(tab.textStorage)
        }
    }

    // MARK: Language selection

    @objc func selectLanguage(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let syntax = Syntax(rawValue: item.tag),
              let tab = activeTab else { return }
        if syntax == tab.activeSyntax && syntaxHighlightingEnabled { return }
        tab.activeSyntax = syntax
        refreshLanguageMenuChecks()
        if !syntaxHighlightingEnabled {
            setSyntaxHighlighting(true)
        } else {
            let full = NSRange(location: 0, length: tab.textStorage.length)
            tab.textStorage.removeAttribute(.foregroundColor, range: full)
            tab.textStorage.addAttribute(.foregroundColor, value: Theme.foreground, range: full)
            syntax.highlight(tab.textStorage)
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
        openOrFocus(url: SettingsStore.fileURL)
    }

    private func confirmDiscardTab(_ tab: DocumentTab) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(tab.displayName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Make this tab active so saveDocument/saveAs operates on it.
            if let i = tabs.firstIndex(where: { $0 === tab }) {
                switchToTab(at: i, force: true)
            }
            saveDocument(nil)
            return !tab.dirty
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
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

    /// Walk the tab list, prompt for each dirty tab. Bail on first cancel.
    func promptSaveBeforeClose() -> Bool {
        for tab in tabs where tab.dirty {
            if !confirmDiscardTab(tab) { return false }
        }
        return true
    }
}
