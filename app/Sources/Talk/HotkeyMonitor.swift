import AppKit
import CoreGraphics
import Foundation

/// Watches the globe/fn key with a listen-only event tap and turns raw key
/// transitions into dictation gestures.
///
/// Two gestures, matching Wispr Flow:
///   * hold fn, speak, release  -> push-to-talk
///   * double-tap fn            -> hands-free until the next tap
///
/// Events are always passed through untouched, so fn+arrow and friends keep
/// working.
@MainActor
final class HotkeyMonitor {
    enum Gesture {
        case holdBegan
        case holdEnded
        /// A hold we started but should throw away (too short, or the user was
        /// really typing an fn+key shortcut).
        case holdAbandoned
        case latchedBegan
        case latchedEnded
        case cancelled
    }

    /// Below this, a press is a tap rather than a hold.
    private let tapThreshold: TimeInterval = 0.25
    /// How long to wait for the second tap of a double-tap.
    private let doubleTapWindow: TimeInterval = 0.35

    var mode: HotkeyMode = .both
    var onGesture: ((Gesture) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnIsDown = false
    private var pressStart: TimeInterval = 0
    private var holdIsLive = false
    private var isLatched = false
    private var secondTapTimer: Timer?

    var isActive: Bool { tap != nil }

    // MARK: - Tap lifecycle

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon)
                    .takeUnretainedValue()
                MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            Log.error("hotkey", "tapCreate failed — Input Monitoring not granted")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
        Log.info("hotkey", "event tap active")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        resetState()
    }

    /// The system disables a tap that blocks for too long; bring it back.
    private func reenableIfNeeded(_ type: CGEventType) -> Bool {
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else {
            return false
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        Log.info("hotkey", "tap re-enabled after \(type.rawValue)")
        return true
    }

    // MARK: - Gesture recognition

    private func handle(type: CGEventType, event: CGEvent) {
        if reenableIfNeeded(type) { return }

        if type == .keyDown {
            handleKeyDown(event)
            return
        }
        guard type == .flagsChanged else { return }

        let isDown = event.flags.contains(.maskSecondaryFn)
        guard isDown != fnIsDown else { return }
        fnIsDown = isDown

        if isDown {
            // Another modifier held alongside fn means this is a shortcut.
            let others: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
            if event.flags.intersection(others).isEmpty {
                fnPressed()
            }
        } else {
            fnReleased()
        }
    }

    private func handleKeyDown(_ event: CGEvent) {
        let escape: Int64 = 53
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if keyCode == escape, holdIsLive || isLatched {
            resetState()
            onGesture?(.cancelled)
            return
        }
        // fn+<key> is a system shortcut, not dictation — drop the hold.
        if holdIsLive, fnIsDown {
            holdIsLive = false
            onGesture?(.holdAbandoned)
        }
    }

    private func fnPressed() {
        if isLatched {
            isLatched = false
            onGesture?(.latchedEnded)
            return
        }
        if secondTapTimer != nil {
            cancelSecondTapTimer()
            isLatched = true
            onGesture?(.latchedBegan)
            return
        }

        pressStart = ProcessInfo.processInfo.systemUptime
        guard mode != .doubleTapFn else { return }
        holdIsLive = true
        onGesture?(.holdBegan)
    }

    private func fnReleased() {
        let wasLive = holdIsLive
        holdIsLive = false
        let duration = ProcessInfo.processInfo.systemUptime - pressStart

        let doubleTapEnabled = mode != .holdFn
        if doubleTapEnabled, duration < tapThreshold {
            if wasLive { onGesture?(.holdAbandoned) }
            armSecondTapTimer()
            return
        }
        if wasLive {
            if duration < tapThreshold {
                onGesture?(.holdAbandoned)
            } else {
                onGesture?(.holdEnded)
            }
        }
    }

    private func armSecondTapTimer() {
        cancelSecondTapTimer()
        secondTapTimer = Timer.scheduledTimer(
            withTimeInterval: doubleTapWindow, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.secondTapTimer = nil }
        }
    }

    private func cancelSecondTapTimer() {
        secondTapTimer?.invalidate()
        secondTapTimer = nil
    }

    private func resetState() {
        cancelSecondTapTimer()
        holdIsLive = false
        isLatched = false
        fnIsDown = false
    }
}
