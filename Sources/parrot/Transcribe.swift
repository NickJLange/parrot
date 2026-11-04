import ArgumentParser
import Darwin
import Foundation

struct Transcribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe audio from stdin or a file to stdout."
    )

    @Argument(help: "Audio file, or - for stdin (default).")
    var input: String = "-"

    @Option(name: .long, help: "Model id. Defaults to the recommended model.")
    var model: String?

    @Option(name: .long, help: "Input format: audio (WAV or other macOS-supported file), or s16le (raw 16 kHz mono signed 16-bit little-endian PCM).")
    var inputFormat: AudioInput.Format = .audio

    @Option(name: .long, help: "Seconds per transcript chunk (1...300).")
    var chunkSeconds: Int = 30

    mutating func validate() throws {
        guard (1...300).contains(chunkSeconds) else {
            throw ValidationError("--chunk-seconds must be between 1 and 300")
        }
        if input == "-", isatty(STDIN_FILENO) != 0 {
            throw ValidationError("pipe audio to stdin or supply an audio file path")
        }
    }

    func run() throws {
        let chosenModel: TranscriptionModel
        if let model {
            guard let registered = ModelRegistry.find(model) else {
                throw ValidationError("unknown model: \(model); run `parrot models list` to see options")
            }
            chosenModel = registered
        } else {
            guard let recommended = ModelRegistry.recommended() else {
                throw ValidationError("no models registered")
            }
            chosenModel = recommended
        }

        // Match the synchronous CLI's model-loading bridge. No NSApplication,
        // microphone, permission checks, or text injection in this command.
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        Task.detached {
            defer { done.signal() }
            do {
                let audio = try AudioInput(path: input, format: inputFormat, chunkSeconds: chunkSeconds)
                let transcriber = WhisperKitTranscriber(model: chosenModel)
                try await Self.writeTranscript(from: audio, transcribe: { samples in
                    try await transcriber.transcribe(samples)
                }, output: FileHandle.standardOutput)
            } catch {
                failure = error
            }
        }
        done.wait()
        if let failure { throw failure }
    }

    /// A chunk is committed immediately so pipes can consume partial results.
    /// A later read/inference failure still propagates as a nonzero exit.
    static func writeTranscript(
        from audio: AudioInput,
        transcribe: ([Float]) async throws -> String,
        output: FileHandle
    ) async throws {
        while let samples = try audio.nextChunk() {
            let text = try await transcribe(samples)
            if !text.isEmpty {
                try output.write(contentsOf: Data((text + "\n").utf8))
            }
        }
    }
}
