import AppKit
import ScreenCaptureKit

/// A frozen, full-resolution capture of one display plus its matching NSScreen.
struct DisplayFrame {
    let display: SCDisplay
    let screen: NSScreen
    let image: CGImage
}

@MainActor
final class ScreenCaptureService {
    static let shared = ScreenCaptureService()

    /// Returns true if screen-recording permission is usable.
    /// CGPreflightScreenCaptureAccess() is unreliable for self-signed/dev builds,
    /// so when it says no we double-check by asking ScreenCaptureKit for real
    /// shareable content before bothering the user.
    @MainActor
    func ensurePermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // CGPreflightScreenCaptureAccess() can lie for self-signed/dev builds,
        // so double-check with a real ScreenCaptureKit query.
        if let content = try? await SCShareableContent.current,
           !content.displays.isEmpty { return true }
        CGRequestScreenCaptureAccess()
        return false
    }

    func captureAllDisplays() async throws -> [DisplayFrame] {
        let content = try await SCShareableContent.current
        var frames: [DisplayFrame] = []
        for display in content.displays {
            guard let screen = NSScreen.forDisplayID(display.displayID) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: Self.nativeResolutionConfig(for: filter)
            )
            frames.append(DisplayFrame(display: display, screen: screen, image: image))
        }
        return frames
    }

    func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: Self.nativeResolutionConfig(for: filter)
        )
    }

    /// Default SCStreamConfiguration outputs at point size (1x); ask for the
    /// display's native pixel resolution so captures stay sharp on Retina.
    private static func nativeResolutionConfig(for filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.captureResolution = .best
        return config
    }

    /// On-screen, normal-layer windows owned by other apps, front to back.
    func capturableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let ownBundleID = Bundle.main.bundleIdentifier
        return content.windows.filter { window in
            window.isOnScreen
                && window.windowLayer == 0
                && window.owningApplication?.bundleIdentifier != ownBundleID
                && window.frame.width >= 40
                && window.frame.height >= 40
        }
    }
}
