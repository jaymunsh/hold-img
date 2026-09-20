import AppKit

/// Borderless panel that floats an image above other windows.
final class FloatingPanel: NSPanel {
    private(set) var image: NSImage
    let hoverToolbar = PanelToolbar()

    /// Detached child window hosting the annotation toolbar while pen mode
    /// is active and the toolbar is wider than the panel itself.
    private var penBarWindow: NSPanel?

    /// Detached child window hosting the size badge below the panel when
    /// the pill is wider than the image itself.
    private var sizeBadgeWindow: NSPanel?

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
            styleMask: [.borderless, .nonactivatingPanel],
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
        hoverToolbar.onExit = { [weak self] in self?.hideHoverToolbar() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange),
            name: NSWindow.didResizeNotification, object: self)
    }

    /// Repositions the detached pen toolbar whenever the panel resizes,
    /// and re-evaluates whether it still needs to live outside.
    @objc private func frameDidChange(_ note: Notification) {
        positionPenBar()
        positionSizeBadge()
        guard let view = contentView as? FloatingImageView else { return }
        let tooWide = hoverToolbar.contentSize.width > view.bounds.width - 16
        if tooWide, !hoverToolbar.isHidden || view.isPenMode {
            detachPenBar()
        } else if !tooWide, penBarWindow != nil {
            attachPenBarInside()
        }
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

    /// True when this panel is the front-most panel under the cursor —
    /// overlapped panels stay dark instead of all flashing their toolbars
    /// at once. `panels` is kept in z-order (each new panel orders front).
    private var isTopmostUnderCursor: Bool {
        let p = NSEvent.mouseLocation
        let panels = FloatingWindowManager.shared.panels
        if panels.contains(where: {
            $0 !== self &&
            ($0.penBarWindow?.frame.contains(p) == true ||
             $0.sizeBadgeWindow?.frame.contains(p) == true)
        }) {
            return false  // another panel's detached bar sits on top of us
        }
        guard let top = panels.last(where: { $0.isVisible && $0.frame.contains(p) })
        else { return true }
        return top === self
    }

    /// Shows the hover toolbar; when it is wider than the panel it is
    /// hosted in the floating bar above the image instead of covering it.
    func showHoverToolbar() {
        guard let view = contentView as? FloatingImageView,
              !view.isPenMode, isTopmostUnderCursor else { return }
        // Only the topmost panel under the cursor may light up — occluded
        // siblings hiding inside the same cursor rect go dark.
        for case let other as FloatingPanel in NSApp.windows where other !== self {
            other.hideHoverToolbar()
        }
        if penBarWindow == nil,
           hoverToolbar.contentSize.width > view.bounds.width - 16 {
            detachPenBar()
        }
        hoverToolbar.show()
    }

    /// Collapses the toolbar once the pointer is off both the panel and
    /// the detached bar — delayed and edge-inflated so crossing the gap
    /// between them does not flicker it shut.
    func hideHoverToolbar() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self,
                  let view = self.contentView as? FloatingImageView,
                  !view.isPenMode else { return }
            let p = NSEvent.mouseLocation
            let insidePanel = self.frame.insetBy(dx: -12, dy: -12).contains(p)
                && self.isTopmostUnderCursor
            let pbad = self.penBarWindow?.frame.insetBy(dx: -12, dy: -12)
            if insidePanel || pbad?.contains(p) == true {
                return
            }
            self.hoverToolbar.hide()
            if self.penBarWindow != nil { self.attachPenBarInside() }
        }
    }

    /// Pen-mode entry: the tool strip is hosted in a floating bar above
    /// (or below) the image only when it is wider than the panel itself.
    func enterAnnotateUI() {
        guard let view = contentView as? FloatingImageView else { return }
        view.enterPenMode()
        hoverToolbar.setMode(.pen)
        // detachPenBar() resizes the existing bar too — the wider pen
        // strip must re-fit the window even when a bar is already out.
        if hoverToolbar.contentSize.width > view.bounds.width - 16 {
            detachPenBar()
        } else if penBarWindow != nil {
            attachPenBarInside()
        }
        hoverToolbar.show()
    }

    private func exitAnnotateUI(bake: Bool) {
        (contentView as? FloatingImageView)?.exitPenMode(bake: bake)
        hoverToolbar.setMode(.normal)
        attachPenBarInside()
    }

    private func detachPenBar() {
        let bar: NSPanel
        if let existing = penBarWindow {
            bar = existing
        } else {
            bar = NSPanel(contentRect: .zero,
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
            bar.isOpaque = false
            bar.backgroundColor = .clear
            bar.hasShadow = false
            bar.isReleasedWhenClosed = false
            bar.hidesOnDeactivate = false
            addChildWindow(bar, ordered: .above)
            penBarWindow = bar
        }
        bar.level = level
        let size = hoverToolbar.contentSize
        hoverToolbar.removeFromSuperview()
        hoverToolbar.autoresizingMask = []
        bar.contentView = hoverToolbar
        bar.setContentSize(size)
        positionPenBar()
        bar.orderFront(nil)
    }

    /// Centers the detached bar over the panel's top edge; flips below the
    /// panel when there is no room above on the current screen.
    private func positionPenBar() {
        guard let bar = penBarWindow else { return }
        let size = bar.frame.size
        var x = frame.midX - size.width / 2
        var y = frame.maxY + 6
        if let vf = (screen ?? NSScreen.main)?.visibleFrame {
            if y + size.height > vf.maxY {
                y = frame.minY - size.height - 6
            }
            x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        }
        bar.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func attachPenBarInside() {
        guard let bar = penBarWindow else { return }
        hoverToolbar.removeFromSuperview()
        attachHoverToolbar()
        removeChildWindow(bar)
        bar.orderOut(nil)
        penBarWindow = nil
    }

    /// Hosts the size badge in a floating child window below the panel —
    /// used while resizing when the pill is wider than the image.
    func detachSizeBadge(_ badge: NSView, size: NSSize) {
        let win: NSPanel
        if let existing = sizeBadgeWindow {
            win = existing
        } else {
            win = NSPanel(contentRect: .zero,
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.isReleasedWhenClosed = false
            win.hidesOnDeactivate = false
            addChildWindow(win, ordered: .above)
            sizeBadgeWindow = win
        }
        win.level = level
        if win.contentView !== badge {
            badge.removeFromSuperview()
            win.contentView = badge
        }
        win.setContentSize(size)
        positionSizeBadge()
        win.orderFront(nil)
    }

    /// Centers the detached badge under the panel's bottom edge; flips
    /// above the panel when there is no room below on the current screen.
    private func positionSizeBadge() {
        guard let win = sizeBadgeWindow else { return }
        var x = frame.midX - win.frame.width / 2
        var y = frame.minY - win.frame.height - 6
        if let vf = (screen ?? NSScreen.main)?.visibleFrame {
            if y < vf.minY {
                y = frame.maxY + 6
            }
            x = min(max(x, vf.minX + 4), vf.maxX - win.frame.width - 4)
        }
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Puts the badge back inside the image view once it fits again.
    func attachSizeBadgeInside(_ badge: NSView) {
        guard let win = sizeBadgeWindow else { return }
        badge.removeFromSuperview()
        contentView?.addSubview(badge)
        removeChildWindow(win)
        win.orderOut(nil)
        sizeBadgeWindow = nil
    }

    /// Hides the detached badge window when the badge fades out.
    func orderOutSizeBadgeWindow() {
        sizeBadgeWindow?.orderOut(nil)
    }

    private func handleToolbar(_ action: PanelToolbar.Action) {
        guard let view = contentView as? FloatingImageView else { return }
        switch action {
        case .pen:
            enterAnnotateUI()
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
            exitAnnotateUI(bake: true)
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
                exitAnnotateUI(bake: false)
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
            case 24, 27: // ⌘= / ⌘- — text annotation size (editor closed)
                if view?.isPenMode == true && view?.tool == .text {
                    view?.adjustTextSize(by: event.keyCode == 24 ? 1 : -1)
                    return
                }
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
            case 37 where flags.isEmpty && view?.isPenMode != true: // L
                aspectLocked.toggle()
                hoverToolbar.setLocked(aspectLocked)
                return
            case 123: nudge(dx: -step, dy: 0); return // ←
            case 124: nudge(dx: step, dy: 0); return // →
            case 125: nudge(dx: 0, dy: -step); return // ↓
            case 126: nudge(dx: 0, dy: step); return // ↑
            case 35 where flags.isEmpty: // P
                if view?.isPenMode == true {
                    exitAnnotateUI(bake: false)
                } else {
                    enterAnnotateUI()
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
