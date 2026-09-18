import AppKit

/// Borderless panel that floats an image above other windows.
final class FloatingPanel: NSPanel {
    let image: NSImage

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
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { // Esc
            close()
            return
        }
        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c":
                copyImageToPasteboard()
                (contentView as? FloatingImageView)?.flashCopyFeedback()
                return
            case "s":
                ClipboardService.saveWithPanel(image: image)
                return
            default:
                break
            }
        }
        if flags.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "t": alwaysOnTop.toggle(); return
            case "g": clickThrough.toggle(); return
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
