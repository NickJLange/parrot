import AVFoundation
import ArgumentParser
import Foundation

/// Bounded-memory input for batch transcription. Container audio from stdin
/// is staged on disk because AVAudioFile needs a seekable source. Raw PCM
/// is read directly, allowing a producer to run indefinitely with backpressure.
final class AudioInput {
    enum Format: String, ExpressibleByArgument {
        case audio
        case s16le
    }

    private let file: AVAudioFile?
    private let raw: FileHandle?
    private let ownsRaw: Bool
    private let framesPerChunk: Int
    private let temporaryDirectory: URL?
    static let sampleRate = 16_000.0

    init(path: String, format: Format, chunkSeconds: Int, stdin: FileHandle = .standardInput) throws {
        guard (1...300).contains(chunkSeconds) else {
            throw InputError("chunk duration must be between 1 and 300 seconds")
        }
        if format == .s16le {
            file = nil
            raw = try path == "-" ? stdin : FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            ownsRaw = path != "-"
            framesPerChunk = chunkSeconds * Int(Self.sampleRate)
            temporaryDirectory = nil
            return
        }

        var staging: URL?
        do {
            let url: URL
            if path == "-" {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("parrot-input-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                staging = directory
                url = directory.appendingPathComponent("audio")
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw InputError("could not create temporary audio file")
                }
                let output = try FileHandle(forWritingTo: url)
                defer { try? output.close() }
                while let data = try stdin.read(upToCount: 65_536), !data.isEmpty {
                    try output.write(contentsOf: data)
                }
            } else {
                url = URL(fileURLWithPath: path)
            }
            let audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let rate = audio.processingFormat.sampleRate
            let channels = audio.processingFormat.channelCount
            guard rate.isFinite, rate > 0, rate <= 384_000, channels > 0, channels <= 64 else {
                throw InputError("unsupported sample rate or channel count")
            }
            file = audio
            raw = nil
            ownsRaw = false
            framesPerChunk = Int(rate * Double(chunkSeconds))
            temporaryDirectory = staging
        } catch {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            throw InputError("cannot read audio: \(error.localizedDescription); use --input-format s16le for raw 16 kHz mono PCM")
        }
    }

    deinit {
        if ownsRaw { try? raw?.close() }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    func nextChunk() throws -> [Float]? {
        if let raw {
            // read(upToCount:) may return short reads from a pipe. Accumulate
            // a whole chunk, retaining byte pairs even across odd-sized reads.
            var data = Data()
            let byteCount = framesPerChunk * 2
            while data.count < byteCount {
                guard let part = try raw.read(upToCount: byteCount - data.count), !part.isEmpty else { break }
                data.append(part)
            }
            guard !data.isEmpty else { return nil }
            guard data.count.isMultiple(of: 2) else { throw InputError("truncated s16le input: incomplete 16-bit sample") }
            return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                stride(from: 0, to: bytes.count, by: 2).map { index in
                    let bits = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                    return Float(Int16(bitPattern: bits)) / 32768
                }
            }
        }

        guard let file, file.framePosition < file.length else { return nil }
        let count = AVAudioFrameCount(min(Int64(framesPerChunk), file.length - file.framePosition))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
            throw InputError("could not allocate audio buffer")
        }
        try file.read(into: buffer, frameCount: count)
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
            throw InputError("could not decode audio samples")
        }

        let rate = file.processingFormat.sampleRate
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else {
            throw InputError("could not allocate mono buffer")
        }
        mono.frameLength = buffer.frameLength
        let channelCount = Int(buffer.format.channelCount)
        let destination = mono.floatChannelData![0]
        for frame in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            destination[frame] = sum / Float(channelCount)
        }
        if rate == Self.sampleRate { return Array(UnsafeBufferPointer(start: destination, count: Int(mono.frameLength))) }

        let target = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        guard let converter = AVAudioConverter(from: monoFormat, to: target),
              let converted = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(ceil(Double(mono.frameLength) * Self.sampleRate / rate))
              ) else { throw InputError("could not create sample-rate converter") }
        converter.primeMethod = .none
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return mono
        }
        guard status != .error, converted.frameLength > 0 else {
            throw InputError("audio conversion failed: \(error?.localizedDescription ?? "no samples")")
        }
        return Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
    }
}

struct InputError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
