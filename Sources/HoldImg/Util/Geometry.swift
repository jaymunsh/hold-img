import AppKit
import CoreGraphics

enum ScreenGeometry {
    /// Converts a selection rect given in global AppKit coordinates (y-up)
    /// into pixel coordinates of that display's captured image (y-down, top-left origin).
    static func pixelRect(forSelection selection: CGRect,
                          inScreenFrame screenFrame: CGRect,
                          imageSize: CGSize) -> CGRect {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return .zero }
        let scaleX = imageSize.width / screenFrame.width
        let scaleY = imageSize.height / screenFrame.height
        let x = (selection.minX - screenFrame.minX) * scaleX
        let y = (screenFrame.maxY - selection.maxY) * scaleY
        let rect = CGRect(x: x, y: y,
                          width: selection.width * scaleX,
                          height: selection.height * scaleY)
        return rect.integral.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Converts a CG screen rect (top-left origin, e.g. SCWindow.frame) to AppKit global coordinates (y-up).
    static func appKitRect(fromCG rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryScreenHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func forDisplayID(_ id: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == id }
    }
}

/// RGBA pixel sampler for a CGImage, indexed by top-left-origin pixel coordinates.
final class PixelSampler {
    private let data: [UInt8]
    let width: Int
    let height: Int
    private let bytesPerRow: Int

    init?(cgImage: CGImage) {
        width = cgImage.width
        height = cgImage.height
        bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = buffer
    }

    /// Point in image pixel coordinates with top-left origin.
    func color(atTopDownPixel point: CGPoint) -> NSColor? {
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let offset = y * bytesPerRow + x * 4
        return NSColor(srgbRed: CGFloat(data[offset]) / 255,
                       green: CGFloat(data[offset + 1]) / 255,
                       blue: CGFloat(data[offset + 2]) / 255,
                       alpha: 1)
    }
}

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }
}
