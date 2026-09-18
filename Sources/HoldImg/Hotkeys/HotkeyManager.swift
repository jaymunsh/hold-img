import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let captureRegion = Self("captureRegion",
                                    default: .init(.c, modifiers: [.control, .option]))
    static let captureWindow = Self("captureWindow",
                                    default: .init(.w, modifiers: [.control, .option]))
    static let recaptureRegion = Self("recaptureRegion",
                                      default: .init(.r, modifiers: [.control, .option]))
    static let pasteFloat = Self("pasteFloat",
                                 default: .init(.v, modifiers: [.control, .option]))
}

enum HotkeyManager {
    @MainActor
    static func register() {
        KeyboardShortcuts.onKeyDown(for: .captureRegion) {
            Task { @MainActor in CaptureCoordinator.shared.startRegionCapture() }
        }
        KeyboardShortcuts.onKeyDown(for: .captureWindow) {
            Task { @MainActor in CaptureCoordinator.shared.startWindowCapture() }
        }
        KeyboardShortcuts.onKeyDown(for: .recaptureRegion) {
            Task { @MainActor in CaptureCoordinator.shared.recaptureLastRegion() }
        }
        KeyboardShortcuts.onKeyDown(for: .pasteFloat) {
            Task { @MainActor in pasteFromClipboard() }
        }
    }

    @MainActor
    static func pasteFromClipboard() {
        guard let image = ClipboardService.imageFromPasteboard() else {
            NSSound.beep()
            return
        }
        CaptureCoordinator.shared.presentExternalImage(image)
    }
}
