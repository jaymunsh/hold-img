import AppKit

@main
enum HoldImgApp {
    // NSApplication.delegate is weak — keep a strong reference for the app's lifetime.
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
