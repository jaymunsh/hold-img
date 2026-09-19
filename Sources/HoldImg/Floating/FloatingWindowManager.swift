import AppKit

@MainActor
final class FloatingWindowManager {
    static let shared = FloatingWindowManager()

    private(set) var panels: [FloatingPanel] = []
    private var cascadeStep = 0

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

    func closeAll() {
        panels.forEach { $0.close() }
        panels.removeAll()
    }

    func disableClickThroughAll() {
        panels.forEach { $0.clickThrough = false }
    }

    private func present(_ panel: FloatingPanel) -> FloatingPanel {
        panel.orderFrontRegardless()
        panels.append(panel)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] note in
            guard let closing = note.object as? FloatingPanel else { return }
            Task { @MainActor [weak self] in
                self?.panels.removeAll { $0 === closing }
            }
        }
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
