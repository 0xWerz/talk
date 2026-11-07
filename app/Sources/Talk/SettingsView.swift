import AppKit
import SwiftUI

/// The settings window: a narrow rail of sections beside one short pane, so
/// every screen is a handful of decisions rather than an endless scroll.
struct SettingsView: View {
    let state: AppState

    enum Pane: String, CaseIterable, Identifiable {
        case dictation, history, cleanup, vocabulary, polish, engine, permissions
        var id: String { rawValue }

        var title: String {
            switch self {
            case .dictation: return "Dictation"
            case .history: return "History"
            case .cleanup: return "Cleanup"
            case .vocabulary: return "Vocabulary"
            case .polish: return "Polish"
            case .engine: return "Engine"
            case .permissions: return "Permissions"
            }
        }

        var subtitle: String {
            switch self {
            case .dictation: return "How you start and stop talking."
            case .history: return "Everything you've dictated, kept on this Mac."
            case .cleanup: return "What happens to your words before they land."
            case .vocabulary: return "Names and jargon the model mishears."
            case .polish: return "An optional second pass for grammar."
            case .engine: return "The speech model and how it's kept."
            case .permissions: return "What macOS needs to let Talk work."
            }
        }

        var symbol: String {
            switch self {
            case .dictation: return "waveform"
            case .history: return "clock.arrow.circlepath"
            case .cleanup: return "wand.and.sparkles"
            case .vocabulary: return "character.book.closed"
            case .polish: return "textformat.abc"
            case .engine: return "cpu"
            case .permissions: return "lock.shield"
            }
        }
    }

    @State private var pane: Pane = .dictation
    @State private var settings: Settings
    @State private var vocabulary: [VocabularyPair]
    @State private var polishAvailability: Polisher.Availability = .unsupported("Checking…")

