import AppKit

/// Keeps the most recent captures as PNG files on disk so they can be re-floated.
final class CaptureHistoryStore {
    @MainActor static let shared = CaptureHistoryStore()

    struct Entry {
        let url: URL
        let date: Date
    }

    private let directory: URL
    private let fileManager = FileManager.default

    /// On-disk folder holding the history PNGs — exposed for Finder reveal.
    var directoryURL: URL { directory }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("HoldImg/History",
                                                         isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.directory,
                                         withIntermediateDirectories: true)
    }

    @MainActor
    func add(_ image: NSImage) {
        guard let cg = image.cgImageRef else { return }
        let directory = self.directory
        let name = Self.filenameFormatter.string(from: Date())
            + "-\(UUID().uuidString.prefix(6)).png"
        // PNG encoding a Retina frame costs ~100-300ms — too long to spend
        // on the main thread while the new panel is animating in.
        Task.detached(priority: .utility) {
            guard let data = NSBitmapImageRep(cgImage: cg)
                .representation(using: .png, properties: [:]) else { return }
            try? data.write(to: directory.appendingPathComponent(name))
            await MainActor.run { CaptureHistoryStore.shared.prune() }
        }
    }

    /// Newest first.
    @MainActor
    func entries() -> [Entry] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "png" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return Entry(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    @MainActor
    func prune() {
        let limit = SettingsStore.shared.historyLimit
        let all = entries()
        for entry in all.dropFirst(max(0, limit)) {
            delete(entry.url)
        }
    }

    @MainActor
    func clear() {
        for entry in entries() {
            delete(entry.url)
        }
    }

    /// Settings-gated: Trash when enabled, permanent delete otherwise.
    @MainActor
    private func delete(_ url: URL) {
        if SettingsStore.shared.trashOnHistoryPurge {
            try? fileManager.trashItem(at: url, resultingItemURL: nil)
        } else {
            try? fileManager.removeItem(at: url)
        }
    }

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
