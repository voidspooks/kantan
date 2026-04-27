import AppKit

// MARK: - Line number gutter

final class GutterView: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    var gutterFont: NSFont = NSFont(name: "Menlo", size: 13)
        ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func viewDidChange(_ note: Notification) { needsDisplay = true }

    override var isFlipped: Bool { return true }

    func refresh() {
        sizeToFitContent()
        needsDisplay = true
    }

    /// Compute the ideal width based on the largest line number we'll need to draw,
    /// then ask whoever owns our layout to grow us. Returns the new width.
    @discardableResult
    func sizeToFitContent() -> CGFloat {
        let lineCount = lineCountInTextView()
        let digits = max(2, String(lineCount).count)
        let sample = String(repeating: "9", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: [.font: gutterFont]).width) + 18
        if abs(width - frame.width) > 0.5 {
            (superview as? GutterContainerView)?.gutterDidRequestWidth(width)
        }
        return width
    }

    private func lineCountInTextView() -> Int {
        guard let text = textView?.string else { return 1 }
        if text.isEmpty { return 1 }
        let nsText = text as NSString
        var count = 1
        for i in 0..<nsText.length where nsText.character(at: i) == 0x0A {
            count += 1
        }
        return count
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gutterBackground.setFill()
        bounds.fill()

        // Right-edge separator (1px, drawn at integer x for crisp line)
        Theme.gutterBorder.setStroke()
        let border = NSBezierPath()
        border.lineWidth = 1
        border.move(to: NSPoint(x: bounds.maxX - 0.5, y: dirtyRect.minY))
        border.line(to: NSPoint(x: bounds.maxX - 0.5, y: dirtyRect.maxY))
        border.stroke()

        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = scrollView else { return }

        let nsText = textView.string as NSString
        let length = nsText.length
        let inset = textView.textContainerInset

        // textView's visible rect (in textView coords) tells us what's currently on screen.
        let docVisibleRect = scrollView.documentVisibleRect
        // Convert: textView coord y -> our (gutter) coord y
        // gutter y = (textView y) + inset.height - docVisibleRect.origin.y
        let yOffset = inset.height - docVisibleRect.origin.y

        let attrs: [NSAttributedString.Key: Any] = [
            .font: gutterFont,
            .foregroundColor: Theme.gutterText
        ]

        func fragmentRect(forCharIndex idx: Int) -> NSRect? {
            if idx >= length {
                if layoutManager.extraLineFragmentTextContainer != nil {
                    return layoutManager.extraLineFragmentRect
                }
                return nil
            }
            // Make sure layout exists for the glyph we're about to query.
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: idx)
            return layoutManager.lineFragmentRect(
                forGlyphAt: glyphIdx,
                effectiveRange: nil,
                withoutAdditionalLayout: false)
        }

        func draw(_ number: Int, in fragment: NSRect) {
            let y = fragment.origin.y + yOffset
            if y + fragment.height < bounds.minY { return }
            if y > bounds.maxY { return }
            let label = "\(number)" as NSString
            let labelSize = label.size(withAttributes: attrs)
            let x = bounds.width - labelSize.width - 8
            label.draw(at: NSPoint(x: x, y: y + (fragment.height - labelSize.height) / 2),
                       withAttributes: attrs)
        }

        // Force layout of the visible portion before we query line fragment rects.
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: docVisibleRect, in: textContainer)
        layoutManager.ensureLayout(forGlyphRange: visibleGlyphRange)

        var lineNumber = 1
        if let r = fragmentRect(forCharIndex: 0) { draw(lineNumber, in: r) }

        for i in 0..<length where nsText.character(at: i) == 0x0A {
            lineNumber += 1
            if let r = fragmentRect(forCharIndex: i + 1) { draw(lineNumber, in: r) }
        }
    }
}

/// Container that lays out the gutter and scroll view side-by-side via Auto Layout.
final class GutterContainerView: NSView {
    private let gutter: GutterView
    private let scroll: NSScrollView
    private let widthConstraint: NSLayoutConstraint

    init(gutter: GutterView, scrollView: NSScrollView) {
        self.gutter = gutter
        self.scroll = scrollView
        self.widthConstraint = gutter.widthAnchor.constraint(equalToConstant: 44)
        super.init(frame: .zero)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addSubview(gutter)

        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func gutterDidRequestWidth(_ width: CGFloat) {
        if abs(width - widthConstraint.constant) > 0.5 {
            widthConstraint.constant = width
        }
    }
}
