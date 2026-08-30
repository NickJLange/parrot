import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Watches a single modifier key (default: Fn) and emits press/release edges.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
final class HotkeyMonitor {
    enum Event { case pressed, released }
    enum HotkeyError: Error { case tapCreateFailed }

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

    /// Name and private per-side modifier bit for each keycode `--hotkey`
    /// presets use. The bits are NX_DEVICE*KEYMASK from IOLLEvent.h —
    /// undocumented but stable and widely relied on (Hammerspoon, Karabiner,
    /// etc.) — and are how we tell left/right apart: the public
    /// `CGEventFlags` masks (.maskControl, .maskAlternate, ...) only report
    /// "this category is down somewhere," not which side. `event.flags` is a
    /// full snapshot of currently-held modifiers, so checking these bits
    /// directly on the event is synchronous and correct for chords too.
    private static let keyInfo: [CGKeyCode: (name: String, deviceBit: UInt64)] = [
        54: ("right-cmd", 0x0010),
        55: ("left-cmd", 0x0008),
        58: ("left-option", 0x0020),
        59: ("left-control", 0x0001),
        61: ("right-option", 0x0040),
        62: ("right-control", 0x2000),
        63: ("fn", 0x800000),
    ]

    func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !trusted {
            FileHandle.standardError.write(Data(
                "accessibility not granted — system prompt opened. Grant access, then quit and relaunch parrot.\n".utf8
            ))
            throw HotkeyError.tapCreateFailed
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        else {
            throw HotkeyError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        onEvent = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        let rawFlags = UInt64(event.flags.rawValue)
        if debug {
            let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let name = Self.keyInfo[keycode]?.name ?? "keycode-\(keycode)"
            let inTrigger = requiredKeycodes.contains(keycode)
            let line = "  [debug] type=\(type.rawValue) key=\(name) flags=\(String(rawFlags, radix: 16)) "
                + "part-of-trigger=\(inTrigger ? "yes" : "no (ignored)")\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        guard type == .flagsChanged else { return }
        let pressed = requiredKeycodes.allSatisfy { keycode in
            guard let bit = Self.keyInfo[keycode]?.deviceBit else { return false }
            return rawFlags & bit != 0
        }
        guard pressed != isPressed else { return }
        isPressed = pressed
        onEvent?(pressed ? .pressed : .released)
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // System disabled our tap; we'll need to re-enable. For now just no-op
        // and let the user restart parrot.
        return Unmanaged.passUnretained(event)
    }

    let copy = event.copy()
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy)
        }
    }
    return Unmanaged.passUnretained(event)
}
