import AppKit

// MARK: - Document tab
//
// One open document. Holds its own NSTextStorage, syntax, dirty flag, undo
// manager, and per-view state (selection, scroll). A Pane owns a list of these
// and swaps the active one in/out of its NSTextView.

final class DocumentTab {
    enum Kind { case editor, terminal }

    let id = UUID()
    let kind: Kind
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

    /// Set only when kind == .terminal. Owns the PTY, parser, and view.
    var terminal: TerminalState?

    init(url: URL?, content: String, syntax: Syntax?, font: NSFont) {
        self.kind = .editor
        self.url = url
        self.activeSyntax = syntax
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.foreground
        ]
        self.textStorage = NSTextStorage(string: content, attributes: attrs)
    }

    /// Construct a tab that hosts a live shell. The PTY isn't started here —
    /// the caller invokes `terminal!.start()` once the tab is wired into a
    /// pane so the initial size is accurate.
    init(terminalFont: NSFont) {
        self.kind = .terminal
        self.url = nil
        self.activeSyntax = nil
        self.textStorage = NSTextStorage()
        self.terminal = TerminalState(font: terminalFont)
    }

    var displayName: String {
        if kind == .terminal { return "Terminal" }
        return url?.lastPathComponent ?? "Untitled"
    }
}

// MARK: - EditorTextView
//
// NSTextView subclass that lets the owning Pane know when it gains focus, so
// the Editor coordinator can mark this pane as the active one.

final class EditorTextView: NSTextView {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onBecomeFirstResponder?() }
        return result
    }

    /// Paint a full-width bar behind the caret's current line before NSTextView
    /// renders glyphs and temporary attributes. Drawn here (rather than via a
    /// temp attribute) so the highlight extends the full width of the view,
    /// not just the typeset extent of the line.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager,
              let container = textContainer else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }

        let nsText = string as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: min(sel.location, nsText.length),
                                                      length: 0))
        let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var lineRect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
        // Trim a few points off the left edge so the bar sits just to the
        // right of where a caret at col 1 lands, rather than extending past it.
        let leftInset: CGFloat = 4
        lineRect.origin.x = bounds.minX + leftInset
        lineRect.size.width = bounds.width - leftInset
        lineRect = lineRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)

        Theme.lineHighlight.setFill()
        lineRect.intersection(rect).fill()
    }
}

// MARK: - Pane
//
// One editor pane. Owns its own tab list, text view, scroll view, gutter, and
// tab bar. Acts as its own delegate for text view + text storage events.
// Coordinator-level events (focus changes, active-tab changes, split requests,
// cross-pane drags) are surfaced via callbacks to the Editor.

