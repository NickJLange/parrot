import AVFoundation
import XCTest
@testable import parrot

final class AudioInputTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func rawFile(_ values: [Int16]) throws -> URL {
        let url = directory.appendingPathComponent("input.pcm")
        var data = Data()
        for value in values {
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        try data.write(to: url)
        return url
    }

    private func waveFile(rate: Double, channels: AVAudioChannelCount, frames: Int) throws -> URL {
        let url = directory.appendingPathComponent("input.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            for frame in 0..<frames {
                buffer.floatChannelData![channel][frame] = channel == 0 ? 0.25 : 0.75
            }
        }
        try file.write(from: buffer)
        return url
    }

    func testRawNormalizationAndFinalPartialChunk() throws {
        let url = try rawFile([-32768, -1, 0, 32767] + Array(repeating: 16384, count: 16_000))
        let input = try AudioInput(path: url.path, format: .s16le, chunkSeconds: 1)
        let first = try XCTUnwrap(input.nextChunk())
        XCTAssertEqual(first.count, 16_000)
        XCTAssertEqual(Array(first.prefix(4)), [-1, -Float(1) / 32768, 0, Float(32767) / 32768])
        XCTAssertEqual(try input.nextChunk(), Array(repeating: 0.5, count: 4))
        XCTAssertNil(try input.nextChunk())
    }

    func testRawPipeHandlesOddShortWrites() throws {
        let pipe = Pipe()
        let finished = expectation(description: "producer finished")
        DispatchQueue.global().async {
            defer { try? pipe.fileHandleForWriting.close(); finished.fulfill() }
            // Each write splits a sample. The reader must retain byte pairs.
            for byte: UInt8 in [0, 128, 255, 127, 0, 64] {
                try? pipe.fileHandleForWriting.write(contentsOf: Data([byte]))
            }
        }
        let input = try AudioInput(path: "-", format: .s16le, chunkSeconds: 1, stdin: pipe.fileHandleForReading)
        XCTAssertEqual(try input.nextChunk(), [-1, Float(32767) / 32768, 0.5])
        XCTAssertNil(try input.nextChunk())
        wait(for: [finished], timeout: 5)
    }

    func testTruncatedRawSampleFails() throws {
        let url = directory.appendingPathComponent("bad.pcm")
        try Data([0, 0, 1]).write(to: url)
        let input = try AudioInput(path: url.path, format: .s16le, chunkSeconds: 1)
        XCTAssertThrowsError(try input.nextChunk())
    }

    func testEmptyRawDoesNotInvokeTranscriber() async throws {
        let url = try rawFile([])
        let input = try AudioInput(path: url.path, format: .s16le, chunkSeconds: 1)
        try await Transcribe.writeTranscript(from: input, transcribe: { _ in
            XCTFail("empty input must not load or invoke the model")
            return ""
        }, output: FileHandle.nullDevice)
    }

    func testWaveDownmixAndResampleInBoundedChunks() throws {
        let url = try waveFile(rate: 48_000, channels: 2, frames: 60_000)
        let input = try AudioInput(path: url.path, format: .audio, chunkSeconds: 1)
        let first = try XCTUnwrap(input.nextChunk())
        let last = try XCTUnwrap(input.nextChunk())
        XCTAssertEqual(first.count, 16_000)
        XCTAssertEqual(last.count, 4_000)
        // Ignore the resampler's filter edge; average both channels.
        XCTAssertEqual(first[1_000], 0.5, accuracy: 0.001)
        XCTAssertEqual(last[1_000], 0.5, accuracy: 0.001)
        XCTAssertNil(try input.nextChunk())
    }

    func testWaveFromStdinWithoutFilenameExtension() throws {
        let url = try waveFile(rate: 16_000, channels: 1, frames: 17)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let input = try AudioInput(path: "-", format: .audio, chunkSeconds: 1, stdin: handle)
        XCTAssertEqual(try input.nextChunk(), Array(repeating: 0.25, count: 17))
        XCTAssertNil(try input.nextChunk())
    }

    func testInvalidContainerFailsBeforeTranscription() throws {
        let url = directory.appendingPathComponent("invalid.wav")
        try Data("not audio".utf8).write(to: url)
        XCTAssertThrowsError(try AudioInput(path: url.path, format: .audio, chunkSeconds: 1))
    }

    func testTranscriptWritesChunksAndSkipsEmptyResults() async throws {
        let url = try rawFile(Array(repeating: 0, count: 32_001))
        let input = try AudioInput(path: url.path, format: .s16le, chunkSeconds: 1)
        let outputURL = directory.appendingPathComponent("transcript.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        var sizes: [Int] = []
        try await Transcribe.writeTranscript(from: input, transcribe: { samples in
            sizes.append(samples.count)
            return sizes.count == 2 ? "" : "chunk \(sizes.count)"
        }, output: output)
        XCTAssertEqual(sizes, [16_000, 16_000, 1])
        XCTAssertEqual(try String(contentsOf: outputURL), "chunk 1\nchunk 3\n")
    }

    func testLaterReadFailurePreservesEarlierTranscript() async throws {
        let url = try rawFile(Array(repeating: 0, count: 16_000))
        let append = try FileHandle(forWritingTo: url)
        try append.seekToEnd()
        try append.write(contentsOf: Data([1]))
        try append.close()
        let input = try AudioInput(path: url.path, format: .s16le, chunkSeconds: 1)
        let pipe = Pipe()
        do {
            try await Transcribe.writeTranscript(from: input, transcribe: { _ in "first chunk" }, output: pipe.fileHandleForWriting)
            XCTFail("expected truncated sample failure")
        } catch {
            XCTAssertTrue(error is InputError)
        }
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(try pipe.fileHandleForReading.readToEnd(), Data("first chunk\n".utf8))
    }
}
