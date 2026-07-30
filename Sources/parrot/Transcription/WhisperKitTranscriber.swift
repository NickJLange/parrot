import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private var pipeline: WhisperKit?

    init(model: TranscriptionModel) {
        self.modelID = model.id
        self.model = model
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let config = WhisperKitConfig(model: whisperKitID, verbose: false, prewarm: true, load: true)
        do {
            pipeline = try await WhisperKit(config)
        } catch {
            throw TranscriberError.modelSetupFailed(Self.describeSetupFailure(error))
        }
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let results = try await pipeline.transcribe(audioArray: audio)
        let raw = results.map(\.text).joined(separator: " ")
        return Self.sanitize(raw)
    }

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func describeSetupFailure(_ error: Error) -> String {
        let details = String(describing: error)
        if details.contains("authorizationRequired") {
            return """
            Hugging Face authentication failed while downloading the model.

            A saved Hugging Face token may be invalid or missing access to the model repo.
            Fix it with `hf auth login --force`, or remove/disable the saved token if you only need public models.

            Underlying error: \(details)
            """
        }
        return details
    }
}

enum TranscriberError: LocalizedError, CustomStringConvertible {
    case missingEngineID
    case notLoaded
    case modelSetupFailed(String)

    var description: String {
        switch self {
        case .missingEngineID:
            return "transcription model is missing its WhisperKit model id"
        case .notLoaded:
            return "transcription model is not loaded"
        case .modelSetupFailed(let message):
            return message
        }
    }

    var errorDescription: String? { description }
}
