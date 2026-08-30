# Configurable Trigger Keys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--hotkey <name>` CLI flag with 4 presets (`fn`, `right-option`, `left-ctrl-option`, `right-cmd`) so the push-to-talk trigger key is configurable, closing the gap between the README's already-documented flag and the current hardcoded-Fn behavior.

**Architecture:** `HotkeyMonitor` swaps its `CGEventFlags` mask for a flat `[CGKeyCode]` of keys that must all be simultaneously down, checked directly via `CGEventSource.keyState` (no internal state tracking needed). `Parrot.swift` maps preset names to keycode lists and validates `--hotkey` the same way it already validates `--model`.

**Tech Stack:** Swift 5.9, ArgumentParser, CoreGraphics (`CGEventTap`, `CGEventSource`).

## Global Constraints

- Keycodes (standard Apple hardware): left-Control=59, right-Control=62, left-Option=58, right-Option=61, left-Command=55, right-Command=54, Fn=63.
- No DSL, no OR/alternatives layer, no IOHIDManager/vendor detection — per `docs/superpowers/specs/2026-08-30-configurable-trigger-keys-design.md` Non-goals.
- No new test target: this repo has no `Tests/` directory or test target in `Package.swift` today. Adding SPM test infrastructure for one validation check would be disproportionate to the feature and inconsistent with the codebase's existing manual-verification convention (see the Citrix debug-logging spec's "Testing" section, which is manual-only too). Verification in this plan is manual `swift build` + CLI runs.

---

### Task 1: Keycode-based trigger matching in `HotkeyMonitor`

**Files:**
- Modify: `Sources/parrot/Input/HotkeyMonitor.swift`

**Interfaces:**
- Consumes: nothing new from other tasks.
- Produces: `HotkeyMonitor.init(requiredKeycodes: [CGKeyCode] = [63], debug: Bool = false)` — replaces the old `init(mask: CGEventFlags = .maskSecondaryFn, debug: Bool = false)`. Task 2 constructs `HotkeyMonitor` with this new signature.

- [ ] **Step 1: Replace the `mask` property with `requiredKeycodes`**

In `Sources/parrot/Input/HotkeyMonitor.swift`, change:

```swift
    /// Mask of the modifier we treat as the hotkey. Fn = `.maskSecondaryFn`.
    private let mask: CGEventFlags
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    init(mask: CGEventFlags = .maskSecondaryFn, debug: Bool = false) {
        self.mask = mask
        self.debug = debug
    }
```

to:

```swift
    /// Physical keycodes that must all be simultaneously down to count as
    /// "pressed". A single-element list is a plain key; multiple elements
    /// form a chord. Fn = `[63]` (default).
    private let requiredKeycodes: [CGKeyCode]
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    init(requiredKeycodes: [CGKeyCode] = [63], debug: Bool = false) {
        self.requiredKeycodes = requiredKeycodes
        self.debug = debug
    }
```

- [ ] **Step 2: Replace the mask-based check in `handle` with `CGEventSource.keyState`**

Change:

```swift
        guard type == .flagsChanged else { return }
        let pressed = event.flags.contains(mask)
        guard pressed != isPressed else { return }
        isPressed = pressed
        onEvent?(pressed ? .pressed : .released)
```

to:

```swift
        guard type == .flagsChanged else { return }
        let pressed = requiredKeycodes.allSatisfy {
            CGEventSource.keyState(.combinedSessionState, key: $0)
        }
        guard pressed != isPressed else { return }
        isPressed = pressed
        onEvent?(pressed ? .pressed : .released)
```

`CGEventSource.keyState` queries each keycode's real hardware state directly from the OS, so no per-key down/up tracking is needed — this also sidesteps a correctness bug that per-category flag inference would have (releasing one side of a duplicated modifier while the other side is still held would falsely read as still-pressed under flag-based inference).

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds cleanly. This will show a compile error at the `HotkeyMonitor(debug: debugHotkey)` call site in `Parrot.swift` — that's expected and fixed in Task 2.

- [ ] **Step 4: Commit**

