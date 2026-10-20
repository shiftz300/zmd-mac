import AppKit

// Developer preview uses the production window without launching Wine.
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    var settings: SettingsWindowController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count >= 2 else { NSApp.terminate(nil); return }
        settings = SettingsWindowController(appURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        settings?.didClose = { NSApp.terminate(nil) }
        settings?.present()

    }
}

@main
enum SettingsPreview {
    static func main() {
        let application = NSApplication.shared
        let delegate = PreviewDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
