import AppKit

/// Borderless panel that floats an image above other windows.
final class FloatingPanel: NSPanel {
    private(set) var image: NSImage
    let hoverToolbar = PanelToolbar()

    /// Corner-drag resize keeps the aspect ratio while locked (default).
    var aspectLocked = true

    var clickThrough: Bool {
        get { ignoresMouseEvents }
        set { ignoresMouseEvents = newValue }
    }

    var alwaysOnTop: Bool {
        get { level == .floating }
        set { level = newValue ? .floating : .normal }
    }

    init(image: NSImage, frameInScreen: CGRect) {
        self.image = image
        super.init(
            contentRect: frameInScreen,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        level = SettingsStore.shared.defaultAlwaysOnTop ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 32, height: 32)
        contentView = FloatingImageView(image: image)
        attachHoverToolbar()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func attachHoverToolbar() {
        guard let contentView else { return }
        contentView.addSubview(hoverToolbar)
        hoverToolbar.autoresizingMask = [.minXMargin, .minYMargin]
        let size = hoverToolbar.contentSize
        hoverToolbar.frame = CGRect(x: contentView.bounds.maxX - size.width - 8,
                               y: contentView.bounds.maxY - size.height - 8,
                               width: size.width, height: size.height)
        hoverToolbar.onAction = { [weak self] action in self?.handleToolbar(action) }
    }

    private func handleToolbar(_ action: PanelToolbar.Action) {
        guard let view = contentView as? FloatingImageView else { return }
        switch action {
        case .pen:
            view.enterPenMode()
            hoverToolbar.setMode(.pen)
            hoverToolbar.show()
        case .copy:
            copyImageToPasteboard()
            view.flashCopyFeedback()
        case .save:
            ClipboardService.saveWithPanel(image: image)
        case .close:
            close()
        case .toggleLock:
            aspectLocked.toggle()
            hoverToolbar.setLocked(aspectLocked)
        case .ocr:
            if OCRService.copyText(from: image) {
                view.flashCopyFeedback()
            } else {
                NSSound.beep()
            }
        case .tool(let index):
            view.selectTool(index)
            hoverToolbar.setToolIndex(index)
        case .color(let index):
            view.selectPenColor(index)
            hoverToolbar.setColorIndex(index)
        case .undo:
            view.undoStroke()
        case .clear:
            view.clearStrokes()
        case .done:
            view.exitPenMode(bake: true)
            hoverToolbar.setMode(.normal)
        }
    }

    func setImage(_ newImage: NSImage) {
        image = newImage
        (contentView as? FloatingImageView)?.image = newImage
    }

    override func keyDown(with event: NSEvent) {
        let view = contentView as? FloatingImageView
        // Only real modifiers — arrows carry .function, which would
        // otherwise break the plain/shift comparisons below.
        let flags = event.modifierFlags
            .intersection([.shift, .control, .option, .command])
        if event.keyCode == 53 { // Esc
            if view?.isPenMode == true {
                view?.exitPenMode(bake: false)
                hoverToolbar.setMode(.normal)
            } else {
                close()
            }
            return
        }
        // Match on keyCode, not characters — non-Latin input sources would
        // turn these into jamo and silently break the shortcuts.
        if flags == .command {
            switch event.keyCode {
            case 8: // C
                copyImageToPasteboard()
                view?.flashCopyFeedback()
                return
            case 1: // S
                ClipboardService.saveWithPanel(image: image)
                return
            case 13: // W
                close()
                return
            case 6 where view?.isPenMode == true: // Z
                view?.undoStroke()
                return
            default:
                break
            }
        }
        if flags.isEmpty || flags == .shift {
            let step: CGFloat = flags == .shift ? 10 : 1
            switch event.keyCode {
            case 17 where flags.isEmpty: alwaysOnTop.toggle(); return // T
            case 5 where flags.isEmpty: clickThrough.toggle(); return // G
            case 15 where view?.isPenMode != true: // R / ⇧R
                rotate(clockwise: flags.isEmpty)
                return
            case 3 where flags.isEmpty && view?.isPenMode != true: // F
                flipHorizontal()
                return
            case 123: nudge(dx: -step, dy: 0); return // ←
            case 124: nudge(dx: step, dy: 0); return // →
            case 125: nudge(dx: 0, dy: -step); return // ↓
            case 126: nudge(dx: 0, dy: step); return // ↑
            case 35 where flags.isEmpty: // P
                if view?.isPenMode == true {
                    view?.exitPenMode(bake: false)
                    hoverToolbar.setMode(.normal)
                } else {
                    view?.enterPenMode()
                    hoverToolbar.setMode(.pen)
                    hoverToolbar.show()
                }
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    /// Moves the window in point increments (Shift = 10pt per press).
    private func nudge(dx: CGFloat, dy: CGFloat) {
        setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY + dy))
    }

    /// Rotates the image 90° and re-frames the window around its center.
    func rotate(clockwise: Bool = true) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard let ctx = CGContext(data: nil, width: Int(h), height: Int(w),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.translateBy(x: h / 2, y: w / 2)
        ctx.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
        ctx.draw(cg, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        applyTransformed(ctx, pointSize: NSSize(width: image.size.height,
                                              height: image.size.width))
        let newSize = NSSize(width: frame.height, height: frame.width)
        setFrame(NSRect(x: frame.midX - newSize.width / 2,
                        y: frame.midY - newSize.height / 2,
                        width: newSize.width, height: newSize.height),
                 display: true)
    }

    /// Mirrors the image left-right; window frame is unchanged.
    func flipHorizontal() {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.translateBy(x: w, y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        applyTransformed(ctx, pointSize: image.size)
    }

    private func applyTransformed(_ ctx: CGContext, pointSize: NSSize) {
        guard let out = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: out)
        rep.size = pointSize
        let transformed = NSImage(size: pointSize)
        transformed.addRepresentation(rep)
        setImage(transformed)
    }

    func copyImageToPasteboard() {
        ClipboardService.copy(image)
    }
}
