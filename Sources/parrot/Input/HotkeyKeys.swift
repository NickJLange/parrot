import CoreGraphics

/// A physical key's identity: display name, hardware keycode, and its
/// private per-side NX_DEVICE*KEYMASK bit (see `HotkeyMonitor` for why the
/// bit matters). Single source of truth so keycodes/bits/names aren't
/// duplicated between the CLI preset table and event-matching code.
struct HotkeyKey {
    let name: String
    let keycode: CGKeyCode
    let deviceBit: UInt64
}

enum HotkeyKeys {
    /// Keys selectable via `--hotkey`.
    static let presets: [HotkeyKey] = [
        HotkeyKey(name: "fn", keycode: 63, deviceBit: 0x800000),
        HotkeyKey(name: "right-option", keycode: 61, deviceBit: 0x0040),
        HotkeyKey(name: "right-cmd", keycode: 54, deviceBit: 0x0010),
    ]

    /// Additional keys with no `--hotkey` preset, named only so
    /// `--debug-hotkey` output can show e.g. "left-option" instead of
    /// "keycode-58" when you press the wrong side.
    private static let debugOnly: [HotkeyKey] = [
        HotkeyKey(name: "left-cmd", keycode: 55, deviceBit: 0x0008),
        HotkeyKey(name: "left-option", keycode: 58, deviceBit: 0x0020),
        HotkeyKey(name: "left-control", keycode: 59, deviceBit: 0x0001),
        HotkeyKey(name: "right-control", keycode: 62, deviceBit: 0x2000),
    ]

    static let byName: [String: HotkeyKey] =
        Dictionary(uniqueKeysWithValues: presets.map { ($0.name, $0) })

    static let byKeycode: [CGKeyCode: HotkeyKey] =
        Dictionary(uniqueKeysWithValues: (presets + debugOnly).map { ($0.keycode, $0) })
}
