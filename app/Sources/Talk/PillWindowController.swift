import AppKit
import SwiftUI

/// Hosts the pill in a borderless, non-activating panel that floats over every
/// app and space, and never takes focus or swallows a click.
@MainActor
final class PillWindowController {
    private var panel: NSPanel?
    private let state: AppState
    /// Generous canvas so the pill can grow and shrink without resizing the
    /// window — SwiftUI animates the layout instead, which is much smoother.
    private let canvas = CGSize(width: 520, height: 140)
    private var dismissTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
    }

    func update(for phase: DictationPhase) {
        guard state.settings.showPillOverlay else { hideNow(); return }
        if case .idle = phase {
            scheduleHide()
        } else {
            show()
        }
    }

    // MARK: - Panel

    private func show() {
        dismissTask?.cancel()
        dismissTask = nil

        let panel = panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Let the exit animation finish before the window disappears.
    private func scheduleHide() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            self?.hideNow()
        }
    }

    private func hideNow() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle
        ]
        // Keep it out of screenshots of the user's own work.
        panel.sharingType = .none

        let host = NSHostingView(rootView: PillHost(state: state))
        host.frame = NSRect(origin: .zero, size: canvas)
        panel.contentView = host
        return panel
    }

    private func reposition(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.midX - canvas.width / 2,
            y: visible.minY + Metrics.pillBottomInset - canvas.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: canvas), display: false)
    }
}

/// Bridges the observable state into the pill and keeps it bottom-centred in
/// the oversized canvas.
private struct PillHost: View {
    let state: AppState

    var body: some View {
        ZStack {
            if state.phase != .idle {
                PillView(
                    phase: state.phase,
                    level: state.level,
                    elapsed: state.elapsed
                )
                .transition(
                    .asymmetric(
                        insertion: .identity,
                        removal: .scale(scale: 0.92).combined(with: .opacity)
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.pillOut, value: state.phase == .idle)
    }
}
