import AppKit
import ScreenCaptureKit

@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    enum Mode {
        case region
        case window
    }

    private var overlayWindows: [CaptureOverlayWindow] = []
    private var frozenFrames: [DisplayFrame] = []
    private var capturableWindows: [SCWindow] = []

    /// Last region captured, in global AppKit coordinates. Used for re-capture.
    private(set) var lastCaptureRect: CGRect?

    var isCapturing: Bool { !overlayWindows.isEmpty }

    // MARK: - Entry points

    func startRegionCapture() {
        startSession(mode: .region)
    }

    func startWindowCapture() {
        startSession(mode: .window)
    }

    func recaptureLastRegion() {
        guard let rect = lastCaptureRect else {
            NSSound.beep()
            return
        }
        Task {
            guard await ScreenCaptureService.shared.ensurePermission() else {
                showPermissionAlert()
                return
            }
            do {
                let frames = try await ScreenCaptureService.shared.captureAllDisplays()
                guard let image = Self.stitch(rect: rect, frames: frames) else { return }
                present(image, inScreenRect: rect)
            } catch {
                showCaptureError(error)
            }
        }
    }

    /// Floats an image that came from the pasteboard or a file.
    func presentExternalImage(_ image: NSImage, near point: NSPoint? = nil) {
        FloatingWindowManager.shared.show(image: image, near: point ?? NSEvent.mouseLocation)
    }

    // MARK: - Session

    private func startSession(mode: Mode) {
        guard !isCapturing else { return }
        Task {
            guard await ScreenCaptureService.shared.ensurePermission() else {
                showPermissionAlert()
                return
            }
            do {
                let frames = try await ScreenCaptureService.shared.captureAllDisplays()
                guard !frames.isEmpty else {
                    showPermissionAlert()
                    return
                }
                frozenFrames = frames
                if mode == .window {
                    capturableWindows = (try? await ScreenCaptureService.shared.capturableWindows()) ?? []
                }
                showOverlays(mode: mode)
            } catch {
                showCaptureError(error)
            }
        }
    }

    private func showOverlays(mode: Mode) {
        NSApp.activate(ignoringOtherApps: true)
        for frame in frozenFrames {
            let windows = mode == .window
                ? capturableWindows.filter { $0.frame.intersects(frame.display.frame) }
                : []
            let overlay = CaptureOverlayWindow(
                displayFrame: frame,
                mode: mode,
                windows: windows,
                coordinator: self
            )
            overlay.orderFrontRegardless()
            overlayWindows.append(overlay)
        }
        overlayWindows.first?.makeKey()
    }

    // MARK: - Overlay callbacks

    func overlay(_ overlay: CaptureOverlayWindow, didSelect rectInView: CGRect) {
        let globalRect = rectInView.offsetBy(dx: overlay.screenFrame.origin.x,
                                             dy: overlay.screenFrame.origin.y)
        let frames = frozenFrames
        closeOverlays()
        guard globalRect.width >= 4, globalRect.height >= 4 else { return }
        lastCaptureRect = globalRect
        guard let image = Self.stitch(rect: globalRect, frames: frames) else { return }
        present(image, inScreenRect: globalRect)
    }

    func overlayDidCancel(_ overlay: CaptureOverlayWindow) {
        closeOverlays()
    }

    func overlay(_ overlay: CaptureOverlayWindow, didPick window: SCWindow) {
        closeOverlays()
        let appKitFrame = ScreenGeometry.appKitRect(
            fromCG: window.frame,
            primaryScreenHeight: ScreenGeometry.primaryScreenHeight
        )
        Task {
            do {
                let cgImage = try await ScreenCaptureService.shared.captureWindow(window)
                let image = NSImage(cgImage: cgImage, size: appKitFrame.size)
                present(image, inScreenRect: appKitFrame)
            } catch {
                showCaptureError(error)
            }
        }
    }

    private func closeOverlays() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        frozenFrames.removeAll()
        capturableWindows.removeAll()
    }

    // MARK: - Output

    private func present(_ image: NSImage, inScreenRect rect: CGRect) {
        FloatingWindowManager.shared.show(image: image, frameInScreen: rect)
        CaptureHistoryStore.shared.add(image)
        if SettingsStore.shared.autoCopyOnCapture {
            ClipboardService.copy(image)
        }
    }

    /// Crops `rect` (global AppKit) out of the frozen display frames,
    /// stitching across multiple displays if needed.
    static func stitch(rect: CGRect, frames: [DisplayFrame]) -> NSImage? {
        let canvas = NSImage(size: rect.size)
        canvas.lockFocus()
        defer { canvas.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high
        var drew = false
        for frame in frames {
            let intersection = rect.intersection(frame.screen.frame)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let cropPixels = ScreenGeometry.pixelRect(
                forSelection: intersection,
                inScreenFrame: frame.screen.frame,
                imageSize: CGSize(width: frame.image.width, height: frame.image.height)
            )
            guard !cropPixels.isEmpty,
                  let crop = frame.image.cropping(to: cropPixels) else { continue }
            let dest = CGRect(
                x: intersection.minX - rect.minX,
                y: intersection.minY - rect.minY,
                width: intersection.width,
                height: intersection.height
            )
            NSImage(cgImage: crop, size: intersection.size).draw(in: dest)
            drew = true
        }
        return drew ? canvas : nil
    }

    // MARK: - Alerts

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "화면 기록 권한이 필요합니다"
        alert.informativeText = "시스템 설정 → 개인정보 보호 및 보안 → 화면 기록에서 HoldImg를 허용해주세요. 허용 후 다시 시도하면 됩니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "설정 열기")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showCaptureError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(error: error)
        alert.messageText = "캡처에 실패했습니다"
        alert.runModal()
    }
}
