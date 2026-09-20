import AppKit
import ServiceManagement
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let autoCopyOnCapture = "autoCopyOnCapture"
        static let defaultAlwaysOnTop = "defaultAlwaysOnTop"
        static let showDockIcon = "showDockIcon"
        static let historyLimit = "historyLimit"
        static let trashOnHistoryPurge = "trashOnHistoryPurge"
        static let saveDirectory = "saveDirectory"
        static let language = "language"
    }

    /// Posted when `language` changes so AppKit chrome (menus, window
    /// titles) can rebuild; SwiftUI views refresh via @Published.
    static let languageDidChange =
        Notification.Name("HoldImgLanguageDidChange")

    /// "system" | "ko" | "en"
    @Published var language: String {
        didSet {
            defaults.set(language, forKey: Key.language)
            NotificationCenter.default.post(
                name: SettingsStore.languageDidChange, object: nil)
        }
    }

    @Published var autoCopyOnCapture: Bool {
        didSet { defaults.set(autoCopyOnCapture, forKey: Key.autoCopyOnCapture) }
    }

    @Published var defaultAlwaysOnTop: Bool {
        didSet { defaults.set(defaultAlwaysOnTop, forKey: Key.defaultAlwaysOnTop) }
    }

    @Published var showDockIcon: Bool {
        didSet {
            defaults.set(showDockIcon, forKey: Key.showDockIcon)
            applyDockPolicy()
        }
    }

    @Published var historyLimit: Int {
        didSet {
            defaults.set(historyLimit, forKey: Key.historyLimit)
            CaptureHistoryStore.shared.prune()
        }
    }

    /// When on, purged history files go to the Trash instead of being
    /// deleted outright. Default off — purges are permanent.
    @Published var trashOnHistoryPurge: Bool {
        didSet { defaults.set(trashOnHistoryPurge, forKey: Key.trashOnHistoryPurge) }
    }

    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    /// Directory suggested to the save panel. nil = system default (last used).
    @Published var saveDirectory: URL? {
        didSet { defaults.set(saveDirectory?.path, forKey: Key.saveDirectory) }
    }

    private init() {
        defaults.register(defaults: [
            Key.autoCopyOnCapture: false,
            Key.defaultAlwaysOnTop: true,
            Key.showDockIcon: false,
            Key.historyLimit: 20,
        ])
        autoCopyOnCapture = defaults.bool(forKey: Key.autoCopyOnCapture)
        defaultAlwaysOnTop = defaults.bool(forKey: Key.defaultAlwaysOnTop)
        showDockIcon = defaults.bool(forKey: Key.showDockIcon)
        historyLimit = max(1, defaults.integer(forKey: Key.historyLimit))
        trashOnHistoryPurge = defaults.bool(forKey: Key.trashOnHistoryPurge)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        language = defaults.string(forKey: Key.language) ?? "system"
        if let path = defaults.string(forKey: Key.saveDirectory), !path.isEmpty {
            saveDirectory = URL(fileURLWithPath: path)
        } else {
            saveDirectory = nil
        }
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
