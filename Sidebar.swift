import AppKit

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

// MARK: - Sidebar (file tree)

final class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outlineView: NSOutlineView
    private let scrollView: NSScrollView
    private var rootNode: FileNode?

    private let cellFont: NSFont = NSFont(name: "Menlo", size: 12)
        ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Fired when the user clicks a file row (not a directory).
    var onSelect: ((URL) -> Void)?

    override init(frame: NSRect) {
        outlineView = NSOutlineView()
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
        outlineView.rowSizeStyle = .small
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleClick(_:))
        outlineView.doubleAction = #selector(handleDoubleClick(_:))

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.sidebarBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setRoot(_ url: URL?) {
        if let url = url {
            rootNode = FileNode(url: url)
        } else {
            rootNode = nil
        }
        outlineView.reloadData()
    }

    /// Drop cached children and reload. Expansion state is lost — acceptable for v1.
    func refresh() {
        rootNode?.invalidate()
        outlineView.reloadData()
    }

    @objc private func handleClick(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if !node.isDirectory {
            onSelect?(node.url)
        }
    }

    @objc private func handleDoubleClick(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        }
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

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        let cell: NSTableCellView
        if let recycled = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = recycled
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
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
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = node.displayName
        return cell
    }
}

// MARK: - Workspace (sidebar + gutter container, splittable)

final class WorkspaceView: NSSplitView, NSSplitViewDelegate {
    let sidebar: SidebarView
    let gutterContainer: GutterContainerView
    private(set) var currentFolder: URL?
    private var savedSidebarWidth: CGFloat = 220
    private let defaultSidebarWidth: CGFloat = 220
    private let minSidebarWidth: CGFloat = 120
    private let minEditorWidth: CGFloat = 300

    init(gutterContainer: GutterContainerView) {
        self.sidebar = SidebarView(frame: .zero)
        self.gutterContainer = gutterContainer
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        addSubview(sidebar)
        addSubview(gutterContainer)
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
