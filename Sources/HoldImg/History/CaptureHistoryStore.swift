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
        guard let data = image.pngData() else { return }
        let name = Self.filenameFormatter.string(from: Date()) + "-\(UUID().uuidString.prefix(6)).png"
        try? data.write(to: directory.appendingPathComponent(name))
        prune()
    }

    /// Newest first.
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
            try? fileManager.removeItem(at: entry.url)
        }
    }

    func clear() {
        for entry in entries() {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
