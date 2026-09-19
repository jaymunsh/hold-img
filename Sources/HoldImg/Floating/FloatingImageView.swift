import AppKit
import CoreText
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

    /// A drawn annotation in normalized (0...1) image coordinates so it
    /// stays aligned when the panel is resized or zoomed.
    private struct Annotation {
        enum Shape {
            case freehand([CGPoint])
            case arrow(from: CGPoint, to: CGPoint)
            case rect(CGRect)
            case mosaic(CGRect)
            case text(String, CGPoint)
        }
        var shape: Shape
        var color: NSColor
        var widthNorm: CGFloat  // fraction of image height
    }

    enum AnnotationTool: Int {
        case pen, arrow, rect, mosaic, text
    }

    private var dragStartGlobal: CGPoint = .zero
    private var dragStartFrame: CGRect = .zero
    private var dragCorner: Corner = .none
    private var didMove = false

    /// Right-button drag state: down arms, drag starts a file drag,
    /// up without movement opens the context menu.
    private var rightDownPoint: CGPoint?
    private var rightDragActive = false

    /// Frame saved when the panel is collapsed to thumbnail by double-click.
    private var expandedFrame: CGRect?
    private var dragFileURL: URL?

    private(set) var isPenMode = false
    private var annotations: [Annotation] = []
    private var activeStroke: [CGPoint]?
    private var dragAnchor: CGPoint?
    private var activeShape: Annotation.Shape?
    private var tool: AnnotationTool = .pen
    private var textField: NSTextField?
    private var penColorIndex = 0
    private var hoverTracking: NSTrackingArea?

    /// Transient size readout shown while resizing/zooming (overlay only —
    /// never baked into the image).
    private lazy var sizeBadge: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        label.layer?.cornerRadius = 6
        label.alphaValue = 0
        label.isHidden = true
        addSubview(label)
        return label
    }()
    private var sizeBadgeTimer: Timer?

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
        for ann in annotations {
            drawAnnotation(ann.shape, color: ann.color, widthNorm: ann.widthNorm)
        }
        if let pts = activeStroke {
            drawAnnotation(.freehand(pts), color: penColor, widthNorm: strokeWidthNorm)
        }
        if let shape = activeShape {
            drawAnnotation(shape, color: penColor, widthNorm: strokeWidthNorm)
        }
    }

    private var penColor: NSColor { PanelToolbar.penColors[penColorIndex] }
    private var strokeWidthNorm: CGFloat { 3.0 / max(bounds.height, 1) }
    private var textFontNorm: CGFloat { 0.05 }

    private func drawAnnotation(_ shape: Annotation.Shape,
                                color: NSColor, widthNorm: CGFloat) {
        let lw = max(widthNorm * bounds.height, 0.5)
        switch shape {
        case .freehand(let points):
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = lw
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for (i, p) in points.enumerated() {
                let v = denormalize(p)
                i == 0 ? path.move(to: v) : path.line(to: v)
            }
            path.stroke()
        case .arrow(let a, let b):
            color.setStroke()
            let path = arrowPath(from: denormalize(a), to: denormalize(b),
                                 headLength: lw * 5)
            path.lineWidth = lw
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        case .rect(let r):
            color.setStroke()
            let path = NSBezierPath(rect: denormalizeRect(r))
            path.lineWidth = lw
            path.stroke()
        case .mosaic(let r):
            drawMosaic(in: denormalizeRect(r))
        case .text(let s, let p):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: textFontNorm * bounds.height,
                                         weight: .bold),
                .foregroundColor: color,
            ]
            NSAttributedString(string: s, attributes: attrs)
                .draw(at: denormalize(p))
        }
    }

    /// Line from `a` to `b` with a V-shaped arrowhead at `b`.
    private func arrowPath(from a: CGPoint, to b: CGPoint,
                           headLength: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        let angle = atan2(b.y - a.y, b.x - a.x)
        for side in [-1.0, 1.0] as [CGFloat] {
            let a2 = angle + CGFloat.pi + side * (CGFloat.pi / 6)
            path.move(to: b)
            path.line(to: CGPoint(x: b.x + headLength * cos(a2),
                                  y: b.y + headLength * sin(a2)))
        }
        return path
    }

    /// Reusable downscale buffer for mosaic rendering — allocating an
    /// NSImage and locking focus per draw call is expensive during drags.
    private var mosaicScratch: NSBitmapImageRep?

    /// Pixelates a region of the image (view coordinates) as a live
    /// preview for the mosaic tool.
    private func drawMosaic(in viewRect: CGRect) {
        let factor: CGFloat = 12
        let smallSize = CGSize(width: max(viewRect.width / factor, 1),
                               height: max(viewRect.height / factor, 1))
        let sx = image.size.width / max(bounds.width, 1)
        let sy = image.size.height / max(bounds.height, 1)
        let src = CGRect(x: viewRect.minX * sx, y: viewRect.minY * sy,
                         width: viewRect.width * sx, height: viewRect.height * sy)
        let w = Int(smallSize.width.rounded(.up))
        let h = Int(smallSize.height.rounded(.up))
        if let rep = mosaicScratch, rep.pixelsWide < w || rep.pixelsHigh < h {
            mosaicScratch = nil
        }
        if mosaicScratch == nil {
            mosaicScratch = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        }
        guard let rep = mosaicScratch,
              let repCtx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = repCtx
        image.draw(in: NSRect(origin: .zero, size: smallSize), from: src,
                   operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        rep.draw(in: viewRect,
                 from: NSRect(origin: .zero, size: smallSize),
                 operation: .sourceOver, fraction: 1,
                 respectFlipped: true, hints: nil)
        NSGraphicsContext.current?.restoreGraphicsState()
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
        // Nonactivating panel: this only takes key status inside this app,
        // so hovered panels can receive ⌘W/keys without stealing app focus.
        window?.makeKey()
    }

    override func mouseExited(with event: NSEvent) {
        if !isPenMode { panel?.hoverToolbar.hide() }
    }

    override func mouseMoved(with event: NSEvent) {
        if isPenMode { NSCursor.crosshair.set() }
    }

    // MARK: - Annotation mode

    func enterPenMode() {
        isPenMode = true
        NSCursor.crosshair.set()
    }

    func exitPenMode(bake: Bool) {
        commitTextField()
        if bake, let baked = bakeAnnotations() {
            image = baked
            panel?.setImage(baked)
        }
        annotations.removeAll()
        activeStroke = nil
        activeShape = nil
        dragAnchor = nil
        isPenMode = false
        needsDisplay = true
    }

    func selectTool(_ index: Int) {
        tool = AnnotationTool(rawValue: index) ?? .pen
        commitTextField()
        NSCursor.crosshair.set()
    }

    func undoStroke() {
        if activeStroke != nil || activeShape != nil {
            activeStroke = nil
            activeShape = nil
        } else {
            _ = annotations.popLast()
        }
        needsDisplay = true
    }

    func clearStrokes() {
        annotations.removeAll()
        activeStroke = nil
        activeShape = nil
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

    private func denormalizeRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * bounds.width, y: r.minY * bounds.height,
               width: r.width * bounds.width, height: r.height * bounds.height)
    }

    private func clampNorm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }

    /// Shape preview for drag-based tools (arrow / rect / mosaic).
    private func shapeFrom(anchor: CGPoint, to current: CGPoint) -> Annotation.Shape {
        let a = normalize(anchor), b = normalize(current)
        switch tool {
        case .arrow:
            return .arrow(from: a, to: b)
        case .rect, .mosaic:
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(b.x - a.x), height: abs(b.y - a.y))
            return tool == .rect ? .rect(r) : .mosaic(r)
        case .pen, .text:
            return .freehand([a, b])
        }
    }

    /// View-space bounds of a shape, used for partial invalidation.
    private func shapeBounds(_ shape: Annotation.Shape) -> CGRect {
        switch shape {
        case .freehand(let points):
            guard let first = points.first else { return .null }
            var r = CGRect(origin: denormalize(first), size: .zero)
            for p in points.dropFirst() {
                r = r.union(CGRect(origin: denormalize(p), size: .zero))
            }
            return r
        case .arrow(let a, let b):
            let va = denormalize(a), vb = denormalize(b)
            return CGRect(x: min(va.x, vb.x), y: min(va.y, vb.y),
                          width: abs(vb.x - va.x), height: abs(vb.y - va.y))
        case .rect(let r), .mosaic(let r):
            return denormalizeRect(r)
        case .text(let s, let p):
            let size = NSAttributedString(
                string: s,
                attributes: [.font: NSFont.systemFont(
                    ofSize: textFontNorm * bounds.height, weight: .bold)]
            ).size()
            return CGRect(origin: denormalize(p), size: size)
        }
    }

    private func beginStroke(at point: CGPoint) {
        activeStroke = [normalize(point)]
    }

    private func appendStroke(at point: CGPoint) {
        let prev = activeStroke?.last.map(denormalize)
        activeStroke?.append(normalize(point))
        // Repaint only the new segment instead of the whole image per event.
        let a = prev ?? point
        let pad = max(strokeWidthNorm * bounds.height, 0.5) + 2
        setNeedsDisplay(CGRect(x: min(a.x, point.x) - pad, y: min(a.y, point.y) - pad,
                               width: abs(point.x - a.x) + pad * 2,
                               height: abs(point.y - a.y) + pad * 2))
    }

    private func endStroke() {
        guard var pts = activeStroke else { return }
        if pts.count == 1 {
            // A single tap: nudge a second point so a round dot is drawn.
            pts.append(CGPoint(x: pts[0].x + 0.002, y: pts[0].y))
        }
        annotations.append(Annotation(shape: .freehand(pts), color: penColor,
                                      widthNorm: strokeWidthNorm))
        activeStroke = nil
        needsDisplay = true
    }

    // MARK: - Text annotation input

    private func showTextInput(at viewPoint: CGPoint) {
        commitTextField()
        let fontSize = textFontNorm * bounds.height
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y - 2,
                                              width: 180,
                                              height: max(fontSize + 8, 22)))
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        field.textColor = penColor
        field.target = self
        field.action = #selector(textFieldCommitted(_:))
        field.delegate = self
        addSubview(field)
        textField = field
        // Defer until the click that spawned the field has finished, or the
        // field editor may not be ready to take first responder.
        DispatchQueue.main.async { [weak self, weak field] in
            self?.window?.makeFirstResponder(field)
        }
    }

    @objc private func textFieldCommitted(_ sender: NSTextField) {
        commitTextField()
    }

    /// Adds the field's text as an annotation (or just removes the field
    /// when the text is empty), returning focus to the panel.
    private func commitTextField() {
        guard let field = textField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            // Anchor = the text's top-left in normalized coordinates.
            let p = CGPoint(x: field.frame.minX / max(bounds.width, 1),
                            y: (field.frame.maxY - 4) / max(bounds.height, 1))
            annotations.append(Annotation(shape: .text(text, p),
                                          color: penColor,
                                          widthNorm: strokeWidthNorm))
        }
        field.removeFromSuperview()
        textField = nil
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    /// Renders the annotations onto the image at its native pixel size.
    private func bakeAnnotations() -> NSImage? {
        guard !annotations.isEmpty,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let pxW = CGFloat(cg.width), pxH = CGFloat(cg.height)
        guard let ctx = CGContext(data: nil, width: Int(pxW), height: Int(pxH),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for ann in annotations {
            let lw = max(ann.widthNorm * pxH, 0.5)
            switch ann.shape {
            case .freehand(let points):
                ctx.setStrokeColor(ann.color.cgColor)
                ctx.setLineWidth(lw)
                for (i, raw) in points.enumerated() {
                    let p = clampNorm(raw)
                    let v = CGPoint(x: p.x * pxW, y: p.y * pxH)
                    i == 0 ? ctx.move(to: v) : ctx.addLine(to: v)
                }
                ctx.strokePath()
            case .arrow(let a, let b):
                ctx.setStrokeColor(ann.color.cgColor)
                ctx.setLineWidth(lw)
                bakeArrow(ctx, from: CGPoint(x: a.x * pxW, y: a.y * pxH),
                          to: CGPoint(x: b.x * pxW, y: b.y * pxH),
                          headLength: lw * 5)
            case .rect(let r):
                ctx.setStrokeColor(ann.color.cgColor)
                ctx.setLineWidth(lw)
                ctx.stroke(CGRect(x: r.minX * pxW, y: r.minY * pxH,
                                  width: r.width * pxW, height: r.height * pxH))
            case .mosaic(let r):
                bakeMosaic(ctx, source: cg,
                           rect: CGRect(x: r.minX * pxW, y: r.minY * pxH,
                                        width: r.width * pxW, height: r.height * pxH),
                           canvasH: pxH)
            case .text(let s, let p):
                bakeText(ctx, s, at: CGPoint(x: p.x * pxW, y: p.y * pxH),
                         fontSize: textFontNorm * pxH, color: ann.color)
            }
        }
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        rep.size = image.size
        let result = NSImage(size: image.size)
        result.addRepresentation(rep)
        return result
    }

    private func bakeArrow(_ ctx: CGContext, from a: CGPoint, to b: CGPoint,
                           headLength: CGFloat) {
        ctx.move(to: a)
        ctx.addLine(to: b)
        let angle = atan2(b.y - a.y, b.x - a.x)
        for side in [-1.0, 1.0] as [CGFloat] {
            let a2 = angle + CGFloat.pi + side * (CGFloat.pi / 6)
            ctx.move(to: b)
            ctx.addLine(to: CGPoint(x: b.x + headLength * cos(a2),
                                    y: b.y + headLength * sin(a2)))
        }
        ctx.strokePath()
    }

    /// Downscales then re-scales the rect region so it is baked pixelated.
    private func bakeMosaic(_ ctx: CGContext, source cg: CGImage,
                            rect: CGRect, canvasH: CGFloat) {
        let factor: CGFloat = 12
        // CGImage rows are top-down; the context draws bottom-up.
        let cropRect = CGRect(x: rect.minX, y: canvasH - rect.maxY,
                              width: rect.width, height: rect.height)
        guard let crop = cg.cropping(to: cropRect) else { return }
        let w = max(Int(rect.width / factor), 1)
        let h = max(Int(rect.height / factor), 1)
        guard let small = CGContext(data: nil, width: w, height: h,
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        small.interpolationQuality = .low
        small.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let sImg = small.makeImage() else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.draw(sImg, in: rect)
        ctx.restoreGState()
    }

    /// Draws text with CoreText so it is not flipped in the CG context.
    private func bakeText(_ ctx: CGContext, _ s: String, at topLeft: CGPoint,
                          fontSize: CGFloat, color: NSColor) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let attrStr = NSAttributedString(string: s, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        // topLeft is the text's top edge; place the baseline under it.
        ctx.textPosition = CGPoint(x: topLeft.x,
                                   y: topLeft.y - font.ascender)
        CTLineDraw(line, ctx)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if isPenMode {
            let p = convert(event.locationInWindow, from: nil)
            switch tool {
            case .pen:
                beginStroke(at: p)
            case .arrow, .rect, .mosaic:
                dragAnchor = p
                activeShape = nil
            case .text:
                showTextInput(at: p)
            }
            return
        }
        if event.clickCount == 2 {
            toggleCollapsed()
            return
        }
        dragStartGlobal = NSEvent.mouseLocation
        dragStartFrame = window?.frame ?? .zero
        dragCorner = corner(at: convert(event.locationInWindow, from: nil))
        didMove = false
    }

    override func mouseDragged(with event: NSEvent) {
        if isPenMode {
            let p = convert(event.locationInWindow, from: nil)
            switch tool {
            case .pen:
                appendStroke(at: p)
            case .arrow, .rect, .mosaic:
                guard let anchor = dragAnchor else { return }
                // Repaint the union of old and new preview bounds.
                var dirty = activeShape.map { shapeBounds($0) } ?? .null
                activeShape = shapeFrom(anchor: anchor, to: p)
                dirty = dirty.union(shapeBounds(activeShape!))
                setNeedsDisplay(dirty.insetBy(dx: -8, dy: -8).intersection(bounds))
            case .text:
                break
            }
            return
        }
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - dragStartGlobal.x
        let dy = mouse.y - dragStartGlobal.y
        if abs(dx) + abs(dy) > 2 { didMove = true }
        if dragCorner == .none {
            let proposed = CGRect(x: dragStartFrame.minX + dx,
                                  y: dragStartFrame.minY + dy,
                                  width: dragStartFrame.width,
                                  height: dragStartFrame.height)
            window.setFrameOrigin(snappedOrigin(for: proposed))
        } else {
            resize(to: mouse)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isPenMode {
            if tool == .pen {
                endStroke()
            } else if let shape = activeShape {
                annotations.append(Annotation(shape: shape, color: penColor,
                                              widthNorm: strokeWidthNorm))
                activeShape = nil
            }
            dragAnchor = nil
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
        rightDownPoint = convert(event.locationInWindow, from: nil)
        rightDragActive = false
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard !rightDragActive, let start = rightDownPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard abs(p.x - start.x) + abs(p.y - start.y) > 4 else { return }
        rightDragActive = true
        beginFileDrag(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        defer { rightDownPoint = nil }
        guard !rightDragActive else {
            rightDragActive = false
            return
        }
        showContextMenu(with: event)
    }

    /// GrabIt-style: drag the panel with the right button to drop the image
    /// into Finder or any app accepting files/images.
    private func beginFileDrag(with event: NSEvent) {
        guard let panel else { return }
        let item = NSPasteboardItem()
        if let tiff = panel.image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        if let url = fileURLForDrag() {
            item.setString(url.absoluteString, forType: .fileURL)
        }
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: panel.image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    /// PNG written to a temp file so the drag offers a real file URL.
    private func fileURLForDrag() -> URL? {
        if let dragFileURL { return dragFileURL }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("holdimg-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            dragFileURL = url
            return url
        } catch {
            return nil
        }
    }

    private func showContextMenu(with event: NSEvent) {
        guard let panel else { return }
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "복사", action: #selector(copyAction), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        let saveItem = menu.addItem(withTitle: "다른 이름으로 저장…", action: #selector(saveAction), keyEquivalent: "s")
        saveItem.keyEquivalentModifierMask = .command
        menu.addItem(withTitle: "텍스트 추출 (OCR)", action: #selector(ocrAction), keyEquivalent: "")
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

        menu.addItem(withTitle: "오른쪽으로 회전", action: #selector(rotateAction), keyEquivalent: "r")
        menu.addItem(withTitle: "왼쪽으로 회전", action: #selector(rotateCCWAction), keyEquivalent: "R")
        menu.addItem(withTitle: "좌우 반전", action: #selector(flipAction), keyEquivalent: "f")
        menu.addItem(withTitle: "축소/복원", action: #selector(collapseAction), keyEquivalent: "")
        let closeItem = menu.addItem(withTitle: "닫기", action: #selector(closeAction), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = .command
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

    @objc private func ocrAction() {
        guard let panel else { return }
        if OCRService.copyText(from: panel.image) {
            flashCopyFeedback()
        } else {
            NSSound.beep()
        }
    }

    @objc private func collapseAction() {
        toggleCollapsed()
    }

    @objc private func rotateAction() {
        panel?.rotate(clockwise: true)
    }

    @objc private func rotateCCWAction() {
        panel?.rotate(clockwise: false)
    }

    @objc private func flipAction() {
        panel?.flipHorizontal()
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

    // MARK: - Collapse / snap

    /// GrabIt-style double-click: fold the panel down to a thumbnail,
    /// double-click again to restore the saved frame.
    private func toggleCollapsed() {
        guard let window else { return }
        if let saved = expandedFrame {
            expandedFrame = nil
            window.setFrame(saved, display: true, animate: true)
        } else {
            expandedFrame = window.frame
            let f = window.frame
            let w = min(160, f.width)
            let h = w / max(f.width / max(f.height, 1), 0.01)
            let origin = CGPoint(x: f.midX - w / 2, y: f.midY - h / 2)
            window.setFrame(CGRect(origin: origin, size: CGSize(width: w, height: h)),
                            display: true, animate: true)
        }
    }

    /// Snap the dragged frame to screen edges and other panels' edges and
    /// centers, like Photoshop smart guides.
    private func snappedOrigin(for proposed: CGRect) -> CGPoint {
        guard let window else { return proposed.origin }
        let mouse = NSEvent.mouseLocation
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? window.screen {
            let f = screen.visibleFrame
            xs += [f.minX, f.midX, f.maxX]
            ys += [f.minY, f.midY, f.maxY]
        }
        for p in FloatingWindowManager.shared.panels where p !== window {
            xs += [p.frame.minX, p.frame.midX, p.frame.maxX]
            ys += [p.frame.minY, p.frame.midY, p.frame.maxY]
        }
        let threshold: CGFloat = 8
        var dx: CGFloat = 0, dy: CGFloat = 0, bestX = threshold, bestY = threshold
        for g in xs {
            for edge in [proposed.minX, proposed.midX, proposed.maxX] {
                let d = abs(g - edge)
                if d <= bestX { bestX = d; dx = g - edge }
            }
        }
        for g in ys {
            for edge in [proposed.minY, proposed.midY, proposed.maxY] {
                let d = abs(g - edge)
                if d <= bestY { bestY = d; dy = g - edge }
            }
        }
        return CGPoint(x: proposed.minX + dx, y: proposed.minY + dy)
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

        let locked = panel?.aspectLocked ?? true
        var newW = abs(mouseGlobal.x - anchor.x)
        var newH = abs(mouseGlobal.y - anchor.y)
        if locked {
            if newW / max(newH, 1) > aspect {
                newW = newH * aspect
            } else {
                newH = newW / aspect
            }
        }
        newW = min(max(newW, minDimension), maxDimension)
        newH = locked ? newW / aspect : min(max(newH, minDimension), maxDimension)
        guard newH >= minDimension else { return }

        let origin = CGPoint(
            x: mouseGlobal.x >= anchor.x ? anchor.x : anchor.x - newW,
            y: mouseGlobal.y >= anchor.y ? anchor.y : anchor.y - newH
        )
        window.setFrame(CGRect(origin: origin, size: CGSize(width: newW, height: newH)),
                        display: true)
        showSizeBadge()
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
        showSizeBadge()
    }

    // MARK: - Size badge

    /// Shows the current view dimensions as a transient overlay at the
    /// bottom center of the panel — never baked into the image.
    private func showSizeBadge() {
        let s = bounds.size
        sizeBadge.stringValue =
            "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))"
        sizeBadge.sizeToFit()
        let w = sizeBadge.frame.width + 16
        let h = sizeBadge.frame.height + 8
        sizeBadge.frame = NSRect(x: (s.width - w) / 2,
                                 y: 8, width: w, height: h)
        sizeBadge.isHidden = false
        sizeBadge.alphaValue = 1
        sizeBadgeTimer?.invalidate()
        sizeBadgeTimer = Timer.scheduledTimer(withTimeInterval: 1.0,
                                            repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    self.sizeBadge.animator().alphaValue = 0
                } completionHandler: {
                    Task { @MainActor in
                        self.sizeBadge.isHidden = true
                    }
                }
            }
        }
    }
}

extension FloatingImageView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

extension FloatingImageView: NSTextFieldDelegate {
    /// Esc inside the text field discards just the field, not pen mode.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:))
        else { return false }
        textField?.stringValue = ""
        commitTextField()
        return true
    }
}
