import AppKit

// MARK: - Minimal scroll bar
//
// Hover-only overlay scroller: no track, just a slim translucent thumb that
// fades in when the cursor enters the scroller strip and fades out when it leaves.
// The backing layer is forced to clear so the strip the scroller occupies takes
// the surrounding pane's color rather than the layer's default fill.

final class MinimalScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override var isOpaque: Bool { false }

    private var trackingArea: NSTrackingArea?
    private var visibility: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    private var fadeTimer: Timer?
    private let fadeDuration: TimeInterval = 0.18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        scrollerStyle = .overlay
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.backgroundColor = NSColor.clear.cgColor
        layer.isOpaque = false
        return layer
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { animateVisibility(to: 1) }
    override func mouseExited(with event: NSEvent)  { animateVisibility(to: 0) }

    private func animateVisibility(to target: CGFloat) {
        fadeTimer?.invalidate()
        let start = visibility
        let startedAt = Date()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let t = min(CGFloat(Date().timeIntervalSince(startedAt) / self.fadeDuration), 1)
            // Ease-out quadratic for a softer arrival.
            let eased = 1 - (1 - t) * (1 - t)
            self.visibility = start + (target - start) * eased
            if t >= 1 {
                timer.invalidate()
                self.fadeTimer = nil
            }
        }
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // No track.
    }

    override func drawKnob() {
        guard visibility > 0 else { return }
        let knob = rect(for: .knob).insetBy(dx: 3, dy: 2)
        let path = NSBezierPath(
            roundedRect: knob,
            xRadius: knob.width / 2,
            yRadius: knob.width / 2)
        NSColor.white.withAlphaComponent(0.4 * visibility).setFill()
        path.fill()
    }
}