final class Pane: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let textView: EditorTextView
    let scrollView: NSScrollView
    let gutterView: GutterView
    let gutterContainer: GutterContainerView
    let tabBar: TabBarView
    let paneView: EditorPaneView

    private(set) var tabs: [DocumentTab] = []
    private(set) var activeTabIndex: Int? = nil
    var activeTab: DocumentTab? {
        guard let i = activeTabIndex, i >= 0, i < tabs.count else { return nil }
        return tabs[i]
    }

    private var editorFont: NSFont
    var syntaxHighlightingEnabled = false

    // Coordinator callbacks. Set by Editor after construction.
    var onActivated: (() -> Void)?
    var onCursorPositionChanged: ((String) -> Void)?
    var onActiveTabChanged: (() -> Void)?
    var onLastTabClosed: (() -> Void)?
    var onSplitRequested: ((NSUserInterfaceLayoutOrientation, Int) -> Void)?
    /// Right-click action: create a new pane with a terminal in the chosen
    /// orientation. The source tab stays put — unlike `onSplitRequested`,
    /// nothing is moved between panes.
    var onNewTerminalSplit: ((NSUserInterfaceLayoutOrientation) -> Void)?
    /// Right-click action: convert the tab at the given index into a terminal,
    /// replacing whatever editor content was there.
    var onSetAsTerminal: ((Int) -> Void)?
    /// User clicked the X on a tab. The editor handles the dirty-confirm
    /// prompt and then calls back into `closeTab(at:)`.
    var onTabCloseRequested: ((Int) -> Void)?
    /// On mouseUp at the end of a tab drag, called with (sourceTabIndex,
    /// windowPoint). The coordinator returns true if it consumed the drop
    /// (transferred the tab to another pane); otherwise the pane handles it
    /// as a normal in-pane reorder.
    var onTabDropOutsideBar: ((Int, NSPoint) -> Bool)?
    /// Called when the active tab's URL or dirty state changes — Editor uses
    /// it to keep the window title in sync.
    var onTitleStateChanged: (() -> Void)?

    init(font: NSFont) {
        self.editorFont = font

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.background
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller = MinimalScroller()

        let initialContentSize = NSSize(width: 600, height: 400)
        textView = EditorTextView(frame: NSRect(origin: .zero, size: initialContentSize))
        textView.minSize = NSSize(width: 0, height: initialContentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: initialContentSize.width,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.font = editorFont
        textView.backgroundColor = Theme.background
        textView.textColor = Theme.foreground
        textView.insertionPointColor = Theme.cursor
        textView.selectedTextAttributes = [
            .backgroundColor: Theme.selection,
            .foregroundColor: Theme.selectionText,
        ]
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

        scrollView.documentView = textView

        gutterView = GutterView(textView: textView, scrollView: scrollView)
        gutterView.gutterFont = editorFont
        gutterContainer = GutterContainerView(gutter: gutterView, scrollView: scrollView)
        gutterContainer.translatesAutoresizingMaskIntoConstraints = false

        tabBar = TabBarView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        paneView = EditorPaneView(tabBar: tabBar, gutterContainer: gutterContainer)
        paneView.translatesAutoresizingMaskIntoConstraints = false

        super.init()

        textView.delegate = self
        textView.onBecomeFirstResponder = { [weak self] in self?.onActivated?() }

        tabBar.onSelect = { [weak self] index in
            self?.onActivated?()
            self?.switchToTab(at: index)
        }
        tabBar.onClose = { [weak self] index in
            self?.onActivated?()
            self?.onTabCloseRequested?(index)
        }
        tabBar.onReorder = { [weak self] from, to in
            self?.reorderTab(from: from, to: to)
        }
        tabBar.onContextMenu = { [weak self] index, event in
            self?.showTabContextMenu(forTabAt: index, event: event)
        }
        tabBar.onTabDropOutsideBar = { [weak self] sourceIndex, windowPoint in
            return self?.onTabDropOutsideBar?(sourceIndex, windowPoint) ?? false
        }

        // Refresh word-under-caret highlights when the visible region scrolls
        // so off-screen-revealed instances pick up the highlight.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scrollViewBoundsChanged(_ note: Notification) {
        updateWordHighlights()
    }

    // MARK: - View configuration

    func applyTheme() {
        textView.backgroundColor = Theme.background
        textView.enclosingScrollView?.backgroundColor = Theme.background
        tabBar.needsDisplay = true
    }

    /// View that should take first responder when this pane is activated.
    /// For editor tabs that's the editor's text view; for terminal tabs it's
    /// the terminal's text view, so typing routes to the shell.
    var preferredFirstResponder: NSView {
        if let term = activeTab?.terminal { return term.view }
        return textView
    }

    func applyLineNumbersVisible(_ visible: Bool) {
        gutterContainer.setGutterVisible(visible)
        // The gutter's width change shifts the scroll view's frame. AppKit can
        // leave the clip view's horizontal origin past the text view's leading
        // inset after that relayout, which visually crops the margin against
        // the gutter. Flush the layout and snap horizontal scroll back to 0.
        gutterContainer.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        if clip.bounds.origin.x != 0 {
            var origin = clip.bounds.origin
            origin.x = 0
            clip.bounds.origin = origin
        }
    }

    func setFont(_ font: NSFont) {
        editorFont = font
        textView.font = font
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: Theme.foreground
        ]
        for tab in tabs {
            let full = NSRange(location: 0, length: tab.textStorage.length)
            tab.textStorage.addAttribute(.font, value: font, range: full)
        }
        if syntaxHighlightingEnabled, let tab = activeTab, let syntax = tab.activeSyntax {
            syntax.highlight(tab.textStorage)
        }
        gutterView.gutterFont = font
        gutterView.refresh()
        tabBar.setFont(font)
    }

    func setSyntaxHighlighting(_ on: Bool) {
        syntaxHighlightingEnabled = on
        guard let tab = activeTab else { return }
        let full = NSRange(location: 0, length: tab.textStorage.length)
        tab.textStorage.removeAttribute(.foregroundColor, range: full)
        tab.textStorage.addAttribute(.foregroundColor, value: Theme.foreground, range: full)
        if on, let syntax = tab.activeSyntax {
            syntax.highlight(tab.textStorage)
        }
    }

    /// Re-apply syntax colors to every tab's storage. Called after settings
    /// hot-reload changes the theme palette.
    func reapplySyntaxColors() {
        guard syntaxHighlightingEnabled else { return }
        for tab in tabs {
            let full = NSRange(location: 0, length: tab.textStorage.length)
            tab.textStorage.removeAttribute(.foregroundColor, range: full)
            tab.textStorage.addAttribute(.foregroundColor, value: Theme.foreground, range: full)
            tab.activeSyntax?.highlight(tab.textStorage)
        }
    }

    // MARK: - Tab management

    func newUntitledTab() {
        let tab = DocumentTab(url: nil, content: "", syntax: nil, font: editorFont)
        tab.textStorage.delegate = self
        tabs.append(tab)
        switchToTab(at: tabs.count - 1)
    }

    /// Create a new terminal tab in this pane and focus it. Spawns the shell
    /// process synchronously; the PTY size is refined when the view lays out.
    func newTerminalTab() {
        let tab = DocumentTab(terminalFont: editorFont)
        wireTerminalLifecycle(tab)
        tabs.append(tab)
        switchToTab(at: tabs.count - 1)
        tab.terminal?.start()
    }

    /// Replace the tab at `index` with a fresh terminal tab. Editor content at
    /// that slot is discarded — the caller is expected to confirm any unsaved
    /// changes before invoking this.
    func setTabAsTerminal(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let tab = DocumentTab(terminalFont: editorFont)
        wireTerminalLifecycle(tab)
        tabs[index] = tab
        switchToTab(at: index, force: true)
        tab.terminal?.start()
    }

    private func wireTerminalLifecycle(_ tab: DocumentTab) {
        tab.terminal?.onShellExit = { [weak self, weak tab] in
            guard let self = self, let tab = tab,
                  let i = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            // Shell exited (user typed `exit` or process died). Drop the tab.
            self.onTabCloseRequested?(i)
        }
        tab.terminal?.view.textView.onBecomeFirstResponder = { [weak self] in
            self?.onActivated?()
        }
    }

    /// Open `url` in this pane. If a tab for the URL already exists in this
    /// pane, it is focused. If the active tab is an empty Untitled buffer, it
    /// is replaced. Returns the loaded DocumentTab on success, nil on failure.
    @discardableResult
    func openOrFocus(url: URL, syntaxAutoEnableHandler: () -> Void) -> DocumentTab? {
        if let i = tabs.firstIndex(where: { $0.url == url }) {
            switchToTab(at: i)
            return tabs[i]
        }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let syntax = Syntax.from(url: url)
            let tab = DocumentTab(url: url, content: content, syntax: syntax, font: editorFont)
            tab.textStorage.delegate = self
            tab.lineChanges = GitDiff.changes(for: url)
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
                syntaxAutoEnableHandler()
            } else if syntaxHighlightingEnabled {
                syntax?.highlight(tab.textStorage)
            }
            return tab
        } catch {
            return nil
        }
    }

    func switchToTab(at index: Int, force: Bool = false) {
        guard index >= 0, index < tabs.count else { return }
        // No early-return on activeTabIndex == index: re-running the bind
        // is idempotent and self-heals if the layout manager somehow
        // detached from the tab's textStorage (rare, but observed).
        _ = force

        if let active = activeTab, active.kind == .editor {
            active.selectedRange = textView.selectedRange()
            active.scrollY = textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0
        }

        activeTabIndex = index
        let tab = tabs[index]

        if tab.kind == .terminal, let term = tab.terminal {
            paneView.setActiveContent(term.view)
            term.view.focusInput()
            rebuildTabBar()
            onActiveTabChanged?()
            onTitleStateChanged?()
            return
        }

        // Editor path: rebind the text view to this tab's storage and restore
        // the editor chrome (gutter, line numbers, cursor position).
        paneView.setActiveContent(gutterContainer)

        if let lm = textView.layoutManager,
           lm.textStorage !== tab.textStorage {
            lm.textStorage?.removeLayoutManager(lm)
            tab.textStorage.addLayoutManager(lm)
        }
        tab.textStorage.delegate = self

        if syntaxHighlightingEnabled, let syntax = tab.activeSyntax {
            syntax.highlight(tab.textStorage)
        }

        // Force the layout manager to lay out the entire document and resize
        // the text view to match. NSTextView lays out lazily by default, which
        // means the scroll view caps you at the partially-laid-out portion
        // until you scroll into the rest. Doing it up front makes scrolling
        // and the saved scrollY restore behave deterministically.
        if let lm = textView.layoutManager, let container = textView.textContainer {
            lm.ensureLayout(for: container)
        }
        textView.sizeToFit()

        textView.setSelectedRange(tab.selectedRange)
        if let scrollView = textView.enclosingScrollView {
            var origin = scrollView.contentView.bounds.origin
            origin.y = tab.scrollY
            scrollView.contentView.bounds.origin = origin
        }

        gutterView.setLineChanges(tab.lineChanges)
        gutterView.refresh()
        rebuildTabBar()
        updateCursorPositionLabel()
        updateWordHighlights()
        onActiveTabChanged?()
        onTitleStateChanged?()
    }

    func closeTab(at index: Int) -> DocumentTab? {
        guard index >= 0, index < tabs.count else { return nil }
        let tab = tabs[index]
        tab.terminal?.session.terminate()
        tabs.remove(at: index)
        if tabs.isEmpty {
            activeTabIndex = nil
            onLastTabClosed?()
            return tab
        }
        let next = min(index, tabs.count - 1)
        activeTabIndex = nil
        switchToTab(at: next, force: true)
        return tab
    }

    func reorderTab(from: Int, to: Int) {
        guard from >= 0, from < tabs.count, to >= 0, to < tabs.count, from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        if let active = activeTabIndex {
            if active == from {
                activeTabIndex = to
            } else if from < active && active <= to {
                activeTabIndex = active - 1
            } else if to <= active && active < from {
                activeTabIndex = active + 1
            }
        }
        rebuildTabBar()
    }

    func cycleTab(by delta: Int) {
        guard !tabs.isEmpty, let i = activeTabIndex else { return }
        let n = tabs.count
        let next = ((i + delta) % n + n) % n
        switchToTab(at: next)
    }

    /// Detach a tab from this pane (used when transferring it to another pane).
    /// Adjusts active index and switches to a remaining tab. Returns the tab.
    func detachTab(at index: Int) -> DocumentTab? {
        guard index >= 0, index < tabs.count else { return nil }
        // Save editor view state on the active tab so it survives the transfer.
        // Terminal tabs carry their state inside TerminalState (cursor, buffer,
        // session) so they don't need anything captured from the editor view.
        if let active = activeTab, activeTabIndex == index, active.kind == .editor {
            active.selectedRange = textView.selectedRange()
            active.scrollY = textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0
        }
        let tab = tabs.remove(at: index)
        if tabs.isEmpty {
            activeTabIndex = nil
            rebuildTabBar()
            onLastTabClosed?()
            return tab
        }
        if let active = activeTabIndex {
            if active == index {
                activeTabIndex = nil
                let next = min(index, tabs.count - 1)
                switchToTab(at: next, force: true)
            } else if active > index {
                activeTabIndex = active - 1
                rebuildTabBar()
            } else {
                rebuildTabBar()
            }
        }
        return tab
    }

    /// Insert an externally-owned tab into this pane at `index` and focus it.
    /// Used by the editor when transferring a tab from another pane.
    func adoptTab(_ tab: DocumentTab, at index: Int) {
        let clamped = max(0, min(index, tabs.count))
        if tab.kind == .editor {
            tab.textStorage.delegate = self
            // Re-apply current font to the adopted tab in case the source
            // pane had a different size.
            let full = NSRange(location: 0, length: tab.textStorage.length)
            tab.textStorage.addAttribute(.font, value: editorFont, range: full)
        } else {
            // Terminal tab moved between panes — re-wire the shell-exit hook
            // to this pane's tab list and snap the buffer's font.
            wireTerminalLifecycle(tab)
        }
        tabs.insert(tab, at: clamped)
        switchToTab(at: clamped, force: true)
    }

    func rebuildTabBar() {
        let items = tabs.map { TabBarItem(title: $0.displayName, dirty: $0.dirty) }
        tabBar.update(items: items, activeIndex: activeTabIndex ?? -1)
    }

    /// Public helper: re-fire the cursor-position callback. Used by the editor
    /// when a different pane gains focus so the sidebar reflects the new caret.
    func pushCursorPosition() {
        updateCursorPositionLabel()
    }

    private func updateCursorPositionLabel() {
        let nsText = textView.string as NSString
        let location = min(textView.selectedRange().location, nsText.length)
        let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        let textBefore = nsText.substring(to: lineRange.location) as NSString
        var line = 1
        var idx = 0
        while idx < textBefore.length {
            let r = textBefore.range(of: "\n", options: .literal,
                                     range: NSRange(location: idx, length: textBefore.length - idx))
            if r.location == NSNotFound { break }
            line += 1
            idx = r.location + r.length
        }
        let column = location - lineRange.location + 1
        onCursorPositionChanged?("Ln \(line), Col \(column)")
    }

    // MARK: - Right-click context menu on tabs

    private func showTabContextMenu(forTabAt index: Int, event: NSEvent) {
        let menu = NSMenu()

        let termV = NSMenuItem(title: "New Terminal (Split Vertically)",
                               action: #selector(handleNewTerminalSplitVertically(_:)),
                               keyEquivalent: "")
        termV.target = self
        let termH = NSMenuItem(title: "New Terminal (Split Horizontally)",
                               action: #selector(handleNewTerminalSplitHorizontally(_:)),
                               keyEquivalent: "")
        termH.target = self
        let setAsTerm = NSMenuItem(title: "Set as Terminal",
                                   action: #selector(handleSetAsTerminal(_:)),
                                   keyEquivalent: "")
        setAsTerm.target = self
        setAsTerm.representedObject = index
        menu.addItem(termV)
        menu.addItem(termH)
        menu.addItem(setAsTerm)
        menu.addItem(.separator())

        let splitV = NSMenuItem(title: "Split Vertically",
                                action: #selector(handleSplitVertically(_:)),
                                keyEquivalent: "")
        splitV.target = self
        splitV.representedObject = index
        let splitH = NSMenuItem(title: "Split Horizontally",
                                action: #selector(handleSplitHorizontally(_:)),
                                keyEquivalent: "")
        splitH.target = self
        splitH.representedObject = index
        menu.addItem(splitV)
        menu.addItem(splitH)
        NSMenu.popUpContextMenu(menu, with: event, for: tabBar)
    }

    @objc private func handleSplitVertically(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int else { return }
        onSplitRequested?(.horizontal, idx)
    }

    @objc private func handleSplitHorizontally(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int else { return }
        onSplitRequested?(.vertical, idx)
    }

    @objc private func handleNewTerminalSplitVertically(_ sender: NSMenuItem) {
        onNewTerminalSplit?(.horizontal)
    }

    @objc private func handleNewTerminalSplitHorizontally(_ sender: NSMenuItem) {
        onNewTerminalSplit?(.vertical)
    }

    @objc private func handleSetAsTerminal(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int else { return }
        onSetAsTerminal?(idx)
    }

    // MARK: - NSTextViewDelegate

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

    func textViewDidChangeSelection(_ notification: Notification) {
        updateCursorPositionLabel()
        updateWordHighlights()
        // Force a redraw so the current-line bar follows the caret. The
        // textView's automatic invalidation only covers the immediate caret
        // rect, not the full-width line bar behind it.
        textView.needsDisplay = true
    }

    // MARK: - Word-under-caret highlighting

    /// Recompute and apply the word-under-caret highlight across the visible
    /// portion of the document. Cheap to call frequently — we clear all
    /// background temporary attributes across the document and reapply
    /// fresh ones, which avoids stale entries left behind when text edits
    /// shift previous match ranges.
    private func updateWordHighlights() {
        guard let lm = textView.layoutManager else { return }

        let nsText = textView.string as NSString
        let docRange = NSRange(location: 0, length: nsText.length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: docRange)

        let sel = textView.selectedRange()
        guard sel.length == 0 else { return }
        guard let (word, _) = wordTouchingCaret(at: sel.location, in: nsText) else { return }

        let visibleRange = visibleCharacterRange()
        guard visibleRange.length > 0 else { return }

        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        regex.enumerateMatches(in: textView.string, range: visibleRange) { match, _, _ in
            guard let m = match else { return }
            lm.addTemporaryAttribute(.backgroundColor,
                                     value: Theme.wordHighlight,
                                     forCharacterRange: m.range)
        }
    }

    /// Find the run of A-Z/a-z characters touching the caret position, where
    /// "touching" means either the character to the left or the character to
    /// the right of the caret is a letter. Returns the word string and its
    /// range, or nil if the caret isn't adjacent to a letter run.
    private func wordTouchingCaret(at location: Int, in nsText: NSString) -> (String, NSRange)? {
        let length = nsText.length
        let leftIsLetter  = location > 0      && Pane.isAsciiLetter(nsText.character(at: location - 1))
        let rightIsLetter = location < length && Pane.isAsciiLetter(nsText.character(at: location))
        if !leftIsLetter && !rightIsLetter { return nil }

        var start = location
        while start > 0, Pane.isAsciiLetter(nsText.character(at: start - 1)) { start -= 1 }
        var end = location
        while end < length, Pane.isAsciiLetter(nsText.character(at: end)) { end += 1 }

        let range = NSRange(location: start, length: end - start)
        guard range.length > 0 else { return nil }
        return (nsText.substring(with: range), range)
    }

    private static func isAsciiLetter(_ c: unichar) -> Bool {
        return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    /// The character range corresponding to the glyphs currently visible in
    /// the text view's clip rect.
    private func visibleCharacterRange() -> NSRange {
        guard let lm = textView.layoutManager,
              let container = textView.textContainer else {
            return NSRange(location: 0, length: 0)
        }
        let glyphRange = lm.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        return lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    private static let autoPairs: [Character: Character] = [
        "{": "}", "[": "]", "(": ")",
        "`": "`", "\"": "\"", "'": "'"
    ]

    func textView(_ textView: NSTextView,
                  shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        guard let str = replacementString, str.count == 1,
              let ch = str.first else { return true }

        let nsText = textView.string as NSString

        // HTML/XML tag auto-close: when the user types '>' inside a markup
        // document, finish the matching closing tag and leave the caret
        // between the two. Void-element handling only applies to HTML.
        let syntax = activeTab?.activeSyntax
        if ch == ">", (syntax == .html || syntax == .xml),
           let tagName = markupTagToAutoClose(at: affectedCharRange.location,
                                              in: nsText,
                                              applyVoidElementCheck: syntax == .html) {
            let insertion = "></\(tagName)>"
            textView.insertText(insertion, replacementRange: affectedCharRange)
            let cursorAt = affectedCharRange.location + 1
            textView.setSelectedRange(NSRange(location: cursorAt, length: 0))
            return false
        }

        guard let closer = Pane.autoPairs[ch] else { return true }

        if ch == "\"" || ch == "'" {
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
        let insertion = "\(ch)\(middle)\(closer)"
        textView.insertText(insertion, replacementRange: affectedCharRange)

        let selStart = affectedCharRange.location + 1
        let selLength = (middle as NSString).length
        textView.setSelectedRange(NSRange(location: selStart, length: selLength))

        return false
    }

    /// Void HTML elements that are never auto-closed (they have no closing tag).
    private static let htmlVoidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    /// Inspect the text immediately to the left of `location` and decide
    /// whether typing '>' there should auto-insert a matching `</tag>`.
    /// Returns the tag name to close, or nil if the context isn't a normal
    /// opening tag (closing tag, comment, doctype/PI, self-closing, or — for
    /// HTML — a void element).
    private func markupTagToAutoClose(at location: Int,
                                      in nsText: NSString,
                                      applyVoidElementCheck: Bool) -> String? {
        // Walk back to the most recent '<' without crossing a '>' first.
        var i = location - 1
        while i >= 0 {
            let c = nsText.character(at: i)
            if c == 0x3E { return nil }  // '>'
            if c == 0x3C { break }        // '<'
            i -= 1
        }
        guard i >= 0, nsText.character(at: i) == 0x3C else { return nil }

        let tagStart = i + 1
        guard tagStart < location else { return nil }

        let firstChar = nsText.character(at: tagStart)
        // Skip closing tags </…, comments <!--, doctype/CDATA <!…, processing
        // instructions <?…
        if firstChar == 0x2F || firstChar == 0x21 || firstChar == 0x3F { return nil }

        guard let firstScalar = UnicodeScalar(firstChar),
              CharacterSet.letters.contains(firstScalar) else { return nil }

        // Tag name: letters, digits, and '-' (custom elements).
        var nameEnd = tagStart
        while nameEnd < location {
            let c = nsText.character(at: nameEnd)
            guard let scalar = UnicodeScalar(c) else { break }
            if CharacterSet.alphanumerics.contains(scalar) || c == 0x2D {
                nameEnd += 1
            } else {
                break
            }
        }
        let name = nsText.substring(with: NSRange(location: tagStart,
                                                  length: nameEnd - tagStart)).lowercased()
        if name.isEmpty { return nil }

        // Self-closing form: a '/' immediately before the '>' we're typing
        // (allowing trailing whitespace) means the tag is already terminated.
        var j = location - 1
        while j >= nameEnd {
            let c = nsText.character(at: j)
            if c == 0x20 || c == 0x09 { j -= 1; continue }
            if c == 0x2F { return nil }
            break
        }

        if applyVoidElementCheck, Pane.htmlVoidElements.contains(name) { return nil }
        return name
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
        let opener: Character?
        switch trimmed.last {
        case "{": opener = "{"
        case "[": opener = "["
        case "(": opener = "("
        default:  opener = nil
        }

        let key = activeTab?.activeSyntax?.key ?? ""
        let cfg = SettingsStore.indentByLanguage[key] ?? IndentConfig.fallback
        let indentUnit = cfg.unitString

        // Smart split: when the caret sits exactly between an opener and its
        // matching closer (e.g. `{|}`, or `<div>|</div>` in HTML/XML),
        // pressing Enter pushes the closer down to its own line aligned with
        // the opener and leaves the caret on an indented blank line between
        // them.
        if selRange.length == 0 {
            var bracketSplit = false
            if let opener = opener, cursor < nsText.length {
                let closer: unichar
                switch opener {
                case "{": closer = 0x7D
                case "[": closer = 0x5D
                case "(": closer = 0x29
                default:  closer = 0
                }
                bracketSplit = closer != 0 && nsText.character(at: cursor) == closer
            }

            let syntax = activeTab?.activeSyntax
            let tagSplit = (syntax == .html || syntax == .xml)
                && tagPairAroundCaret(at: cursor, in: nsText) != nil

            if bracketSplit || tagSplit {
                let prefix = "\n" + leading + indentUnit
                let suffix = "\n" + leading
                textView.insertText(prefix + suffix, replacementRange: selRange)
                let caretAt = selRange.location + (prefix as NSString).length
                textView.setSelectedRange(NSRange(location: caretAt, length: 0))
                return
            }
        }

        var insertion = "\n" + leading
        if opener != nil {
            insertion += indentUnit
        }
        textView.insertText(insertion, replacementRange: selRange)
    }

    /// Detect whether `location` sits exactly between a matching pair of HTML/
    /// XML tags, e.g. `<div>|</div>`. Returns the tag name on a match (case
    /// preserved from the opening tag) or nil if the surrounding text isn't a
    /// matched pair. Comparison of the closing tag is case-insensitive so
    /// `<DIV></div>` still smart-splits.
    private func tagPairAroundCaret(at location: Int, in nsText: NSString) -> String? {
        // Char to the immediate left must be the '>' that closes an opening tag.
        guard location > 0, nsText.character(at: location - 1) == 0x3E else { return nil }

        // Walk back from before the '>' to find the matching '<' without
        // crossing another '>' first.
        var i = location - 2
        while i >= 0 {
            let c = nsText.character(at: i)
            if c == 0x3E { return nil }
            if c == 0x3C { break }
            i -= 1
        }
        guard i >= 0, nsText.character(at: i) == 0x3C else { return nil }

        let nameStart = i + 1
        guard nameStart < location - 1 else { return nil }
        let firstChar = nsText.character(at: nameStart)
        // Skip closing/comment/PI starts.
        if firstChar == 0x2F || firstChar == 0x21 || firstChar == 0x3F { return nil }
        guard let firstScalar = UnicodeScalar(firstChar),
              CharacterSet.letters.contains(firstScalar) else { return nil }

        var nameEnd = nameStart
        while nameEnd < location - 1 {
            let c = nsText.character(at: nameEnd)
            guard let scalar = UnicodeScalar(c) else { break }
            if CharacterSet.alphanumerics.contains(scalar)
                || c == 0x2D /* - */
                || c == 0x5F /* _ */
                || c == 0x3A /* : */ {
                nameEnd += 1
            } else {
                break
            }
        }
        guard nameEnd > nameStart else { return nil }

        // Skip self-closing forms — `<foo/>` shouldn't smart-split.
        var k = location - 2
        while k >= nameEnd {
            let c = nsText.character(at: k)
            if c == 0x20 || c == 0x09 { k -= 1; continue }
            if c == 0x2F { return nil }
            break
        }

        let openName = nsText.substring(with: NSRange(location: nameStart,
                                                      length: nameEnd - nameStart))

        // Forward: text starting at `location` must be `</openName>`.
        let needed = "</\(openName)>"
        let neededLength = (needed as NSString).length
        guard location + neededLength <= nsText.length else { return nil }
        let forward = nsText.substring(with: NSRange(location: location, length: neededLength))
        if forward.caseInsensitiveCompare(needed) == .orderedSame {
            return openName
        }
        return nil
    }

    // MARK: - NSTextStorageDelegate

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
            if tab === activeTab { onTitleStateChanged?() }
        }
        if syntaxHighlightingEnabled, let syntax = tab.activeSyntax {
            syntax.highlight(textStorage)
        }
        if tab === activeTab {
            gutterView.refresh()
        }
    }
}

