import AppKit

@MainActor
final class FloatingWindowManager {
    static let shared = FloatingWindowManager()

    private(set) var panels: [FloatingPanel] = []
    private var cascadeStep = 0

    /// True while all panels are parked off-screen (GrabIt-style hide all).
    private(set) var allHidden = false

    /// Recently closed panels (image + frame) for undo-close, newest last.
    private var closedStack: [(image: NSImage, frame: CGRect)] = []

    /// willClose observer tokens per panel — removed when the panel closes,
    /// otherwise NotificationCenter would retain them forever.
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Shows a floating panel occupying `frameInScreen` (global AppKit coords).
    @discardableResult
    func show(image: NSImage, frameInScreen rect: CGRect) -> FloatingPanel {
        let panel = FloatingPanel(image: image, frameInScreen: rect)
        return present(panel)
    }

    /// Shows a floating panel near a screen point, centered, scaled down to fit.
    @discardableResult
    func show(image: NSImage, near point: CGPoint) -> FloatingPanel {
        let size = fittedSize(for: image.size)
        let origin = CGPoint(x: point.x - size.width / 2 + CGFloat(cascadeStep) * 20,
                             y: point.y - size.height / 2 - CGFloat(cascadeStep) * 20)
        cascadeStep = (cascadeStep + 1) % 8
        let panel = FloatingPanel(image: image,
                                  frameInScreen: CGRect(origin: origin, size: size))
        return present(panel)
    }

    /// Parks every panel off-screen, or brings them all back.
    func toggleHidden() {
        allHidden.toggle()
        if allHidden {
            panels.forEach { $0.orderOut(nil) }
        } else {
            panels.forEach { $0.orderFrontRegardless() }
        }
    }

    func closeAll() {
        allHidden = false
        panels.forEach { $0.close() }
        panels.removeAll()
    }

    func disableClickThroughAll() {
        panels.forEach { $0.clickThrough = false }
    }

    var canReopen: Bool { !closedStack.isEmpty }

    /// Reopens the most recently closed panel at its previous frame.
    func reopenLastClosed() {
        guard let last = closedStack.popLast() else {
            NSSound.beep()
            return
        }
        show(image: last.image, frameInScreen: last.frame)
    }

    private func present(_ panel: FloatingPanel) -> FloatingPanel {
        // A freshly presented panel resets the parked state — it would be
        // confusing for a new capture to land on a hidden desktop.
        allHidden = false
        panel.orderFrontRegardless()
        panels.append(panel)
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] note in
            guard let closing = note.object as? FloatingPanel else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.panels.removeAll { $0 === closing }
                self.closedStack.append((closing.image, closing.frame))
                if self.closedStack.count > 10 { self.closedStack.removeFirst() }
                let id = ObjectIdentifier(closing)
                if let observer = self.closeObservers.removeValue(forKey: id) {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
        closeObservers[ObjectIdentifier(panel)] = token
        return panel
    }

    private func fittedSize(for size: CGSize) -> CGSize {
        guard let screen = NSScreen.main else { return size }
        let limit = CGSize(width: screen.visibleFrame.width * 0.9,
                           height: screen.visibleFrame.height * 0.9)
        let scale = min(1, limit.width / max(size.width, 1), limit.height / max(size.height, 1))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
