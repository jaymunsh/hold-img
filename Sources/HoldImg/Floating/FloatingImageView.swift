import AppKit
import CoreText
import UniformTypeIdentifiers

/// Content view of a floating panel: draws the image aspect-fit and handles
/// move, resize, zoom, copy, annotation, and context-menu interactions.
final class FloatingImageView: NSView {
    var image: NSImage {
        didSet { invalidateComposite(); needsDisplay = true }
    }

    private enum ResizeZone {
        case none, topLeft, topRight, bottomLeft, bottomRight,
             left, right, top, bottom
    }

    /// A drawn annotation in normalized (0...1) image coordinates so it
    /// stays aligned when the panel is resized or zoomed.
    private struct Annotation {
        enum Shape {
            case freehand([CGPoint])
            case highlight([CGPoint])
            case arrow(from: CGPoint, to: CGPoint)
            case rect(CGRect)
            case mosaic(CGRect)
            case text(String, CGPoint, fontNorm: CGFloat)
        }
        var shape: Shape
        var color: NSColor
        var widthNorm: CGFloat  // fraction of image height
    }

    enum AnnotationTool: Int {
        case pen, highlighter, arrow, rect, mosaic, text, move
    }

    private var dragStartGlobal: CGPoint = .zero
    private var dragStartFrame: CGRect = .zero
    private var dragZone: ResizeZone = .none
    private var didMove = false

    /// Right-button drag state: down arms, drag starts a file drag,
    /// up without movement opens the context menu.
    private var rightDownPoint: CGPoint?
    private var rightDragActive = false

    /// Frame saved when the panel is collapsed to thumbnail by double-click.
    private var expandedFrame: CGRect?
    private var dragFileURL: URL?

    private(set) var isPenMode = false
    private var annotations: [Annotation] = [] {
        didSet { invalidateComposite() }
    }
    private var activeStroke: [CGPoint]?
    /// Shift+drag axis constraint for the highlighter: nil = undecided,
    /// true = horizontal, false = vertical. Locked on first >4pt movement.
    private var strokeAxisLock: Bool?
    private var dragAnchor: CGPoint?
    private var activeShape: Annotation.Shape?
    /// Text annotation being repositioned: its index and the grab offset
    /// (view coords) between the click point and the text's anchor.
    private var draggingTextIndex: Int?
    private var textDragOffset: CGSize = .zero
    /// Move tool: the annotation being dragged is excluded from the
    /// composite once, then previewed via activeShape until mouse-up.
    private var movingIndex: Int?
    private var moveExcludedIndex: Int?
    private var moveOrigin: Annotation.Shape?
    private var moveStart: CGPoint = .zero
    /// Bounds of the grabbed shape, so a move drag doesn't re-walk every
    /// stroke point per frame — the preview bounds is just this + delta.
    private var moveOriginBounds: CGRect = .null
    private(set) var tool: AnnotationTool = .pen
    private var textEditor: AnnotationTextView?
    /// Top-left anchor (view coords) of the open text editor.
    private var textAnchor: CGPoint = .zero
    private var penColorIndex = 0
    private var hoverTracking: NSTrackingArea?