    init(state: AppState, initialPane: Pane = .dictation) {
        self.state = state
        _pane = State(initialValue: initialPane)
        _settings = State(initialValue: state.settings)
        _vocabulary = State(initialValue: VocabularyPair.from(state.settings.cleanup.vocabulary))
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(Palette.hairline).frame(width: 1)
            content
        }
        .frame(width: Metrics.windowWidth, height: Metrics.windowHeight)
        .background(Palette.ink)
        .onAppear {
            polishAvailability = state.polisher.availability
            state.refreshPermissions()
        }
        .onChange(of: settings) { _, newValue in
            state.applySettings { $0 = newValue }
        }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Metrics.trafficLightInset)

            HStack(spacing: 9) {
                WaveformMark()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Talk")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Text("local dictation")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textFaint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 22)

            ForEach(Pane.allCases) { item in
                railItem(item)
            }

            Spacer()
            engineStatus
        }
        .frame(width: Metrics.railWidth)
        .background(Palette.rail)
    }

    private func railItem(_ item: Pane) -> some View {
        let isSelected = item == pane
        let needsAttention = item == .permissions && !state.missingPermissions.isEmpty

        return HStack(spacing: 9) {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .regular))
                .frame(width: 16)
            Text(item.title)
                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
            Spacer(minLength: 4)
            if needsAttention {
                Circle().fill(Palette.danger).frame(width: 5, height: 5)
            }
        }
        .foregroundStyle(isSelected ? Palette.text : Palette.textMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.055))
            }
        }
        .overlay(alignment: .leading) {
            // A short accent tick rather than a filled blue bar.
            if isSelected {
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: 2, height: 13)
                    .offset(x: -5)
            }
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Motion.paneSwap) { pane = item }
        }
    }

    private var engineStatus: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 7) {
                StatusDot(isGood: state.modelIsLoaded)
                Text(state.modelIsLoaded ? "Engine loaded" : "Engine idle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Metrics.trafficLightInset - 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title)
                    .font(.paneTitle())
                    .foregroundStyle(Palette.text)
                Text(pane.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textMuted)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 18)

            if SettingsView.rendersFlat {
                panes
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    panes
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(pane)
        .transition(.opacity)
    }

    /// Set by the offscreen renderer, which cannot lay out a ScrollView.
    nonisolated(unsafe) static var rendersFlat = false

    private var panes: some View {
        VStack(alignment: .leading, spacing: 26) {
            switch pane {
            case .dictation: dictationPane
            case .history: historyPane
            case .cleanup: cleanupPane
            case .vocabulary: vocabularyPane
            case .polish: polishPane
            case .engine: enginePane
            case .permissions: permissionsPane
            }
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Panes

    private var dictationPane: some View {
        VStack(alignment: .leading, spacing: 26) {
            gestureHero

            SettingsSection(
                title: "Gesture",
                footnote: "Press esc while speaking to cancel. fn with any other key is "
                    + "passed straight through, so your existing shortcuts still work."
            ) {
                Row(title: "Enabled gestures", isFirst: true) {
                    SegmentedChoice(
                        options: [
                            (HotkeyMode.both, "Both"),
                            (HotkeyMode.holdFn, "Hold only"),
                            (HotkeyMode.doubleTapFn, "Double-tap only")
                        ],
                        selection: $settings.hotkeyMode
                    )
                }
            }

            SettingsSection(title: "While speaking") {
                Row(
                    title: "Floating pill",
                    subtitle: "A live waveform and timer above the Dock.",
                    isFirst: true
                ) {
                    TalkToggle(isOn: $settings.showPillOverlay)
                }
                Row(title: "Haptic feedback", subtitle: "A tap on the trackpad as recording starts and stops.") {
                    TalkToggle(isOn: $settings.hapticFeedback)
                }
                Row(title: "Sounds") {
                    TalkToggle(isOn: $settings.playSounds)
                }
            }
        }
    }

    private var enginePane: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(
                title: "Model",
                footnote: "Parakeet TDT 0.6b v3, running on MLX. Roughly a hundred times "
                    + "faster than real time on Apple silicon, and it never leaves this Mac."
            ) {
                Row(title: "Status", isFirst: true) {
                    HStack(spacing: 8) {
                        StatusDot(isGood: state.modelIsLoaded)
                        Text(state.modelIsLoaded ? "Loaded and ready" : "Not loaded")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textMuted)
                    }
                }
                Row(
                    title: "Unload when idle",
                    subtitle: "Frees about 2.5 GB after a quiet spell; reloads in seconds."
                ) {
                    SegmentedChoice(
                        options: [(0, "Never"), (300, "5 min"), (900, "15 min"), (3600, "1 hr")],
                        selection: $settings.idleUnloadSeconds
                    )
                }
            }

            SettingsSection(title: "System") {
                Row(
                    title: "Launch at login",
                    subtitle: "Requires Talk to live in /Applications.",
                    isFirst: true
                ) {
                    TalkToggle(isOn: $settings.launchAtLogin)
                }
            }

            HStack(spacing: 8) {
                ActionButton(title: "Restart shortcut") { state.restartHotkeys() }
                Spacer()
                ActionButton(title: "Quit Talk", tint: Palette.danger) { NSApp.terminate(nil) }
            }
        }
    }

    /// Shows the two gestures rather than describing them.
    private var gestureHero: some View {
        HStack(spacing: 0) {
            gestureStep(
                caps: [KeyCap(label: "fn", symbol: "globe", isPressed: true)],
                title: "Hold",
                detail: "Speak, release to insert."
            )
            Rectangle().fill(Palette.hairline).frame(width: 1, height: 52)
            gestureStep(
                caps: [
                    KeyCap(label: "fn", symbol: "globe"),
                    KeyCap(label: "fn", symbol: "globe", isPressed: true)
                ],
                title: "Double-tap",
                detail: "Hands-free until you tap again."
            )
        }
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }

    private func gestureStep(caps: [KeyCap], title: String, detail: String) -> some View {
        VStack(spacing: 11) {
            HStack(spacing: 5) {
                ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in cap }
            }
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var cleanupPane: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(
                title: "Rules",
                footnote: "All of this is plain pattern matching: instant, offline, and "
                    + "no model held in memory."
            ) {
                Row(
                    title: "Clean up transcripts",
                    subtitle: "Turn everything below off at once.",
                    isFirst: true
                ) {
                    TalkToggle(isOn: $settings.cleanup.enabled)
                }
                if settings.cleanup.enabled {
                    Row(title: "Remove fillers", subtitle: "“um”, “uh”, “erm” and friends.") {
                        TalkToggle(isOn: $settings.cleanup.removeFillers)
                    }
                    Row(
                        title: "Collapse stutters",
                        subtitle: "“we should, we should ship” becomes “we should ship”."
                    ) {
                        TalkToggle(isOn: $settings.cleanup.dedupeStutters)
                    }
                    Row(
                        title: "Spoken punctuation",
                        subtitle: "Say “new line”, “comma”, “question mark”, “bullet point”."
                    ) {
                        TalkToggle(isOn: $settings.cleanup.spokenCommands)
                    }
                    Row(title: "Fix capitalization", subtitle: "Sentence starts, and a lone “i”.") {
                        TalkToggle(isOn: $settings.cleanup.fixCapitalization)
                    }
                }
            }

            SettingsSection(title: "Result") {
                Row(
                    title: "Leave text on the clipboard",
                    subtitle: "By default Talk puts back whatever you had copied.",
                    isFirst: true
                ) {
                    TalkToggle(isOn: $settings.copyToClipboard)
                }
                Row(
                    title: "Press Return after pasting",
                    subtitle: "Sends the prompt straight to your agent or chat."
                ) {
                    TalkToggle(isOn: $settings.pressReturnAfterPaste)
                }
            }
        }
    }

    private var vocabularyPane: some View {
        SettingsSection(
            title: "Replacements",
            footnote: "Matched whole-word and case-insensitively, after the other "
                + "cleanup rules run."
        ) {
            if vocabulary.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No replacements yet")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.textMuted)
                    Text("Add one when Talk keeps mishearing a name you use.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 22)
                .padding(.horizontal, 16)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
            } else {
                Row(title: "", isFirst: true) {
                    HStack(spacing: 0) {
                        Text("HEARD")
                            .frame(width: 148, alignment: .leading)
                        Text("WRITTEN")
                            .frame(width: 148, alignment: .leading)
                        Spacer()
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Palette.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            ForEach($vocabulary) { $pair in
                Row(title: "") {
                    HStack(spacing: 0) {
                        VocabularyField(text: $pair.heard, placeholder: "wisper flow")
                            .frame(width: 140)
                        Spacer().frame(width: 8)
                        VocabularyField(text: $pair.written, placeholder: "Wispr Flow")
                            .frame(width: 140)
                        Spacer(minLength: 10)
                        Button {
                            vocabulary.removeAll { $0.id == pair.id }
                            commitVocabulary()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Palette.textFaint)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: pair) { _, _ in commitVocabulary() }
                }
            }

            HStack {
                ActionButton(title: "Add replacement") {
                    withAnimation(Motion.control) {
                        vocabulary.append(VocabularyPair(heard: "", written: ""))
                    }
                }
                Spacer()
            }
            .padding(.top, 14)
        }
    }

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 26) {
            if state.history.isEmpty {
                Text("Nothing yet. Dictations appear here as you make them.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textMuted)
            } else {
                SettingsSection(
                    title: "\(state.history.count) dictation\(state.history.count == 1 ? "" : "s")",
                    footnote: "Saved in ~/Library/Application Support/Talk/history.json. "
                        + "Up to \(HistoryStore.limit) are kept."
                ) {
                    ForEach(Array(state.history.enumerated()), id: \.element.id) { index, entry in
                        HistoryRow(
                            entry: entry,
                            isFirst: index == 0,
                            onDelete: { state.deleteHistoryEntry(entry.id) }
                        )
                    }
                }
                HStack {
                    Spacer()
                    ActionButton(title: "Clear history", tint: Palette.danger) {
                        state.clearHistory()
                    }
                }
            }
        }
    }

    private var polishPane: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(
                title: "On-device grammar",
                footnote: polishAvailability.explanation
                    ?? "Runs on Apple's system model, which macOS already manages — Talk "
                        + "loads no model of its own for this. Nothing leaves your Mac. "
                        + "Costs roughly half a second per dictation."
            ) {
                Row(
                    title: "Polish after cleanup",
                    subtitle: "A light proofread. If the model starts rewriting or "
                        + "answering instead, the result is discarded.",
                    isFirst: true
                ) {
                    if polishAvailability.isReady {
                        TalkToggle(isOn: $settings.polishWithAppleIntelligence)
                    } else {
                        Text("Unavailable")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textFaint)
                    }
                }
            }
        }
    }

    private var permissionsPane: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Required") {
                ForEach(Array(Permissions.Kind.allCases.enumerated()), id: \.element.id) {
                    index, kind in
                    let granted = !state.missingPermissions.contains(kind)
                    Row(title: kind.title, subtitle: kind.reason, isFirst: index == 0) {
                        HStack(spacing: 9) {
                            StatusDot(isGood: granted)
                            if granted {
                                Text("Granted")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.textMuted)
                            } else {
                                ActionButton(title: "Grant", tint: Palette.accent) {
                                    Permissions.request(kind)
                                }
                            }
                        }
                    }
                }
            }

            SettingsSection(
                title: "One manual step",
                footnote: "Otherwise macOS opens its own dictation at the same time as Talk."
            ) {
                Row(
                    title: "Press 🌐 to → Do Nothing",
                    subtitle: "In System Settings ▸ Keyboard.",
                    isFirst: true
                ) {
                    ActionButton(title: "Open Keyboard") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
                        )
                    }
                }
            }

            ActionButton(title: "Recheck permissions") { state.refreshPermissions() }
        }
    }

    private func commitVocabulary() {
        settings.cleanup.vocabulary = VocabularyPair.toDictionary(vocabulary)
    }
}

