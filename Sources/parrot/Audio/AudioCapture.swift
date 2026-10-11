import AVFoundation
import Foundation

/// Captures microphone audio while recording is active and returns a 16 kHz
/// mono Float32 buffer when stopped. Format-converts on the fly so callers
/// don't have to worry about the input device's native rate.
final class AudioCapture {
    enum CaptureError: Error {
        case engineStartFailed(Error)
        case converterCreationFailed
        /// No usable input device, or the input format is still
        /// inconsistent after rebuilding the engine.
        case inputFormatUnavailable
    }

    static let targetSampleRate: Double = 16_000

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var isRecording = false
    private let lock = NSLock()
    private var configChangeObserver: NSObjectProtocol?

    /// Called for every audio buffer with the buffer's RMS level (0…~1).
    /// Invoked on an arbitrary thread; hop to main if you touch UI.
    var onLevel: ((Float) -> Void)?

    init() {
        observeConfigurationChanges()
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    /// The observer is tied to the current `engine` instance, so this is
    /// re-run whenever start() replaces the engine.
    ///
    /// `queue: nil` delivers this block *synchronously* on whatever thread
    /// AVAudioEngine posts the notification from -- an internal engine
    /// queue, not ours. Touching the engine directly there can deadlock,
    /// since that internal queue may itself be waiting on engine state. So
    /// this only hops to main -- the same queue start()/stop() already
    /// always run on (see HotkeyMonitor's DispatchQueue.main.async
    /// callback) -- and does the actual recovery there, serialized with
    /// any in-flight start()/stop() call.
    private func observeConfigurationChanges() {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            DispatchQueue.main.async {
                // A notification from an engine start() has since replaced
                // may already be queued here; ignore it, or it would stop
                // and discard the new engine's recording.
                guard let self, let engine, engine === self.engine else { return }
                self.handleConfigurationChange()
            }
        }
    }

    /// Runs on main, serialized with start()/stop() by construction (see
    /// observeConfigurationChanges()).
    private func handleConfigurationChange() {
        guard isRecording else {
            // Idle: nothing to reconcile. start() checks for a stale
            // input format before every session (see below) -- this
            // notification isn't reliably delivered anyway.
            return
        }
        // The device changed mid-recording -- the running tap/engine are
        // no longer valid for whatever format the hardware switched to,
        // and there's no way to salvage this utterance's audio across a
        // format change. Stop and discard cleanly (matching stop()'s own
        // teardown) rather than leave isRecording true while capture has
        // actually stopped underneath it, or risk feeding the converter
        // mismatched-format buffers.
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        FileHandle.standardError.write(Data("input device changed mid-recording; recording discarded\n".utf8))
    }

    /// Begin recording. Idempotent — calling while already recording is a no-op.
    func start() throws {
        guard !isRecording else { return }

        // When the input device changes while idle (system default mic
        // switches, a Bluetooth/USB/Continuity mic connects or
        // disconnects), the input node keeps reporting the old device's
        // format from outputFormat(forBus:) -- engine.reset() does not
        // refresh it, and the configuration-change notification isn't
        // reliably delivered. Installing a tap with that stale format
        // raises an ObjC NSException ("Input HW format and tap format not
        // matching") that can't be caught as a Swift Error and crashes the
        // process. inputFormat(forBus:) does reflect the current hardware,
        // so compare the two and replace the engine on a mismatch; a fresh
        // engine derives its formats from the current device. Not done
        // unconditionally because building an engine costs ~30ms+, which
        // would clip the start of every utterance.
        if !inputFormatIsConsistent() {
            engine = AVAudioEngine()
            observeConfigurationChanges()
            // Still inconsistent (no input device, or the device is mid-
            // transition): fail as a normal Swift error rather than reach
            // installTap and crash.
            guard inputFormatIsConsistent() else {
                throw CaptureError.inputFormatUnavailable
            }
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterCreationFailed
        }
        self.converter = converter

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        // Tap with input format; convert inside the callback.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }

        isRecording = true
    }

    /// True when the input node's cached format matches the current
    /// hardware on the fields installTap validates, and describes a usable
    /// device (a missing input reports 0 Hz / 0 channels).
    private func inputFormatIsConsistent() -> Bool {
        let hardware = engine.inputNode.inputFormat(forBus: 0)
        let cached = engine.inputNode.outputFormat(forBus: 0)
        return cached.sampleRate > 0 && cached.channelCount > 0
            && hardware.sampleRate == cached.sampleRate
            && hardware.channelCount == cached.channelCount
    }

    /// Stop recording and return all captured samples (16 kHz mono Float32).
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false

        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return captured
    }

    private func process(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Output buffer capacity scales with sample-rate ratio.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64

        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outCapacity
        ) else { return }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, let channelData = outBuffer.floatChannelData else { return }

        let count = Int(outBuffer.frameLength)
        let ptr = channelData[0]
        let chunk = Array(UnsafeBufferPointer(start: ptr, count: count))

        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        if let onLevel {
            onLevel(computeRMS(chunk))
        }
    }
}

// MARK: - WAV writer (for debugging M3 captures)

enum WAVWriter {
    /// Write Float32 mono samples as 16-bit PCM WAV to `path`.
    static func write(samples: [Float], sampleRate: Int, to path: String) throws {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32LE(36 + UInt32(dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32LE(16))                       // fmt chunk size
        data.append(uint16LE(1))                        // PCM
        data.append(uint16LE(1))                        // mono
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(sampleRate * bytesPerSample)))
        data.append(uint16LE(UInt16(bytesPerSample)))   // block align
        data.append(uint16LE(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32LE(UInt32(dataSize)))

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i = Int16(clamped * 32767.0)
            data.append(uint16LE(UInt16(bitPattern: i)))
        }

        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
}

func computeRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Double = 0
    for s in samples { sum += Double(s * s) }
    return Float((sum / Double(samples.count)).squareRoot())
}
