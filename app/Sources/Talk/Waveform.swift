import SwiftUI

/// A centre-out level meter.
///
/// Rather than pumping every bar with the same value — which reads as a
/// machine — each pair of bars shows the level from slightly further back in
/// time, so loudness ripples outward from the middle the way a voice feels.
/// In silence the bars keep a slow idle breath so the pill never looks frozen.
struct Waveform: View {
    let level: Float
    let color: Color
    /// Drives the idle breath; comes from a TimelineView upstream.
    let time: TimeInterval
    var isActive = true

    @State private var trail: [CGFloat] = Array(
        repeating: 0, count: Metrics.barCount / 2 + 1
    )

    private var ringCount: Int { Metrics.barCount / 2 + 1 }

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.barSpacing) {
            ForEach(0..<Metrics.barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(gradient(for: index))
                    .frame(width: Metrics.barWidth, height: height(for: index))
            }
        }
        .frame(height: Metrics.barMaxHeight)
        .animation(Motion.barAttack, value: level)
        .onAppear {
            // Start from the current level rather than flat, so the first
            // frame after the pill appears is already a waveform.
            if level > 0 { trail = trail.map { _ in CGFloat(level) } }
        }
        .onChange(of: level) { _, newValue in advanceTrail(with: newValue) }
        .onChange(of: isActive) { _, active in
            if !active { trail = Array(repeating: 0, count: ringCount) }
        }
    }

    private func gradient(for index: Int) -> LinearGradient {
        // Outer bars sit back a little so the shape has a soft falloff.
        let distance = Double(abs(index - Metrics.barCount / 2))
        let fade = 1.0 - (distance / Double(Metrics.barCount)) * 0.55
        return LinearGradient(
            colors: [color.opacity(fade), color.opacity(fade * 0.72)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func height(for index: Int) -> CGFloat {
        let ring = min(abs(index - Metrics.barCount / 2), ringCount - 1)
        let sampled = trail.indices.contains(ring) ? trail[ring] : 0

        // Idle breath: a slow, shallow sine offset per ring.
        let phase = time * 1.9 - Double(ring) * 0.55
        let breath = isActive ? (sin(phase) * 0.5 + 0.5) * 0.18 : 0

        let amount = max(CGFloat(breath), sampled)
        let span = Metrics.barMaxHeight - Metrics.barMinHeight
        return Metrics.barMinHeight + span * min(1, amount)
    }

    private func advanceTrail(with newValue: Float) {
        guard isActive else { return }
        var updated = trail
        // Shift the history outward, newest value at the centre.
        for index in stride(from: updated.count - 1, through: 1, by: -1) {
            updated[index] = max(updated[index] * 0.82, updated[index - 1])
        }
        updated[0] = CGFloat(newValue)
        trail = updated
    }
}

/// Three dots travelling left to right — the "working" counterpart to the
/// waveform, used while the engine transcribes or loads.
struct ThinkingDots: View {
    let color: Color
    let time: TimeInterval

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                let phase = time * 2.4 - Double(index) * 0.42
                let wave = sin(phase) * 0.5 + 0.5
                Circle()
                    .fill(color.opacity(0.4 + wave * 0.6))
                    .frame(width: 5, height: 5)
                    .scaleEffect(0.78 + wave * 0.34)
            }
        }
        .frame(height: Metrics.barMaxHeight)
    }
}

/// The static waveform mark used as Talk's wordmark in settings. Fixed bar
/// heights rather than live levels, so it reads as a logo rather than a meter.
struct WaveformMark: View {
    var color: Color = Palette.accent
    var height: CGFloat = 18
    var barWidth: CGFloat = 2.5

    private let shape: [CGFloat] = [0.34, 0.62, 1.0, 0.72, 0.44]

    var body: some View {
        HStack(alignment: .center, spacing: barWidth * 1.3) {
            ForEach(Array(shape.enumerated()), id: \.offset) { _, fraction in
                Capsule()
                    .fill(color.opacity(0.55 + fraction * 0.45))
                    .frame(width: barWidth, height: max(barWidth, height * fraction))
            }
        }
        .frame(height: height)
    }
}
