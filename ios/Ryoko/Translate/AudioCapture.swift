import AVFoundation
import Foundation
import os
import Synchronization

/// About 120 ms of 16 kHz mono 16-bit PCM, plus its loudness for the mic button.
nonisolated struct AudioChunk: Sendable {
    var pcm: Data
    /// 0 (silence) to 1 (loud), from the chunk's RMS level.
    var level: Float
}

/// Where Translate's audio comes from: the microphone, or (DEBUG) silence.
nonisolated protocol AudioSource: Sendable {
    /// Starts producing chunks. The stream ends after `stop()`.
    func start() throws -> AsyncStream<AudioChunk>
    func stop()
}

/// The microphone through `AVAudioEngine`, converted to 16 kHz mono Int16 with
/// `AVAudioConverter` and cut into ~120 ms chunks.
///
/// The tap runs on a real-time audio thread, so everything it touches is
/// nonisolated and guarded by a lock (AGENTS.md: a MainActor tap crashes).
nonisolated final class MicrophoneCapture: AudioSource, @unchecked Sendable {
    static let sampleRate = Double(SonioxConfig.sampleRate)
    /// 120 ms at 16 kHz.
    static let chunkFrames = 1_920

    private let engine = AVAudioEngine()
    private let state = Mutex<TapState?>(nil)

    func start() throws -> AsyncStream<AudioChunk> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            RyokoLog.translate.error("No usable microphone input format")
            throw TranslateProblem.microphoneUnavailable
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(500))
        let tap = TapState(converter: converter, target: target, continuation: continuation)
        state.withLock { $0 = tap }
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat, block: Self.tapBlock(tap))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            state.withLock { $0 = nil }
            RyokoLog.translate.error("Audio engine didn't start: \(String(describing: error), privacy: .public)")
            throw TranslateProblem.microphoneUnavailable
        }
        RyokoLog.translate.notice("Microphone started at \(inputFormat.sampleRate) Hz")
        return stream
    }

    func stop() {
        // Only touch the engine if capture started: `inputNode` wakes the microphone.
        let tap = state.withLock { state -> TapState? in
            defer { state = nil }
            return state
        }
        guard let tap else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tap.finish()
    }

    /// Built outside any actor, so the closure is nonisolated.
    private static func tapBlock(_ tap: TapState) -> AVAudioNodeTapBlock {
        { buffer, _ in tap.consume(buffer) }
    }
}

/// The tap's working state. Only the audio thread calls `consume`; `finish`
/// comes from whoever stops capture, so both take the lock.
private nonisolated final class TapState: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let lock = NSLock()
    private var pending = Data()
    private var finished = false

    private static let chunkBytes = MicrophoneCapture.chunkFrames * 2

    init(converter: AVAudioConverter, target: AVAudioFormat, continuation: AsyncStream<AudioChunk>.Continuation) {
        self.converter = converter
        self.target = target
        self.continuation = continuation
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let feeder = Feeder(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            feeder.next(inputStatus)
        }
        guard status != .error, let samples = output.int16ChannelData?[0], output.frameLength > 0 else { return }
        pending.append(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        while pending.count >= Self.chunkBytes {
            let chunk = Data(pending.prefix(Self.chunkBytes))
            pending.removeFirst(Self.chunkBytes)
            continuation.yield(AudioChunk(pcm: chunk, level: Self.level(of: chunk)))
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if !pending.isEmpty {
            continuation.yield(AudioChunk(pcm: pending, level: Self.level(of: pending)))
            pending = Data()
        }
        continuation.finish()
    }

    /// RMS in dBFS, mapped from -50…0 dB to 0…1.
    static func level(of pcm: Data) -> Float {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        let sum = pcm.withUnsafeBytes { raw -> Double in
            raw.bindMemory(to: Int16.self).reduce(0) { $0 + Double($1) * Double($1) }
        }
        let rms = (sum / Double(count)).squareRoot() / 32_768
        let decibels = 20 * log10(max(rms, 1e-7))
        return Float(min(max((decibels + 50) / 50, 0), 1))
    }
}

/// Hands the converter one input buffer, then reports "no data for now".
private nonisolated final class Feeder: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}

/// The audio session and microphone permission for listening.
nonisolated enum TranslateAudioSession {
    /// `.playAndRecord` isn't silenced by the ring/silent switch (design §8.1),
    /// and keeps haptics working while recording (the face-to-face flip).
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
        } catch {
            RyokoLog.translate.error("Audio session didn't activate: \(String(describing: error), privacy: .public)")
            throw TranslateProblem.microphoneUnavailable
        }
        guard session.isInputAvailable else {
            RyokoLog.translate.error("No audio input available")
            throw TranslateProblem.microphoneUnavailable
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    enum Permission {
        case granted
        case denied
        case undetermined
    }

    static var permission: Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    /// Asks for the microphone if needed. True when granted.
    static func requestPermission() async -> Bool {
        switch permission {
        case .granted: true
        case .denied: false
        case .undetermined: await AVAudioApplication.requestRecordPermission()
        }
    }
}

#if DEBUG
/// DEBUG: 120 ms frames of silence, so the real Soniox path (connection, key,
/// errors) can run in the simulator without a microphone.
nonisolated final class SilenceSource: AudioSource, @unchecked Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    func start() throws -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let frame = Data(count: MicrophoneCapture.chunkFrames * 2)
        let producer = Task {
            while !Task.isCancelled {
                continuation.yield(AudioChunk(pcm: frame, level: 0))
                try? await Task.sleep(for: .milliseconds(120))
            }
            continuation.finish()
        }
        task.withLock { $0 = producer }
        return stream
    }

    func stop() {
        task.withLock { $0?.cancel() }
    }
}
#endif