    /// Transient size readout shown while resizing/zooming (overlay only —
    /// never baked into the image). The container carries the pill styling
    /// so the label can be centered inside it exactly.
    private lazy var sizeBadge: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        v.layer?.cornerRadius = 6
        v.alphaValue = 0
        v.isHidden = true
        addSubview(v)
        return v
    }()
    private lazy var sizeBadgeLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
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

    /// Committed annotations composited with the image at view size —
    /// invalidated on annotation/size/image change so repaint during a
    /// drag doesn't re-render every stroke vector each frame.
    private var compositeCache: NSImage?
    private var compositeSize: CGSize = .zero
    /// True while a resize/zoom gesture is in flight — the stale composite
    /// is drawn scaled instead of re-rendered at the new size every frame,
    /// then rebuilt once the gesture settles.
    private var isLiveResizing = false
    private var resizeSettleTimer: Timer?

    private func invalidateComposite() {
        compositeCache = nil
    }

    private func rebuildComposite() {
        let size = bounds.size
        let cached = NSImage(size: size, flipped: false) { rect in
            self.image.draw(in: rect)
            for (i, ann) in self.annotations.enumerated()
            where i != self.moveExcludedIndex {
                self.drawAnnotation(ann.shape, color: ann.color,
                                    widthNorm: ann.widthNorm)
            }
            return true
        }
        compositeCache = cached
        compositeSize = size
    }

    /// Marks a live resize/zoom frame: skip the cache rebuild and just
    /// scale the previous composite until the gesture ends.
    private func beginLiveResize() {
        isLiveResizing = true
        resizeSettleTimer?.invalidate()
        resizeSettleTimer = Timer.scheduledTimer(withTimeInterval: 0.2,
                                               repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.endLiveResize()
            }
        }
    }

    private func endLiveResize() {
        guard isLiveResizing else { return }
        isLiveResizing = false
        resizeSettleTimer?.invalidate()
        resizeSettleTimer = nil
        invalidateComposite()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if compositeCache == nil || (compositeSize != bounds.size && !isLiveResizing) {
            rebuildComposite()
        }
        compositeCache?.draw(in: bounds)
        if let pts = activeStroke {
            let shape: Annotation.Shape =
                tool == .highlighter ? .highlight(pts) : .freehand(pts)
            drawAnnotation(shape, color: penColor, widthNorm: currentWidthNorm)
        }
        if let shape = activeShape {
            if let mi = movingIndex, mi < annotations.count {
                let ann = annotations[mi]
                drawAnnotation(shape, color: ann.color,
                               widthNorm: ann.widthNorm)
            } else {
                drawAnnotation(shape, color: penColor,
                               widthNorm: strokeWidthNorm)
            }
        }
    }

    private var penColor: NSColor { PanelToolbar.penColors[penColorIndex] }
    private var strokeWidthNorm: CGFloat { 3.0 / max(bounds.height, 1) }
    /// Highlighter band: screen-fixed ~20pt like the pen's 3pt.
    private var highlightWidthNorm: CGFloat { 20.0 / max(bounds.height, 1) }
    /// Shared by the live draw and the bake pass so both render identically.
    private let highlightAlpha: CGFloat = 0.25
    private var currentWidthNorm: CGFloat {
        tool == .highlighter ? highlightWidthNorm : strokeWidthNorm
    }
    /// Text annotation size, adjustable with ⌘+/⌘- — stored per annotation.
    private(set) var textSizeNorm: CGFloat = 0.05

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
        case .highlight(let points):
            // Marker stroke: translucent, wide, flat ends — reads as a
            // rectangular band along the drag path.
            color.withAlphaComponent(highlightAlpha).setStroke()
            let path = NSBezierPath()
            path.lineWidth = lw
            path.lineCapStyle = .butt
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
        case .text(let s, let p, let fontNorm):
            // CoreText, same as the bake path: NSStringDrawing's draw(at:)
            // renders mirrored in this context. The anchor is the text's
            // top-left; each line's baseline sits one ascender below the
            // previous line's top.
            let font = NSFont.systemFont(ofSize: fontNorm * bounds.height,
                                         weight: .bold)
            let v = denormalize(p)
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()
            let lineHeight = font.ascender - font.descender + font.leading
            for (i, sLine) in s.components(separatedBy: "\n").enumerated() {
                let attrStr = NSAttributedString(string: sLine, attributes: [
                    .font: font,
                    .foregroundColor: color,
                ])
                let line = CTLineCreateWithAttributedString(attrStr)
                ctx.textPosition = CGPoint(
                    x: v.x, y: v.y - font.ascender - CGFloat(i) * lineHeight)
                CTLineDraw(line, ctx)
            }
            ctx.restoreGState()
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
        panel?.showHoverToolbar()
        // Nonactivating panel: this only takes key status inside this app,
        // so hovered panels can receive ⌘W/keys without stealing app focus.
        window?.makeKey()
    }

    override func mouseExited(with event: NSEvent) {
        panel?.hideHoverToolbar()
    }

    override func mouseMoved(with event: NSEvent) {
        if !isPenMode {
            // Sliding from an occluded spot into the open fires no new
            // mouseEntered — re-show once the toolbar had been collapsed.
            if let p = panel, p.hoverToolbar.isHidden {
                p.showHoverToolbar()
            }
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if tool == .move {
            NSCursor.openHand.set()
        } else if tool == .text, hitTestText(at: p) != nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
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
        draggingTextIndex = nil
        movingIndex = nil
        moveExcludedIndex = nil
        moveOrigin = nil
        isPenMode = false
        needsDisplay = true
    }

    func selectTool(_ index: Int) {
        tool = AnnotationTool(rawValue: index) ?? .pen
        commitTextField()
        draggingTextIndex = nil
        NSCursor.crosshair.set()
    }

    func undoStroke() {
        if activeStroke != nil || activeShape != nil {
            activeStroke = nil
            activeShape = nil
            if moveExcludedIndex != nil {
                movingIndex = nil
                moveExcludedIndex = nil
                moveOrigin = nil
                invalidateComposite()
            }
        } else {
            _ = annotations.popLast()
        }
        needsDisplay = true
    }

    func clearStrokes() {
        annotations.removeAll()
        activeStroke = nil
        activeShape = nil
        movingIndex = nil
        moveExcludedIndex = nil
        moveOrigin = nil
        needsDisplay = true
    }

    func selectPenColor(_ index: Int) {
        guard PanelToolbar.penColors.indices.contains(index) else { return }
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
        case .pen, .highlighter, .text, .move:
            return .freehand([a, b])
        }
    }

    /// View-space bounds of a shape, used for partial invalidation.
    private func shapeBounds(_ shape: Annotation.Shape) -> CGRect {
        switch shape {
        case .freehand(let points), .highlight(let points):
            guard let first = points.first else { return .null }
            var r = CGRect(origin: denormalize(first), size: .zero)
            for p in points.dropFirst() {
                r = r.union(CGRect(origin: denormalize(p), size: .zero))
            }
            return r
        case .arrow(let a, let b):
            let va = denormalize(a), vb = denormalize(b)
            var r = CGRect(x: min(va.x, vb.x), y: min(va.y, vb.y),
                           width: abs(vb.x - va.x), height: abs(vb.y - va.y))
            // Arrowhead tips stick out past the endpoint box — include them
            // so preview invalidation doesn't leave specks behind.
            let head = strokeWidthNorm * bounds.height * 5
            let angle = atan2(vb.y - va.y, vb.x - va.x)
            for side in [-1.0, 1.0] as [CGFloat] {
                let a2 = angle + CGFloat.pi + side * (CGFloat.pi / 6)
                let tip = CGPoint(x: vb.x + head * cos(a2),
                                  y: vb.y + head * sin(a2))
                r = r.union(CGRect(origin: tip, size: .zero))
            }
            return r
        case .rect(let r), .mosaic(let r):
            return denormalizeRect(r)
        case .text(let s, let p, let fontNorm):
            let font = NSFont.systemFont(ofSize: fontNorm * bounds.height,
                                         weight: .bold)
            let lineHeight = font.ascender - font.descender + font.leading
            let lines = s.components(separatedBy: "\n")
            var w: CGFloat = 0
            for sLine in lines {
                w = max(w, NSAttributedString(
                    string: sLine, attributes: [.font: font]).size().width)
            }
            // The anchor is the text's top-left; it extends downward in
            // screen terms, i.e. to lower y in this non-flipped view.
            let v = denormalize(p)
            let h = font.ascender - font.descender
                + CGFloat(lines.count - 1) * lineHeight
            return CGRect(x: v.x, y: v.y - h, width: w, height: h)
        }
    }

    private func beginStroke(at point: CGPoint) {
        activeStroke = [normalize(point)]
        strokeAxisLock = nil
    }

    private func appendStroke(at point: CGPoint, shiftConstrained: Bool = false) {
        var point = point
        if shiftConstrained, tool == .highlighter,
           let start = activeStroke?.first.map(denormalize) {
            let dx = point.x - start.x, dy = point.y - start.y
            if let horizontal = strokeAxisLock {
                point = horizontal ? CGPoint(x: point.x, y: start.y)
                                   : CGPoint(x: start.x, y: point.y)
            } else if max(abs(dx), abs(dy)) > 4 {
                let horizontal = abs(dx) > abs(dy)
                strokeAxisLock = horizontal
                point = horizontal ? CGPoint(x: point.x, y: start.y)
                                   : CGPoint(x: start.x, y: point.y)
            }
        }
        // Marker-style backtrack: dragging back over the stroke trims the
        // tail instead of stacking a darker second layer.
        if tool == .highlighter, let pts = activeStroke, pts.count > 4 {
            let radius = currentWidthNorm * bounds.height * 0.6
            for i in 0 ..< pts.count - 3 {
                let v = denormalize(pts[i])
                if hypot(point.x - v.x, point.y - v.y) < radius {
                    activeStroke = Array(pts[0...i])
                    needsDisplay = true
                    break
                }
            }
        }
        let prev = activeStroke?.last.map(denormalize)
        // Skip sub-pixel jitter — long strokes would otherwise accumulate
        // thousands of points and rebuild a huge path on every repaint.
        if let prev, abs(point.x - prev.x) + abs(point.y - prev.y) < 0.5 { return }
        activeStroke?.append(normalize(point))
        // Repaint only the new segment instead of the whole image per event.
        let a = prev ?? point
        let pad = max(currentWidthNorm * bounds.height, 0.5) + 2
        setNeedsDisplay(CGRect(x: min(a.x, point.x) - pad, y: min(a.y, point.y) - pad,
                               width: abs(point.x - a.x) + pad * 2,
                               height: abs(point.y - a.y) + pad * 2))
    }

    /// Top-most committed text annotation under the point, if any — used
    /// to grab and reposition text while the text tool is selected.
    private func hitTestText(at viewPoint: CGPoint) -> Int? {
        for (i, ann) in annotations.enumerated().reversed() {
            if case .text = ann.shape,
               shapeBounds(ann.shape).insetBy(dx: -8, dy: -8).contains(viewPoint) {
                return i
            }
        }
        return nil
    }

    /// Top-most annotation the move tool can grab: strokes/arrows hit by
    /// proximity to their path, other shapes by their bounds.
    private func hitTestAnnotation(at p: CGPoint) -> Int? {
        for (i, ann) in annotations.enumerated().reversed() {
            let lw = max(ann.widthNorm * bounds.height, 0.5)
            let pad = lw / 2 + 6
            switch ann.shape {
            case .freehand(let pts), .highlight(let pts):
                var hit = pts.count == 1 &&
                    shapeBounds(ann.shape)
                        .insetBy(dx: -pad, dy: -pad).contains(p)
                for j in 0 ..< max(pts.count - 1, 0) where !hit {
                    if pointToSegment(p, denormalize(pts[j]),
                                      denormalize(pts[j + 1])) <= pad {
                        hit = true
                    }
                }
                if hit { return i }
            case .arrow(let a, let b):
                let va = denormalize(a), vb = denormalize(b)
                if pointToSegment(p, va, vb) <= pad + 4 { return i }
                let head = lw * 5
                let angle = atan2(vb.y - va.y, vb.x - va.x)
                for side in [-1.0, 1.0] as [CGFloat] {
                    let a2 = angle + CGFloat.pi + side * (CGFloat.pi / 6)
                    let tip = CGPoint(x: vb.x + head * cos(a2),
                                      y: vb.y + head * sin(a2))
                    if pointToSegment(p, vb, tip) <= pad { return i }
                }
            default:
                if shapeBounds(ann.shape)
                    .insetBy(dx: -6, dy: -6).contains(p) { return i }
            }
        }
        return nil
    }

    /// Distance from `p` to segment a–b.
    private func pointToSegment(_ p: CGPoint, _ a: CGPoint,
                                _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 > 0
            ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Translates a shape by a view-space delta.
    private func translated(_ shape: Annotation.Shape,
                            dx: CGFloat, dy: CGFloat) -> Annotation.Shape {
        let nx = dx / max(bounds.width, 1), ny = dy / max(bounds.height, 1)
        func o(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + nx, y: p.y + ny) }
        switch shape {
        case .freehand(let pts): return .freehand(pts.map(o))
        case .highlight(let pts): return .highlight(pts.map(o))
        case .arrow(let a, let b): return .arrow(from: o(a), to: o(b))
        case .rect(let r): return .rect(r.offsetBy(dx: nx, dy: ny))
        case .mosaic(let r): return .mosaic(r.offsetBy(dx: nx, dy: ny))
        case .text(let s, let p, let f): return .text(s, o(p), fontNorm: f)
        }
    }

    private func endStroke() {
        guard var pts = activeStroke else { return }
        if pts.count == 1 {
            // A single tap: nudge a second point so a round dot is drawn.
            pts.append(CGPoint(x: pts[0].x + 0.002, y: pts[0].y))
        }
        let shape: Annotation.Shape =
            tool == .highlighter ? .highlight(pts) : .freehand(pts)
        annotations.append(Annotation(shape: shape, color: penColor,
                                      widthNorm: currentWidthNorm))
        activeStroke = nil
        needsDisplay = true
    }

    // MARK: - Text annotation input

    private func showTextInput(at viewPoint: CGPoint) {
        commitTextField()
        let fontSize = textSizeNorm * bounds.height
        let tv = AnnotationTextView(
            frame: NSRect(x: viewPoint.x, y: viewPoint.y - fontSize - 10,
                          width: 60, height: fontSize + 10))
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.drawsBackground = false
        tv.font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        tv.textColor = penColor
        tv.insertionPointColor = penColor
        tv.textContainerInset = NSSize(width: 2, height: 4)
        // No auto-wrap: an unbounded container so the box only grows with
        // the text and explicit Shift+Enter newlines.
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = self
        tv.onCommit = { [weak self] in self?.commitTextField() }
        tv.onCancel = { [weak self] in self?.cancelTextField() }
        tv.onResize = { [weak self] d in self?.adjustTextSize(by: d) }
        addSubview(tv)
        textEditor = tv
        textAnchor = viewPoint
        sizeTextEditor(tv)
        // Defer until the click that spawned the editor has finished, or it
        // may not be ready to take first responder.
        DispatchQueue.main.async { [weak self, weak tv] in
            self?.window?.makeFirstResponder(tv)
        }
    }

    /// Keeps the editor's frame fitted to its text, anchored at the top-left.
    private func sizeTextEditor(_ tv: NSTextView) {
        guard let container = tv.textContainer,
              let lm = tv.layoutManager else { return }
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        let w = max(used.width + 12, 60)
        let h = max(used.height + 10, textSizeNorm * bounds.height + 10)
        tv.frame = NSRect(x: textAnchor.x, y: textAnchor.y - h,
                          width: w, height: h)
    }

    /// ⌘+/⌘-: scale the text size — live in the open editor, otherwise the
    /// default for the next text annotation.
    func adjustTextSize(by dir: CGFloat) {
        textSizeNorm = min(max(textSizeNorm + dir * 0.01, 0.02), 0.15)
        guard let tv = textEditor else { return }
        let font = NSFont.systemFont(ofSize: textSizeNorm * bounds.height,
                                     weight: .bold)
        tv.textStorage?.addAttribute(.font, value: font,
                                     range: NSRange(location: 0,
                                                    length: tv.string.count))
        tv.typingAttributes[.font] = font
        tv.textStorage?.addAttribute(.foregroundColor, value: penColor,
                                     range: NSRange(location: 0,
                                                    length: tv.string.count))
        tv.typingAttributes[.foregroundColor] = penColor
        sizeTextEditor(tv)
    }

    /// Adds the editor's text as an annotation (or just removes the editor
    /// when the text is empty), returning focus to the panel.
    private func commitTextField() {
        guard let field = textEditor else { return }
        let text = field.string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            // Anchor = the text's top-left in normalized coordinates.
            let p = CGPoint(
                x: (field.frame.minX + 2) / max(bounds.width, 1),
                y: (field.frame.maxY - 4) / max(bounds.height, 1))
            annotations.append(
                Annotation(shape: .text(text, p, fontNorm: textSizeNorm),
                           color: penColor, widthNorm: strokeWidthNorm))
        }
        cancelTextField()
    }

    private func cancelTextField() {
        textEditor?.removeFromSuperview()
        textEditor = nil
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
            case .highlight(let points):
                ctx.saveGState()
                ctx.setStrokeColor(ann.color.withAlphaComponent(highlightAlpha).cgColor)
                ctx.setLineWidth(lw)
                ctx.setLineCap(.butt)
                for (i, raw) in points.enumerated() {
                    let p = clampNorm(raw)
                    let v = CGPoint(x: p.x * pxW, y: p.y * pxH)
                    i == 0 ? ctx.move(to: v) : ctx.addLine(to: v)
                }
                ctx.strokePath()
                ctx.restoreGState()
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
            case .text(let s, let p, let fontNorm):
                bakeText(ctx, s, at: CGPoint(x: p.x * pxW, y: p.y * pxH),
                         fontSize: fontNorm * pxH, color: ann.color)
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
        let lineHeight = font.ascender - font.descender + font.leading
        // topLeft is the text's top edge; each line's baseline sits one
        // ascender below the previous line's top.
        for (i, sLine) in s.components(separatedBy: "\n").enumerated() {
            let attrStr = NSAttributedString(string: sLine, attributes: [
                .font: font,
                .foregroundColor: color,
            ])
            let line = CTLineCreateWithAttributedString(attrStr)
            ctx.textPosition = CGPoint(
                x: topLeft.x,
                y: topLeft.y - font.ascender - CGFloat(i) * lineHeight)
            CTLineDraw(line, ctx)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if isPenMode {
            let p = convert(event.locationInWindow, from: nil)
            switch tool {
            case .pen, .highlighter:
                beginStroke(at: p)
            case .arrow, .rect, .mosaic:
                dragAnchor = p
                activeShape = nil
            case .text:
                if let idx = hitTestText(at: p) {
                    draggingTextIndex = idx
                    if case .text(_, let anchor, _) = annotations[idx].shape {
                        let a = denormalize(anchor)
                        textDragOffset = CGSize(width: p.x - a.x,
                                                height: p.y - a.y)
                    }
                } else {
                    showTextInput(at: p)
                }
            case .move:
                guard let idx = hitTestAnnotation(at: p) else { return }
                movingIndex = idx
                moveExcludedIndex = idx
                moveOrigin = annotations[idx].shape
                moveOriginBounds = shapeBounds(annotations[idx].shape)
                moveStart = p
                activeShape = annotations[idx].shape
                invalidateComposite()
                needsDisplay = true
                NSCursor.closedHand.set()
            }
            return
        }
        if event.clickCount == 2 {
            toggleCollapsed()
            return
        }
        dragStartGlobal = NSEvent.mouseLocation
        dragStartFrame = window?.frame ?? .zero
        dragZone = resizeZone(at: convert(event.locationInWindow, from: nil))
        didMove = false
    }

    override func mouseDragged(with event: NSEvent) {
        if isPenMode {
            let p = convert(event.locationInWindow, from: nil)
            switch tool {
            case .pen, .highlighter:
                appendStroke(at: p, shiftConstrained: event.modifierFlags.contains(.shift))
            case .arrow, .rect, .mosaic:
                guard let anchor = dragAnchor else { return }
                // Repaint the union of old and new preview bounds.
                var dirty = activeShape.map { shapeBounds($0) } ?? .null
                activeShape = shapeFrom(anchor: anchor, to: p)
                dirty = dirty.union(shapeBounds(activeShape!))
                setNeedsDisplay(dirty.insetBy(dx: -8, dy: -8).intersection(bounds))
            case .text:
                guard let idx = draggingTextIndex, idx < annotations.count,
                      case .text(let s, _, let fontNorm) = annotations[idx].shape
                else { return }
                var dirty = shapeBounds(annotations[idx].shape)
                let np = CGPoint(x: p.x - textDragOffset.width,
                                 y: p.y - textDragOffset.height)
                annotations[idx].shape =
                    .text(s, clampNorm(normalize(np)), fontNorm: fontNorm)
                dirty = dirty.union(shapeBounds(annotations[idx].shape))
                setNeedsDisplay(dirty.insetBy(dx: -4, dy: -4))
            case .move:
                guard let idx = movingIndex, idx < annotations.count,
                      let origin = moveOrigin else { return }
                let dx = p.x - moveStart.x, dy = p.y - moveStart.y
                var dirty = activeShape.map { shapeBounds($0) } ?? .null
                activeShape = translated(origin, dx: dx, dy: dy)
                dirty = dirty.union(moveOriginBounds.offsetBy(dx: dx, dy: dy))
                setNeedsDisplay(dirty.insetBy(dx: -16, dy: -16))
            }
            return
        }
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - dragStartGlobal.x
        let dy = mouse.y - dragStartGlobal.y
        if abs(dx) + abs(dy) > 2 { didMove = true }
        if dragZone == .none {
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
            if tool == .move {
                if let idx = movingIndex, idx < annotations.count,
                   let shape = activeShape {
                    annotations[idx].shape = shape
                }
                movingIndex = nil
                moveExcludedIndex = nil
                moveOrigin = nil
                activeShape = nil
                needsDisplay = true
            } else if tool == .pen || tool == .highlighter {
                endStroke()
            } else if let shape = activeShape {
                annotations.append(Annotation(shape: shape, color: penColor,
                                              widthNorm: strokeWidthNorm))
                activeShape = nil
                needsDisplay = true
            }
            dragAnchor = nil
            draggingTextIndex = nil
            return
        }
        if !didMove, dragZone == .none {
            panel?.copyImageToPasteboard()
            flashCopyFeedback()
        }
        dragZone = .none
        endLiveResize()
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
        let copyItem = menu.addItem(withTitle: L10n.tr("복사"), action: #selector(copyAction), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        let saveItem = menu.addItem(withTitle: L10n.tr("다른 이름으로 저장…"), action: #selector(saveAction), keyEquivalent: "s")
        saveItem.keyEquivalentModifierMask = .command
        menu.addItem(withTitle: L10n.tr("텍스트 추출 (OCR)"), action: #selector(ocrAction), keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr("펜으로 표시"), action: #selector(penAction), keyEquivalent: "p")
        menu.addItem(.separator())

        let topItem = menu.addItem(withTitle: L10n.tr("항상 위에 표시"), action: #selector(toggleAlwaysOnTop), keyEquivalent: "t")
        topItem.state = panel.alwaysOnTop ? .on : .off
        let ghostItem = menu.addItem(withTitle: L10n.tr("클릭-스루 모드"), action: #selector(toggleClickThrough), keyEquivalent: "g")
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
        let opacityItem = menu.addItem(withTitle: L10n.tr("투명도"), action: nil, keyEquivalent: "")
        menu.setSubmenu(opacityMenu, for: opacityItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: L10n.tr("오른쪽으로 회전"), action: #selector(rotateAction), keyEquivalent: "r")
        menu.addItem(withTitle: L10n.tr("왼쪽으로 회전"), action: #selector(rotateCCWAction), keyEquivalent: "R")
        menu.addItem(withTitle: L10n.tr("좌우 반전"), action: #selector(flipAction), keyEquivalent: "f")
        menu.addItem(withTitle: L10n.tr("축소/복원"), action: #selector(collapseAction), keyEquivalent: "")
        let closeItem = menu.addItem(withTitle: L10n.tr("닫기"), action: #selector(closeAction), keyEquivalent: "w")
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
        panel?.enterAnnotateUI()
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

    /// Corners use the wider grab zone; edges get a thin band between them.
    /// All resizes run through this view — the panel intentionally omits
    /// .resizable so AppKit's native edge-resize can't fight our aspect lock.
    private func resizeZone(at point: CGPoint) -> ResizeZone {
        let w = bounds.width, h = bounds.height
        let nearLeft = point.x < cornerSize, nearRight = point.x > w - cornerSize
        let nearBottom = point.y < cornerSize, nearTop = point.y > h - cornerSize
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        let e: CGFloat = 6
        if point.x < e { return .left }
        if point.x > w - e { return .right }
        if point.y < e { return .bottom }
        if point.y > h - e { return .top }
        return .none
    }

    /// Aspect-preserving resize: the corner opposite to the dragged one stays
    /// fixed. Edge drags move that edge while the other axis follows the ratio
    /// (locked) or stays put (unlocked).
    private func resize(to mouseGlobal: CGPoint) {
        guard let window else { return }
        let f = dragStartFrame
        let aspect = f.width / f.height
        let locked = panel?.aspectLocked ?? true
        var frame = f

        switch dragZone {
        case .none:
            return
        case .left, .right:
            var newW = dragZone == .right ? mouseGlobal.x - f.minX
                                          : f.maxX - mouseGlobal.x
            newW = min(max(newW, minDimension), maxDimension)
            let newH = locked ? newW / aspect : f.height
            frame.size = CGSize(width: newW, height: newH)
            frame.origin.x = dragZone == .right ? f.minX : f.maxX - newW
            frame.origin.y = locked ? f.midY - newH / 2 : f.minY
        case .top, .bottom:
            var newH = dragZone == .top ? mouseGlobal.y - f.minY
                                        : f.maxY - mouseGlobal.y
            newH = min(max(newH, minDimension), maxDimension)
            let newW = locked ? newH * aspect : f.width
            frame.size = CGSize(width: newW, height: newH)
            frame.origin.y = dragZone == .top ? f.minY : f.maxY - newH
            frame.origin.x = locked ? f.midX - newW / 2 : f.minX
        default:
            // Anchor = the diagonally opposite corner, in AppKit coords
            // (view y is bottom-up: .bottom* zones sit at minY).
            let anchor: CGPoint
            switch dragZone {
            case .bottomRight: anchor = CGPoint(x: f.minX, y: f.maxY)
            case .bottomLeft:  anchor = CGPoint(x: f.maxX, y: f.maxY)
            case .topRight:    anchor = f.origin
            default:           anchor = CGPoint(x: f.maxX, y: f.minY)
            }
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
            frame.size = CGSize(width: newW, height: newH)
            frame.origin = CGPoint(
                x: mouseGlobal.x >= anchor.x ? anchor.x : anchor.x - newW,
                y: mouseGlobal.y >= anchor.y ? anchor.y : anchor.y - newH
            )
        }
        window.setFrame(frame, display: true)
        beginLiveResize()
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
        beginLiveResize()
        showSizeBadge()
    }

    // MARK: - Size badge

    /// Shows the current view size and the stored image's native pixel
    /// size as a transient overlay at the bottom center — never baked.
    /// When the pill is wider than the panel it floats just below the
    /// image instead of covering it.
    private func showSizeBadge() {
        let s = bounds.size
        // Effective pixels (points × screen scale) — matches the capture's
        // native resolution when the panel sits at 100% on Retina.
        let scale = window?.backingScaleFactor ?? 2
        let text = "\(Int((s.width * scale).rounded())) × \(Int((s.height * scale).rounded()))"
        sizeBadgeLabel.stringValue = text
        sizeBadgeLabel.sizeToFit()
        let lw = sizeBadgeLabel.frame.width
        let lh = sizeBadgeLabel.frame.height
        let w = lw + 16
        let h = lh + 8
        if sizeBadgeLabel.superview !== sizeBadge {
            sizeBadge.addSubview(sizeBadgeLabel)
        }
        sizeBadgeLabel.frame = NSRect(x: (w - lw) / 2, y: (h - lh) / 2,
                                      width: lw, height: lh)
        if w <= s.width - 8 {
            panel?.attachSizeBadgeInside(sizeBadge)
            sizeBadge.frame = NSRect(x: (s.width - w) / 2,
                                     y: 6, width: w, height: h)
        } else {
            panel?.detachSizeBadge(sizeBadge, size: NSSize(width: w, height: h))
        }
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
                        self.panel?.orderOutSizeBadgeWindow()
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

extension FloatingImageView: NSTextViewDelegate {
    /// Grow/shrink the editor to fit its text on every keystroke.
    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? AnnotationTextView,
              tv === textEditor else { return }
        sizeTextEditor(tv)
    }
}

/// Multi-line editor for the text tool. Enter commits, Shift+Enter inserts
/// a newline, Esc cancels, ⌘+/⌘- resize the text.
private final class AnnotationTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / keypad Enter
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else {
                onCommit?()
            }
        case 53: // Esc — discard the editor, stay in annotate mode
            onCancel?()
        case 24, 27: // ⌘= / ⌘-
            if event.modifierFlags.contains(.command) {
                onResize?(event.keyCode == 24 ? 1 : -1)
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }
}
