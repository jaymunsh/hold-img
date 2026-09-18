import AppKit
import KeyboardShortcuts

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var recentMenuItem: NSMenuItem?

    override init() {
        super.init()
        item.button?.image = NSImage(
            systemSymbolName: "photo.on.rectangle.angled",
            accessibilityDescription: "HoldImg"
        )
        let menu = NSMenu()
        menu.delegate = self

        addAction(menu, "영역 캡처", .captureRegion, #selector(captureRegion))
        addAction(menu, "윈도우 캡처", .captureWindow, #selector(captureWindow))
        addAction(menu, "마지막 영역 재캡처", .recaptureRegion, #selector(recapture))
        addAction(menu, "클립보드 이미지 붙여넣기", .pasteFloat, #selector(pasteFloat))
        menu.addItem(action("이미지 파일 열기…", #selector(openFiles)))
        menu.addItem(.separator())

        let recent = NSMenuItem(title: "최근 캡처", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu()
        menu.addItem(recent)
        recentMenuItem = recent
        menu.addItem(.separator())

        menu.addItem(action("모든 창 닫기", #selector(closeAll)))
        menu.addItem(action("모든 창 클릭-스루 해제", #selector(disableClickThrough)))
        menu.addItem(.separator())

        menu.addItem(action("설정…", #selector(openSettings), keyEquivalent: ","))
        menu.addItem(action("단축키 보기", #selector(showShortcuts)))
        menu.addItem(.separator())
        menu.addItem(action("HoldImg 종료", #selector(quit), keyEquivalent: "q"))

        item.menu = menu
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
    }

    private func rebuildRecentSubmenu() {
        guard let submenu = recentMenuItem?.submenu else { return }
        submenu.removeAllItems()
        let entries = CaptureHistoryStore.shared.entries()
        if entries.isEmpty {
            let empty = NSMenuItem(title: "없음", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for entry in entries {
                let menuItem = NSMenuItem(
                    title: Self.entryTitle(for: entry.date),
                    action: #selector(refloatEntry(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.representedObject = entry.url
                if let image = NSImage(contentsOf: entry.url) {
                    image.size = thumbnailSize(for: image.size)
                    menuItem.image = image
                }
                submenu.addItem(menuItem)
            }
            submenu.addItem(.separator())
            let clear = NSMenuItem(title: "기록 전체 삭제",
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
