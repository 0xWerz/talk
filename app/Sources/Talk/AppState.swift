import AppKit
import Observation
import SwiftUI

/// What the pill is showing, and what the app is doing.
enum DictationPhase: Equatable {
    case idle
    /// `latched` is hands-free mode (double-tap), where no key is being held.
    case listening(latched: Bool)
    case transcribing
    case loadingModel
    case inserted(characters: Int)
    /// No text field had focus, so the text went to the clipboard.
    case copied
    case failed(String)

    var isRecording: Bool { if case .listening = self { return true }; return false }
    var isBusy: Bool {
        switch self {
        case .transcribing, .loadingModel: return true
        default: return false
        }
    }
}

/// Owns the dictation lifecycle: gesture in, text out.
@MainActor
@Observable
final class AppState {
    private(set) var phase: DictationPhase = .idle
    private(set) var level: Float = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var history: [HistoryEntry] = HistoryStore.load()
    private(set) var modelIsLoaded = false
    private(set) var missingPermissions: [Permissions.Kind] = []

    let config = ConfigStore()
    let polisher = Polisher()

    private let recorder = AudioRecorder()
    private let sidecar = SidecarClient()
    private let hotkeys = HotkeyMonitor()
    private var elapsedTimer: Timer?
    private var permissionTimer: Timer?
    private var resetTask: Task<Void, Never>?
    private var levelDecayTimer: Timer?
    /// The live recording's audio on its way to the sidecar.
    private var streamFeed: AsyncStream<Data>.Continuation?
    /// Sends `streamFeed` to the sidecar; yields the stream if every chunk arrived.
    private var streamTask: Task<SidecarClient.Stream?, Never>?

    /// How long a result or error stays visible before the pill leaves.
    private let successLinger: Duration = .milliseconds(850)
    private let errorLinger: Duration = .seconds(3)
    private let copiedLinger: Duration = .milliseconds(2200)

    var settings: Settings { config.settings }

    // MARK: - Start-up

    func start() {
        refreshPermissions()
        hotkeys.mode = settings.hotkeyMode
        hotkeys.onGesture = { [weak self] gesture in self?.handle(gesture) }
        _ = hotkeys.start()

        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }

        Task { await sidecar.setModelStateHandler { [weak self] state in
            Task { @MainActor in
                // Only the states that mean something; other pushes leave it.
                if state == "ready" { self?.modelIsLoaded = true }
                if state == "loading" || state == "unloaded" { self?.modelIsLoaded = false }
            }
        } }

