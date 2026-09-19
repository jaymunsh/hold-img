import AppKit

/// Borderless panel that floats an image above other windows.
final class FloatingPanel: NSPanel {
    private(set) var image: NSImage
    let hoverToolbar = PanelToolbar()

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
        let size = hoverToolbar.fittingSize
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
        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c":
                copyImageToPasteboard()
                view?.flashCopyFeedback()
                return
            case "s":
                ClipboardService.saveWithPanel(image: image)
                return
            case "z" where view?.isPenMode == true:
                view?.undoStroke()
                return
            default:
                break
            }
        }
        if flags.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "t": alwaysOnTop.toggle(); return
            case "g": clickThrough.toggle(); return
            case "p":
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
