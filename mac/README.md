# Dogball Whisper

MacWhisper is great, but it's buggy and bloated. I tried a dozen different
projects here on GitHub and none of them did what I wanted, so I threw this
one together. Hope you enjoy.

Hold right ⌥, talk, let go, and the text appears wherever you were typing.
It lives in the menu bar, and transcription and an optional cleanup pass
that tidies up the wording both run on your Mac. Nothing you say is sent
anywhere.

## Download

[Latest release](https://github.com/jonclegg/dogball-whisper/releases/latest) —
a notarized build for Apple Silicon, macOS 14 or later. Unzip it, drag
`Dogball Whisper.app` into Applications, and open it. First launch walks you
through microphone and Accessibility access and downloads a speech model.

Grant Accessibility when asked: it carries both the hotkey and the paste.
Input Monitoring is listed as optional and is usually unnecessary.

## Build and install

    ./scripts/build-mac.sh [--launch]   # builds Release, signs, installs to /Applications
    ./scripts/test.sh [filter]          # unit tests, optional -only-testing filter
                                         # e.g. ./scripts/test.sh DogballWhisperTests/HotkeyMatcherTests
    ./scripts/release-macos.sh v1.2.3 [--dry-run]   # notarize, staple, publish

Every build shows its version just above Quit in the menu bar menu, as
"Version 0.1.3 (63)": the latest release tag, then the commit count. A local
`build-mac.sh` build takes both from git, so it reports the release it builds
on and a build number that rises with every commit (it fails if no release
tag is present; run `git fetch --tags`). The release script stamps the
version from the tag it is given, and it refuses a tag that is not greater
than every tag that already exists — with no auto-update and no crash
reporting, the version string is the only way to tell which build a bug
report is about.

Never open Xcode: `project.yml` plus `xcodegen` owns the project file, which
is gitignored. Both scripts run `xcodegen generate` first, so a new source
file is picked up automatically.

The unit suite proves the logic in isolation (state machine, geometry,
parsing, gating). It does not prove the app works: the event tap,
Accessibility queries, and synthetic paste all need a real permission grant
and a real window to type into, which the suite cannot fake. See
`docs/MANUAL-SMOKE.md` for that.

### Gated integration tests

A few tests need real hardware or a real network call and are gated behind
environment variables so they don't run by default:

    RUN_ENGINE_IT=1 ./scripts/test.sh DogballWhisperTests/EngineIntegrationTests
    RUN_AUDIO_IT=1 ./scripts/test.sh DogballWhisperTests/AudioRecorderTests
    RUN_MIRROR_IT=1 ./scripts/test.sh DogballWhisperTests/ModelMirrorIntegrationTests

`scripts/test.sh` forwards `RUN_AUDIO_IT`, `RUN_ENGINE_IT`, and
`RUN_MIRROR_IT` into the test host as `TEST_RUNNER_`-prefixed variables.
This exists because `xcodebuild` launches the test host through
LaunchServices, which does not inherit the invoking shell's environment;
only variables Xcode copies through with that prefix reach the process. If
a gated test looks like it's not seeing its flag, check that mechanism
before assuming the gate itself is broken.

`RUN_AUDIO_IT` in particular needs an interactive microphone permission
grant for the test host, not just the app, so it can't run headlessly or in
CI.

## Permissions

Microphone and Accessibility are required. Accessibility carries three
things: the event tap that sees the hotkey, the caret query that positions
the panel, and the synthetic ⌘V that pastes.

Input Monitoring is optional and usually unnecessary. A session event tap
runs on the Accessibility grant, and macOS will not even list an app under
Input Monitoring until it has installed a tap. If you do grant it, macOS
offers to quit and reopen the app.

Bundle ID (`com.jonclegg.DogballWhisper`) and signing identity
(`Developer ID Application: Jonathan Clegg (22CTWHGWQQ)`) are fixed on
purpose. macOS keys Accessibility and Input Monitoring grants to both, so
changing either forces every user to re-grant everything.

## Cleanup

Cleanup runs on this Mac with S1-mini by Superwhisper: a 0.6B model
fine-tuned only to turn raw dictation into clean text (fillers and false
starts removed, self-corrections resolved, punctuation and capitalization
fixed). Nothing is sent anywhere. It is a one-time 484 MB download, offered
in setup and in Settings > Cleanup, pinned to one revision and checked
against its SHA-256, into
`~/Library/Application Support/DogballWhisper/Models/cleanup/`. Until it is
downloaded, dictation inserts the raw transcript. It runs through llama.cpp
(a pinned prebuilt XCFramework, `Packages/LlamaCpp`) and is loaded at
launch, since loading takes longer than the cleanup budget. Settings >
Cleanup can also switch cleanup off.

On 44 synthetic dictations it scored 94.6 to gpt-oss-120b's 95.4 (through
Groq, the cloud engine it replaced), at a 185ms median instead of 958ms. Its
weak spots: it does not fix wrong-word errors ("there car"), it can drop
words it mistakes for dictation commands, and its semi-formal register turns
"gonna" into "going to". There is no cleanup prompt to edit: the model card
requires its own fixed prompt and format.

