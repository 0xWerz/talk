import Darwin
import Foundation

/// Talks to the Python speech-to-text sidecar over a unix socket, spawning it
/// if it is not already running and reconnecting if it dies.
///
/// Wire format mirrors `talk_sidecar/server.py`: one line of JSON per message,
/// with `bin` bytes of raw payload following the newline when present.
actor SidecarClient {
    enum Failure: LocalizedError {
        case notRunning
        case interpreterMissing(String)
        case server(String)
        case disconnected

        var errorDescription: String? {
            switch self {
            case .notRunning: return "The speech engine is not running."
            case .interpreterMissing(let path): return "Python not found at \(path)."
            case .server(let message): return message
            case .disconnected: return "Lost connection to the speech engine."
            }
        }
    }

    struct Transcript: Sendable {
        let text: String
        let raw: String
        let milliseconds: Int
        let audioSeconds: Double
        /// Stretches decoded while the user was still talking (streaming only).
        let segments: Int?
    }

    /// Lowest sidecar protocol this app can drive. An older sidecar left
    /// running from a previous build is replaced rather than reused.
    static let protocolVersion = 2

    /// Pushed when the engine starts loading or finishes loading its model.
    var onModelState: (@Sendable (String) -> Void)?

    private var fd: Int32 = -1
    private var process: Process?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var connecting: Task<Void, Error>?
    /// Bumped on every new connection; a stream belongs to one connection.
    private var generation = 0
    private var nextStreamID = 1

    func setModelStateHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onModelState = handler
    }

    // MARK: - Lifecycle

    func ensureConnected() async throws {
        if fd >= 0 { return }
        // Concurrent callers (warm-up and a new stream fire together) share
        // one attempt instead of each spawning a sidecar.
        if let connecting { return try await connecting.value }
        let attempt = Task { try await self.establish() }
        connecting = attempt
        defer { connecting = nil }
        try await attempt.value
    }

    private func establish() async throws {
        if connect() {
            startReader()
            if try await isCurrent() { return }
            try await replaceStaleSidecar()
        }

        try spawnSidecar()
        // The sidecar binds its socket within a second; poll rather than sleep long.
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(50))
            if connect() {
                startReader()
                _ = try await isCurrent()
                return
            }
        }
        throw Failure.notRunning
    }

    /// Pings the sidecar; false if it speaks an older protocol.
    private func isCurrent() async throws -> Bool {
        let pong = try await request(["t": "ping"], payload: nil)
        if let loaded = pong["loaded"] as? Bool { onModelState?(loaded ? "ready" : "unloaded") }
        return (pong["proto"] as? Int ?? 0) >= Self.protocolVersion
    }

    /// A sidecar from an older build outlives the app that spawned it and
    /// keeps the socket. Stop it so a current one can take over.
    private func replaceStaleSidecar() async throws {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        let gotPID = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 0
        teardown()
        Log.info("sidecar", "replacing outdated sidecar pid \(gotPID ? pid : -1)")
        guard gotPID else { return }
        kill(pid, SIGTERM)
        for _ in 0..<40 where kill(pid, 0) == 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: Paths.socket)
    }

    private func connect() -> Bool {
        let path = Paths.socket.path
        guard FileManager.default.fileExists(atPath: path) else { return false }

        let handle = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.utf8.count <= maxLength else { close(handle); return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { source in
                raw.copyMemory(from: source)
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(handle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            close(handle)
            return false
        }
        // Streamed audio is fire-and-forget; a roomy buffer means a sidecar
        // busy loading the model never blocks the writer.
        var bufferSize: Int32 = 4 * 1024 * 1024
        setsockopt(handle, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        // A sidecar that dies mid-write must not take the app down with SIGPIPE.
        var noSigPipe: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        fd = handle
        generation += 1
        Log.info("sidecar", "connected")
        return true
    }

    private func spawnSidecar() throws {
        let python = Self.resolvePythonPath()
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw Failure.interpreterMissing(python)
        }
        let workingDirectory = Self.resolveSidecarDirectory()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = ["-m", "talk_sidecar", "--socket", Paths.socket.path]
        task.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONPATH"] = workingDirectory
        environment["TOKENIZERS_PARALLELISM"] = "false"
        task.environment = environment

        FileManager.default.createFile(atPath: Paths.sidecarLog.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: Paths.sidecarLog) {
            log.seekToEndOfFile()
            task.standardOutput = log
            task.standardError = log
        }

        try task.run()
        process = task
        Log.info("sidecar", "spawned pid \(task.processIdentifier)")
    }

    static func resolvePythonPath() -> String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "TalkSidecarPython") as? String,
           !configured.isEmpty {
            return (configured as NSString).expandingTildeInPath
        }
        return resolveSidecarDirectory() + "/.venv/bin/python"
    }

    static func resolveSidecarDirectory() -> String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "TalkSidecarRoot") as? String,
           !configured.isEmpty {
            return (configured as NSString).expandingTildeInPath
        }
        return FileManager.default.currentDirectoryPath + "/sidecar"
    }

    private func teardown() {
        if fd >= 0 { close(fd) }
        fd = -1
        readerTask?.cancel()
        readerTask = nil
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: Failure.disconnected)
        }
    }

    func shutdown() {
        teardown()
        process?.terminate()
        process = nil
    }

    // MARK: - Requests

    func warmUp() async throws {
        try await ensureConnected()
        let reply = try await request(["t": "warm"], payload: nil)
        if reply["loaded"] as? Bool == true { onModelState?("ready") }
    }

    // MARK: - Streaming

    /// A dictation being transcribed while it is recorded.
    struct Stream: Sendable {
        let id: Int
        let generation: Int
    }

    func beginStream() async throws -> Stream {
        try await ensureConnected()
        let stream = Stream(id: nextStreamID, generation: generation)
        nextStreamID += 1
        try send(["t": "stream_begin", "sid": stream.id], payload: nil)
        return stream
    }

    func streamAudio(_ pcm: Data, to stream: Stream) throws {
        guard stream.generation == generation, fd >= 0 else { throw Failure.disconnected }
        try send(["t": "stream_audio", "sid": stream.id], payload: pcm)
    }

    func endStream(_ stream: Stream, applyCleanup: Bool) async throws -> Transcript {
        // A reconnect mid-dictation lost the sidecar's half of the stream.
        guard stream.generation == generation, fd >= 0 else { throw Failure.disconnected }
        let response = try await request(
            ["t": "stream_end", "sid": stream.id, "cleanup": applyCleanup], payload: nil
        )
        return Self.transcript(from: response)
    }

    func cancelStream(_ stream: Stream) {
        guard stream.generation == generation, fd >= 0 else { return }
        try? send(["t": "stream_cancel", "sid": stream.id], payload: nil)
    }

    private func send(_ header: [String: Any], payload: Data?) throws {
        guard let frame = Self.frame(header, payload: payload), fd >= 0 else {
            throw Failure.disconnected
        }
        if !writeAll(frame) {
            teardown()
            throw Failure.disconnected
        }
    }

    private static func frame(_ header: [String: Any], payload: Data?) -> Data? {
        var message = header
        if let payload { message["bin"] = payload.count }
        guard var frame = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        frame.append(0x0A)
        if let payload { frame.append(payload) }
        return frame
    }

    private static func transcript(from response: [String: Any]) -> Transcript {
        Transcript(
            text: response["text"] as? String ?? "",
            raw: response["raw"] as? String ?? "",
            milliseconds: response["ms"] as? Int ?? 0,
            audioSeconds: response["audio_seconds"] as? Double ?? 0,
            segments: response["segments"] as? Int
        )
    }

    func reloadConfig() async throws {
        try await ensureConnected()
        _ = try await request(["t": "reload_config"], payload: nil)
    }

    func transcribe(pcm: Data, applyCleanup: Bool) async throws -> Transcript {
        try await ensureConnected()
        let response = try await request(
            ["t": "transcribe", "cleanup": applyCleanup],
            payload: pcm
        )
        return Self.transcript(from: response)
    }

    private func request(
        _ header: [String: Any],
        payload: Data?
    ) async throws -> [String: Any] {
        let id = nextID
        nextID += 1

        var message = header
        message["id"] = id
        guard let frame = Self.frame(message, payload: payload), fd >= 0 else {
            throw Failure.disconnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            if !writeAll(frame) {
                pending[id] = nil
                teardown()
                continuation.resume(throwing: Failure.disconnected)
            }
        }
    }

    private func writeAll(_ data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress, raw.count)
            }
            if written < 0, errno == EINTR { continue }
            if written <= 0 { return false }
            remaining.removeFirst(written)
        }
        return true
    }

    // MARK: - Reading

    private func startReader() {
        readerTask?.cancel()
        let handle = fd
        readerTask = Task.detached { [weak self] in
            var buffer = Data()
            var scratch = [UInt8](repeating: 0, count: 16384)
            while !Task.isCancelled {
                let count = scratch.withUnsafeMutableBytes { raw in
                    Darwin.read(handle, raw.baseAddress, raw.count)
                }
                if count <= 0 { break }
                buffer.append(contentsOf: scratch[0..<count])

                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard
                        let object = try? JSONSerialization.jsonObject(with: Data(line)),
                        let message = object as? [String: Any]
                    else { continue }
                    await self?.dispatch(message)
                }
            }
            await self?.handleDisconnect()
        }
    }

    private func dispatch(_ message: [String: Any]) {
        if message["t"] as? String == "status" {
            if let state = message["state"] as? String { onModelState?(state) }
            return
        }
        guard let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id)
        else { return }

        if message["t"] as? String == "error" {
            let text = message["message"] as? String ?? "The speech engine failed."
            continuation.resume(throwing: Failure.server(text))
        } else {
            continuation.resume(returning: message)
        }
    }

    private func handleDisconnect() {
        guard fd >= 0 else { return }
        Log.error("sidecar", "disconnected")
        teardown()
    }
}
