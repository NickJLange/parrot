# TextInjector Debug Logging (`--debug-inject`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `--debug-inject` flag that logs exactly what `TextInjector` sends to the OS, chunk by chunk, so a mangled Citrix Viewer session can be compared line-by-line against what was actually posted.

**Architecture:** `TextInjector.inject(_:)` gains a `debug: Bool = false` parameter. When true, it logs each chunk (index, elapsed ms, literal substring, UTF-16 hex codepoints) to stderr immediately before posting it. `Parrot.swift` adds the flag and threads it through, following the same pattern as the existing `--dump-wav`/`debugHotkey` flags.

**Tech Stack:** Swift 5.9, CoreGraphics (`CGEvent`), Foundation (`Date`, `FileHandle`).

## Global Constraints

- Instrumentation only — no attempt to fix the Citrix mangling in this change (per `docs/superpowers/specs/2026-08-01-textinjector-debug-logging-design.md` Non-goals).
- Output goes to `FileHandle.standardError` only — no new log file or sink, consistent with every other log line in the app.
- No new test target: this repo has no `Tests/` directory or test target in `Package.swift`. Verification here is manual `swift build` + a live run, matching the spec's own "Testing" section (manual only) and the precedent set by the trigger-keys work on the sibling branch.

---

### Task 1: Add debug logging to `TextInjector`

**Files:**
- Modify: `Sources/parrot/Input/TextInjector.swift`

**Interfaces:**
- Consumes: nothing new from other tasks.
- Produces: `TextInjector.inject(_ text: String, debug: Bool = false)` — replaces the old `inject(_ text: String)`. Task 2 calls this with `debug: debugInject`.

- [ ] **Step 1: Add the `debug` parameter and per-chunk logging**

Current `Sources/parrot/Input/TextInjector.swift`:

```swift
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
    static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            postChunk(&chunk)
            index = end
        }
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
```

Replace it with:

```swift
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
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds cleanly. `TextInjector.inject(text)` call sites elsewhere still compile because `debug` has a default value.

- [ ] **Step 3: Commit**

```bash
git add Sources/parrot/Input/TextInjector.swift
git commit -m "textinjector: add opt-in per-chunk debug logging

Logs chunk index, elapsed ms, literal text, and UTF-16 hex codepoints
to stderr before each chunk is posted, when enabled. Instrumentation
only -- gathers evidence for the Citrix Viewer mangling bug without
attempting a fix yet."
```

---

### Task 2: Wire up `--debug-inject` in the CLI

**Files:**
- Modify: `Sources/parrot/Parrot.swift`

**Interfaces:**
- Consumes: `TextInjector.inject(_ text: String, debug: Bool = false)` from Task 1.
- Produces: nothing consumed by later tasks (this is the last task in the plan).

- [ ] **Step 1: Add the `--debug-inject` flag**

In `Sources/parrot/Parrot.swift`, add this flag to `struct Run` alongside the existing `debugHotkey` flag (around line 25-26):

```swift
    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Log each injected text chunk (index, timing, UTF-16 codepoints) to stderr.")
    var debugInject: Bool = false
```

- [ ] **Step 2: Pass the flag through to `TextInjector.inject`**

In `Run.run()`, change the injection call site (currently `TextInjector.inject(text)`, inside the `await MainActor.run { ... }` block after transcription succeeds):

```swift
                            await MainActor.run {
                                TextInjector.inject(text)
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
```

to:

```swift
                            await MainActor.run {
                                TextInjector.inject(text, debug: debugInject)
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds cleanly, no errors.

- [ ] **Step 4: Manually verify**

```sh
swift run parrot run --debug-inject
```

Dictate a sentence longer than 20 characters into any text field. Expected: stderr shows one `inject[N] +Xms "..." [0x....,...]` line per 20-character chunk, in order, with monotonically increasing `+Xms` offsets, immediately followed by the normal `→ %.2fs · <transcript>` line already logged elsewhere. Confirm the chunk texts concatenate back to exactly the transcribed text.

Also run without the flag (`swift run parrot run`) and confirm no `inject[...]` lines appear — the flag must be strictly opt-in.

- [ ] **Step 5: Commit**

```bash
git add Sources/parrot/Parrot.swift
git commit -m "cli: add --debug-inject flag

Wires TextInjector's new debug logging into the Run command, following
the same pattern as --debug-hotkey and --dump-wav."
```
