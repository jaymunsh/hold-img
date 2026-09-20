import AppKit
import SwiftUI
import KeyboardShortcuts

@MainActor
final class ShortcutsWindowController {
    static let shared = ShortcutsWindowController()
    private var window: NSWindow?
    private var languageObserver: NSObjectProtocol?

    init() {
        languageObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.languageDidChange,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.window?.title = L10n.tr("단축키 보기")
            }
        }
    }

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: ShortcutsView()
                .environmentObject(SettingsStore.shared))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 380),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.tr("단축키 보기")
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ShortcutsView: View {
    // Subscribed so a language change re-renders every label.
    @EnvironmentObject private var settings: SettingsStore

    private func shortcutText(_ name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.Shortcut(name: name)?.description ?? L10n.tr("미지정")
    }

    var body: some View {
        List {
            Section(L10n.tr("전역 단축키 (설정에서 변경 가능)")) {
                row(L10n.tr("영역 캡처"), shortcutText(.captureRegion))
                row(L10n.tr("윈도우 캡처"), shortcutText(.captureWindow))
                row(L10n.tr("마지막 영역 재캡처"), shortcutText(.recaptureRegion))
                row(L10n.tr("클립보드 이미지 붙여넣기"), shortcutText(.pasteFloat))
                row(L10n.tr("모든 창 숨기기/보이기"), shortcutText(.toggleHidden))
                row(L10n.tr("닫은 창 복원"), shortcutText(.reopenClosed))
            }
            Section(L10n.tr("플로팅 창 (포커스된 상태)")) {
                row(L10n.tr("클릭 — 이미지 복사"), "")
                row(L10n.tr("더블클릭 — 축소/복원"), "")
                row(L10n.tr("우클릭 드래그 — 파일로 드롭"), "")
                row(L10n.tr("스크롤 — 크기 조절"), "")
                row(L10n.tr("⌥스크롤 — 투명도 조절"), "")
                row(L10n.tr("모서리·가장자리 드래그 — 리사이즈"), "")
                row(L10n.tr("비율 잠금 토글"), "L")
                row(L10n.tr("복사"), "⌘C")
                row(L10n.tr("다른 이름으로 저장"), "⌘S")
                row(L10n.tr("주석 모드 (펜·형광펜·화살표·사각형·모자이크·텍스트)"), "P")
                row(L10n.tr("회전 90° (시계/반시계)"), "R / ⇧R")
                row(L10n.tr("좌우 반전"), "F")
                row(L10n.tr("미세 이동 (1pt / 10pt)"), L10n.tr("방향키 / ⇧방향키"))
                row(L10n.tr("항상 위 토글"), "T")
                row(L10n.tr("클릭-스루 토글"), "G")
                row(L10n.tr("닫기"), "⌘W / Esc")
            }
            Section(L10n.tr("주석 모드")) {
                row(L10n.tr("주석 되돌리기"), "⌘Z")
                row(L10n.tr("텍스트 확정 / 취소"), "Return / Esc")
                row(L10n.tr("완료(이미지에 적용) / 취소"), "✓ / Esc·P")
            }
            Section(L10n.tr("캡처 화면")) {
                row(L10n.tr("픽셀 컬러 복사"), "C")
                row(L10n.tr("돋보기 토글"), "M")
                row(L10n.tr("비율/크기 선택"), "1~6")
                row(L10n.tr("취소"), "Esc")
            }
        }
        .listStyle(.inset)
    }

    private func row(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .foregroundStyle(.secondary)
        }
    }
}
