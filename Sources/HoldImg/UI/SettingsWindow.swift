import AppKit
import SwiftUI
import KeyboardShortcuts

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var languageObserver: NSObjectProtocol?

    init() {
        languageObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.languageDidChange,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.window?.title = L10n.tr("HoldImg 설정")
            }
        }
    }

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
            window.title = L10n.tr("HoldImg 설정")
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
            Section(L10n.tr("캡처")) {
                Toggle(L10n.tr("캡처 시 클립보드에도 복사"), isOn: $settings.autoCopyOnCapture)
                Toggle(L10n.tr("새 창을 항상 위에 표시"), isOn: $settings.defaultAlwaysOnTop)
                Stepper(L10n.tr("최근 캡처 보관: %d개", settings.historyLimit),
                        value: $settings.historyLimit, in: 1...50)
                HStack {
                    Text(L10n.tr("기본 저장 위치"))
                    Spacer()
                    Text(settings.saveDirectory?.lastPathComponent ?? L10n.tr("마지막 사용 위치"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button(L10n.tr("변경…")) { chooseSaveDirectory() }
                }
            }
            Section(L10n.tr("단축키")) {
                LabeledContent(L10n.tr("영역 캡처")) {
                    KeyboardShortcuts.Recorder(for: .captureRegion)
                }
                LabeledContent(L10n.tr("윈도우 캡처")) {
                    KeyboardShortcuts.Recorder(for: .captureWindow)
                }
                LabeledContent(L10n.tr("마지막 영역 재캡처")) {
                    KeyboardShortcuts.Recorder(for: .recaptureRegion)
                }
                LabeledContent(L10n.tr("클립보드 붙여넣기")) {
                    KeyboardShortcuts.Recorder(for: .pasteFloat)
                }
                LabeledContent(L10n.tr("모든 창 숨기기/보이기")) {
                    KeyboardShortcuts.Recorder(for: .toggleHidden)
                }
                LabeledContent(L10n.tr("닫은 창 복원")) {
                    KeyboardShortcuts.Recorder(for: .reopenClosed)
                }
            }
            Section(L10n.tr("앱")) {
                Picker(L10n.tr("언어"), selection: $settings.language) {
                    Text(L10n.tr("시스템 기본")).tag("system")
                    Text("한국어").tag("ko")
                    Text("English").tag("en")
                }
                Toggle(L10n.tr("로그인 시 자동 실행"), isOn: $settings.launchAtLogin)
                Toggle(L10n.tr("Dock 아이콘 표시"), isOn: $settings.showDockIcon)
            }
            Section {
                HStack {
                    Text("HoldImg")
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("버전 %@", Self.appVersion))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link(L10n.tr("업데이트 로그 ↗"),
                         destination: URL(string: "https://github.com/jaymunsh/hold-img/releases")!)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
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
