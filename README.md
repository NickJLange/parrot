# parrot

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

## Install

```sh
curl -fsSL https://digimata.github.io/parrot/install.sh | sh
parrot setup                       # grants mic + accessibility, downloads the model
parrot install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 14+. Built and tested on Apple Silicon (M1 or newer), where transcription runs on the Apple Neural Engine via CoreML. Intel support is untested — the installer doesn't block it, but WhisperKit's published models are compiled for the Neural Engine and may not load correctly without one.

The installer drops the binary in `/usr/local/bin/parrot`. Builds are unsigned for now, so the installer strips the quarantine xattr — once you've inspected the script you'll see exactly what it does.

## How to use

1. **Run it.** Either `parrot install --launch-at-login` (daemonized, runs forever, lives in the menu bar), or `parrot` in any terminal tab.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

That's it. There is no record button, no stop button, no "send" — `fn` is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn`.

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions + fn key setting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --hotkey right-option           # trigger keys: fn, right-option, right-cmd
parrot --no-overlay                    # disable the bottom-of-screen pill
parrot transcribe < recording.wav      # stdin audio -> transcript on stdout
parrot transcribe recording.wav        # read a file directly
```

## Transcribe files and pipes

`parrot transcribe` runs without the mic, hotkey, menu bar, or text injection.
It uses the same on-device models as dictation, downloading the selected model
on first use. Microphone and Accessibility permissions are not required.

```sh
parrot transcribe < recording.wav > transcript.txt
parrot transcribe recording.wav --model whisper-large-v3-turbo > transcript.txt
cat recording.wav | parrot transcribe -

# Convert any ffmpeg-supported source, or stream audio from another program:
ffmpeg -i recording.mp3 -f s16le -ar 16000 -ac 1 - | parrot transcribe --input-format s16le
```

The default `--input-format audio` decodes WAV and other audio files supported
by macOS, averages channels to mono, and resamples to 16 kHz. Container audio
from stdin is copied to a temporary file and decoded after EOF; allow enough
temporary disk space for the input. The temporary file is removed on completion
or a handled error. Supplying a file path avoids this copy.

For streaming input, use `--input-format s16le`: headerless, signed 16-bit
little-endian PCM, **16 kHz, mono**. It reads directly from the pipe and emits
text after each chunk, including a final partial chunk at EOF. Other raw sample
rates, channel counts, and encodings must be converted first.

Both modes process 30 seconds at a time to bound memory. Use
`--chunk-seconds 10` to change this (1–300 seconds). Each nonempty transcript
chunk is written as one line to stdout; status and errors go to stderr. Chunks
are transcribed independently, so words crossing a boundary may lose context.
Empty raw input produces no output. Invalid input or inference failures exit
nonzero; earlier transcript lines may already have been written.

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```
