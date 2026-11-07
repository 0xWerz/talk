import AppKit

/// Talk runs as a menu-bar accessory: no dock icon, no main window.
@main
@MainActor
struct TalkApp {
    /// Held statically because `NSApplication.delegate` is a weak reference.
    private static let delegate = AppDelegate()

    static func main() {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-ui") {
            RenderPreview.run(arguments: Array(CommandLine.arguments[(index + 1)...]))
        }
        #endif

        let application = NSApplication.shared
        application.delegate = delegate
        application.run()
    }
}
