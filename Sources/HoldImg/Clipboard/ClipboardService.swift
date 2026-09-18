import AppKit
import UniformTypeIdentifiers

extension NSImage {
    var cgImageRef: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func pngData() -> Data? {
        guard let cg = cgImageRef else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    func jpegData(quality: CGFloat = 0.92) -> Data? {
        guard let cg = cgImageRef else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        )
    }
}

enum ClipboardService {
    static func copy(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if let png = image.pngData() { item.setData(png, forType: .png) }
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
    }

    static func imageFromPasteboard() -> NSImage? {
        let pb = NSPasteboard.general
        if let image = NSImage(pasteboard: pb) { return image }
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first,
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }

    /// NSSavePanel for PNG/JPEG export.
    @MainActor
    static func saveWithPanel(image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = defaultFilename()
        panel.canCreateDirectories = true
        if let dir = SettingsStore.shared.saveDirectory {
            panel.directoryURL = dir
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.lowercased()
        let data = (ext == "jpg" || ext == "jpeg") ? image.jpegData() : image.pngData()
        try? data?.write(to: url)
    }

    static func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "HoldImg-\(formatter.string(from: Date())).png"
    }
}
