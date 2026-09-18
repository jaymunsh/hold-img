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
        static let saveDirectory = "saveDirectory"
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
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
