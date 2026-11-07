import SwiftUI

/// Talk's visual language.
///
/// A warm neutral ink, close to black, with a single restrained accent for
/// anything interactive. Saturated colour is rationed: coral means "this Mac is
/// listening to you right now" and appears nowhere else, so a glance at the
/// menu bar or the pill is unambiguous. Settings never shout.
enum Palette {
    // Surfaces, darkest first. Neutral and faintly warm, never blue or violet.
    static let rail = Color(hex: 0x0C0C0E)
    static let ink = Color(hex: 0x121214)
    static let surface = Color(hex: 0x17171A)
    static let surfaceRaised = Color(hex: 0x202024)
    static let hairline = Color.white.opacity(0.06)
    static let hairlineStrong = Color.white.opacity(0.10)

    // Type. Warm off-white rather than pure white, which glares on OLED.
    static let text = Color(hex: 0xEAE8E4)
    static let textMuted = Color(hex: 0x94918B)
    static let textFaint = Color(hex: 0x5E5B57)

    /// Selection, switches, focus. Warm sand — present but never loud.
    static let accent = Color(hex: 0xD9A566)

    // States. Only ever used for live status, never for chrome.
    static let listening = Color(hex: 0xFF6B4A)   // recording, and only that
    static let thinking = Color(hex: 0x8E93F5)
    static let success = Color(hex: 0x7BC8A4)
    static let danger = Color(hex: 0xE06C75)
}

enum Motion {
    /// Entry of the pill: quick, with just enough overshoot to feel alive.
    static let pillIn = SwiftUI.Animation.spring(response: 0.34, dampingFraction: 0.70)
    /// Exit is faster than entry — getting out of the way should feel instant.
    static let pillOut = SwiftUI.Animation.easeOut(duration: 0.16)
    static let stateChange = SwiftUI.Animation.spring(response: 0.30, dampingFraction: 0.82)
    /// Fast attack, slower release, so the waveform reads as breathing.
    static let barAttack = SwiftUI.Animation.easeOut(duration: 0.055)
    static let barRelease = SwiftUI.Animation.easeOut(duration: 0.16)
    /// Switches and selection: short, no bounce. Controls should feel crisp.
    static let control = SwiftUI.Animation.spring(response: 0.24, dampingFraction: 0.86)
    static let paneSwap = SwiftUI.Animation.easeOut(duration: 0.18)
}

enum Metrics {
    static let pillHeight: CGFloat = 42
    static let pillBottomInset: CGFloat = 96
    static let barCount = 7
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 3.5
    static let barMaxHeight: CGFloat = 19
    static let barMinHeight: CGFloat = 3

    static let windowWidth: CGFloat = 764
    static let windowHeight: CGFloat = 524
    static let railWidth: CGFloat = 196
    /// Space kept clear at the top of the rail for the traffic lights.
    static let trafficLightInset: CGFloat = 34
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension Font {
    /// Tabular, so the elapsed timer does not shuffle as digits change.
    static func pillLabel() -> Font {
        .system(size: 12, weight: .medium, design: .rounded).monospacedDigit()
    }
    static func rowTitle() -> Font { .system(size: 13) }
    static func rowSubtitle() -> Font { .system(size: 11) }
    static func sectionTitle() -> Font { .system(size: 10, weight: .semibold) }
    static func paneTitle() -> Font { .system(size: 19, weight: .semibold) }
}
