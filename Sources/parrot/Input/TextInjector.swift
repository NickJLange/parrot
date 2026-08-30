import CoreGraphics
import Foundation

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
enum TextInjector {
    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit (~20 chars).
    ///
    /// When `debug` is true, logs each chunk (index, elapsed ms, literal
    /// text, UTF-16 codepoints) to stderr before posting it — useful for
    /// comparing what was actually sent against what a remote client
    /// (e.g. Citrix Viewer) ends up displaying.
    static func inject(_ text: String, debug: Bool = false) {
        guard !text.isEmpty else { return }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0
        var chunkIndex = 0
        let startTime = Date()

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            if debug {
                logChunk(chunk, index: chunkIndex, startTime: startTime)
            }
            postChunk(&chunk)
            index = end
            chunkIndex += 1
        }
    }

    private static func logChunk(_ chunk: [UniChar], index: Int, startTime: Date) {
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let text = String(utf16CodeUnits: chunk, count: chunk.count)
        let hex = chunk.map { String(format: "0x%04X", $0) }.joined(separator: ",")
        let line = "  inject[\(index)] +\(elapsedMs)ms \"\(text)\" [\(hex)]\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
    }
}
