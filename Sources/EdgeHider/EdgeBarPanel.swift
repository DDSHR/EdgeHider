import AppKit

class EdgeBarPanel: NSPanel {
    let pid: pid_t
    var onHover: (() -> Void)?

    init(pid: pid_t, icon: NSImage, screenFrame: CGRect, side: HiddenSide) {
        self.pid = pid
        let horizontal = side == .top || side == .bottom
        let w: CGFloat = horizontal ? 60 : 24, h: CGFloat = horizontal ? 24 : 60
        var origin: CGPoint
        switch side {
        case .left: origin = CGPoint(x: screenFrame.minX, y: screenFrame.midY - h/2)
        case .right: origin = CGPoint(x: screenFrame.maxX - w, y: screenFrame.midY - h/2)
        case .top: origin = CGPoint(x: screenFrame.midX - w/2, y: screenFrame.maxY - h)
        case .bottom: origin = CGPoint(x: screenFrame.midX - w/2, y: screenFrame.minY)
        case .automatic: origin = CGPoint(x: screenFrame.minX, y: screenFrame.midY - h/2)
        }
        super.init(contentRect: CGRect(origin: origin, size: CGSize(width: w, height: h)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false; hasShadow = true; backgroundColor = .clear
        level = .statusBar + 1
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = false; ignoresMouseEvents = false

        let iv = NSImageView(frame: CGRect(x: (w - 20)/2, y: (h - 20)/2, width: 20, height: 20))
        iv.image = icon; iv.imageScaling = .scaleProportionallyDown
        contentView?.addSubview(iv)

        let ta = NSTrackingArea(rect: contentView?.bounds ?? .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        contentView?.addTrackingArea(ta)
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }

    func moveTo(offset: CGFloat, screenFrame: CGRect, side: HiddenSide) {
        var f = frame
        switch side {
        case .left, .automatic: f.origin = CGPoint(x: screenFrame.minX, y: offset)
        case .right: f.origin = CGPoint(x: screenFrame.maxX - f.width, y: offset)
        case .top: f.origin = CGPoint(x: offset, y: screenFrame.maxY - f.height)
        case .bottom: f.origin = CGPoint(x: offset, y: screenFrame.minY)
        }
        setFrame(f, display: true)
    }
}
