import AppKit

/// Talk's menu-bar glyph: four bars drawn by hand rather than a stock symbol,
/// so the icon is the same waveform language as the pill — and so it can come
/// alive with your voice while you dictate.
enum MenuBarIcon {
    static let size = CGSize(width: 19, height: 18)
    private static let barCount = 4
    private static let barWidth: CGFloat = 2.5
    private static let spacing: CGFloat = 2.6
    private static let restHeights: [CGFloat] = [0.36, 0.72, 0.52, 0.26]

    /// - Parameters:
    ///   - level: 0...1 input level; drives bar height while recording.
    ///   - phase: current dictation phase, which picks the tint.
    ///   - tick: monotonically rising time, for the travelling animation.
    static func image(level: Float, phase: DictationPhase, tick: TimeInterval) -> NSImage {
        let heights = barHeights(level: level, phase: phase, tick: tick)
        let tint = color(for: phase)

        let image = NSImage(size: size, flipped: false) { rect in
            let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
            var x = rect.midX - totalWidth / 2

            for height in heights {
                let barHeight = max(barWidth, rect.height * height)
                let bar = NSRect(
                    x: x,
                    y: rect.midY - barHeight / 2,
                    width: barWidth,
                    height: barHeight
                )
                (tint ?? .black).setFill()
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2)
                    .fill()
                x += barWidth + spacing
            }
            return true
        }
        // Idle stays a template so it follows the menu bar's own appearance;
        // active states keep their colour so the state is unmistakable.
        image.isTemplate = (tint == nil)
        return image
    }

    private static func color(for phase: DictationPhase) -> NSColor? {
        switch phase {
        case .idle: return nil
        case .listening: return NSColor(Palette.listening)
        case .transcribing, .loadingModel: return NSColor(Palette.thinking)
        case .inserted, .copied: return NSColor(Palette.success)
        case .failed: return NSColor(Palette.danger)
        }
    }

    private static func barHeights(
        level: Float,
        phase: DictationPhase,
        tick: TimeInterval
    ) -> [CGFloat] {
        switch phase {
        case .listening:
            let amount = CGFloat(min(1, max(0, level)))
            return (0..<barCount).map { index in
                let wave = sin(tick * 7.5 - Double(index) * 0.9) * 0.5 + 0.5
                let reach = restHeights[index] + (0.9 - restHeights[index]) * amount
                return min(0.92, max(0.18, reach * (0.72 + CGFloat(wave) * 0.42)))
            }
        case .transcribing, .loadingModel:
            return (0..<barCount).map { index in
                let wave = sin(tick * 4.0 - Double(index) * 0.8) * 0.5 + 0.5
                return 0.26 + CGFloat(wave) * 0.4
            }
        case .inserted, .copied, .failed, .idle:
            return restHeights
        }
    }
}
