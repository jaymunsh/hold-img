import AppKit
import ScreenCaptureKit

/// Fullscreen overlay over one display: shows the frozen frame dimmed,
/// lets the user drag-select a region or click a window.
final class CaptureOverlayWindow: NSWindow {
    let screenFrame: CGRect
    private let overlayView: CaptureOverlayView

    init(displayFrame: DisplayFrame,
         mode: CaptureCoordinator.Mode,
         windows: [SCWindow],
         coordinator: CaptureCoordinator) {
        screenFrame = displayFrame.screen.frame
        overlayView = CaptureOverlayView(
            frame: NSRect(origin: .zero, size: displayFrame.screen.frame.size),
            displayFrame: displayFrame,
            mode: mode,
            windows: windows,
            coordinator: coordinator
        )
        super.init(
            contentRect: displayFrame.screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        overlayView.overlayWindow = self
        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CaptureOverlayView: NSView {
    weak var overlayWindow: CaptureOverlayWindow?

    private let coordinator: CaptureCoordinator
    private let mode: CaptureCoordinator.Mode
    private let displayImage: NSImage
    private let sampler: PixelSampler?
    private let imageSize: CGSize

    /// Candidate windows for .window mode, in view coordinates, front to back.
    private let windowRects: [(rect: CGRect, window: SCWindow)]

    private var dragStart: CGPoint?
    private var selection: CGRect = .zero
    private var cursor: CGPoint?
    private var hoveredWindowIndex: Int?
    private var copiedFlashUntil: Date?

    init(frame: NSRect,
         displayFrame: DisplayFrame,
         mode: CaptureCoordinator.Mode,
         windows: [SCWindow],
         coordinator: CaptureCoordinator) {
        self.coordinator = coordinator
        self.mode = mode
        imageSize = CGSize(width: displayFrame.image.width, height: displayFrame.image.height)
        displayImage = NSImage(cgImage: displayFrame.image,
                               size: displayFrame.screen.frame.size)
        sampler = PixelSampler(cgImage: displayFrame.image)
        let primaryH = ScreenGeometry.primaryScreenHeight
        let origin = displayFrame.screen.frame.origin
        windowRects = windows.map { window in
            let appKit = ScreenGeometry.appKitRect(fromCG: window.frame,
                                                   primaryScreenHeight: primaryH)
            return (rect: appKit.offsetBy(dx: -origin.x, dy: -origin.y), window: window)
        }
        super.init(frame: frame)
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Events

    override func mouseDown(with event: NSEvent) {
        let p = clampToBounds(convert(event.locationInWindow, from: nil))
        switch mode {
        case .region:
            dragStart = p
            selection = CGRect(origin: p, size: .zero)
        case .window:
            if let index = hoveredWindowIndex, let overlayWindow {
                coordinator.overlay(overlayWindow, didPick: windowRects[index].window)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clampToBounds(convert(event.locationInWindow, from: nil))
        cursor = p
        if let start = dragStart {
            selection = normalizedRect(from: start, to: p)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            needsDisplay = true
        }
        guard mode == .region, let overlayWindow else { return }
        let rect = normalizedRect(from: dragStart ?? selection.origin,
                                  to: clampToBounds(convert(event.locationInWindow, from: nil)))
        coordinator.overlay(overlayWindow, didSelect: rect)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursor = p
        if mode == .window {
            hoveredWindowIndex = windowRects.firstIndex { $0.rect.contains(p) }
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        cursor = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            if let overlayWindow { coordinator.overlayDidCancel(overlayWindow) }
            return
        }
        if event.charactersIgnoringModifiers?.lowercased() == "c",
           let cursor, let color = colorAtViewPoint(cursor) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(color.hexString, forType: .string)
            copiedFlashUntil = Date().addingTimeInterval(0.8)
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        displayImage.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()

        switch mode {
        case .region: drawRegionMode()
        case .window: drawWindowMode()
        }
        drawHint()
        if let cursor { drawLoupe(at: cursor) }
    }

    private func drawRegionMode() {
        guard !selection.isEmpty else { return }
        displayImage.draw(in: selection, from: selection, operation: .sourceOver, fraction: 1)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: selection)
        path.lineWidth = 1
        path.stroke()
        drawLabel("\(Int(selection.width)) × \(Int(selection.height))",
                  near: CGPoint(x: selection.maxX, y: selection.maxY))
    }

    private func drawWindowMode() {
        guard let index = hoveredWindowIndex else { return }
        let rect = windowRects[index].rect
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        rect.fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
        if let name = windowRects[index].window.title, !name.isEmpty {
            drawLabel(name, near: CGPoint(x: rect.minX, y: rect.maxY + 4))
        }
    }

    private func drawHint() {
        let text = mode == .region
            ? "드래그로 영역 선택 · C: 컬러 복사 · Esc: 취소"
            : "캡처할 윈도우 클릭 · Esc: 취소"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let point = CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 40)
        let bg = CGRect(x: point.x - 10, y: point.y - 6,
                        width: size.width + 20, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        str.draw(at: point)
    }

    private func drawLabel(_ text: String, near point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        var p = CGPoint(x: point.x - size.width - 6, y: point.y + 6)
        p.x = min(max(p.x, 4), bounds.width - size.width - 8)
        p.y = min(max(p.y, 4), bounds.height - size.height - 8)
        let bg = CGRect(x: p.x - 4, y: p.y - 3,
                        width: size.width + 8, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        str.draw(at: p)
    }

    private func drawLoupe(at point: CGPoint) {
        let loupeSize: CGFloat = 120
        let pixelSpan: CGFloat = 11 // view points sampled across the loupe
        var origin = CGPoint(x: point.x + 18, y: point.y + 18)
        if origin.x + loupeSize > bounds.maxX - 8 { origin.x = point.x - loupeSize - 18 }
        if origin.y + loupeSize > bounds.maxY - 8 { origin.y = point.y - loupeSize - 18 }
        let loupeRect = CGRect(origin: origin, size: CGSize(width: loupeSize, height: loupeSize))

        let source = CGRect(x: point.x - pixelSpan / 2, y: point.y - pixelSpan / 2,
                            width: pixelSpan, height: pixelSpan)
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        displayImage.draw(in: loupeRect, from: source, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(roundedRect: loupeRect, xRadius: 6, yRadius: 6)
        border.lineWidth = 1.5
        border.stroke()

        // Crosshair on the center pixel.
        let cell = loupeSize / pixelSpan
        let center = CGRect(x: loupeRect.midX - cell / 2, y: loupeRect.midY - cell / 2,
                            width: cell, height: cell)
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        NSBezierPath(rect: center).stroke()

        if let color = colorAtViewPoint(point) {
            let hex = color.hexString
            let isFlash = copiedFlashUntil.map { $0 > Date() } ?? false
            drawLabel(isFlash ? "\(hex) 복사됨" : hex,
                      near: CGPoint(x: loupeRect.midX, y: loupeRect.minY - 26))
        }
    }

    // MARK: - Helpers

    private func colorAtViewPoint(_ p: CGPoint) -> NSColor? {
        guard let sampler, bounds.width > 0, bounds.height > 0 else { return nil }
        let px = p.x / bounds.width * imageSize.width
        let py = (bounds.height - p.y) / bounds.height * imageSize.height
        return sampler.color(atTopDownPixel: CGPoint(x: px, y: py))
    }

    private func clampToBounds(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX),
                y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
