import AppKit
import CoreServices
import os.log

private let sidebarLog = OSLog(subsystem: "com.kantan.editor", category: "Sidebar")

// MARK: - FSEvents directory watcher

/// Watches a directory tree for changes using macOS FSEvents. Coalesces rapid
/// bursts of events with a short latency so we don't spam `git status` on every
/// individual write. The callback is debounced — only fires after the file system
/// has been quiet for the debounce interval.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void
    private var debounceItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 1.0

    init(directory: URL, callback: @escaping () -> Void) {
        self.callback = callback

        let paths = [directory.path] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            nil,
            { (_, info, _, _, _, _) in
                guard let info = info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.scheduleDebouncedCallback()
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,   // 2s FSEvents coalescing latency
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    private func scheduleDebouncedCallback() {
        os_log(.info, log: sidebarLog, "FSEvents fired — scheduling debounced callback (%.1f s)", debounceInterval)
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            os_log(.info, log: sidebarLog, "Debounce timer fired — calling watcher callback")
            self?.callback()
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    func stop() {
        debounceItem?.cancel()
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

// MARK: - File node (lazy directory tree)

final class FileNode {
    let url: URL
    let isDirectory: Bool
    private var _children: [FileNode]?

    init(url: URL) {
        self.url = url
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = exists && isDir.boolValue
    }

    var displayName: String { url.lastPathComponent }

    /// Children of this node. `nil` for files. Lazily computed and cached on first access.
    var children: [FileNode] {
        if let cached = _children { return cached }
        let computed = loadChildren()
        _children = computed
        return computed
    }

    /// Drop the cached children so the next access re-reads from disk.
    func invalidate() {
        _children = nil
    }

    /// Children that have already been loaded. Does not trigger a load.
    var cachedChildren: [FileNode] { _children ?? [] }

    /// Re-read children from disk while preserving FileNode identity for URLs that
    /// still exist. NSOutlineView keys expansion off of item identity, so reusing
    /// instances keeps sub-trees expanded across a refresh.
    func reloadChildren() {
        guard isDirectory else { _children = []; return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            _children = []
            return
        }
        let existingByURL = Dictionary(uniqueKeysWithValues: (_children ?? []).map { ($0.url, $0) })
        let nodes = entries.map { url in existingByURL[url] ?? FileNode(url: url) }
        _children = nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func loadChildren() -> [FileNode] {
        guard isDirectory else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let nodes = entries.map { FileNode(url: $0) }
        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

// MARK: - Sidebar row view (custom selection drawing)

/// Replaces the system's blue selection fill with a muted pill that matches the
/// editor's dark aesthetic. Color comes from `Theme.sidebarSelection`.
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let r = bounds.insetBy(dx: 5, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        Theme.sidebarSelection.setFill()
        path.fill()
    }
}

// MARK: - Outline view (no system disclosure triangle)

/// Hides the system-drawn disclosure triangle so we can render a chevron inside
/// the cell's image slot — same x-position as a file's language icon. Also pulls
/// the cell flush to its level-indent so depth-0 rows aren't pushed right by the
/// space NSOutlineView would normally reserve for the disclosure.
final class IconAlignedOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        return .zero
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let target = CGFloat(self.level(forRow: row)) * self.indentationPerLevel
        if frame.origin.x > target {
            let delta = frame.origin.x - target
            frame.origin.x -= delta
            frame.size.width += delta
        }
        return frame
    }
}

// MARK: - File row cell

/// Holds references to the icon's size constraints so the row can resize them
/// when the editor font (and hence the row height) changes.
final class FileCellView: NSTableCellView {
    var iconWidthConstraint: NSLayoutConstraint!
    var iconHeightConstraint: NSLayoutConstraint!
}

// MARK: - Sidebar (file tree)

final class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private let outlineView: NSOutlineView
    private let scrollView: NSScrollView
    private var rootNode: FileNode?

    private var cellFont: NSFont = NSFont(name: "Menlo", size: 13)
        ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Icon size tracks the cell font so language SVGs and SF Symbols grow/shrink
    /// alongside the editor's font-size shortcuts.
    private var iconSize: CGFloat {
        return ceil(cellFont.pointSize)
    }

    /// Snapshot of `git status --porcelain` for the open project. Refreshed
    /// when the root changes and after any sidebar operation that touches files.
    private let gitStatus = GitStatus()

    /// Watches the project directory for external changes (other editors, git
    /// operations, build tools) and auto-refreshes git status + file tree.
    private var directoryWatcher: DirectoryWatcher?

    // Footer: gray divider + branch icon + branch name. Hidden (height 0)
    // when the project root isn't a git repo.
    private let dividerView = NSView()
    private let branchContainer = NSView()
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let cursorPositionLabel = NSTextField(labelWithString: "")
    private var dividerHeight: NSLayoutConstraint!
    private var branchContainerHeight: NSLayoutConstraint!
    private var branchIconWidth: NSLayoutConstraint!
    private var branchIconHeight: NSLayoutConstraint!
    private var cursorPositionText: String = ""

    // Header: black bar with folder/repo name at the top of the sidebar.
    private let headerContainer = NSView()
    private let headerDivider = NSView()
    private let headerIcon = NSImageView()
    private let headerLabel = NSTextField(labelWithString: "")
    private var headerHeight: NSLayoutConstraint!
    private var headerIconWidth: NSLayoutConstraint!
    private var headerIconHeight: NSLayoutConstraint!

    /// Fired when the user clicks a file row (not a directory).
    var onSelect: ((URL) -> Void)?

    /// Fired after an inline rename succeeds. The editor uses this to retarget
    /// `currentURL` if the renamed file is the one it has open.
    var onRename: ((_ from: URL, _ to: URL) -> Void)?

    /// Fired when the file system watcher detects external changes. The editor
    /// uses this to recompute gutter diff strips for the active tab.
    var onExternalChange: (() -> Void)?

    // Inline-rename state. The text field is held weakly because cell views are
    // recycled — if the row scrolls offscreen mid-rename the field can vanish.
    private var renamingNode: FileNode?
    private weak var renamingTextField: NSTextField?

    override init(frame: NSRect) {
        outlineView = IconAlignedOutlineView()
        scrollView = NSScrollView()
        super.init(frame: frame)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.backgroundColor = Theme.sidebarBackground
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.indentationPerLevel = 14
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = ceil(cellFont.boundingRectForFont.height) + 4
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleClick(_:))
        outlineView.doubleAction = #selector(handleDoubleClick(_:))
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.sidebarBackground
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller = MinimalScroller()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        setupBranchFooter()
        setupHeader()
        dividerHeight = dividerView.heightAnchor.constraint(equalToConstant: 0)
        branchContainerHeight = branchContainer.heightAnchor.constraint(equalToConstant: 0)
        branchIconWidth = branchIcon.widthAnchor.constraint(equalToConstant: iconSize)
        branchIconHeight = branchIcon.heightAnchor.constraint(equalToConstant: iconSize)
        headerHeight = headerContainer.heightAnchor.constraint(equalToConstant: 0)
        headerIconWidth = headerIcon.widthAnchor.constraint(equalToConstant: iconSize)
        headerIconHeight = headerIcon.heightAnchor.constraint(equalToConstant: iconSize)
        NSLayoutConstraint.activate([
            // Leave a 1px gap at the top so SidebarView.draw can paint the
            // window-spanning gray border that meets the tab bar's top line.
            headerContainer.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            headerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerHeight,

            headerIcon.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 12),
            headerIcon.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            headerIconWidth,
            headerIconHeight,

            headerLabel.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 7),
            headerLabel.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -8),
            headerLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor, constant: 1),

            headerDivider.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            headerDivider.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: dividerView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            dividerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: branchContainer.topAnchor),
            dividerHeight,

            branchContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            branchContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            branchContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            branchContainerHeight,

            branchIcon.leadingAnchor.constraint(equalTo: branchContainer.leadingAnchor, constant: 12),
            branchIcon.centerYAnchor.constraint(equalTo: branchContainer.centerYAnchor),
            branchIconWidth,
            branchIconHeight,

            branchLabel.leadingAnchor.constraint(equalTo: branchIcon.trailingAnchor, constant: 7),
            branchLabel.trailingAnchor.constraint(lessThanOrEqualTo: cursorPositionLabel.leadingAnchor, constant: -8),
            branchLabel.centerYAnchor.constraint(equalTo: branchContainer.centerYAnchor),

            cursorPositionLabel.trailingAnchor.constraint(equalTo: branchContainer.trailingAnchor, constant: -8),
            cursorPositionLabel.centerYAnchor.constraint(equalTo: branchContainer.centerYAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gutterBorder.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Re-bind background colors from `Theme` after settings.yaml changes.
    func applyTheme() {
        outlineView.backgroundColor = Theme.sidebarBackground
        scrollView.backgroundColor = Theme.sidebarBackground
        outlineView.needsDisplay = true
        scrollView.needsDisplay = true
    }

    func setRowFont(_ font: NSFont) {
        cellFont = font
        applyRowHeight()
        updateHeader()
        updateBranchFooter()
        outlineView.reloadData()
    }

    private func applyRowHeight() {
        outlineView.rowHeight = ceil(cellFont.boundingRectForFont.height) + 4
    }

    func setRoot(_ url: URL?) {
        os_log(.info, log: sidebarLog, "setRoot: %{public}@", url?.path ?? "<nil>")
        directoryWatcher?.stop()
        directoryWatcher = nil

        if let url = url {
            rootNode = FileNode(url: url)
            directoryWatcher = DirectoryWatcher(directory: url) { [weak self] in
                os_log(.info, log: sidebarLog, "DirectoryWatcher callback invoked")
                self?.refreshGitStatusAsync()
                self?.onExternalChange?()
            }
            os_log(.info, log: sidebarLog, "DirectoryWatcher created for %{public}@", url.path)
        } else {
            rootNode = nil
        }
        gitStatus.setRoot(url)
        updateHeader()
        updateBranchFooter()
        outlineView.reloadData()
    }

    /// Drop cached children and reload. Expansion state is lost — acceptable for v1.
    func refresh() {
        rootNode?.invalidate()
        gitStatus.refresh()
        updateBranchFooter()
        outlineView.reloadData()
    }

    /// Re-read git status without touching the file tree.
    func refreshGitStatus() {
        os_log(.info, log: sidebarLog, "refreshGitStatus() called (sync)")
        gitStatus.refresh()
        updateBranchFooter()
        reloadVisibleRowColors()
    }

    /// Non-blocking variant used by the file system watcher. Runs `git status`
    /// on a background queue and dispatches UI updates back to the main thread.
    private func refreshGitStatusAsync() {
        os_log(.info, log: sidebarLog, "refreshGitStatusAsync() dispatching to background")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            os_log(.info, log: sidebarLog, "refreshGitStatusAsync() background — calling gitStatus.refresh()")
            self?.gitStatus.refresh()
            DispatchQueue.main.async { [weak self] in
                os_log(.info, log: sidebarLog, "refreshGitStatusAsync() main thread — updating UI, clearing %d diff overrides",
                       self?.diffOverrides.count ?? 0)
                self?.diffOverrides.removeAll()
                self?.updateBranchFooter()
                self?.reloadVisibleRowColors()
            }
        }
    }

    /// Update text colors on visible rows without calling reloadData (which
    /// destroys selection, first responder, and inline-rename state).
    private func reloadVisibleRowColors() {
        let visible = outlineView.rows(in: outlineView.visibleRect)
        os_log(.info, log: sidebarLog, "reloadVisibleRowColors() — %d visible rows (loc=%d len=%d)",
               visible.length, visible.location, visible.length)
        var colored = 0
        for row in visible.location..<(visible.location + visible.length) {
            guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView,
                  let node = outlineView.item(atRow: row) as? FileNode else { continue }
            let color = textColor(for: node)
            cell.textField?.textColor = color
            if color != Theme.sidebarText { colored += 1 }
        }
        os_log(.info, log: sidebarLog, "reloadVisibleRowColors() — %d rows colored", colored)
    }

    /// One-time wiring of the header bar that shows the folder name.
    private func setupHeader() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.wantsLayer = true
        headerContainer.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(headerContainer)

        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        headerDivider.wantsLayer = true
        headerDivider.layer?.backgroundColor = Theme.gutterBorder.cgColor
        headerContainer.addSubview(headerDivider)

        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        headerIcon.contentTintColor = Theme.gutterBorder
        headerContainer.addSubview(headerIcon)

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.drawsBackground = false
        headerLabel.isBordered = false
        headerLabel.isEditable = false
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.font = cellFont
        headerLabel.textColor = Theme.gutterBorder
        headerContainer.addSubview(headerLabel)
    }

    /// Show/hide the header and update its text when the root changes.
    private func updateHeader() {
        let name = rootNode?.url.lastPathComponent
        let visible = name != nil
        headerLabel.stringValue = name ?? ""
        headerLabel.font = cellFont
        headerIcon.image = symbolImage(named: "chevron.down", pointSize: iconSize * 0.85)
        headerIconWidth.constant = iconSize
        headerIconHeight.constant = iconSize
        headerHeight.constant = visible ? 32 : 0
    }

    /// One-time wiring of the divider + branch row subviews. Layout constraints
    /// are added separately in init alongside the scroll view's; visibility is
    /// driven by `updateBranchFooter`.
    private func setupBranchFooter() {
        dividerView.translatesAutoresizingMaskIntoConstraints = false
        dividerView.wantsLayer = true
        dividerView.layer?.backgroundColor = Theme.gutterBorder.cgColor
        addSubview(dividerView)

        branchContainer.translatesAutoresizingMaskIntoConstraints = false
        branchContainer.wantsLayer = true
        branchContainer.layer?.backgroundColor = Theme.sidebarBackground.cgColor
        addSubview(branchContainer)

        branchIcon.translatesAutoresizingMaskIntoConstraints = false
        branchIcon.imageScaling = .scaleProportionallyUpOrDown
        branchIcon.contentTintColor = Theme.sidebarText
        branchContainer.addSubview(branchIcon)

        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        branchLabel.drawsBackground = false
        branchLabel.isBordered = false
        branchLabel.isEditable = false
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.textColor = Theme.sidebarText
        branchContainer.addSubview(branchLabel)

        cursorPositionLabel.translatesAutoresizingMaskIntoConstraints = false
        cursorPositionLabel.drawsBackground = false
        cursorPositionLabel.isBordered = false
        cursorPositionLabel.isEditable = false
        cursorPositionLabel.lineBreakMode = .byClipping
        cursorPositionLabel.textColor = Theme.sidebarText
        cursorPositionLabel.alignment = .right
        cursorPositionLabel.setContentHuggingPriority(.required, for: .horizontal)
        cursorPositionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        branchContainer.addSubview(cursorPositionLabel)
    }

    /// Show/hide the divider + branch row, refresh the icon (so it tracks font
    /// size changes) and label. Called after any git refresh and any font change.
    private func updateBranchFooter() {
        let branch = gitStatus.currentBranch
        let visible = branch != nil || !cursorPositionText.isEmpty

        // Collapsing the heights to 0 (rather than just hiding) lets the file
        // list reclaim the footer's space when there's nothing to show.
        dividerHeight.constant = visible ? 1 : 0
        branchContainerHeight.constant = visible ? max(iconSize + 10, 24) : 0
        branchIconWidth.constant = 0
        branchIconHeight.constant = 0

        branchIcon.image = nil
        branchLabel.font = cellFont
        branchLabel.stringValue = branch != nil ? "⎇ \(branch!)" : ""
        cursorPositionLabel.font = cellFont
        cursorPositionLabel.stringValue = cursorPositionText
    }

    /// Update the cursor-position readout shown on the right side of the footer.
    /// Pass an empty string to hide it.
    func setCursorPosition(_ text: String) {
        cursorPositionText = text
        updateBranchFooter()
    }

    /// Refresh only the directory containing `url`, preserving expansion of
    /// unrelated sub-trees. No-op if the directory isn't part of the loaded tree
    /// (e.g., the file lives in a sub-folder that's never been expanded — it'll
    /// appear naturally when the user expands it).
    func refreshDirectory(containing url: URL) {
        guard let root = rootNode else { return }
        let parent = url.deletingLastPathComponent()
        guard let target = findNode(matching: parent, in: root) else { return }
        target.reloadChildren()
        // NSOutlineView's data source uses `nil` for the root.
        outlineView.reloadItem(target === root ? nil : target, reloadChildren: true)
    }

    private func findNode(matching url: URL, in node: FileNode) -> FileNode? {
        if node.url.path == url.path { return node }
        if !node.isDirectory { return nil }
        for child in node.cachedChildren {
            if let found = findNode(matching: url, in: child) { return found }
        }
        return nil
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico", "svg"
    ]

    @objc private func handleClick(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            toggle(node)
        } else if Self.imageExtensions.contains(node.url.pathExtension.lowercased()) {
            NSWorkspace.shared.open(node.url)
        } else {
            onSelect?(node.url)
        }
    }

    @objc private func handleDoubleClick(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            toggle(node)
        }
    }

    private func toggle(_ node: FileNode) {
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    // MARK: Right-click menu

    /// Dynamic menu — items are rebuilt on each open so we can hide Paste on files
    /// (and on directories when the pasteboard has nothing to paste). NSMenuDelegate.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let node = clickedNode() {
            appendItem(menu, "Copy", #selector(copyClicked(_:)))
            if node.isDirectory && pasteboardHasFileURLs() {
                appendItem(menu, "Paste", #selector(pasteClicked(_:)))
            }
            menu.addItem(.separator())
            appendItem(menu, "Rename", #selector(renameClicked(_:)))
            if node.isDirectory {
                appendItem(menu, "New File", #selector(newFileClicked(_:)))
                appendItem(menu, "New Folder", #selector(newFolderClicked(_:)))
            }
            menu.addItem(.separator())
            appendItem(menu, "Delete", #selector(deleteClicked(_:)))
        } else if rootNode != nil {
            // Empty-space click: create-in-root actions only.
            appendItem(menu, "New File", #selector(newFileClicked(_:)))
            appendItem(menu, "New Folder", #selector(newFolderClicked(_:)))
        }
    }

    private func appendItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func clickedNode() -> FileNode? {
        let row = outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? FileNode
    }

    /// Reload only the renamed/deleted item's parent subtree so other expanded
    /// directories keep their state.
    private func reloadParent(of node: FileNode) {
        gitStatus.refresh()
        if let parent = outlineView.parent(forItem: node) as? FileNode {
            parent.reloadChildren()
            outlineView.reloadItem(parent, reloadChildren: true)
        } else {
            rootNode?.reloadChildren()
            outlineView.reloadData()
        }
    }

    @objc private func copyClicked(_ sender: Any?) {
        guard let node = clickedNode() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([node.url as NSURL])
    }

    @objc private func pasteClicked(_ sender: Any?) {
        guard let target = clickedNode(), target.isDirectory else { return }
        let sources = pasteboardFileURLs()
        guard !sources.isEmpty else { return }

        let fm = FileManager.default
        for src in sources {
            let dst = uniqueDestination(in: target.url, fromName: src.lastPathComponent)
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                NSAlert(error: error).runModal()
                break
            }
        }

        // Refresh the target subtree and reveal its contents so the new file is visible.
        gitStatus.refresh()
        target.reloadChildren()
        outlineView.reloadItem(target, reloadChildren: true)
        outlineView.expandItem(target)
    }

    private func pasteboardHasFileURLs() -> Bool {
        return !pasteboardFileURLs().isEmpty
    }

    private func pasteboardFileURLs() -> [URL] {
        let pb = NSPasteboard.general
        let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        return urls.filter { $0.isFileURL }
    }

    /// Pick a non-colliding destination URL inside `folder` for a given source name.
    /// On collision, suffix the basename with " 2", " 3", … (Finder convention).
    private func uniqueDestination(in folder: URL, fromName name: String) -> URL {
        let candidate = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let nextName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let next = folder.appendingPathComponent(nextName)
            if !FileManager.default.fileExists(atPath: next.path) {
                return next
            }
            n += 1
        }
    }

    @objc private func renameClicked(_ sender: Any?) {
        guard let node = clickedNode() else { return }
        beginRename(of: node)
    }

    /// Switch the row's text field into edit mode and focus it. Shared by the
    /// Rename menu action and the New File / New Folder flow (which drop straight
    /// into rename so the user can replace "untitled" without an extra step).
    private func beginRename(of node: FileNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView,
              let textField = cell.textField else { return }

        renamingNode = node
        renamingTextField = textField
        textField.isEditable = true
        textField.isSelectable = true
        textField.delegate = self
        window?.makeFirstResponder(textField)

        // Pre-select the basename so typing replaces just the name; users keep the
        // extension by default but can shift-arrow to extend if they want it gone.
        if let editor = textField.currentEditor() {
            let name = textField.stringValue
            if !node.isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex {
                let baseLength = name.distance(from: name.startIndex, to: dot)
                editor.selectedRange = NSRange(location: 0, length: baseLength)
            } else {
                editor.selectAll(nil)
            }
        }
    }

    @objc private func newFileClicked(_ sender: Any?) {
        createItem(isDirectory: false, defaultName: "untitled")
    }

    @objc private func newFolderClicked(_ sender: Any?) {
        createItem(isDirectory: true, defaultName: "untitled folder")
    }

    /// Resolve the target folder, write the new item to disk, refresh that
    /// subtree, and drop the freshly-created node into rename mode so the user
    /// can name it without an extra click.
    private func createItem(isDirectory: Bool, defaultName: String) {
        guard let target = newItemTargetFolder() else { return }
        let url = uniqueDestination(in: target.url, fromName: defaultName)
        do {
            if isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try Data().write(to: url, options: .withoutOverwriting)
            }
        } catch {
            NSAlert(error: error).runModal()
            return
        }

        gitStatus.refresh()
        target.reloadChildren()
        if target === rootNode {
            outlineView.reloadData()
        } else {
            outlineView.reloadItem(target, reloadChildren: true)
            outlineView.expandItem(target)
        }

        if let newNode = target.cachedChildren.first(where: { $0.url == url }) {
            beginRename(of: newNode)
        }
    }

    /// The folder that should receive a new file/folder for the current right-click.
    /// Directory rows create inside themselves; empty-space clicks create in root.
    private func newItemTargetFolder() -> FileNode? {
        if let node = clickedNode(), node.isDirectory {
            return node
        }
        if outlineView.clickedRow == -1 {
            return rootNode
        }
        return nil
    }

    @objc private func deleteClicked(_ sender: Any?) {
        guard let node = clickedNode() else { return }
        let alert = NSAlert()
        alert.messageText = "Move \u{201C}\(node.displayName)\u{201D} to Trash?"
        alert.informativeText = "You can restore it from the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        NSWorkspace.shared.recycle([node.url]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    NSAlert(error: error).runModal()
                    return
                }
                self.reloadParent(of: node)
            }
        }
    }

    // MARK: NSTextFieldDelegate (inline rename commit)

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField,
              textField === renamingTextField,
              let node = renamingNode else { return }

        let newName = textField.stringValue
        let oldName = node.displayName

        // Restore the field to its label-style appearance regardless of outcome.
        textField.isEditable = false
        textField.isSelectable = false
        textField.delegate = nil
        renamingNode = nil
        renamingTextField = nil

        if newName.isEmpty || newName == oldName {
            textField.stringValue = oldName
            return
        }

        let oldURL = node.url
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } catch {
            NSAlert(error: error).runModal()
            textField.stringValue = oldName
            return
        }
        onRename?(oldURL, newURL)
        reloadParent(of: node)
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootNode?.children.count ?? 0
        }
        guard let node = item as? FileNode else { return 0 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootNode!.children[index]
        }
        let node = item as! FileNode
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return node.isDirectory
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        return SidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        let cell: FileCellView
        if let recycled = outlineView.makeView(withIdentifier: identifier, owner: self) as? FileCellView {
            cell = recycled
        } else {
            cell = FileCellView()
            cell.identifier = identifier
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(imageView)
            cell.imageView = imageView
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.drawsBackground = false
            textField.isBordered = false
            textField.isEditable = false
            textField.lineBreakMode = .byTruncatingTail
            textField.font = cellFont
            textField.textColor = Theme.sidebarText
            cell.addSubview(textField)
            cell.textField = textField
            cell.iconWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: iconSize)
            cell.iconHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: iconSize)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                cell.iconWidthConstraint,
                cell.iconHeightConstraint,
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = node.displayName
        cell.textField?.font = cellFont
        cell.textField?.textColor = textColor(for: node)
        cell.iconWidthConstraint.constant = iconSize
        cell.iconHeightConstraint.constant = iconSize

        // Reset before deciding — cells get reused, so a previous icon could otherwise
        // bleed onto a folder or unrecognized file.
        cell.imageView?.image = nil
        cell.imageView?.contentTintColor = nil
        if node.isDirectory {
            let symbol = outlineView.isItemExpanded(node) ? "chevron.down" : "chevron.right"
            // Chevrons render visually heavier than the language SVGs at the same point
            // size, so we draw them a few points smaller to match the visual weight.
            cell.imageView?.image = symbolImage(named: symbol, pointSize: iconSize - 5)
            cell.imageView?.contentTintColor = Theme.sidebarText
        } else {
            var languageImage: NSImage? = nil
            let syntax = Syntax.from(url: node.url)
            if let sf = syntax?.sfSymbolName {
                // SF Symbol takes priority — used for languages (e.g. Swift) whose
                // devicon SVG masks badly because it ships as a colored badge.
                languageImage = symbolImage(named: sf)
            } else if let iconPath = syntax?.iconPath {
                languageImage = IconCache.shared.image(forPath: iconPath) { [weak outlineView, weak node] in
                    guard let outlineView = outlineView, let node = node else { return }
                    outlineView.reloadItem(node)
                }
            }
            if let languageImage = languageImage {
                cell.imageView?.image = languageImage
                cell.imageView?.contentTintColor = Theme.sidebarText
            } else {
                // Fallback: generic text-document glyph for unknown extensions and as a
                // placeholder while a language icon is still being fetched from the CDN.
                cell.imageView?.image = symbolImage(named: "doc.text")
                cell.imageView?.contentTintColor = Theme.sidebarText
            }
        }
        return cell
    }

    /// Build an SF Symbol image sized to track the cell font. Without an explicit
    /// SymbolConfiguration the symbol renders at its natural ~13pt regardless of
    /// the imageView frame, so it would stay tiny when the editor font grows.
    /// `pointSize` overrides the default (`iconSize`) — used by chevrons, which
    /// look too heavy when sized identically to the language SVGs.
    private func symbolImage(named name: String, pointSize: CGFloat? = nil) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize ?? iconSize, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// Per-file overrides set directly by the editor when it knows a file's diff
    /// state (e.g. after save). Takes priority over gitStatus lookups.
    private var diffOverrides: [String: Bool] = [:]

    /// Mark a file as modified (has changes) or clean based on diff results.
    /// Immediately updates visible row colors so the filename color updates.
    func markFile(_ url: URL, hasChanges: Bool) {
        os_log(.info, log: sidebarLog, "markFile(%{public}@, hasChanges: %{public}@)",
               url.lastPathComponent, hasChanges ? "true" : "false")
        diffOverrides[url.path] = hasChanges
        reloadVisibleRowColors()
    }

    /// Foreground color for a row's filename. Defaults to `Theme.sidebarText`,
    /// switching to muted green for untracked files and muted yellow for files
    /// git considers modified.
    private func textColor(for node: FileNode) -> NSColor {
        if let override = diffOverrides[node.url.path] {
            os_log(.info, log: sidebarLog, "textColor(%{public}@) override=%{public}@",
                   node.url.lastPathComponent, override ? "modified" : "clean")
            return override ? Theme.gitModified : Theme.sidebarText
        }
        let result = gitStatus.status(for: node.url)
        if result != nil {
            os_log(.info, log: sidebarLog, "textColor(%{public}@) git=%{public}@",
                   node.url.lastPathComponent,
                   result == .untracked ? "untracked" : "modified")
        }
        switch result {
        case .untracked: return Theme.gitUntracked
        case .modified:  return Theme.gitModified
        case nil:        return Theme.sidebarText
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? FileNode {
            outlineView.reloadItem(node)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? FileNode {
            outlineView.reloadItem(node)
        }
    }
}

// MARK: - Workspace (sidebar + gutter container, splittable)

final class WorkspaceView: NSSplitView, NSSplitViewDelegate {
    let sidebar: SidebarView
    let editorPane: EditorPaneView
    var gutterContainer: GutterContainerView { editorPane.gutterContainer }
    var tabBar: TabBarView { editorPane.tabBar }
    private(set) var currentFolder: URL?
    private var savedSidebarWidth: CGFloat = 220
    private let defaultSidebarWidth: CGFloat = 220
    private let minSidebarWidth: CGFloat = 120
    private let minEditorWidth: CGFloat = 300

    override var dividerColor: NSColor { Theme.gutterBorder }

    init(editorPane: EditorPaneView) {
        self.sidebar = SidebarView(frame: .zero)
        self.editorPane = editorPane
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        addSubview(sidebar)
        addSubview(editorPane)
        setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        setHoldingPriority(.defaultLow,  forSubviewAt: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Start collapsed so single-file mode is identical to pre-sidebar layout.
        if currentFolder == nil {
            setPosition(0, ofDividerAt: 0)
        }
    }

    func setRootFolder(_ url: URL?) {
        currentFolder = url
        sidebar.setRoot(url)
        if url == nil {
            collapseSidebar()
        } else {
            expandSidebar(toWidth: savedSidebarWidth > 0 ? savedSidebarWidth : defaultSidebarWidth)
        }
    }

    func toggleSidebar() {
        guard currentFolder != nil else { return }
        if isSubviewCollapsed(sidebar) {
            expandSidebar(toWidth: savedSidebarWidth)
        } else {
            collapseSidebar()
        }
    }

    func refreshSidebar() {
        sidebar.refresh()
    }

    private func expandSidebar(toWidth width: CGFloat) {
        layoutSubtreeIfNeeded()
        setPosition(width, ofDividerAt: 0)
    }

    private func collapseSidebar() {
        if !isSubviewCollapsed(sidebar) {
            savedSidebarWidth = max(sidebar.frame.width, minSidebarWidth)
        }
        setPosition(0, ofDividerAt: 0)
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return subview === sidebar
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        return isSubviewCollapsed(sidebar)
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        return minSidebarWidth
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        return max(minSidebarWidth, splitView.bounds.width - minEditorWidth)
    }
}