struct VocabularyPair: Identifiable, Equatable {
    let id = UUID()
    var heard: String
    var written: String

    static func from(_ dictionary: [String: String]) -> [VocabularyPair] {
        dictionary.sorted { $0.key < $1.key }
            .map { VocabularyPair(heard: $0.key, written: $0.value) }
    }

    static func toDictionary(_ pairs: [VocabularyPair]) -> [String: String] {
        var result: [String: String] = [:]
        for pair in pairs {
            let heard = pair.heard.trimmingCharacters(in: .whitespaces)
            let written = pair.written.trimmingCharacters(in: .whitespaces)
            if !heard.isEmpty, !written.isEmpty { result[heard] = written }
        }
        return result
    }
}

/// A text field that does not look like a 1998 bevel in a dark window.
private struct VocabularyField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Palette.rail)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
    }
}

/// One saved dictation: when, the full text, and a copy button.
private struct HistoryRow: View {
    let entry: HistoryEntry
    let isFirst: Bool
    let onDelete: () -> Void

    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.textFaint)
                    Text(String(format: "%.0fs", entry.audioSeconds))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.textFaint)
                    Spacer()
                    ActionButton(title: justCopied ? "Copied" : "Copy") {
                        TextInjector.copyOnly(entry.text)
                        justCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            justCopied = false
                        }
                    }
                    ActionButton(title: "Delete", tint: Palette.textMuted, action: onDelete)
                }
                Text(entry.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.text)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 11)
        }
    }
}
