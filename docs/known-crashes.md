# Known crashes

## Input HW format and tap format not matching (2026-08-01, fixed 2026-10-11)

```text
*** Terminating app due to uncaught exception 'com.apple.coreaudio.avfaudio', reason: 'Input HW format and tap format not matching'
```

First seen right after a normal transcription completed, on the *next* fn-key
press. Confirmed trigger (2026-09-01): switching the system's microphone
input source (e.g. in System Settings, or a device connecting/disconnecting)
while `parrot` is running and idle, then pressing the hotkey to record again.

### Location

`Sources/parrot/Audio/AudioCapture.swift`, in `AudioCapture.start()`:

```swift
let input = engine.inputNode
let inputFormat = input.outputFormat(forBus: 0)
...
input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { ... }
```

`AudioCapture` wraps a single long-lived `AVAudioEngine` that is reused for
every recording session over the life of the process — `engine.stop()` /
`removeTap` on release, then `installTap` again on the next press.

### Root cause

`input.outputFormat(forBus: 0)` reflects the engine's *cached* notion of the
input node's format. If the actual input hardware format changes while the
engine is idle — the system default input device switches, a Bluetooth/USB
mic connects or disconnects, or another app renegotiates the shared audio
session's sample rate — that cache goes stale relative to what CoreAudio
validates against at tap-install time, producing the ObjC `NSException`
(`Input HW format and tap format not matching`). This exception cannot be
caught as a Swift `Error`, so it takes the whole process down instead of
being reported as a normal capture failure.

### Fix

`parrot`'s mitigation, informed by Apple observing
`.AVAudioEngineConfigurationChange` as the documented signal for this kind of
hardware change (`Sources/parrot/Audio/AudioCapture.swift`):

