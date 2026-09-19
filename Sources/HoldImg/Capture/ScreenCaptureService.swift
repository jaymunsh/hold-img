import AppKit
import ScreenCaptureKit

/// A frozen, full-resolution capture of one display plus its matching NSScreen.
/// @unchecked: NSScreen isn't Sendable, but instances are immutable
/// system objects and the frame is only ever read.
struct DisplayFrame: @unchecked Sendable {
    let display: SCDisplay
    let screen: NSScreen
    let image: CGImage
}

/// Boxes non-Sendable framework objects (SCDisplay, NSScreen) so they can
/// cross a task boundary. Both are immutable system objects — read-only
/// access after the capture call returns is safe.
private struct SendableBox<T>: @unchecked Sendable {
    let value: T
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

    /// One shareable-content fetch for a capture session — reusing it for
    /// both display frames and the window list avoids a second round-trip
    /// and keeps the frozen frames consistent with the detected windows.
    func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
    }

    func captureAllDisplays(from content: SCShareableContent) async throws -> [DisplayFrame] {
        // NSScreen lookup stays on the main actor; the screenshots run in
        // parallel so multi-display setups don't capture serially.
        let pairs: [(SCDisplay, NSScreen)] = content.displays.compactMap { display in
            guard let screen = NSScreen.forDisplayID(display.displayID) else { return nil }
            return (display, screen)
        }
        return try await withThrowingTaskGroup(of: DisplayFrame.self) { group in
            for (display, screen) in pairs {
                let packed = SendableBox(value: (display, screen))
                group.addTask {
                    let (display, screen) = packed.value
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: Self.nativeResolutionConfig(for: filter)
                    )
                    return DisplayFrame(display: display, screen: screen, image: image)
                }
            }
            var frames: [DisplayFrame] = []
            for try await frame in group { frames.append(frame) }
            return frames
        }
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
    nonisolated private static func nativeResolutionConfig(for filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.captureResolution = .best
        return config
    }

    /// On-screen, normal-layer windows owned by other apps, front to back.
    func capturableWindows(from content: SCShareableContent) -> [SCWindow] {
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
