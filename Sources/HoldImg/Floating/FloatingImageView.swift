import AppKit
import UniformTypeIdentifiers

/// Content view of a floating panel: draws the image aspect-fit and handles
/// move, resize, zoom, copy, annotation, and context-menu interactions.
final class FloatingImageView: NSView {
    var image: NSImage {
        didSet { needsDisplay = true }
    }

    private enum Corner {
        case none, topLeft, topRight, bottomLeft, bottomRight
    }

    /// Freehand annotation in normalized (0...1) image coordinates so strokes
    /// stay aligned when the panel is resized or zoomed.
    private struct Stroke {
        var points: [CGPoint]
        var color: NSColor
        var widthNorm: CGFloat  // fraction of image height
    }

    private var dragStartGlobal: CGPoint = .zero
    private var dragStartFrame: CGRect = .zero
    private var dragCorner: Corner = .none
    private var didMove = false

    private(set) var isPenMode = false
    private var strokes: [Stroke] = []
    private var activeStroke: Stroke?
    private var penColorIndex = 0
    private var hoverTracking: NSTrackingArea?

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
        for stroke in strokes + [activeStroke].compactMap({ $0 }) {
            stroke.color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = max(stroke.widthNorm * bounds.height, 0.5)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for (i, p) in stroke.points.enumerated() {
                let v = denormalize(p)
                i == 0 ? path.move(to: v) : path.line(to: v)
            }
            path.stroke()
        }
    }

    // MARK: - Hover tracking / toolbar

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverTracking { removeTrackingArea(t) }
        hoverTracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(hoverTracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        panel?.hoverToolbar.show()
    }

    override func mouseExited(with event: NSEvent) {
        if !isPenMode { panel?.hoverToolbar.hide() }
    }

    override func mouseMoved(with event: NSEvent) {
        if isPenMode { NSCursor.crosshair.set() }
    }

    // MARK: - Pen mode

    func enterPenMode() {
        isPenMode = true
        NSCursor.crosshair.set()
    }

    func exitPenMode(bake: Bool) {
        if bake, let baked = bakeAnnotations() {
            image = baked
            panel?.setImage(baked)
        }
        strokes.removeAll()
        activeStroke = nil
        isPenMode = false
        needsDisplay = true
    }

    func undoStroke() {
        if activeStroke != nil {
            activeStroke = nil
        } else {
            strokes.popLast()
        }
        needsDisplay = true
    }

    func clearStrokes() {
        strokes.removeAll()
        activeStroke = nil
        needsDisplay = true
    }

    func selectPenColor(_ index: Int) {
        penColorIndex = index
    }

    private func normalize(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / max(bounds.width, 1), y: p.y / max(bounds.height, 1))
    }

    private func denormalize(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * bounds.width, y: p.y * bounds.height)
    }

    private func clampNorm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }

    private func beginStroke(at point: CGPoint) {
        activeStroke = Stroke(points: [normalize(point)],
                              color: PanelToolbar.penColors[penColorIndex],
                              widthNorm: 3.0 / max(bounds.height, 1))
    }

    private func appendStroke(at point: CGPoint) {
        let prev = activeStroke?.points.last.map(denormalize)
        activeStroke?.points.append(normalize(point))
        // Repaint only the new segment instead of the whole image per event.
        let a = prev ?? point
        let pad = max((activeStroke?.widthNorm ?? 0) * bounds.height, 0.5) + 2
        setNeedsDisplay(CGRect(x: min(a.x, point.x) - pad, y: min(a.y, point.y) - pad,
                               width: abs(point.x - a.x) + pad * 2,
                               height: abs(point.y - a.y) + pad * 2))
    }

    private func endStroke() {
        guard var stroke = activeStroke else { return }
        if stroke.points.count == 1 {
            // A single tap: nudge a second point so a round dot is drawn.
            stroke.points.append(CGPoint(x: stroke.points[0].x + 0.002,
                                         y: stroke.points[0].y))
        }
        strokes.append(stroke)
        activeStroke = nil
        needsDisplay = true
    }

    /// Renders the strokes onto the image at its native pixel size.
    private func bakeAnnotations() -> NSImage? {
        guard !strokes.isEmpty,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let pxW = cg.width, pxH = cg.height
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes {
            ctx.setStrokeColor(stroke.color.cgColor)
            ctx.setLineWidth(max(stroke.widthNorm * CGFloat(pxH), 0.5))
            for (i, raw) in stroke.points.enumerated() {
                let p = clampNorm(raw)
                let v = CGPoint(x: p.x * CGFloat(pxW), y: p.y * CGFloat(pxH))
                i == 0 ? ctx.move(to: v) : ctx.addLine(to: v)
            }
            ctx.strokePath()
        }
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        rep.size = image.size
        let result = NSImage(size: image.size)
        result.addRepresentation(rep)
        return result
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if isPenMode {
            beginStroke(at: convert(event.locationInWindow, from: nil))
            return
        }
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
        if isPenMode {
            appendStroke(at: convert(event.locationInWindow, from: nil))
            return
        }
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
        if isPenMode {
            endStroke()
            return
        }
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
        menu.addItem(withTitle: "펜으로 표시", action: #selector(penAction), keyEquivalent: "p")
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

    @objc private func penAction() {
        guard let panel else { return }
        enterPenMode()
        panel.hoverToolbar.setMode(.pen)
        panel.hoverToolbar.show()
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
