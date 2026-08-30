# Configurable trigger keys (`--hotkey`)

Status: design approved, not yet implemented.

## Problem

`parrot` currently hardcodes the push-to-talk trigger to the Fn key
(`HotkeyMonitor`'s `mask` defaults to `.maskSecondaryFn` and nothing in
`Sources/parrot/Parrot.swift` lets a caller change it). The README already
documents a `parrot --hotkey right-option` flag (`README.md:39`) that does not
exist — the feature was promised but never built.

We want to add a small, fixed set of alternative trigger keys, selectable at
launch:

1. `fn` — the existing default, unchanged.
2. `right-option` — right Option/Alt only, not left.
3. `left-ctrl-option` — a chord: left-Control **and** left-Option held
   together.
4. `right-cmd` — right Command only, not left.

`CGEventFlags` masks (`.maskControl`, `.maskAlternate`, `.maskCommand`,
`.maskSecondaryFn`) don't distinguish left/right — both sides of a modifier
set the same bit. Side-specific and chord triggers need per-keycode state.

## Design

**Keycodes.** Standard Apple hardware keycodes: left-Control=59,
right-Control=62, left-Option=58, right-Option=61, left-Command=55,
right-Command=54, Fn=63.

**Trigger representation.** A trigger is a flat `[CGKeyCode]` — the list of
keycodes that must all be simultaneously down. Single-key triggers are a
one-element list; `left-ctrl-option` is `[59, 58]`. No DSL, no OR/alternatives
layer — YAGNI, since the only requirement is "pick one preset at launch,"
not user-composable combos or multiple simultaneously-active triggers.

**HotkeyMonitor.** `init` changes from `mask: CGEventFlags` to
`requiredKeycodes: [CGKeyCode]`. `handle(type:event:)` drops the
`event.flags.contains(mask)` check in favor of directly querying hardware key
state via `CGEventSource.keyState(_:key:)`:

```swift
guard type == .flagsChanged else { return }
let pressed = requiredKeycodes.allSatisfy {
    CGEventSource.keyState(.combinedSessionState, key: $0)
}
guard pressed != isPressed else { return }
isPressed = pressed
onEvent?(pressed ? .pressed : .released)
```

`keyState` reports each physical key's real current state directly from the
OS, so there's no need to track a `Set<CGKeyCode>` of "keys we've seen go
down/up via flag-category inference." That alternative was considered and
rejected: deriving a keycode's down/up state from whether its modifier
*category* bit is present in a given event's flags breaks when two keys of
the same category are both in play (e.g. holding both Option keys, then
releasing only the right one — `.maskAlternate` stays set because left Option
is still down, so per-category inference would wrongly keep the right key
"on"). Querying `keyState` per keycode sidesteps this entirely and is less
code.

**CLI surface.** `Parrot.swift` gets:

```swift
private let hotkeyPresets: [String: [CGKeyCode]] = [
    "fn": [63],
    "right-option": [61],
    "left-ctrl-option": [59, 58],
    "right-cmd": [54],
]
```

and `@Option(name: .long, help: "...") var hotkey: String = "fn"`. At startup,
look up `hotkey` in `hotkeyPresets`; on miss, print the valid names to stderr
and exit with `ExitCode(1)` — the same pattern already used for `--model`
validation via `ModelRegistry.find` (clear message, list valid options, exit
before doing any further setup). On hit, pass the keycode list to
`HotkeyMonitor`.

**README.** Update the existing `--hotkey right-option` line to list all four
valid values.

## Non-goals

- No IOHIDManager/vendor-device detection. A user-mentioned Logitech
  keyboard's Fn key is handled best-effort via whatever keycode/flags it
  emits through the standard event tap — if that keyboard intercepts Fn in
  firmware and never surfaces a distinguishable event, this is a known
  limitation, not addressed here.
- No custom user-defined key combos or DSL — only the 4 named presets above.
- No support for multiple simultaneously-active triggers — exactly one
  trigger is selected per launch via `--hotkey`.
- No config file or runtime hotkey switching — CLI flag only, requires
  restart to change, consistent with existing flags.

## Testing

- Manual: `parrot run --hotkey right-option` (and the other 3 presets),
  confirm press/release edges fire only for the intended physical key(s) and
  not for the other side (e.g. left Option does not trigger
  `right-option`).
- Manual verification specifically for `CGEventSource.keyState` behavior
  inside a `.listenOnly` `cgSessionEventTap`: confirm it reports promptly and
  correctly relative to the `.flagsChanged` events already being observed —
  this API is well-established but hasn't been used elsewhere in this
  codebase yet, so a quick manual check with `--debugHotkey` before relying
  on it is worthwhile.
- Unit test: invalid `--hotkey` name produces the expected error message and
  non-zero exit, without opening an event tap.

## Relationship to other known issues

Unrelated to the Citrix `TextInjector` mangling bug tracked in
`docs/superpowers/specs/2026-08-01-textinjector-debug-logging-design.md` —
that's about text injection after transcription; this is about which
physical key(s) start/stop recording.
