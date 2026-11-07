import AVFoundation
import Foundation

/// Captures the microphone and hands back mono 16 kHz float32 PCM — exactly
/// what Parakeet wants, so no resampling happens later in the hot path.
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Safety valve so a stuck hotkey cannot eat all available memory.
    static let maxDuration: TimeInterval = 300

    /// Smoothed input level, 0...1, for the waveform. Read on the main thread.
    private(set) var level: Float = 0

    var onLevel: (@Sendable (Float) -> Void)?
    /// Each converted chunk as it is captured, for streaming transcription.
    /// Called on the audio thread, in order, and never after `stop()` returns.
    var onChunk: (@Sendable (Data) -> Void)?

    private let engine = AVAudioEngine()
    private let bufferLock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var isRunning = false

    private lazy var targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.sampleRate,
        channels: 1,
        interleaved: false
    )!

    var duration: TimeInterval {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return Double(samples.count) / Self.sampleRate
    }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        bufferLock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(Self.sampleRate) * 10)
        bufferLock.unlock()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            Log.error("audio", "no input device available")
            return false
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }

        // Running before the engine starts, so the first chunk is streamed too.
        bufferLock.lock()
        isRunning = true
        bufferLock.unlock()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.error("audio", "engine failed to start: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            bufferLock.lock()
            isRunning = false
            bufferLock.unlock()
            return false
        }
        return true
    }

    /// Stops capture and returns the recording as little-endian float32 bytes.
    func stop() -> Data {
        guard isRunning else { return Data() }
        engine.inputNode.removeTap(onBus: 0)
        bufferLock.lock()
        isRunning = false
        let captured = samples
        samples.removeAll(keepingCapacity: false)
        bufferLock.unlock()
        engine.stop()
        converter = nil
        updateLevel(to: 0)
        return captured.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func cancel() {
        _ = stop()
    }

    // MARK: - Capture

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let converted = convert(buffer, using: converter) else { return }
        guard let channel = converted.floatChannelData?[0] else { return }
        let count = Int(converted.frameLength)
        guard count > 0 else { return }

        let chunk = UnsafeBufferPointer(start: channel, count: count)
        var sumOfSquares: Float = 0
        for value in chunk { sumOfSquares += value * value }
        let rms = (sumOfSquares / Float(count)).squareRoot()

        bufferLock.lock()
        let overflowing = Double(samples.count) / Self.sampleRate >= Self.maxDuration
        if !overflowing {
            samples.append(contentsOf: chunk)
            // Under the lock, so `stop()` can't return between storing a chunk
            // and handing it on; the stream and the full recording always agree.
            if isRunning { onChunk?(Data(buffer: chunk)) }
        }
        bufferLock.unlock()

        // Map RMS onto a perceptual curve: quiet speech should still move bars.
        let normalized = min(1, (rms * 7.5).squareRoot())
        updateLevel(to: normalized)
    }

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            Log.error("audio", "conversion failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }

    private func updateLevel(to value: Float) {
        level = value
        onLevel?(value)
    }
}