        // Load the model now so the first dictation is instant. The sidecar
        // drops it again after `idle_unload_seconds`.
        Task { try? await sidecar.warmUp() }
    }

    func restartHotkeys() {
        hotkeys.stop()
        hotkeys.mode = settings.hotkeyMode
        _ = hotkeys.start()
        refreshPermissions()
    }

    func refreshPermissions() {
        missingPermissions = Permissions.Kind.allCases.filter { !Permissions.isGranted($0) }
    }

    /// While the settings window is open, notice grants as they happen rather
    /// than making the user come back and press a button.
    func beginPermissionWatch() {
        refreshPermissions()
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.pollPermissions() }
        }
    }

    func endPermissionWatch() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func pollPermissions() {
        let before = missingPermissions
        refreshPermissions()
        guard before != missingPermissions else { return }

        // The event tap cannot be created until input access exists, so the
        // moment it appears, arm the shortcut without being asked.
        let canListen = !missingPermissions.contains(.inputMonitoring)
            && !missingPermissions.contains(.accessibility)
        if canListen, !hotkeys.isActive {
            restartHotkeys()
        }
    }

    func deleteHistoryEntry(_ id: HistoryEntry.ID) {
        history.removeAll { $0.id == id }
        HistoryStore.save(history)
    }

    func clearHistory() {
        history.removeAll()
        HistoryStore.save(history)
    }

    func applySettings(_ mutate: (inout Settings) -> Void) {
        let wasLaunchingAtLogin = settings.launchAtLogin
        config.update(mutate)
        hotkeys.mode = settings.hotkeyMode
        if settings.launchAtLogin != wasLaunchingAtLogin {
            LoginItem.sync(enabled: settings.launchAtLogin)
        }
        Task { try? await sidecar.reloadConfig() }
    }

    func shutdown() {
        endPermissionWatch()
        hotkeys.stop()
        recorder.cancel()
        Task { await sidecar.shutdown() }
    }

    // MARK: - Gestures

    private func handle(_ gesture: HotkeyMonitor.Gesture) {
        switch gesture {
        case .holdBegan: beginRecording(latched: false)
        case .latchedBegan: beginRecording(latched: true)
        case .holdEnded, .latchedEnded: finishRecording()
        case .holdAbandoned, .cancelled: abandonRecording()
        }
    }

    // MARK: - Recording

    private func beginRecording(latched: Bool) {
        guard !phase.isRecording else { return }
        resetTask?.cancel()

        guard Permissions.hasMicrophone else {
            refreshPermissions()
            Task { _ = await recorder.requestPermission(); refreshPermissions() }
            show(.failed("Microphone access needed"), linger: errorLinger)
            return
        }
        openStream()
        guard recorder.start() else {
            closeStream(cancel: true)
            show(.failed("No microphone found"), linger: errorLinger)
            return
        }

        // Overlap a cold model load (or paging the weights back in after a
        // long idle) with speaking rather than waiting for release.
        Task { try? await sidecar.warmUp() }

        phase = .listening(latched: latched)
        elapsed = 0
        startElapsedTimer()
        Feedback.recordingStarted(settings)
    }

    private func abandonRecording() {
        guard phase.isRecording else { return }
        recorder.cancel()
        closeStream(cancel: true)
        stopElapsedTimer()
        phase = .idle
        level = 0
    }

    // MARK: - Streaming

    /// Audio goes to the sidecar while the user talks, so that most of it is
    /// already transcribed by the time they let go.
    private func openStream() {
        let (chunks, feed) = AsyncStream<Data>.makeStream()
        streamFeed = feed
        recorder.onChunk = { chunk in feed.yield(chunk) }
        let sidecar = sidecar
        streamTask = Task {
            guard let stream = try? await sidecar.beginStream() else { return nil }
            var intact = true
            for await chunk in chunks where intact {
                do { try await sidecar.streamAudio(chunk, to: stream) } catch { intact = false }
            }
            return intact ? stream : nil
        }
    }

    /// Ends the feed. Returns the task that reports whether streaming held up.
    @discardableResult
    private func closeStream(cancel: Bool) -> Task<SidecarClient.Stream?, Never>? {
        recorder.onChunk = nil
        streamFeed?.finish()
        streamFeed = nil
        let task = streamTask
        streamTask = nil
        if cancel, let task {
            let sidecar = sidecar
            Task {
                if let stream = await task.value { await sidecar.cancelStream(stream) }
            }
        }
        return task
    }

    private func finishRecording() {
        guard phase.isRecording else { return }
        let releasedAt = ProcessInfo.processInfo.systemUptime
        stopElapsedTimer()
        let pcm = recorder.stop()
        let captureStoppedAt = ProcessInfo.processInfo.systemUptime
        level = 0
        Feedback.recordingStopped(settings)

        // Under a third of a second is a stray keypress, not speech.
        let seconds = Double(pcm.count / 4) / AudioRecorder.sampleRate
        guard seconds >= 0.3 else {
            closeStream(cancel: true)
            phase = .idle
            return
        }

        let streaming = closeStream(cancel: false)
        phase = modelIsLoaded ? .transcribing : .loadingModel
        Task {
            await transcribe(
                pcm: pcm, streaming: streaming,
                releasedAt: releasedAt, captureStoppedAt: captureStoppedAt
            )
        }
    }

    /// The streamed result when streaming held up, otherwise the whole clip.
    private func fetchTranscript(
        pcm: Data, streaming: Task<SidecarClient.Stream?, Never>?
    ) async throws -> SidecarClient.Transcript {
        let cleanup = settings.cleanup.enabled
        if let stream = await streaming?.value {
            do {
                return try await sidecar.endStream(stream, applyCleanup: cleanup)
            } catch {
                Log.error("dictation", "stream failed, sending whole clip: \(error.localizedDescription)")
            }
        }
        return try await sidecar.transcribe(pcm: pcm, applyCleanup: cleanup)
    }

    private func transcribe(
        pcm: Data,
        streaming: Task<SidecarClient.Stream?, Never>?,
        releasedAt: TimeInterval,
        captureStoppedAt: TimeInterval
    ) async {
        do {
            let result = try await fetchTranscript(pcm: pcm, streaming: streaming)
            modelIsLoaded = true
            let receivedAt = ProcessInfo.processInfo.systemUptime
            guard !result.text.isEmpty else {
                show(.failed("Didn't catch that"), linger: errorLinger)
                return
            }

            var text = result.text
            if settings.polishWithAppleIntelligence,
               let polished = await polisher.polish(text) {
                text = polished
            }
            let polishedAt = ProcessInfo.processInfo.systemUptime

            history.insert(
                HistoryEntry(
                    text: text,
                    date: .now,
                    audioSeconds: result.audioSeconds,
                    milliseconds: result.milliseconds
                ),
                at: 0
            )
            if history.count > HistoryStore.limit {
                history.removeLast(history.count - HistoryStore.limit)
            }
            HistoryStore.save(history)

            let outcome = TextInjector.insert(
                text,
                keepOnClipboard: settings.copyToClipboard,
                pressReturn: settings.pressReturnAfterPaste
            )
            let pastedAt = ProcessInfo.processInfo.systemUptime
            func ms(_ seconds: TimeInterval) -> Int { Int(seconds * 1000) }
            Log.info("latency", "stop=\(ms(captureStoppedAt - releasedAt))ms sidecar=\(ms(receivedAt - captureStoppedAt))ms engine=\(result.milliseconds)ms segments=\(result.segments.map(String.init) ?? "none") audio=\(result.audioSeconds)s polish=\(ms(polishedAt - receivedAt))ms paste=\(ms(pastedAt - polishedAt))ms total=\(ms(pastedAt - releasedAt))ms outcome=\(outcome)")
            switch outcome {
            case .pasted:
                Feedback.textInserted(settings)
                show(.inserted(characters: text.count), linger: successLinger)
            case .copied:
                Feedback.textInserted(settings)
                show(.copied, linger: copiedLinger)
            case .needsAccessibility:
                refreshPermissions()
                show(.failed("Copied — grant Accessibility to paste"), linger: errorLinger)
            }
        } catch {
            Log.error("dictation", error.localizedDescription)
            show(.failed(Self.friendlyMessage(for: error)), linger: errorLinger)
        }
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let failure = error as? SidecarClient.Failure {
            switch failure {
            case .interpreterMissing: return "Speech engine not installed"
            case .notRunning, .disconnected: return "Speech engine unavailable"
            case .server(let message): return message
            }
        }
        return error.localizedDescription
    }

    // MARK: - Phase helpers

    private func show(_ newPhase: DictationPhase, linger: Duration) {
        phase = newPhase
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard !Task.isCancelled else { return }
            self?.phase = .idle
        }
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase.isRecording else { return }
                self.elapsed += 0.1
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}

/// Sound and trackpad haptics. Both are quiet by default.
@MainActor
enum Feedback {
    static func recordingStarted(_ settings: Settings) {
        if settings.hapticFeedback { tap(.generic) }
        if settings.playSounds { NSSound(named: "Tink")?.play() }
    }

    static func recordingStopped(_ settings: Settings) {
        if settings.hapticFeedback { tap(.generic) }
    }

    static func textInserted(_ settings: Settings) {
        if settings.hapticFeedback { tap(.alignment) }
        if settings.playSounds { NSSound(named: "Pop")?.play() }
    }

    private static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
