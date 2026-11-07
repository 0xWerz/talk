import SwiftUI

// MARK: - Structure

/// A labelled group of rows. No boxes: a quiet header and hairline-separated
/// rows carry the grouping, which keeps the pane from reading as a stack of
/// identical cards.
struct SettingsSection<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.sectionTitle())
                .tracking(0.9)
                .foregroundStyle(Palette.textFaint)
                .padding(.bottom, 10)

            VStack(spacing: 0) { content }

            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textFaint)
                    .lineSpacing(2)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One line of settings: label, optional explanation, trailing control.
struct Row<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var isFirst = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    if !title.isEmpty {
                        Text(title)
                            .font(.rowTitle())
                            .foregroundStyle(Palette.text)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.rowSubtitle())
                            .foregroundStyle(Palette.textMuted)
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing.alignmentGuide(.firstTextBaseline) { $0.height * 0.74 }
            }
            .padding(.vertical, 11)
        }
    }
}

// MARK: - Controls

/// A small, flat switch. The system one arrives in macOS blue and the fat iOS
/// shape dominates a quiet pane, so Talk draws its own at control scale.
struct TalkToggle: View {
    @Binding var isOn: Bool
    var tint: Color = Palette.accent

    private let width: CGFloat = 30
    private let height: CGFloat = 17

    var body: some View {
        Capsule()
            .fill(isOn ? tint.opacity(0.85) : Palette.surfaceRaised)
            .overlay(
                Capsule().strokeBorder(
                    isOn ? .clear : Palette.hairlineStrong, lineWidth: 1
                )
            )
            .frame(width: width, height: height)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Palette.text : Palette.textMuted)
                    .frame(width: height - 5, height: height - 5)
                    .padding(.horizontal, 2.5)
            }
            .animation(Motion.control, value: isOn)
            .contentShape(Capsule())
            .onTapGesture { isOn.toggle() }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isOn ? "on" : "off")
    }
}

/// Segmented control in the app's palette, with the selection sliding.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Text(option.label)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Palette.text : Palette.textMuted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Palette.surfaceRaised)
                                .matchedGeometryEffect(id: "segment", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Motion.control) { selection = option.value }
                    }
            }
        }
        .padding(2)
        .background(Palette.rail)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }
}

/// Quiet bordered button for the handful of real actions.
struct ActionButton: View {
    let title: String
    var tint: Color = Palette.text
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint.opacity(isHovering ? 1 : 0.85))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.07 : 0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Palette.hairlineStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Status dot for the permission and engine rows.
struct StatusDot: View {
    let isGood: Bool
    var body: some View {
        Circle()
            .fill(isGood ? Palette.success : Palette.danger)
            .frame(width: 6, height: 6)
    }
}

/// A key cap, drawn so the shortcut pane can show the gesture rather than
/// describe it.
struct KeyCap: View {
    let label: String
    var symbol: String? = nil
    var isPressed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isPressed ? Palette.accent.opacity(0.22) : Palette.surfaceRaised)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isPressed ? Palette.accent.opacity(0.55) : Palette.hairlineStrong,
                    lineWidth: 1
                )
            VStack(spacing: 1) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(isPressed ? Palette.accent : Palette.textMuted)
        }
        .frame(width: 42, height: 34)
        .animation(Motion.control, value: isPressed)
    }
}
