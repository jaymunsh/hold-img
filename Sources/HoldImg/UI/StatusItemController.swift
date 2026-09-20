import AppKit
import KeyboardShortcuts

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var recentMenuItem: NSMenuItem?
    private var hideMenuItem: NSMenuItem?
    private var reopenMenuItem: NSMenuItem?
    /// History PNGs are write-once files, so decoded thumbnails are safe to
    /// keep keyed by path — avoids re-decoding every entry on each menu open.
    private let thumbnailCache = NSCache<NSString, NSImage>()

    override init() {
        super.init()
        item.button?.image = Self.menuBarImage()
        rebuildMenu()
        NotificationCenter.default.addObserver(
            forName: SettingsStore.languageDidChange,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildMenu() }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        addAction(menu, L10n.tr("영역 캡처"), .captureRegion, #selector(captureRegion))
        addAction(menu, L10n.tr("윈도우 캡처"), .captureWindow, #selector(captureWindow))
        addAction(menu, L10n.tr("마지막 영역 재캡처"), .recaptureRegion, #selector(recapture))
        addAction(menu, L10n.tr("클립보드 이미지 붙여넣기"), .pasteFloat, #selector(pasteFloat))
        menu.addItem(action(L10n.tr("이미지 파일 열기…"), #selector(openFiles)))
        menu.addItem(.separator())

        let recent = NSMenuItem(title: L10n.tr("최근 캡처"), action: nil, keyEquivalent: "")
        recent.submenu = NSMenu()
        menu.addItem(recent)
        recentMenuItem = recent
        menu.addItem(.separator())

        let reopen = action(L10n.tr("마지막으로 닫은 창 복원"), #selector(reopenClosed))
        reopen.setShortcut(for: .reopenClosed)
        menu.addItem(reopen)
        reopenMenuItem = reopen
        let hide = action(L10n.tr("모든 창 숨기기"), #selector(toggleHidden))
        hide.setShortcut(for: .toggleHidden)
        menu.addItem(hide)
        hideMenuItem = hide
        menu.addItem(action(L10n.tr("모든 창 닫기"), #selector(closeAll)))
        menu.addItem(action(L10n.tr("모든 창 클릭-스루 해제"), #selector(disableClickThrough)))
        menu.addItem(.separator())

        menu.addItem(action(L10n.tr("설정…"), #selector(openSettings), keyEquivalent: ","))
        menu.addItem(action(L10n.tr("단축키 보기"), #selector(showShortcuts)))
        menu.addItem(.separator())
        menu.addItem(action(L10n.tr("HoldImg 종료"), #selector(quit), keyEquivalent: "q"))

        item.menu = menu
    }

    private static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for name in ["menubar_18", "menubar_36", "menubar_54"] {
            if let path = Bundle.main.path(forResource: name, ofType: "png"),
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let rep = NSBitmapImageRep(data: data) {
                rep.size = NSSize(width: 18, height: 18)
                image.addRepresentation(rep)
            }
        }
        if image.representations.isEmpty,
           let symbol = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                accessibilityDescription: "HoldImg") {
            symbol.isTemplate = true
            return symbol
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu construction helpers

    private func action(_ title: String,
                        _ selector: Selector,
                        keyEquivalent: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: keyEquivalent)
        menuItem.target = self
        return menuItem
    }

    private func addAction(_ menu: NSMenu,
                           _ title: String,
                           _ shortcutName: KeyboardShortcuts.Name,
                           _ selector: Selector) {
        let menuItem = action(title, selector)
        menuItem.setShortcut(for: shortcutName)
        menu.addItem(menuItem)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildRecentSubmenu()
        hideMenuItem?.title = FloatingWindowManager.shared.allHidden
            ? L10n.tr("모든 창 보이기") : L10n.tr("모든 창 숨기기")
        reopenMenuItem?.isEnabled = FloatingWindowManager.shared.canReopen
    }

    private func rebuildRecentSubmenu() {
        guard let submenu = recentMenuItem?.submenu else { return }
        submenu.removeAllItems()
        let entries = CaptureHistoryStore.shared.entries()
        let openFolder = NSMenuItem(title: L10n.tr("기록 폴더 열기"),
                                  action: #selector(openHistoryFolder),
                                  keyEquivalent: "")
        openFolder.target = self
        if entries.isEmpty {
            let empty = NSMenuItem(title: L10n.tr("없음"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            submenu.addItem(.separator())
            submenu.addItem(openFolder)
        } else {
            for entry in entries {
                let menuItem = NSMenuItem(
                    title: Self.entryTitle(for: entry.date),
                    action: #selector(refloatEntry(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.representedObject = entry.url
                let key = entry.url.path as NSString
                if let cached = thumbnailCache.object(forKey: key) {
                    menuItem.image = cached
                } else if let image = NSImage(contentsOf: entry.url) {
                    image.size = thumbnailSize(for: image.size)
                    thumbnailCache.setObject(image, forKey: key)
                    menuItem.image = image
                }
                submenu.addItem(menuItem)
            }
            submenu.addItem(.separator())
            submenu.addItem(openFolder)
            let clear = NSMenuItem(title: L10n.tr("기록 전체 삭제"),
                                   action: #selector(clearHistory),
                                   keyEquivalent: "")
            clear.target = self
            submenu.addItem(clear)
        }
    }

    private func thumbnailSize(for size: CGSize) -> CGSize {
        let height: CGFloat = 28
        let scale = height / max(size.height, 1)
        return CGSize(width: max(16, size.width * scale), height: height)
    }

    private static let entryDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm:ss"
        return f
    }()

    private static func entryTitle(for date: Date) -> String {
        entryDateFormatter.string(from: date)
    }

    // MARK: - Actions

    @objc private func captureRegion() {
        CaptureCoordinator.shared.startRegionCapture()
    }

    @objc private func captureWindow() {
        CaptureCoordinator.shared.startWindowCapture()
    }

    @objc private func recapture() {
        CaptureCoordinator.shared.recaptureLastRegion()
    }

    @objc private func pasteFloat() {
        HotkeyManager.pasteFromClipboard()
    }

    @objc private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .bmp, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let image = NSImage(contentsOf: url) {
                CaptureCoordinator.shared.presentExternalImage(image)
            }
        }
    }

    @objc private func refloatEntry(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let image = NSImage(contentsOf: url) else { return }
        CaptureCoordinator.shared.presentExternalImage(image)
    }

    @objc private func clearHistory() {
        CaptureHistoryStore.shared.clear()
    }

    @objc private func openHistoryFolder() {
        NSWorkspace.shared.open(CaptureHistoryStore.shared.directoryURL)
    }

    @objc private func reopenClosed() {
        FloatingWindowManager.shared.reopenLastClosed()
    }

    @objc private func toggleHidden() {
        FloatingWindowManager.shared.toggleHidden()
    }

    @objc private func closeAll() {
        FloatingWindowManager.shared.closeAll()
    }

    @objc private func disableClickThrough() {
        FloatingWindowManager.shared.disableClickThroughAll()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func showShortcuts() {
        ShortcutsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
