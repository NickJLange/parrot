# Backlog

Ideas worth doing later, not yet spec'd or scheduled. Not upstream-facing —
this is our own fork's list.

## Reliable non-English language detection

**Status:** idea, not designed yet.

`WhisperKitTranscriber` calls `transcribe(audioArray:)` with no
`DecodingOptions`, which pins the decoder to `<|en|>` regardless of what was
spoken (root-caused upstream in
[digimata/parrot#15](https://github.com/digimata/parrot/pull/15)). The naive
fix — `DecodingOptions(detectLanguage: true)` unconditionally — was tried and
reverted by its own author after it regressed real usage: dictation
utterances are short (0.6–2s), and Whisper's language detection is unreliable
at that length. Their log, same English phrase spoken three times:

```
→ 0.58s · Testing and speaking in English.
→ 0.58s · Testar e falar em inglês          <- misdetected as pt
→ 0.58s · Testing and speaking in English.
```

The middle utterance was misdetected as Portuguese, so the decoder was
prefilled with `<|pt|>` and *translated* the English audio instead of
transcribing it — the whole utterance lost, not degraded.

**Proposed approach (not yet designed):** two decode passes instead of one --
one with language detection on, one pinned to English -- and verify
agreement over roughly the first 3 seconds before trusting the detected
language. If the two disagree (or detection looks unreliable), snap back to
the English-pinned result rather than risk a silently translated/lost
utterance. Costs one extra decode pass per utterance (measured as
unnoticeable against 0.8–1.9s transcription time in #15's own testing of a
single pass), in exchange for not needing to unconditionally trust
short-clip detection.

Needs: a real design pass (this doc is not a spec), and empirical testing
against misdetection cases like the one above before considering it done.

## Per-language dictation examples

**Status:** idea, not designed yet.

[digimata/parrot#23](https://github.com/digimata/parrot/pull/23) primes
Whisper with one example sentence per language (in the words actually
dictated) rather than a bare vocabulary list, claiming a 46%→85% technical-
term recall improvement on the author's own recordings. Interesting, but
**not self-contained**: the PR is built on top of
[digimata/parrot#21](https://github.com/digimata/parrot/pull/21) (menu-bar
model switching, a new Parakeet engine, on-disk model pruning) as an explicit
dependency, and its diff touches 13 files including new `ModelStore.swift`,
`ModelWeights.swift`, `ActiveTranscriber.swift`, and `ParakeetTranscriber.swift`
— not just the dictation-examples piece itself.

Before adopting: decide whether to pull in #21's whole model-switching scope
too, or extract just the per-language example-priming idea
(`DictationExamples.swift` in #23) as an independent, smaller change against
the current model registry.
