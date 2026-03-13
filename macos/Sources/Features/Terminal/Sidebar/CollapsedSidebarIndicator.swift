import Cocoa

/// A thin indicator view shown at the left edge when the sidebar is collapsed.
/// Clicking it (or pressing Cmd+S) expands the sidebar back.
class CollapsedSidebarIndicator: NSView {
    /// Called when the user clicks the indicator to expand the sidebar.
    var onExpand: (() -> Void)?

    /// The base color for the strip, derived from terminal background.
    var baseColor: NSColor = .controlBackgroundColor {
        didSet { updateStripAppearance() }
    }

    private let stripLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var widthConstraint: NSLayoutConstraint?

    static let collapsedWidth: CGFloat = 6
    private static let hoveredWidth: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(stripLayer)
        updateStripAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.addSublayer(stripLayer)
        updateStripAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        animateWidth(Self.hoveredWidth)
        updateStripAppearance()
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        animateWidth(Self.collapsedWidth)
        updateStripAppearance()
        NSCursor.pop()
    }

    private func animateWidth(_ width: CGFloat) {
        if widthConstraint == nil {
            widthConstraint = constraints.first { $0.firstAttribute == .width }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            widthConstraint?.constant = width
            superview?.layoutSubtreeIfNeeded()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onExpand?()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stripLayer.frame = bounds
        CATransaction.commit()
    }

    private func updateStripAppearance() {
        // Slightly brighter than the terminal background; extra lighten on hover
        let brightened = baseColor.blended(withFraction: 0.12, of: .white) ?? baseColor
        stripLayer.backgroundColor = isHovered
            ? (brightened.highlight(withLevel: 0.15)?.cgColor ?? brightened.cgColor)
            : brightened.cgColor
    }
}