To check it end to end (downloads the real model):

    RUN_S1MINI_IT=1 ./scripts/test.sh DogballWhisperTests/S1MiniIntegrationTests

## Fix selected text (⌘⇧1 by default)

Select text in any app and press the fix shortcut (⌘⇧1 by default, the
shortcut the [Fixit](https://github.com/ivanrvpereira/fixit) app uses).
Change it in Settings > General > Fix selected text: click the shortcut,
press the new combination (it needs ⌘, ⌃ or ⌥; Esc cancels), or Reset to
go back to ⌘⇧1. It works even while macOS has secure input on, such as
with a password field focused, because it is a registered system hot key
rather than something read from the keyboard tap. Dogball Whisper
copies the selection, runs it through S1-mini on this Mac, and shows Fixit's
review dialog: the edit as an inline diff (or the plain result), with Replace
(Return), Copy, and Dismiss (Esc). Replace pastes the fix over the selection
and gives your clipboard back. With nothing selected it fixes the clipboard
instead, and the button becomes Copy to Clipboard. The dialog is ported from
Fixit (MIT License, Copyright (c) 2026 Ivan Pereira).

It uses S1-mini even with dictation cleanup switched off, so the model
stays loaded once downloaded. S1-mini takes no prompt: it does what it does
for dictation (punctuation, capitalization, fillers, stutters), not Fixit's
"Sound native" rewrite, so it leaves grammar like "I am agree" alone. Quit
Fixit, or change one of the two shortcuts, since only one app can own a
combination; if another app has it, Settings says so under the shortcut.

To check it end to end (takes focus for a few seconds, needs Accessibility
granted to the test build and S1-mini downloaded):

    RUN_FIX_E2E=1 ./scripts/test.sh DogballWhisperTests/FixEndToEndTests

## Diagnostics

Failures are always logged. Per-dictation detail (caret position, character
counts, cleanup timings) is off, because those lines persist in the system
log store for days and would record when you dictated and how much you said.
Turn it on only while chasing something:

    defaults write com.jonclegg.DogballWhisper verboseDiagnostics -bool YES
    # quit and reopen the app, reproduce, then:
    log show --last 10m --predicate 'subsystem == "com.jonclegg.DogballWhisper"'
    defaults write com.jonclegg.DogballWhisper verboseDiagnostics -bool NO

Neither level ever logs what you said or the cleaned text.

## Models

Parakeet V3 (the default) downloads from a privately hosted CloudFront
mirror. The four Whisper variants download from WhisperKit's HuggingFace
repo. They land in different places, and that is deliberate:

- Whisper variants go to
  `~/Library/Application Support/DogballWhisper/Models/`.
- Parakeet goes to
  `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/`,
  because FluidAudio loads it from its own cache directory and cannot be
  pointed at ours.

Either way, downloads run one at a time and are resumable at byte
granularity, managed by `Transcribe/ModelManager.swift`.

## Layout

- `Hotkey/` - the event tap and the pure matcher that decides began / ended / cancelled, and the fix shortcut's Carbon hot key
- `Capture/` - 16kHz mono WAV recording with level metering
- `Transcribe/` - engine protocol, Parakeet (FluidAudio), Whisper (WhisperKit), model catalog
- `Polish/` - S1-mini on llama.cpp, the on-device cleanup model
- `Insert/` - caret location and clipboard-preserving paste
- `Fix/` - the fix shortcut (⌘⇧1 by default): copy the selection, fix it with S1-mini, Fixit's review dialog
- `Core/DictationCoordinator.swift` - the state machine everything else hangs off
- `UI/` - floating panel, settings, onboarding

## Docs

- `docs/superpowers/specs/` - the design doc, kept current with the app
- `docs/superpowers/plans/` - the implementation plan this was built from
- `docs/MANUAL-SMOKE.md` - the pre-ship checklist for everything the test
  suite cannot verify by itself