1. Observe `.AVAudioEngineConfigurationChange`. That notification is posted
   *synchronously* on an internal AVAudioEngine queue, not ours — touching
   the engine directly from inside the callback (e.g. calling `reset()`) can
   deadlock. So the callback only hops to main, the same queue `start()`/
   `stop()` always already run on, and does the actual recovery there,
   serialized with any in-flight `start()`/`stop()` call:
   - If idle, there's nothing to reconcile (see point 2).
   - If a recording is in progress, stop and discard it cleanly (matching
     `stop()`'s own teardown) and update `isRecording` — there's no way to
     salvage audio across a format change, and leaving `isRecording` true
     while the tap is actually gone would show "recording" in the UI while
     nothing is being captured.
2. At the top of every `start()`, compare `input.inputFormat(forBus: 0)`
   (the current hardware format) against `input.outputFormat(forBus: 0)`
   (the cached one). On a sample-rate or channel-count mismatch, replace the
   engine with a fresh `AVAudioEngine` -- which derives its formats from the
   current device -- and re-attach the observer to it. This is the actual
   fix; the notification in point 1 is not reliably delivered (it fired in
   only about half of the repro runs).

   An earlier version of this fix called `engine.reset()` here instead. That
   does **not** work: `reset()` leaves the input node's cached output format
   untouched, and the crash recurred (2026-10-11). The engine isn't rebuilt
   unconditionally because constructing one costs ~30ms+ (~130ms cold),
   which would clip the start of every utterance.

### Verification status

Reproduced 2026-10-11 by switching the system default input from the
built-in mic (48 kHz) to a Jabra Engage 65 USB headset (16 kHz) between two
recordings, using a small driver compiled together with `AudioCapture.swift`
that records, switches the default input via CoreAudio, and records again.
The `reset()` version crashed 2/2 runs; the engine-replacement version
completed 3/3 runs (record on built-in, record on Jabra, record on built-in
again, ~1s of audio captured each time). Switching devices *during* an
active recording (point 1's discard path) has not been exercised.

### Full stack trace

```text
*** First throw call stack:
(
    0   CoreFoundation                      0x000000019c1d78a0 __exceptionPreprocess + 176
    1   libobjc.A.dylib                     0x000000019bc9ab90 objc_exception_throw + 88
    2   AVFAudio                            0x00000001fcbccf30 _ZN17AVAudioIONodeImpl15SetOutputFormatEmP13AVAudioFormat + 1268
    3   AVFAudio                            0x00000001fcb22fd0 _ZN17AUGraphNodeBaseV318CreateRecordingTapEmjP13AVAudioFormatU13block_pointerFvP16AVAudioPCMBufferP11AVAudioTimeE + 904
    4   AVFAudio                            0x00000001fcbe1c7c _ZN17AVAudioEngineImpl16InstallTapOnNodeEP11AVAudioNodemjP13AVAudioFormatU13block_pointerFvP16AVAudioPCMBufferP11AVAudioTimeE + 1380
    5   AVFAudio                            0x00000001fcbbfe0c -[AVAudioNode installTapOnBus:bufferSize:format:block:] + 608
    6   parrot                              0x000000010442c3ec $s6parrot12AudioCaptureC5startyyKF + 1136
    7   parrot                              0x0000000104443d5c $s6parrot3RunV3runyyKFyAA13HotkeyMonitorC5EventOcfU4_ + 316
    8   parrot                              0x0000000104435e80 $s6parrot13HotkeyMonitorC6handle33_1D22495CA77AACFECA2E5C227890766FLL4type5eventySo11CGEventTypeV_So0L3RefatF + 2784
    9   parrot                              0x0000000104435fc4 $s6parrot14hotkeyCallback33_1D22495CA77AACFECA2E5C227890766FLL5proxy4type5event8userInfos9UnmanagedVySo10CGEventRefaGSgs13OpaquePointerV_So0O4TypeVAKSvSgtFyyScMYccfU_ + 120
    10  parrot                              0x0000000104436074 $sIeg_IeyB_TR + 48
    11  libdispatch.dylib                   0x000000019bec3b2c _dispatch_call_block_and_release + 32
    12  libdispatch.dylib                   0x000000019bedd85c _dispatch_client_callout + 16
    13  libdispatch.dylib                   0x000000019befab80 _dispatch_main_queue_drain.cold.5 + 812
    14  libdispatch.dylib                   0x000000019bed2db0 _dispatch_main_queue_drain + 180
    15  libdispatch.dylib                   0x000000019bed2cec _dispatch_main_queue_callback_4CF + 44
    16  CoreFoundation                      0x000000019c1a49a0 __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__ + 16
    17  CoreFoundation                      0x000000019c16569c __CFRunLoopRun + 1980
    18  CoreFoundation                      0x000000019c164858 CFRunLoopRunSpecific + 572
    19  HIToolbox                           0x00000001a7c0c27c RunCurrentEventLoopInMode + 324
    20  HIToolbox                           0x00000001a7c0f4e8 ReceiveNextEventCommon + 676
    21  HIToolbox                           0x00000001a7d9a484 _BlockUntilNextEventMatchingListInModeWithFilter + 76
    22  AppKit                              0x00000001a0086a34 _DPSNextEvent + 684
    23  AppKit                              0x00000001a0a255cc -[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:] + 688
    24  AppKit                              0x00000001a0079be4 -[NSApplication run] + 480
    25  parrot                              0x0000000104442578 $s6parrot3RunV3runyyKF + 5976
    26  parrot                              0x0000000104447fe4 $s6parrot3RunV14ArgumentParser15ParsableCommandAadEP3runyyKFTW + 44
    27  parrot                              0x000000010410a29c $s14ArgumentParser15ParsableCommandPAAE4mainyySaySSGSgFZ + 544
    28  parrot                              0x000000010410aa64 $s14ArgumentParser15ParsableCommandPAAE4mainyyFZ + 52
    29  parrot                              0x000000010443e6ec $s6parrot6ParrotV5$mainyyFZ + 40
    30  parrot                              0x000000010444b310 main + 12
    31  dyld                                0x000000019bcdab98 start + 6076
)
libc++abi: terminating due to uncaught exception of type NSException
```
