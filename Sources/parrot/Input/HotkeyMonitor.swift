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

    /// Friendly names for the keycodes `--hotkey` presets use, for debug output.
    private static let keyNames: [CGKeyCode: String] = [
        54: "right-cmd", 55: "left-cmd",
        58: "left-option", 61: "right-option",
        59: "left-control", 62: "right-control",
        63: "fn",
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
        if debug {
            let flags = event.flags
            let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let name = Self.keyNames[keycode] ?? "keycode-\(keycode)"
            let inTrigger = requiredKeycodes.contains(keycode)
            let line = "  [debug] type=\(type.rawValue) key=\(name) flags=\(String(flags.rawValue, radix: 16)) "
                + "part-of-trigger=\(inTrigger ? "yes" : "no (ignored)")\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        guard type == .flagsChanged else { return }
        let pressed = requiredKeycodes.allSatisfy {
            CGEventSource.keyState(.combinedSessionState, key: $0)
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