```bash
git add Sources/parrot/Input/HotkeyMonitor.swift
git commit -m "hotkey: match trigger via keycode list + CGEventSource.keyState

Replaces the single CGEventFlags mask with a list of required keycodes,
enabling left/right-specific and chord triggers without per-key state
tracking."
```

---

### Task 2: `--hotkey` CLI flag, preset table, and README

**Files:**
- Modify: `Sources/parrot/Parrot.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `HotkeyMonitor.init(requiredKeycodes: [CGKeyCode] = [63], debug: Bool = false)` from Task 1.
- Produces: nothing consumed by later tasks (this is the last task in the plan).

- [ ] **Step 1: Add the preset table and `--hotkey` option**

In `Sources/parrot/Parrot.swift`, add this near the top of the file (after the imports, before `struct Parrot`):

```swift
let hotkeyPresets: [String: [CGKeyCode]] = [
    "fn": [63],
    "right-option": [61],
    "left-ctrl-option": [59, 58],
    "right-cmd": [54],
]
```

In `struct Run`, add the option alongside the existing `@Option var model: String?` (around line 34-35):

```swift
    @Option(name: .long, help: "Trigger key: fn, right-option, left-ctrl-option, right-cmd.")
    var hotkey: String = "fn"
```

- [ ] **Step 2: Validate `--hotkey` and pass keycodes into `HotkeyMonitor`**

In `Run.run()`, add validation right after the existing model-resolution block (after the `chosenModel = m` / closing brace around line 62, before `let transcriber = ...` on line 64):

```swift
        guard let requiredKeycodes = hotkeyPresets[hotkey] else {
            FileHandle.standardError.write(Data("unknown hotkey: \(hotkey)\n".utf8))
            FileHandle.standardError.write(Data(
                "valid values: \(hotkeyPresets.keys.sorted().joined(separator: ", "))\n".utf8
            ))
            throw ExitCode(1)
        }
```

Then change the monitor construction (currently line 84):

```swift
        let monitor = HotkeyMonitor(debug: debugHotkey)
```

to:

```swift
        let monitor = HotkeyMonitor(requiredKeycodes: requiredKeycodes, debug: debugHotkey)
```

- [ ] **Step 3: Reflect the chosen hotkey in the startup log line**

Change the final status line (currently line 172):

```swift
        FileHandle.standardError.write(Data("listening on fn hold · model: \(chosenModel.id) · ^C to quit\n".utf8))
```

to:

```swift
        FileHandle.standardError.write(Data("listening on \(hotkey) hold · model: \(chosenModel.id) · ^C to quit\n".utf8))
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds cleanly, no errors.

- [ ] **Step 5: Manually verify each preset and the error path**

Run each of the following and hold/release the named key(s) to confirm `● recording` / `○ captured` lines appear only for the intended key(s):

```sh
swift run parrot run --hotkey fn
swift run parrot run --hotkey right-option
swift run parrot run --hotkey left-ctrl-option
swift run parrot run --hotkey right-cmd
swift run parrot run --hotkey bogus
```

Expected: first four log `listening on <name> hold · ...` and respond only to the intended physical key(s) (e.g. `right-option` does not trigger on left Option). `bogus` prints `unknown hotkey: bogus` and the valid-values list, then exits 1 without opening the event tap.

Also spot-check the chord case specifically: with `--hotkey left-ctrl-option`, confirm holding *only* left-Control or *only* left-Option does not trigger recording — both must be held together.

- [ ] **Step 6: Update the README**

In `README.md`, change line 39 from:

```
parrot --hotkey right-option           # change the push-to-talk key
```

to:

```
parrot --hotkey right-option           # trigger keys: fn, right-option, left-ctrl-option, right-cmd
```

- [ ] **Step 7: Commit**

```bash
git add Sources/parrot/Parrot.swift README.md
git commit -m "hotkey: add --hotkey flag with fn/right-option/left-ctrl-option/right-cmd presets

Closes the gap between the README's documented --hotkey flag and the
previously-hardcoded Fn-only trigger."
```
