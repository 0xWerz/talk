#if DEBUG
import AppKit
import SwiftUI

/// Renders the settings window straight to a PNG, so the design can be checked
/// without a screen recording permission or a live window.
/// Usage: `Talk --render-ui <out.png> [pane]`
@MainActor
enum RenderPreview {
    static func run(arguments: [String]) {
        SettingsView.rendersFlat = true
        let path = arguments.first ?? "settings.png"
        let name = arguments.dropFirst().first ?? "dictation"

        if name == "pill" {
            renderPills(to: path)
            return
        }
        let pane = SettingsView.Pane(rawValue: name) ?? .dictation

        let state = AppState()
        state.refreshPermissions()

        let renderer = ImageRenderer(
            content: SettingsView(state: state, initialPane: pane)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2

        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        write(png, to: path)
    }

    /// Every pill state stacked on a neutral backdrop, to check the states
    /// read differently at a glance.
    private static func renderPills(to path: String) {
        let states: [(String, DictationPhase, Float)] = [
            ("listening", .listening(latched: false), 0.72),
            ("hands-free", .listening(latched: true), 0.4),
            ("warming", .loadingModel, 0),
            ("transcribing", .transcribing, 0),
            ("inserted", .inserted(characters: 142), 0),
            ("copied", .copied, 0),
            ("failed", .failed("Didn't catch that"), 0)
        ]

        let board = VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 18) {
                    Text(entry.0)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.textFaint)
                        .frame(width: 86, alignment: .trailing)
                    PillView(phase: entry.1, level: entry.2, elapsed: 7)
                    Spacer()
                }
            }
        }
        .padding(30)
        .frame(width: 520)
        .background(Color(hex: 0x2A2A30))

        let renderer = ImageRenderer(content: board.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("pill render failed\n".utf8))
            exit(1)
        }
        write(png, to: path)
    }

    private static func write(_ png: Data, to path: String) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        exit(0)
    }
}
#endif
