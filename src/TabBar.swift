import AppKit

// MARK: - Tab bar
//
// Visual-only component. Editor owns the source of truth (the array of
// DocumentTabs) and rebuilds the bar by calling `update(items:activeIndex:)`
// after any tab-state change. Click and close events fire as callbacks.

struct TabBarItem {
    let title: String
    let dirty: Bool
}

final class TabBarView: NSView {
    static let height: CGFloat = 32

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let documentView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor),
            documentView.heightAnchor.constraint(equalToConstant: TabBarView.height),
        ])

        scroll.documentView = documentView
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric, height: TabBarView.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        Theme.gutterBorder.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        // Bottom border — separates the tab strip from the editor below.
        path.move(to: NSPoint(x: 0, y: 0.5))
        path.line(to: NSPoint(x: bounds.maxX, y: 0.5))
        // Top border — separates the strip from the title bar above. Tab cells
        // cover their own area, so they paint a matching line themselves.
        path.move(to: NSPoint(x: 0, y: bounds.maxY - 0.5))
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        path.stroke()
    }

    func update(items: [TabBarItem], activeIndex: Int) {
        for v in stack.arrangedSubviews { stack.removeView(v) }
        for (i, item) in items.enumerated() {
            let view = TabItemView(item: item, isActive: i == activeIndex)
            view.onClick = { [weak self] in self?.onSelect?(i) }
            view.onClose = { [weak self] in self?.onClose?(i) }
            stack.addArrangedSubview(view)
        }
        needsDisplay = true
    }
}

// MARK: - Single tab cell

final class TabItemView: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?

    private let item: TabBarItem
    private let isActive: Bool
    private let label = NSTextField(labelWithString: "")
    private let dirtyDot = NSView()
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(item: TabBarItem, isActive: Bool) {
        self.item = item
        self.isActive = isActive
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = item.title
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = isActive ? Theme.foreground : Theme.gutterText
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        dirtyDot.wantsLayer = true
        dirtyDot.layer?.backgroundColor = (isActive ? Theme.foreground : Theme.gutterText).cgColor
        dirtyDot.layer?.cornerRadius = 3
        dirtyDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dirtyDot)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.contentTintColor = Theme.gutterText
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: dirtyDot.leadingAnchor, constant: -8),

            dirtyDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dirtyDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dirtyDot.widthAnchor.constraint(equalToConstant: 6),
            dirtyDot.heightAnchor.constraint(equalToConstant: 6),

            closeButton.centerXAnchor.constraint(equalTo: dirtyDot.centerXAnchor),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),

            heightAnchor.constraint(equalToConstant: TabBarView.height),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])

        updateRightSlot()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        if isActive {
            // 2px foreground accent — punches through the gray top border with a
            // brighter color so the active tab is unambiguous.
            Theme.foreground.setFill()
            NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 2).fill()
        } else {
            // 1px top edge that matches the strip's gray line so the separator
            // reads continuously across the bar.
            Theme.gutterBorder.setFill()
            NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    @objc private func handleClose() {
        onClose?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateRightSlot()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateRightSlot()
    }

    /// Right-side slot shows close-button on hover, dirty-dot otherwise (only if dirty).
    private func updateRightSlot() {
        if isHovered {
            closeButton.isHidden = false
            dirtyDot.isHidden = true
        } else {
            closeButton.isHidden = true
            dirtyDot.isHidden = !item.dirty
        }
    }
}

// MARK: - Editor pane (tab bar + gutter container, stacked vertically)

final class EditorPaneView: NSView {
    let tabBar: TabBarView
    let gutterContainer: GutterContainerView

    init(tabBar: TabBarView, gutterContainer: GutterContainerView) {
        self.tabBar = tabBar
        self.gutterContainer = gutterContainer
        super.init(frame: .zero)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        gutterContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)
        addSubview(gutterContainer)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            gutterContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            gutterContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutterContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            gutterContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}
