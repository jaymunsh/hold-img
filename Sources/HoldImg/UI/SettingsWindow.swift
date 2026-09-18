import AppKit
import SwiftUI
import KeyboardShortcuts

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = SettingsView()
                .environmentObject(SettingsStore.shared)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "HoldImg 설정"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("캡처") {
                Toggle("캡처 시 클립보드에도 복사", isOn: $settings.autoCopyOnCapture)
                Toggle("새 창을 항상 위에 표시", isOn: $settings.defaultAlwaysOnTop)
                Stepper("최근 캡처 보관: \(settings.historyLimit)개",
                        value: $settings.historyLimit, in: 1...50)
                HStack {
                    Text("기본 저장 위치")
                    Spacer()
                    Text(settings.saveDirectory?.lastPathComponent ?? "마지막 사용 위치")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("변경…") { chooseSaveDirectory() }
                }
            }
            Section("단축키") {
                LabeledContent("영역 캡처") {
                    KeyboardShortcuts.Recorder(for: .captureRegion)
                }
                LabeledContent("윈도우 캡처") {
                    KeyboardShortcuts.Recorder(for: .captureWindow)
                }
                LabeledContent("마지막 영역 재캡처") {
                    KeyboardShortcuts.Recorder(for: .recaptureRegion)
                }
                LabeledContent("클립보드 붙여넣기") {
                    KeyboardShortcuts.Recorder(for: .pasteFloat)
                }
            }
            Section("앱") {
                Toggle("로그인 시 자동 실행", isOn: $settings.launchAtLogin)
                Toggle("Dock 아이콘 표시", isOn: $settings.showDockIcon)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            settings.saveDirectory = panel.url
        }
    }
}
