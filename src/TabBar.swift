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
    var onReorder: ((_ from: Int, _ to: Int) -> Void)?
    /// Fires when the user right-clicks a tab. The Pane uses this to show its
    /// "Split Vertically / Horizontally" menu.
    var onContextMenu: ((_ index: Int, _ event: NSEvent) -> Void)?
    /// Fires on mouseUp when the cursor sits outside this bar's bounds. Return
    /// true if the coordinator consumed the drop (e.g. transferred the tab to
    /// another pane); otherwise the bar treats it as a no-op.
    var onTabDropOutsideBar: ((_ sourceIndex: Int, _ windowPoint: NSPoint) -> Bool)?

    /// Live array of tab item views in their current visual order — used by
    /// the editor coordinator when computing the insertion index for a tab
    /// dropped from another pane.
    var arrangedTabViews: [TabItemView] {
        return stack.arrangedSubviews.compactMap { $0 as? TabItemView }
    }

    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let documentView = NSView()
    private(set) var tabFont: NSFont = NSFont(name: "Menlo", size: 13)
        ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

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

    func setFont(_ font: NSFont) {
        tabFont = font
        for case let tab as TabItemView in stack.arrangedSubviews {
            tab.updateFont(font)
        }
    }

    func update(items: [TabBarItem], activeIndex: Int) {
        for v in stack.arrangedSubviews { stack.removeView(v) }
        for (i, item) in items.enumerated() {
            let view = TabItemView(item: item, isActive: i == activeIndex, font: tabFont)
            view.onMouseDown = { [weak self] tab, event in
                self?.handleTabMouseDown(tab: tab, event: event)
            }
            view.onClose = { [weak self] in
                guard let self = self,
                      let idx = self.stack.arrangedSubviews.firstIndex(of: view) else { return }
                self.onClose?(idx)
            }
            view.onRightMouseDown = { [weak self] tab, event in
                guard let self = self,
                      let idx = self.stack.arrangedSubviews.firstIndex(of: tab) else { return }
                self.onContextMenu?(idx, event)
            }
            stack.addArrangedSubview(view)
        }
        needsDisplay = true
    }

    /// Threshold (in points) the cursor must travel before a press becomes a
    /// drag. Below this, the gesture is treated as a click.
    private static let dragThreshold: CGFloat = 4

    /// Distinguishes a click from a drag-reorder. Runs a modal event loop and
    /// either reorders tabs in place (firing onReorder on release) or fires
    /// onSelect for a plain click. While dragging, the tab is translated via a
    /// layer transform so it visually tracks the cursor; neighbors swap
    /// underneath it as the cursor crosses their midpoints.
    private func handleTabMouseDown(tab: TabItemView, event: NSEvent) {
        guard let window = self.window,
              let originalIndex = stack.arrangedSubviews.firstIndex(of: tab) else { return }

        let downInBar = convert(event.locationInWindow, from: nil)
        let initialMidX = tab.frame.midX
        var didDrag = false

        tab.wantsLayer = true

        trackingLoop: while true {
            guard let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { continue }
            switch next.type {
            case .leftMouseDragged:
                let pointInBar = convert(next.locationInWindow, from: nil)
                if !didDrag {
                    if abs(pointInBar.x - downInBar.x) < TabBarView.dragThreshold &&
                       abs(pointInBar.y - downInBar.y) < TabBarView.dragThreshold {
                        continue
                    }
                    didDrag = true
                    // Lift the dragged tab above its neighbors so the swapping
                    // siblings slide underneath it rather than over.
                    tab.layer?.zPosition = 1
                }
                let dragOffset = pointInBar.x - downInBar.x
                let desiredMidX = initialMidX + dragOffset

                swapNeighbor(of: tab, towardCenterX: desiredMidX)
                stack.layoutSubtreeIfNeeded()

                // Visual position = layout position + this transform. Recomputing
                // each tick keeps the cursor "glued" to the tab even after swaps
                // shift the tab into a different slot.
                let translateBy = desiredMidX - tab.frame.midX
                tab.layer?.setAffineTransform(CGAffineTransform(translationX: translateBy, y: 0))
            case .leftMouseUp:
                tab.layer?.zPosition = 0
                tab.layer?.setAffineTransform(.identity)
                if didDrag {
                    let pointInBar = convert(next.locationInWindow, from: nil)
                    let droppedOutside = !bounds.contains(pointInBar)
                    if droppedOutside,
                       let handler = onTabDropOutsideBar,
                       handler(originalIndex, next.locationInWindow) {
                        // Coordinator transferred the tab to another pane. The
                        // source pane will rebuild its tab bar shortly.
                    } else {
                        let finalIndex = stack.arrangedSubviews.firstIndex(of: tab) ?? originalIndex
                        if finalIndex != originalIndex {
                            onReorder?(originalIndex, finalIndex)
                        } else {
                            onSelect?(originalIndex)
                        }
                    }
                } else {
                    onSelect?(originalIndex)
                }
                break trackingLoop
            default:
                break
            }
        }
    }

    /// If `desiredCenterX` has crossed the midpoint of an adjacent arranged
    /// subview, swap `tab` past it. At most one swap per call so the stack
    /// animates one neighbor at a time even when the cursor jumps.
    private func swapNeighbor(of tab: TabItemView, towardCenterX desiredCenterX: CGFloat) {
        let arranged = stack.arrangedSubviews
        guard let currentIndex = arranged.firstIndex(of: tab) else { return }

        var neighbor: NSView?
        var newIndex = currentIndex

        if currentIndex > 0 {
            let left = arranged[currentIndex - 1]
            if desiredCenterX < left.frame.midX {
                neighbor = left
                newIndex = currentIndex - 1
            }
        }
        if neighbor == nil, currentIndex < arranged.count - 1 {
            let right = arranged[currentIndex + 1]
            if desiredCenterX > right.frame.midX {
                neighbor = right
                newIndex = currentIndex + 1
            }
        }
        guard let movedNeighbor = neighbor else { return }

        let oldNeighborMinX = movedNeighbor.frame.minX
        stack.removeArrangedSubview(tab)
        stack.insertArrangedSubview(tab, at: newIndex)
        stack.layoutSubtreeIfNeeded()
        slideAnimation(view: movedNeighbor, fromDeltaX: oldNeighborMinX - movedNeighbor.frame.minX)
    }

    /// Visually slide `view` from `fromDeltaX` (relative to its now-current
    /// layout position) back to identity. Used to animate neighbors that have
    /// just been displaced by a tab swap.
    private func slideAnimation(view: NSView, fromDeltaX dx: CGFloat) {
        guard dx != 0 else { return }
        view.wantsLayer = true
        let anim = CABasicAnimation(keyPath: "transform.translation.x")
        anim.fromValue = dx
        anim.toValue = 0
        anim.duration = 0.18
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.layer?.add(anim, forKey: "tabSlide")
    }
}

