import SwiftUI

/// The floating HUD. Small, legible at a glance, and never in the way.
struct PillView: View {
    let phase: DictationPhase
    let level: Float
    let elapsed: TimeInterval

    @State private var hasAppeared = false

    private var accent: Color {
        switch phase {
        case .listening: return Palette.listening
        case .transcribing, .loadingModel: return Palette.thinking
        case .inserted, .copied: return Palette.success
        case .failed: return Palette.danger
        case .idle: return Palette.textMuted
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !needsTicks)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            content(time: time)
                .padding(.horizontal, 14)
                .frame(height: Metrics.pillHeight)
                .background(background)
                .overlay(rim)
                .clipShape(Capsule(style: .continuous))
                .shadow(color: .black.opacity(0.20), radius: 5, y: 3)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                .shadow(color: accent.opacity(glowStrength), radius: 10, y: 0)
                .scaleEffect(hasAppeared ? 1 : 0.86)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 10)
        }
        .animation(Motion.stateChange, value: phase)
        .onAppear {
            withAnimation(Motion.pillIn) { hasAppeared = true }
        }
    }

    /// Only burn frames when something is actually moving.
    private var needsTicks: Bool {
        switch phase {
        case .listening, .transcribing, .loadingModel: return true
        default: return false
        }
    }

    private var glowStrength: Double {
        switch phase {
        case .listening: return 0.22
        case .transcribing, .loadingModel: return 0.14
        case .inserted, .copied: return 0.16
        case .failed: return 0.14
        case .idle: return 0
        }
    }

    @ViewBuilder
    private func content(time: TimeInterval) -> some View {
        HStack(spacing: 10) {
            switch phase {
            case .listening(let latched):
                Waveform(level: level, color: accent, time: time)
                Text(Self.format(elapsed))
                    .font(.pillLabel())
                    .foregroundStyle(Palette.text.opacity(0.92))
                    .contentTransition(.numericText())
                if latched {
                    LatchedBadge(color: accent)
                        .transition(.scale.combined(with: .opacity))
                }

            case .loadingModel:
                ThinkingDots(color: accent, time: time)
                label("Warming up")

            case .transcribing:
                ThinkingDots(color: accent, time: time)
                label("Transcribing")

            case .inserted(let characters):
                Glyph(symbol: "checkmark", color: accent)
                label(characters == 1 ? "1 character" : "\(characters) characters")

            case .copied:
                Glyph(symbol: "doc.on.clipboard", color: accent)
                label("Copied — ⌘V to paste")

            case .failed(let message):
                Glyph(symbol: "exclamationmark", color: accent)
                label(message)

            case .idle:
                EmptyView()
            }
        }
        .transition(.opacity.combined(with: .offset(y: 3)))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.pillLabel())
            .foregroundStyle(Palette.text.opacity(0.88))
            .lineLimit(1)
            .fixedSize()
    }

    private var background: some View {
        ZStack {
            BlurBackdrop()
            Palette.ink.opacity(0.78)
            // Just a trace of the state colour, so the pill is readable out of
            // the corner of your eye without becoming a coloured slab.
            LinearGradient(
                colors: [accent.opacity(0.10), accent.opacity(0.02)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var rim: some View {
        Capsule(style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.16),
                        accent.opacity(0.30),
                        Color.white.opacity(0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    static func format(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        if whole < 60 { return String(format: "0:%02d", whole) }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// A small pinned dot that says "hands-free — tap fn again to finish".
private struct LatchedBadge: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .opacity(pulsing ? 0.35 : 1)
            Text("hands-free")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.textMuted)
        }
        .padding(.leading, 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

private struct Glyph: View {
    let symbol: String
    let color: Color

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18))
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: 18, height: 18)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    }
}

/// NSVisualEffectView, so the pill picks up whatever is behind it.
struct BlurBackdrop: View {
    var body: some View {
        // The real blur cannot be rendered offscreen, so previews approximate
        // it with the colour it settles to over a dark desktop.
        if SettingsView.rendersFlat {
            Color(hex: 0x1B1B1F)
        } else {
            VisualEffectBackdrop()
        }
    }
}

private struct VisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
