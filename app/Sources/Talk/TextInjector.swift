import AppKit
import ApplicationServices
import CoreGraphics

/// Puts text into whatever app has focus by pasting, then restoring the
/// clipboard so the user's copy buffer survives a dictation. When nothing
/// editable has focus, the text is left on the clipboard instead.
@MainActor
enum TextInjector {
    /// Time the frontmost app needs to read the pasteboard before we restore it.
    private static let restoreDelay: Duration = .milliseconds(180)
    /// Between the paste and the Return that sends it.
    private static let returnDelay: Duration = .milliseconds(60)

    enum Outcome {
        /// Pasted into a focused text field.
        case pasted
        /// Nowhere to paste, so the text was left on the clipboard instead.
        case copied
        /// Accessibility is missing, so the text was only copied.
        case needsAccessibility
    }

    @discardableResult
    static func insert(_ text: String, keepOnClipboard: Bool, pressReturn: Bool = false) -> Outcome {
        guard !text.isEmpty else { return .copied }
        guard Permissions.hasAccessibility else {
            // Without Accessibility we cannot synthesize the keystroke, so at
            // least leave the text somewhere the user can reach it.
            copyOnly(text)
            return .needsAccessibility
        }

        let focus = FocusProbe.current()
        if focus == .notEditable {
            // Pasting now would drop the text on the floor. Leave it on the
            // clipboard so the user can paste it wherever they meant to.
            copyOnly(text)
            return .copied
        }

        let pasteboard = NSPasteboard.general
        // When we can't tell what has focus (some Electron and canvas apps
        // expose nothing to Accessibility), paste anyway but keep the text on
        // the clipboard so a missed paste never loses a dictation.
        let restoreAfter = !keepOnClipboard && focus == .editable
        let snapshot = restoreAfter ? snapshotPasteboard(pasteboard) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard sendCommandV() else { return .copied }
        if pressReturn {
            // Give the app a beat to apply the paste; Electron and terminal
            // apps handle Cmd-V asynchronously and would see Return first.
            Task {
                try? await Task.sleep(for: returnDelay)
                sendKey(36)
            }
        }

        if let snapshot {
            Task {
                try? await Task.sleep(for: restoreDelay)
                restore(snapshot, to: pasteboard)
            }
        }
        return .pasted
    }

    static func copyOnly(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Focus

    /// Whether the focused UI element will accept a paste.
    private enum FocusProbe: Equatable {
        case editable
        case notEditable
        case unknown

        private static let textRoles: Set<String> = [
            kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"
        ]

        /// Roles that are plainly not a place to type. Containers such as
        /// windows, groups and web areas are left out on purpose: apps that
        /// expose little to Accessibility (Electron, canvases) report those
        /// even when a text field really has focus.
        private static let nonTextRoles: Set<String> = [
            kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXListRole,
            kAXOutlineRole, kAXTableRole, kAXRowRole, kAXCellRole, kAXImageRole,
            "AXLink", kAXMenuItemRole, kAXMenuButtonRole, kAXPopUpButtonRole,
            kAXSliderRole, kAXTabGroupRole, kAXToolbarRole, kAXStaticTextRole,
            kAXBrowserRole, kAXScrollBarRole, kAXDisclosureTriangleRole,
            kAXColumnRole, kAXIncrementorRole, kAXDockItemRole
        ]

        static func current() -> FocusProbe {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.25)

            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &value
            )
            guard status == .success, let value,
                  CFGetTypeID(value) == AXUIElementGetTypeID()
            else {
                // No focused element at all (the desktop, an app with no
                // window) is a clear "nowhere to paste". Anything else is an
                // app that doesn't answer Accessibility, which we can't judge.
                return status == .noValue ? .notEditable : .unknown
            }
            let element = value as! AXUIElement

            let role = string(element, kAXRoleAttribute)
            if let role, textRoles.contains(role) { return .editable }
            // Web content: contenteditable regions and inputs inside them.
            if attribute(element, "AXEditableAncestor") != nil { return .editable }
            if isSettable(element, kAXSelectedTextRangeAttribute)
                || isSettable(element, kAXValueAttribute) && string(element, kAXValueAttribute) != nil {
                return .editable
            }
            if let role, nonTextRoles.contains(role) { return .notEditable }
            return .unknown
        }

        private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
            else { return nil }
            return value
        }

        private static func string(_ element: AXUIElement, _ name: String) -> String? {
            attribute(element, name) as? String
        }

        private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
            else { return false }
            return settable.boolValue
        }
    }

    // MARK: - Keystroke

    private static func sendCommandV() -> Bool {
        sendKey(9, flags: .maskCommand)
    }

    @discardableResult
    private static func sendKey(_ key: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        // Don't let our synthetic keystrokes feed back into our own event tap.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }

        // Explicit flags, so a modifier still physically held can't turn
        // Return into Shift-Return or Cmd-V into something else.
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Clipboard preservation

    private struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> Snapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var stored: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { stored[type] = data }
            }
            return stored
        }
        return Snapshot(items: items)
    }

    private static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.items.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
