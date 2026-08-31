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
        // Monotonic, so a wall-clock adjustment mid-run can't make elapsedMs
        // in the debug log jump backward.
        let startTime = DispatchTime.now()

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

    private static func logChunk(_ chunk: [UniChar], index: Int, startTime: DispatchTime) {
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        let elapsedMs = elapsedNs / 1_000_000
        let text = String(utf16CodeUnits: chunk, count: chunk.count)
        let hex = chunk.map { String(format: "0x%04X", $0) }.joined(separator: ",")
        // A 20-unit chunk boundary can land inside a surrogate pair (e.g. an
        // emoji); String(utf16CodeUnits:) silently substitutes U+FFFD for
        // the lone surrogate, which would otherwise misrepresent what was
        // actually posted in this chunk. The hex column is always ground
        // truth; flag it explicitly here too instead of masking it.
        let splitPairNote = chunkSplitsSurrogatePair(chunk)
            ? " (splits a surrogate pair -- see hex for true code units)"
            : ""
        // debugDescription escapes quotes/backslashes/control characters, so
        // a transcript containing e.g. a literal `"` or newline can't break
        // the log line's quoting or span multiple physical lines.
        let line = "  inject[\(index)] +\(elapsedMs)ms \(text.debugDescription)\(splitPairNote) [\(hex)]\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func chunkSplitsSurrogatePair(_ chunk: [UniChar]) -> Bool {
        guard let first = chunk.first, let last = chunk.last else { return false }
        let startsWithLoneTrailingSurrogate = (0xDC00...0xDFFF).contains(first)
        let endsWithLoneLeadingSurrogate = (0xD800...0xDBFF).contains(last)
        return startsWithLoneTrailingSurrogate || endsWithLoneLeadingSurrogate
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
