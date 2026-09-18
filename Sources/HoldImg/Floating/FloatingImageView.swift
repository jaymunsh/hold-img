import AppKit
import UniformTypeIdentifiers

/// Content view of a floating panel: draws the image aspect-fit and handles
/// move, resize, zoom, copy, and context-menu interactions.
final class FloatingImageView: NSView {
    private let image: NSImage

    private enum Corner {
        case none, topLeft, topRight, bottomLeft, bottomRight
    }

    private var dragStartGlobal: CGPoint = .zero
    private var dragStartFrame: CGRect = .zero
    private var dragCorner: Corner = .none
    private var didMove = false

    private let cornerSize: CGFloat = 14
    private let minDimension: CGFloat = 32
    private let maxDimension: CGFloat = 8192

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.close()
            return
        }
        dragStartGlobal = NSEvent.mouseLocation
        dragStartFrame = window?.frame ?? .zero
        dragCorner = corner(at: convert(event.locationInWindow, from: nil))
        didMove = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - dragStartGlobal.x
        let dy = mouse.y - dragStartGlobal.y
        if abs(dx) + abs(dy) > 2 { didMove = true }
        if dragCorner == .none {
            window.setFrameOrigin(CGPoint(x: dragStartFrame.minX + dx,
                                          y: dragStartFrame.minY + dy))
        } else {
            resize(to: mouse)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !didMove, dragCorner == .none {
            panel?.copyImageToPasteboard()
            flashCopyFeedback()
        }
        dragCorner = .none
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        if event.modifierFlags.contains(.option) {
            let delta = event.scrollingDeltaY > 0 ? 0.05 : -0.05
            window.alphaValue = min(max(window.alphaValue + delta, 0.1), 1)
            return
        }
        let factor = max(0.05, 1 + event.scrollingDeltaY * 0.02)
        zoom(by: factor, anchoredAt: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let panel else { return }
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "복사", action: #selector(copyAction), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        let saveItem = menu.addItem(withTitle: "다른 이름으로 저장…", action: #selector(saveAction), keyEquivalent: "s")
        saveItem.keyEquivalentModifierMask = .command
        menu.addItem(.separator())

        let topItem = menu.addItem(withTitle: "항상 위에 표시", action: #selector(toggleAlwaysOnTop), keyEquivalent: "t")
        topItem.state = panel.alwaysOnTop ? .on : .off
        let ghostItem = menu.addItem(withTitle: "클릭-스루 모드", action: #selector(toggleClickThrough), keyEquivalent: "g")
        ghostItem.state = panel.clickThrough ? .on : .off

        let opacityMenu = NSMenu()
        for value in [1.0, 0.75, 0.5, 0.25] {
            let item = opacityMenu.addItem(
                withTitle: "\(Int(value * 100))%",
                action: #selector(setOpacity(_:)),
                keyEquivalent: ""
            )
            item.tag = Int(value * 100)
            item.state = abs(panel.alphaValue - value) < 0.01 ? .on : .off
        }
        let opacityItem = menu.addItem(withTitle: "투명도", action: nil, keyEquivalent: "")
        menu.setSubmenu(opacityMenu, for: opacityItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "닫기", action: #selector(closeAction), keyEquivalent: "\u{1b}")
        menu.items.forEach { $0.target = self }
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    // MARK: - Context menu actions

    @objc private func copyAction() {
        panel?.copyImageToPasteboard()
        flashCopyFeedback()
    }

    @objc private func saveAction() {
        guard let panel else { return }
        ClipboardService.saveWithPanel(image: panel.image)
    }

    @objc private func toggleAlwaysOnTop() {
        panel?.alwaysOnTop.toggle()
    }

    @objc private func toggleClickThrough() {
        panel?.clickThrough.toggle()
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        window?.alphaValue = CGFloat(sender.tag) / 100
    }

    @objc private func closeAction() {
        window?.close()
    }

    // MARK: - Feedback

    func flashCopyFeedback() {
        let flash = NSView(frame: bounds)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.white.cgColor
        flash.layer?.opacity = 0.4
        flash.autoresizingMask = [.width, .height]
        addSubview(flash)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            flash.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                flash.removeFromSuperview()
            }
        }
    }

    // MARK: - Geometry

    private var panel: FloatingPanel? { window as? FloatingPanel }

    private func corner(at point: CGPoint) -> Corner {
        let w = bounds.width, h = bounds.height
        let nearLeft = point.x < cornerSize, nearRight = point.x > w - cornerSize
        let nearBottom = point.y < cornerSize, nearTop = point.y > h - cornerSize
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        return .none
    }

    /// Aspect-preserving resize: the corner opposite to the dragged one stays fixed.
    private func resize(to mouseGlobal: CGPoint) {
        guard let window else { return }
        let f = dragStartFrame
        let aspect = f.width / f.height

        let anchor: CGPoint
        switch dragCorner {
        case .bottomRight: anchor = f.origin
        case .bottomLeft:  anchor = CGPoint(x: f.maxX, y: f.minY)
        case .topRight:    anchor = CGPoint(x: f.minX, y: f.maxY)
        case .topLeft:     anchor = CGPoint(x: f.maxX, y: f.maxY)
        case .none:        return
        }

        var newW = abs(mouseGlobal.x - anchor.x)
        var newH = abs(mouseGlobal.y - anchor.y)
        if newW / max(newH, 1) > aspect {
            newW = newH * aspect
        } else {
            newH = newW / aspect
        }
        newW = min(max(newW, minDimension), maxDimension)
        newH = newW / aspect
        guard newH >= minDimension else { return }

        let origin = CGPoint(
            x: mouseGlobal.x >= anchor.x ? anchor.x : anchor.x - newW,
            y: mouseGlobal.y >= anchor.y ? anchor.y : anchor.y - newH
        )
        window.setFrame(CGRect(origin: origin, size: CGSize(width: newW, height: newH)),
                        display: true)
    }

    private func zoom(by factor: CGFloat, anchoredAt viewPoint: CGPoint) {
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        let fracX = viewPoint.x / bounds.width
        let fracY = viewPoint.y / bounds.height
        let frame = window.frame
        var newW = frame.width * factor
        var newH = frame.height * factor
        if newW < minDimension || newH < minDimension { return }
        newW = min(newW, maxDimension)
        newH = min(newH, maxDimension)
        let mouse = NSEvent.mouseLocation
        let origin = CGPoint(x: mouse.x - newW * fracX,
                             y: mouse.y - newH * fracY)
        window.setFrame(CGRect(origin: origin, size: CGSize(width: newW, height: newH)),
                        display: true)
    }
}
