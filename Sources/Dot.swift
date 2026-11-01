// The floating dot and the borderless panel that can take keyboard focus.

import AppKit

final class DotView: NSView {
    var onClick: () -> Void = {}
    var onRightClick: (NSEvent) -> Void = { _ in }
    var onMoved: () -> Void = {}

    private let ring = CAShapeLayer()
    private let circle = CAShapeLayer()
    private let badgeBack = CAShapeLayer()
    private let badge = CATextLayer()
    private var pulse: Double = -1
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var dragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let d: CGFloat = 24
        let dotRect = CGRect(x: (frame.width - d) / 2, y: (frame.height - d) / 2, width: d, height: d)
        for l in [ring, circle] {
            l.frame = bounds
            l.path = CGPath(ellipseIn: dotRect, transform: nil)
        }
        ring.opacity = 0
        circle.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        circle.lineWidth = 2
        circle.shadowColor = NSColor.black.cgColor
        circle.shadowOpacity = 0.35
        circle.shadowRadius = 3
        circle.shadowOffset = CGSize(width: 0, height: -1)

        let b = CGRect(x: dotRect.maxX - 9, y: dotRect.maxY - 9, width: 15, height: 15)
        badgeBack.path = CGPath(ellipseIn: b, transform: nil)
        badgeBack.fillColor = NSColor.systemRed.cgColor
        badgeBack.strokeColor = NSColor.white.cgColor
        badgeBack.lineWidth = 1.5
        badge.frame = b.offsetBy(dx: 0, dy: -2)
        badge.fontSize = 9.5
        badge.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        badge.alignmentMode = .center
        badge.foregroundColor = NSColor.white.cgColor
        badge.contentsScale = 2
        [ring, circle, badgeBack, badge].forEach { layer!.addSublayer($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `beat` is seconds per pulse; 0 means steady.
    func show(color: NSColor, alpha: CGFloat, count: Int, beat: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.fillColor = color.withAlphaComponent(alpha).cgColor
        ring.fillColor = color.cgColor
        badge.string = count > 9 ? "9+" : "\(count)"
        badge.isHidden = count == 0
        badgeBack.isHidden = count == 0
        CATransaction.commit()
        guard beat != pulse else { return }
        pulse = beat
        ring.removeAllAnimations()
        guard beat > 0 else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 1.7
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = beat
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "pulse")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - startMouse.x, dy = p.y - startMouse.y
        if hypot(dx, dy) > 3 { dragged = true }
        if dragged { window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)) }
    }

    override func mouseUp(with event: NSEvent) {
        dragged ? onMoved() : onClick()
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick(event) }
}

final class KeyPanel: NSPanel {
    var onEscape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape() }
}
