import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let state = AppState()
    private var statusItem: StatusItemController!
    private var pill: PillWindowController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        pill = PillWindowController(state: state)
        statusItem = StatusItemController(state: state)
        statusItem.onOpenSettings = { [weak self] in self?.showSettings() }

        state.start()
        observePhase()

        // First run, or a revoked permission: show the user what is missing
        // instead of silently doing nothing when they press fn.
        if !state.missingPermissions.isEmpty {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }

    func windowWillClose(_ notification: Notification) {
        state.endPermissionWatch()
    }

    /// Re-arms itself after every change, which is the supported way to follow
    /// an @Observable property from outside SwiftUI.
    private func observePhase() {
        withObservationTracking {
            _ = state.phase
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pill.update(for: self.state.phase)
                self.statusItem.update(for: self.state.phase)
                self.observePhase()
            }
        }
    }

    // MARK: - Settings window

    func showSettings() {
        state.beginPermissionWatch()

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: Metrics.windowWidth, height: Metrics.windowHeight
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Talk"
        // The rail reaches the top of the window, with the traffic lights
        // floating over it, so there is no empty title bar band.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(Palette.rail)
        window.appearance = NSAppearance(named: .darkAqua)
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(state: state))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}

/// Login item registration. `SMAppService` needs the app to live somewhere
/// stable (i.e. /Applications), so failures are reported rather than hidden.
@MainActor
enum LoginItem {
    static func sync(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            Log.error("login", "could not update login item: \(error.localizedDescription)")
        }
    }
}
