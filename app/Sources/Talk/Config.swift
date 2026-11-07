import Foundation

/// The hotkey gesture that starts dictation.
enum HotkeyMode: String, Codable, CaseIterable {
    /// Hold the globe/fn key, speak, release to insert. Wispr Flow's default.
    case holdFn
    /// Double-tap fn to start, tap again to stop. Hands-free.
    case doubleTapFn
    /// Both gestures live at once.
    case both

    var label: String {
        switch self {
        case .holdFn: return "Hold fn"
        case .doubleTapFn: return "Double-tap fn"
        case .both: return "Hold or double-tap fn"
        }
    }
}

/// User settings, stored as JSON next to the sidecar's own config so both
/// processes read one file.
struct Settings: Codable, Equatable {
    var hotkeyMode: HotkeyMode = .both
    var playSounds = false
    var hapticFeedback = true
    var polishWithAppleIntelligence = false
    var showPillOverlay = true
    var copyToClipboard = false
    /// Press Return after pasting, so a dictated prompt is sent straight away.
    var pressReturnAfterPaste = false
    var launchAtLogin = false
    var idleUnloadSeconds: Int = 0

    var cleanup = CleanupSettings()

    struct CleanupSettings: Codable, Equatable {
        var enabled = true
        var removeFillers = true
        var dedupeStutters = true
        var spokenCommands = true
        var fixCapitalization = true
        var vocabulary: [String: String] = [:]

        enum CodingKeys: String, CodingKey {
            case enabled
            case removeFillers = "remove_fillers"
            case dedupeStutters = "dedupe_stutters"
            case spokenCommands = "spoken_commands"
            case fixCapitalization = "fix_capitalization"
            case vocabulary
        }

        init() {}

        /// Hand-written so a config file that is missing keys — the sidecar
        /// writes its own subset, and users edit the file — still decodes.
        /// The synthesized initializer would throw on the first absent key and
        /// cost us every setting in the file.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = container.value(.enabled, Self.fallback.enabled)
            removeFillers = container.value(.removeFillers, Self.fallback.removeFillers)
            dedupeStutters = container.value(.dedupeStutters, Self.fallback.dedupeStutters)
            spokenCommands = container.value(.spokenCommands, Self.fallback.spokenCommands)
            fixCapitalization = container.value(
                .fixCapitalization, Self.fallback.fixCapitalization
            )
            vocabulary = container.value(.vocabulary, Self.fallback.vocabulary)
        }

        private static let fallback = CleanupSettings()
    }

    enum CodingKeys: String, CodingKey {
        case hotkeyMode = "hotkey_mode"
        case playSounds = "play_sounds"
        case hapticFeedback = "haptic_feedback"
        case polishWithAppleIntelligence = "polish_with_apple_intelligence"
        case showPillOverlay = "show_pill_overlay"
        case copyToClipboard = "copy_to_clipboard"
        case pressReturnAfterPaste = "press_return_after_paste"
        case launchAtLogin = "launch_at_login"
        case idleUnloadSeconds = "idle_unload_seconds"
        case cleanup
    }

    /// All keys are optional for the same reason as `CleanupSettings`: the
    /// sidecar owns part of this file and the user may hand-edit the rest.
    static let keys: Set<String> = Set(
        [CodingKeys.hotkeyMode, .playSounds, .hapticFeedback,
         .polishWithAppleIntelligence, .showPillOverlay, .copyToClipboard, .pressReturnAfterPaste,
         .launchAtLogin, .idleUnloadSeconds, .cleanup].map(\.rawValue)
    )

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkeyMode = container.value(.hotkeyMode, Self.fallback.hotkeyMode)
        playSounds = container.value(.playSounds, Self.fallback.playSounds)
        hapticFeedback = container.value(.hapticFeedback, Self.fallback.hapticFeedback)
        polishWithAppleIntelligence = container.value(
            .polishWithAppleIntelligence, Self.fallback.polishWithAppleIntelligence
        )
        showPillOverlay = container.value(.showPillOverlay, Self.fallback.showPillOverlay)
        copyToClipboard = container.value(.copyToClipboard, Self.fallback.copyToClipboard)
        pressReturnAfterPaste = container.value(
            .pressReturnAfterPaste, Self.fallback.pressReturnAfterPaste
        )
        launchAtLogin = container.value(.launchAtLogin, Self.fallback.launchAtLogin)
        idleUnloadSeconds = container.value(
            .idleUnloadSeconds, Self.fallback.idleUnloadSeconds
        )
        cleanup = container.value(.cleanup, Self.fallback.cleanup)
    }

    private static let fallback = Settings()
}

extension KeyedDecodingContainer {
    /// Decode, or keep the supplied default if the key is absent or malformed.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil ?? fallback
    }
}

/// Paths shared with the Python sidecar.
enum Paths {
    static let supportDirectory: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Talk", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var config: URL { supportDirectory.appendingPathComponent("config.json") }
    static var socket: URL { supportDirectory.appendingPathComponent("sidecar.sock") }
    static var history: URL { supportDirectory.appendingPathComponent("history.json") }
    static var sidecarLog: URL { supportDirectory.appendingPathComponent("sidecar.log") }
}

/// Reads and writes the shared config file, preserving keys this app does not
/// know about (the sidecar owns `model`, for instance).
@MainActor
final class ConfigStore {
    private(set) var settings: Settings
    private var foreignKeys: [String: Any] = [:]

    init() {
        let (settings, foreign) = Self.read()
        self.settings = settings
        self.foreignKeys = foreign
    }

    private static func read() -> (Settings, [String: Any]) {
        guard let data = try? Data(contentsOf: Paths.config) else {
            return (Settings(), [:])
        }
        let settings = (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (settings, object.filter { !Settings.keys.contains($0.key) })
    }

    func update(_ mutate: (inout Settings) -> Void) {
        mutate(&settings)
        save()
    }

    func save() {
        guard let encoded = try? JSONEncoder().encode(settings),
              var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]
        else { return }

        // Merge our cleanup flags into whatever cleanup block already exists so
        // the sidecar's filler list and vocabulary survive a write from here.
        if var existingCleanup = foreignKeys["cleanup"] as? [String: Any],
           let ours = object["cleanup"] as? [String: Any] {
            existingCleanup.merge(ours) { _, new in new }
            object["cleanup"] = existingCleanup
        }
        for (key, value) in foreignKeys where key != "cleanup" {
            if object[key] == nil { object[key] = value }
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: Paths.config, options: .atomic)
    }
}