// MARK: - Editor (window-level coordinator)

final class Editor: NSObject, NSWindowDelegate {
    var window: NSWindow!
    var workspaceView: WorkspaceView!

    private(set) var panes: [Pane] = []
    private(set) var focusedPane: Pane!

    /// Convenience accessors on the focused pane.
    var activeTab: DocumentTab? { focusedPane?.activeTab }
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
    weak var themesMenu: NSMenu?

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

        let firstPane = makePane()
        panes = [firstPane]
        focusedPane = firstPane

        workspaceView = WorkspaceView(initialPaneView: firstPane.paneView)
        workspaceView.frame = frame
        workspaceView.autoresizingMask = [.width, .height]

        workspaceView.sidebar.onSelect = { [weak self] url in
            self?.openOrFocus(url: url)
        }
        workspaceView.sidebar.onRename = { [weak self] oldURL, newURL in
            self?.handleSidebarRename(from: oldURL, to: newURL)
        }
        workspaceView.sidebar.onExternalChange = { [weak self] in
            self?.refreshActiveLineChanges()
        }

        workspaceView.sidebar.setRowFont(editorFont)
        applyLineNumbersVisibility()

        window.contentView = workspaceView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(firstPane.textView)

        restoreLastSession()
        updateTitle()
        firstPane.rebuildTabBar()
    }

    /// Construct and wire a new pane.
    private func makePane() -> Pane {
        let pane = Pane(font: editorFont)
        pane.syntaxHighlightingEnabled = syntaxHighlightingEnabled
        wirePane(pane)
        return pane
    }

    private func wirePane(_ pane: Pane) {
        pane.onActivated = { [weak self, weak pane] in
            guard let self = self, let pane = pane else { return }
            self.setFocusedPane(pane)
        }
        pane.onCursorPositionChanged = { [weak self, weak pane] text in
            guard let self = self, let pane = pane, pane === self.focusedPane else { return }
            self.workspaceView?.sidebar.setCursorPosition(text)
        }
        pane.onActiveTabChanged = { [weak self, weak pane] in
            guard let self = self, let pane = pane, pane === self.focusedPane else { return }
            AppState.lastFile = pane.activeTab?.url
            self.refreshLanguageMenuChecks()
        }
        pane.onTitleStateChanged = { [weak self, weak pane] in
            guard let self = self, let pane = pane, pane === self.focusedPane else { return }
            self.updateTitle()
        }
        pane.onLastTabClosed = { [weak self, weak pane] in
            guard let self = self, let pane = pane else { return }
            self.handlePaneEmptied(pane)
        }
        pane.onSplitRequested = { [weak self, weak pane] orientation, tabIndex in
            guard let self = self, let pane = pane else { return }
            self.splitPane(pane, takingTabAt: tabIndex, orientation: orientation)
        }
        pane.onNewTerminalSplit = { [weak self] orientation in
            guard let self = self else { return }
            self.openNewTerminalSplit(orientation: orientation)
        }
        pane.onSetAsTerminal = { [weak pane] index in
            guard let pane = pane else { return }
            pane.setTabAsTerminal(at: index)
        }
        pane.onTabDropOutsideBar = { [weak self, weak pane] sourceIndex, windowPoint in
            guard let self = self, let pane = pane else { return false }
            return self.handleCrossPaneDrop(from: pane, sourceIndex: sourceIndex, windowPoint: windowPoint)
        }
        pane.onTabCloseRequested = { [weak self, weak pane] index in
            guard let self = self, let pane = pane else { return }
            self.closeTab(in: pane, at: index)
        }
    }

    private func setFocusedPane(_ pane: Pane) {
        guard pane !== focusedPane else { return }
        focusedPane = pane
        updateTitle()
        refreshLanguageMenuChecks()
        AppState.lastFile = pane.activeTab?.url
        // Push the new pane's cursor position to the sidebar so the footer
        // tracks the focused pane rather than the previous one.
        pane.pushCursorPosition()
        // If activation came from a tab-bar click rather than a textView
        // click, the pane's preferred input view still needs to take first
        // responder so typing lands in the right pane (and in the right kind
        // of content — terminal vs editor).
        let target = pane.preferredFirstResponder
        if window?.firstResponder !== target {
            window?.makeFirstResponder(target)
        }
    }

    private func restoreLastSession() {
        let fm = FileManager.default
        if let folder = AppState.lastFolder, fm.fileExists(atPath: folder.path) {
            setRootFolder(folder)
        }
        if let file = AppState.lastFile, fm.fileExists(atPath: file.path) {
            openOrFocus(url: file)
        } else {
            focusedPane.newUntitledTab()
        }
    }

    // MARK: - File open/close routing

    private func openOrFocus(url: URL) {
        // If the URL is open in any pane already, focus that pane and tab.
        // force=true so the LM/textStorage binding is re-applied even if the
        // tab is already active — defensive against any stale state.
        for pane in panes {
            if let i = pane.tabs.firstIndex(where: { $0.url == url }) {
                setFocusedPane(pane)
                pane.switchToTab(at: i, force: true)
                window.makeFirstResponder(pane.textView)
                return
            }
        }
        let result = focusedPane.openOrFocus(url: url) { [weak self] in
            self?.setSyntaxHighlighting(true)
        }
        if result == nil {
            showError("Couldn't open file at \(url.path)")
        }
    }

    @objc func closeActiveTab(_ sender: Any?) {
        guard let i = focusedPane.activeTabIndex else { return }
        closeTab(in: focusedPane, at: i)
    }

    private func closeTab(in pane: Pane, at index: Int) {
        guard index >= 0, index < pane.tabs.count else { return }
        let tab = pane.tabs[index]
        if tab.dirty && !confirmDiscardTab(tab, in: pane) { return }
        _ = pane.closeTab(at: index)
    }

    /// A pane reported its last tab was closed. If it's the only pane, open a
    /// fresh untitled tab. Otherwise remove the pane and collapse the split.
    private func handlePaneEmptied(_ pane: Pane) {
        if panes.count <= 1 {
            pane.newUntitledTab()
            return
        }
        removePane(pane)
    }

    private func removePane(_ pane: Pane) {
        guard let idx = panes.firstIndex(where: { $0 === pane }) else { return }
        workspaceView.removePane(pane.paneView)
        panes.remove(at: idx)
        let next = panes.first!
        focusedPane = next
        window.makeFirstResponder(next.preferredFirstResponder)
        updateTitle()
        refreshLanguageMenuChecks()
        AppState.lastFile = next.activeTab?.url
    }

    // MARK: - Splitting

    /// Move tab at `tabIndex` from `source` into a new pane created in the
    /// given orientation (NSSplitView.isVertical flag — `.vertical` means the
    /// divider runs vertically i.e. side-by-side panes).
    private func splitPane(_ source: Pane,
                           takingTabAt tabIndex: Int,
                           orientation: NSUserInterfaceLayoutOrientation) {
        // A split needs at least 2 tabs in the source pane (otherwise the
        // source would be left empty), and we only allow a single split.
        guard panes.count < 2, source.tabs.count > 1 else { return }
        guard let detached = source.detachTab(at: tabIndex) else { return }
        let newPane = makePane()
        panes.append(newPane)
        workspaceView.addPane(newPane.paneView, orientation: orientation)
        newPane.adoptTab(detached, at: 0)
        newPane.setFont(editorFont)
        newPane.setSyntaxHighlighting(syntaxHighlightingEnabled)
        newPane.applyLineNumbersVisible(SettingsStore.showLineNumbers)
        focusedPane = newPane
        window.makeFirstResponder(newPane.textView)
        updateTitle()
    }

    /// Cmd+T action. If there's only one pane, create a new split (in the
    /// settings-configured orientation) with an empty untitled tab. If a split
    /// already exists, add the untitled tab to the *other* pane.
    @objc func newSplit(_ sender: Any?) {
        if panes.count >= 2 {
            let other = panes.first(where: { $0 !== focusedPane }) ?? focusedPane!
            other.newUntitledTab()
            focusedPane = other
            window.makeFirstResponder(other.textView)
            updateTitle()
            return
        }
        let orientation = SettingsStore.splitOrientation
        let newPane = makePane()
        panes.append(newPane)
        workspaceView.addPane(newPane.paneView, orientation: orientation)
        newPane.setFont(editorFont)
        newPane.setSyntaxHighlighting(syntaxHighlightingEnabled)
        newPane.applyLineNumbersVisible(SettingsStore.showLineNumbers)
        newPane.newUntitledTab()
        focusedPane = newPane
        window.makeFirstResponder(newPane.textView)
        updateTitle()
    }

    /// Cmd+Shift+T action. Open a new pane with a terminal tab; if a split
    /// already exists, drop the terminal tab into the *other* pane (mirroring
    /// `newSplit` so the keystroke is predictable).
    @objc func newTerminalSplit(_ sender: Any?) {
        openNewTerminalSplit(orientation: SettingsStore.terminalSplitOrientation)
    }

    /// Open a new terminal in another pane. If only one pane exists, create
    /// a split in the requested orientation; otherwise reuse the existing
    /// non-focused pane.
    fileprivate func openNewTerminalSplit(orientation: NSUserInterfaceLayoutOrientation) {
        if panes.count >= 2 {
            let other = panes.first(where: { $0 !== focusedPane }) ?? focusedPane!
            other.newTerminalTab()
            focusedPane = other
            updateTitle()
            return
        }
        let newPane = makePane()
        panes.append(newPane)
        workspaceView.addPane(newPane.paneView, orientation: orientation)
        newPane.setFont(editorFont)
        newPane.setSyntaxHighlighting(syntaxHighlightingEnabled)
        newPane.applyLineNumbersVisible(SettingsStore.showLineNumbers)
        newPane.newTerminalTab()
        focusedPane = newPane
        updateTitle()
    }

    // MARK: - Cross-pane tab dragging

    /// Called by a pane when a tab drag ends with the cursor outside its own
    /// tab bar. Returns true if we transferred the tab to another pane.
    private func handleCrossPaneDrop(from source: Pane,
                                     sourceIndex: Int,
                                     windowPoint: NSPoint) -> Bool {
        guard let target = paneForTabBarHit(windowPoint: windowPoint),
              target !== source else {
            return false
        }
        let pointInTargetBar = target.tabBar.convert(windowPoint, from: nil)
        let insertIndex = insertionIndex(in: target.tabBar, atX: pointInTargetBar.x)
        guard let detached = source.detachTab(at: sourceIndex) else { return false }
        target.adoptTab(detached, at: insertIndex)
        focusedPane = target
        window.makeFirstResponder(target.preferredFirstResponder)
        updateTitle()
        return true
    }

    private func paneForTabBarHit(windowPoint: NSPoint) -> Pane? {
        for pane in panes {
            let inBar = pane.tabBar.convert(windowPoint, from: nil)
            if pane.tabBar.bounds.contains(inBar) {
                return pane
            }
        }
        return nil
    }

    /// Find where to insert a transferred tab in `bar` given the drop x.
    private func insertionIndex(in bar: TabBarView, atX x: CGFloat) -> Int {
        let items = bar.arrangedTabViews
        if items.isEmpty { return 0 }
        for (i, view) in items.enumerated() {
            if x < view.frame.midX { return i }
        }
        return items.count
    }

    // MARK: - Tab cycling

    @objc func nextTab(_ sender: Any?) { focusedPane.cycleTab(by: +1) }
    @objc func prevTab(_ sender: Any?) { focusedPane.cycleTab(by: -1) }

    // MARK: - Sidebar interaction

    private func handleSidebarRename(from oldURL: URL, to newURL: URL) {
        for pane in panes {
            for tab in pane.tabs where tab.url == oldURL {
                tab.url = newURL
                let next = Syntax.from(url: newURL)
                if next != tab.activeSyntax {
                    tab.activeSyntax = next
                    if syntaxHighlightingEnabled {
                        let full = NSRange(location: 0, length: tab.textStorage.length)
                        tab.textStorage.removeAttribute(.foregroundColor, range: full)
                        tab.textStorage.addAttribute(.foregroundColor,
                                                    value: Theme.foreground,
                                                    range: full)
                        next?.highlight(tab.textStorage)
                    }
                }
            }
            pane.rebuildTabBar()
        }
        if focusedPane.activeTab?.url == newURL {
            updateTitle()
            refreshLanguageMenuChecks()
            AppState.lastFile = newURL
        }
    }

    private func refreshActiveLineChanges() {
        for pane in panes {
            guard let tab = pane.activeTab, let url = tab.url else { continue }
            DispatchQueue.global(qos: .utility).async {
                let changes = GitDiff.changes(for: url)
                DispatchQueue.main.async {
                    tab.lineChanges = changes
                    pane.gutterView.setLineChanges(changes)
                }
            }
        }
    }

    // MARK: - Title

    func updateTitle() {
        let name = currentURL?.lastPathComponent ?? "Untitled"
        window.title = "\(dirty ? "● " : "")\(name) — Kantan"
    }

    // MARK: - File actions

    @objc func newDocument(_ sender: Any?) {
        focusedPane.newUntitledTab()
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

    @objc func toggleSidebar(_ sender: Any?) { workspaceView.toggleSidebar() }
    @objc func refreshSidebar(_ sender: Any?) { workspaceView.refreshSidebar() }

    @objc func saveDocument(_ sender: Any?) {
        guard let tab = focusedPane.activeTab else { return }
        if let url = tab.url {
            saveTo(url: url, tab: tab, in: focusedPane)
        } else {
            _ = saveAs(in: focusedPane)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        _ = saveAs(in: focusedPane)
    }

    @discardableResult
    private func saveAs(in pane: Pane) -> Bool {
        guard let tab = pane.activeTab else { return false }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = tab.url?.lastPathComponent ?? "untitled.rb"
        if panel.runModal() == .OK, let url = panel.url {
            tab.url = url
            saveTo(url: url, tab: tab, in: pane)
            workspaceView?.sidebar.refreshDirectory(containing: url)
            return true
        }
        return false
    }

    private func saveTo(url: URL, tab: DocumentTab, in pane: Pane) {
        do {
            try pane.textView.string.write(to: url, atomically: true, encoding: .utf8)
            tab.dirty = false
            tab.url = url
            updateTitle()
            selectSyntax(for: url, in: pane)
            AppState.lastFile = url
            tab.lineChanges = GitDiff.changes(for: url)
            pane.gutterView.setLineChanges(tab.lineChanges)
            workspaceView?.sidebar.markFile(url, hasChanges: !tab.lineChanges.isEmpty)
            pane.rebuildTabBar()
            if url == SettingsStore.fileURL {
                SettingsStore.loadAndApply()
                for p in panes { p.reapplySyntaxColors() }
                applyLineNumbersVisibility()
                applyWorkspaceTheme()
                rebuildThemesMenu()
            }
        } catch {
            showError("Couldn't save file: \(error.localizedDescription)")
        }
    }

    // MARK: - Font sizing

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
        for pane in panes { pane.setFont(editorFont) }
        workspaceView?.sidebar.setRowFont(editorFont)
    }

    // MARK: - Syntax / line numbers / theme

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
        for pane in panes { pane.applyTheme() }
        workspaceView?.sidebar.applyTheme()
    }

    @objc func selectTheme(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        SettingsStore.setActiveTheme(name)
        SettingsStore.loadAndApply()
        for p in panes { p.reapplySyntaxColors() }
        applyLineNumbersVisibility()
        applyWorkspaceTheme()
        refreshThemesMenuChecks()
    }

    /// Rebuild the Themes submenu items to reflect the current `themesByName`
    /// map and active selection. Called after the menu is first built and
    /// after settings.yaml changes (a user may have added/removed themes).
    func rebuildThemesMenu() {
        guard let menu = themesMenu else { return }
        menu.removeAllItems()
        for key in SettingsStore.themeOrder {
            let title = SettingsStore.themeDisplayNames[key] ?? key
            let item = NSMenuItem(title: title,
                                  action: #selector(Editor.selectTheme(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = (key == SettingsStore.activeTheme) ? .on : .off
            menu.addItem(item)
        }
    }

    private func refreshThemesMenuChecks() {
        guard let menu = themesMenu else { return }
        for item in menu.items {
            if let key = item.representedObject as? String {
                item.state = (key == SettingsStore.activeTheme) ? .on : .off
            }
        }
    }

    private func applyLineNumbersVisibility() {
        for pane in panes { pane.applyLineNumbersVisible(SettingsStore.showLineNumbers) }
        lineNumbersMenuItem?.state = SettingsStore.showLineNumbers ? .on : .off
    }

    private func setSyntaxHighlighting(_ on: Bool) {
        syntaxHighlightingEnabled = on
        syntaxHighlightingMenuItem?.state = on ? .on : .off
        for pane in panes { pane.setSyntaxHighlighting(on) }
    }

    private func selectSyntax(for url: URL, in pane: Pane) {
        guard let tab = pane.activeTab else { return }
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

    // MARK: - Language selection

    @objc func selectLanguage(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let syntax = Syntax(rawValue: item.tag),
              let tab = focusedPane.activeTab else { return }
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

    // MARK: - Settings

    @objc func openSettings(_ sender: Any?) {
        openOrFocus(url: SettingsStore.fileURL)
    }

    private func confirmDiscardTab(_ tab: DocumentTab, in pane: Pane) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(tab.displayName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let i = pane.tabs.firstIndex(where: { $0 === tab }) {
                pane.switchToTab(at: i, force: true)
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

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return promptSaveBeforeClose()
    }

    func promptSaveBeforeClose() -> Bool {
        for pane in panes {
            for tab in pane.tabs where tab.dirty {
                if !confirmDiscardTab(tab, in: pane) { return false }
            }
        }
        return true
    }
}
