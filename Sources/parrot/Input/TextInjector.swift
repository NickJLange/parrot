import CoreGraphics
import Foundation

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
enum TextInjector {
    /// Serializes injection so two overlapping dictations (e.g. a second
    /// hold-to-talk starting while a paced Citrix injection is still
    /// sleeping between chunks) never interleave their CGEvent posts --
    /// each call to `inject` fully completes before the next one starts.
    /// `inject` submits work here with `.async` (not `.sync`) and awaits a
    /// continuation, so the *calling* thread/actor is never blocked -- only
    /// this queue's own dedicated thread sees the `Thread.sleep` pacing
    /// delay. That matters because `inject` could otherwise be called from
    /// MainActor by mistake, which would freeze the event tap for the
    /// duration of a paced Citrix injection.
    private static let injectionQueue = DispatchQueue(label: "parrot.textinjector")

    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks (the underlying API has a per-event
    /// character limit) with a delay between each, per `InjectionPacing` --
    /// which paces Citrix automatically and leaves every other app at full
    /// speed. Pacing is resolved *inside* the serialized queue, right before
    /// this injection actually starts, not when `inject` is called -- if an
    /// earlier injection is still running, this one may wait behind it, and
    /// the frontmost app (and therefore the right pacing) could have
    /// changed in the meantime.
    ///
    /// When `debug` is true, logs each chunk (index, elapsed ms, literal
    /// text, UTF-16 code units) to stderr before posting it — useful for
    /// comparing what was actually sent against what a remote client
    /// (e.g. Citrix Viewer) ends up displaying.
    static func inject(_ text: String, debug: Bool = false) async {
        guard !text.isEmpty else { return }

        await withCheckedContinuation { continuation in
            injectionQueue.async {
                let pacing = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { InjectionPacing.forFrontmostApp() }
                }
                // Defensive: InjectionPacing's own presets are always
                // positive, but a chunkSize <= 0 would otherwise loop
                // forever without advancing `index`.
                let chunkSize = max(pacing.chunkSize, 1)
                let delayMs = pacing.delayMs

                let utf16 = Array(text.utf16)
                var index = 0
                var chunkIndex = 0
                // Monotonic, so a wall-clock adjustment mid-run can't make
                // elapsedMs in the debug log jump backward.
                let startTime = DispatchTime.now()

                while index < utf16.count {
                    var end = min(index + chunkSize, utf16.count)
                    // Don't split a surrogate pair (e.g. an emoji) across
                    // chunks -- a lone leading surrogate posted alone
                    // renders as a replacement character.
                    if end < utf16.count, end - 1 > index, (0xD800...0xDBFF).contains(utf16[end - 1]) {
                        end -= 1
                    }
                    var chunk = Array(utf16[index..<end])
                    if debug {
                        logChunk(chunk, index: chunkIndex, startTime: startTime)
                    }
                    postChunk(&chunk)
                    index = end
                    chunkIndex += 1
                    if delayMs > 0, index < utf16.count {
                        Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
                    }
                }
                continuation.resume()
            }
        }
    }

    private static func logChunk(_ chunk: [UniChar], index: Int, startTime: DispatchTime) {
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        let elapsedMs = elapsedNs / 1_000_000
        let text = String(utf16CodeUnits: chunk, count: chunk.count)
        let hex = chunk.map { String(format: "0x%04X", $0) }.joined(separator: ",")
        // A chunk boundary can still land inside a surrogate pair in the
        // edge case where the boundary-avoidance above couldn't back off
        // (chunkSize == 1); String(utf16CodeUnits:) silently substitutes
        // U+FFFD for the lone surrogate, which would otherwise misrepresent
        // what was actually posted in this chunk. The hex column is always
        // ground truth; flag it explicitly here too instead of masking it.
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
