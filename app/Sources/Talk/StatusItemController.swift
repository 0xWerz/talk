import AppKit
import SwiftUI

/// The menu-bar presence: an animated glyph plus the menu.
@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let state: AppState
    private var animationTimer: Timer?
    private var tick: TimeInterval = 0

    var onOpenSettings: (() -> Void)?

    init(state: AppState) {
        self.state = state
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip =
            "Talk — \(state.settings.hotkeyMode.label) to dictate\nRight-click for more"
        item.button?.image = MenuBarIcon.image(level: 0, phase: .idle, tick: 0)
        // Clicking the icon opens the window directly. The menu moves to the
        // right click, where it is there when wanted and out of the way when not.
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            presentMenu()
        } else {
            onOpenSettings?()
        }
    }

    /// Attaching the menu and clicking the button is the supported way to pop
    /// a status item menu on demand; it is detached again straight after so the
    /// next left click still reaches our action.
    private func presentMenu() {
        item.menu = buildMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    func update(for phase: DictationPhase) {
        switch phase {
        case .listening, .transcribing, .loadingModel:
            startAnimating()
        default:
            stopAnimating()
            redraw()
        }
    }

    // MARK: - Glyph animation

    private func startAnimating() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick += 1.0 / 24.0
                self.redraw()
            }
        }
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        tick = 0
    }

    private func redraw() {
        item.button?.image = MenuBarIcon.image(
            level: state.level, phase: state.phase, tick: tick
        )
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(header())

        let hint = NSMenuItem(title: state.settings.hotkeyMode.label + " to dictate", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        if !state.missingPermissions.isEmpty {
            let warning = NSMenuItem(
                title: "Finish setup — \(state.missingPermissions.count) permission(s) needed",
                action: #selector(openSettings),
                keyEquivalent: ""
            )
            warning.target = self
            warning.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: nil
            )
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        if state.history.isEmpty {
            let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for entry in state.history.prefix(8) {
                let title = entry.text.replacingOccurrences(of: "\n", with: " ")
                let item = NSMenuItem(
                    title: title.count > 52 ? String(title.prefix(52)) + "…" : title,
                    action: #selector(copyEntry(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry.text
                item.toolTip = "Click to copy"
                submenu.addItem(item)
            }
            recent.submenu = submenu
            menu.addItem(recent)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(
            title: "Quit Talk", action: #selector(quit), keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func header() -> NSMenuItem {
        let item = NSMenuItem()
        let title = NSMutableAttributedString(
            string: "Talk\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        title.append(
            NSAttributedString(
                string: statusLine(),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        )
        item.attributedTitle = title
        item.isEnabled = false
        return item
    }

    private func statusLine() -> String {
        switch state.phase {
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .loadingModel: return "Loading the speech model…"
        case .failed(let message): return message
        case .inserted: return "Inserted"
        case .copied: return "Copied to clipboard"
        case .idle:
            if !state.missingPermissions.isEmpty { return "Setup needed" }
            return state.modelIsLoaded ? "Ready · model loaded" : "Ready · model loads on demand"
        }
    }

    // MARK: - Actions

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        TextInjector.copyOnly(text)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
