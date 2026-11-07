import AppKit
import ApplicationServices
import AVFoundation
import IOKit.hid

/// The three grants Talk needs, and deep links to the exact settings panes.
@MainActor
enum Permissions {
    enum Kind: String, CaseIterable, Identifiable {
        case microphone, accessibility, inputMonitoring
        var id: String { rawValue }

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        var reason: String {
            switch self {
            case .microphone: return "To hear what you dictate."
            case .accessibility: return "To paste text into the app you're using."
            case .inputMonitoring: return "To notice the fn key."
            }
        }

        var settingsURL: URL {
            let anchor: String
            switch self {
            case .microphone: anchor = "Privacy_Microphone"
            case .accessibility: anchor = "Privacy_Accessibility"
            case .inputMonitoring: anchor = "Privacy_ListenEvent"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .microphone: return hasMicrophone
        case .accessibility: return hasAccessibility
        case .inputMonitoring: return hasInputMonitoring
        }
    }

    static var allGranted: Bool { Kind.allCases.allSatisfy(isGranted) }

    /// Triggers the system prompt where one exists, otherwise opens Settings.
    static func request(_ kind: Kind) {
        switch kind {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        openSettings(kind)
    }

    static func openSettings(_ kind: Kind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
