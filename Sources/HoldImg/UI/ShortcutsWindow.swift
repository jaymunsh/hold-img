import AppKit
import SwiftUI
import KeyboardShortcuts

@MainActor
final class ShortcutsWindowController {
    static let shared = ShortcutsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: ShortcutsView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 380),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "단축키 보기"
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
    private func shortcutText(_ name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.Shortcut(name: name)?.description ?? "미지정"
    }

    var body: some View {
        List {
            Section("전역 단축키 (설정에서 변경 가능)") {
                row("영역 캡처", shortcutText(.captureRegion))
                row("윈도우 캡처", shortcutText(.captureWindow))
                row("마지막 영역 재캡처", shortcutText(.recaptureRegion))
                row("클립보드 이미지 붙여넣기", shortcutText(.pasteFloat))
                row("모든 창 숨기기/보이기", shortcutText(.toggleHidden))
            }
            Section("플로팅 창 (포커스된 상태)") {
                row("클릭 — 이미지 복사", "")
                row("더블클릭 — 축소/복원", "")
                row("우클릭 드래그 — 파일로 드롭", "")
                row("스크롤 — 크기 조절", "")
                row("⌥스크롤 — 투명도 조절", "")
                row("모서리 드래그 — 리사이즈", "")
                row("복사", "⌘C")
                row("다른 이름으로 저장", "⌘S")
                row("주석 모드 (펜·화살표·사각형·모자이크·텍스트)", "P")
                row("항상 위 토글", "T")
                row("클릭-스루 토글", "G")
                row("닫기", "⌘W / Esc")
            }
            Section("주석 모드") {
                row("주석 되돌리기", "⌘Z")
                row("텍스트 확정 / 취소", "Return / Esc")
                row("완료(이미지에 적용) / 취소", "✓ / Esc·P")
            }
            Section("캡처 화면") {
                row("픽셀 컬러 복사", "C")
                row("돋보기 토글", "M")
                row("비율/크기 선택", "1~6")
                row("취소", "Esc")
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
