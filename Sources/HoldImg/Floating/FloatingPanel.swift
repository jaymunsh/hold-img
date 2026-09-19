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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
        if flags.isEmpty {
            switch event.keyCode {
            case 17: alwaysOnTop.toggle(); return // T
            case 5: clickThrough.toggle(); return // G
            case 35: // P
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

    func copyImageToPasteboard() {
        ClipboardService.copy(image)
    }
}