// MARK: - Single tab cell

final class TabItemView: NSView {
    var onMouseDown: ((TabItemView, NSEvent) -> Void)?
    var onRightMouseDown: ((TabItemView, NSEvent) -> Void)?
    var onClose: (() -> Void)?

    private let item: TabBarItem
    private let isActive: Bool
    private let label = NSTextField(labelWithString: "")
    private let dirtyDot = NSView()
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(item: TabBarItem, isActive: Bool, font: NSFont) {
        self.item = item
        self.isActive = isActive
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = item.title
        label.font = font
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

    func updateFont(_ font: NSFont) {
        label.font = font
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()

        Theme.gutterBorder.setFill()
        // Bottom border
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        // Right border — also serves as the divider before the next tab.
        // We deliberately omit a left border so the leftmost tab doesn't double
        // up with the workspace split divider, and so adjacent tabs share a
        // single 1pt line rather than stacking right-of-N and left-of-N+1.
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()

        if isActive {
            // Thicker white top border for the active tab
            Theme.foreground.setFill()
            NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 2).fill()
        } else {
            // 1px gray top border for inactive tabs
            Theme.gutterBorder.setFill()
            NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(self, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(self, event)
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
    /// Editor content (gutter + scroll view + text view). Always retained so
    /// switching back from a terminal tab restores the same instance.
    let gutterContainer: GutterContainerView
    /// Container that holds the currently visible content (either
    /// gutterContainer for editor tabs or a TerminalView for terminal tabs).
    private let contentArea: NSView
    private weak var activeContent: NSView?

    init(tabBar: TabBarView, gutterContainer: GutterContainerView) {
        self.tabBar = tabBar
        self.gutterContainer = gutterContainer
        self.contentArea = NSView()
        super.init(frame: .zero)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)
        addSubview(contentArea)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            contentArea.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setActiveContent(gutterContainer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Swap the visible content view. The previous one is detached but kept
    /// alive by its owner (the Pane for editor content, the DocumentTab's
    /// TerminalState for terminal content).
    func setActiveContent(_ view: NSView) {
        if activeContent === view { return }
        activeContent?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentArea.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])
        activeContent = view
    }
}
