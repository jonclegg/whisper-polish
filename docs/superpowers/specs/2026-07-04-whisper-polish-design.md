# Whisper Polish — Design

*2026-07-04 · personal-use iPhone app*

## What it is

A clone of the "Whisper Notes" voice-transcription app with one addition: a **Polish** button that rewrites a rambling transcript into human-sounding text in a chosen style (Email, Reddit post, Marketing, Text message, Just clean it up). Input can be voice (on-device transcription) or pasted/typed text.

Mockups: https://claude.ai/code/artifact/2760e9f7-ac1e-47e5-b48c-5c5311018e94

## Decisions made

| Decision | Choice |
|---|---|
| Transcription | On-device **Parakeet V3** (`parakeet-tdt-0.6b-v3`) via the FluidAudio Swift package. No model picker. English-focused. |
| Polish engine | Two modes, toggle in the Polish sheet. **Normal**: one OpenRouter chat call with a humanize prompt + style instructions, high temperature. **Stealth**: port of lynote-ai/humanize-text 4-step chain — LLM rewrite→Chinese (temp ~1.3), LLM rewrite→Japanese (with step-1 history), translate→Finnish, translate→English. All four steps run through OpenRouter (different models per hop to vary fingerprint) instead of Google Translate/Niutrans, so one API key covers everything. |
| LLM access | OpenRouter, key entered in Settings. |
| Distribution | Personal use; run on device from Xcode. No App Store concerns. |

## Screens (match mockups)

1. **Notes list** — search, settings gear, note cards (date, text preview, waveform+duration for voice or "Aa pasted text" for text notes, teal "✦ Polished · <style>" badge when polished). Dock: Aa button (type/paste composer, offers clipboard) · big record button · folders button (v1: omit folders).
2. **Recording** — timer, live waveform, stop button. Auto-entered on launch when "Record on launch" is on. On stop: transcribe locally, land on note detail.
3. **Note detail** — full original text, play button for voice notes, actions: Copy · **Polish** · Share.
4. **Polish sheet** — style chips (last-used preselected), Stealth toggle with explanation, "Polish as <style>" button.
5. **Result** — segmented Original/Polished, style+model tag, Re-polish (reopens sheet) and Copy (primary). Copy/Share act on the visible version.
6. **Settings** — Record on launch, Auto-copy transcript, OpenRouter API key, model picker (default `openai/gpt-4o`), default style, Stealth by default, Parakeet download status.

## Architecture

SwiftUI app, iOS 17+, no backend. Project generated with xcodegen (`project.yml` committed, `.xcodeproj` gitignored).

- **Models (SwiftData)**: `Note` — id, createdAt, sourceType (voice|text), originalText, audioFileName?, duration?, plus latest polish fields: polishedText?, polishStyle?, polishStealth, polishModel?, polishedAt?. Polishing again overwrites the polished fields; the original is never modified.
- **AudioRecorder** — AVAudioSession + AVAudioRecorder to 16kHz WAV in Documents/Audio/.
- **TranscriptionService** — wraps FluidAudio's `AsrManager`; downloads Parakeet CoreML models from Hugging Face on first run; exposes `transcribe(url) async throws -> String`.
- **PolishService** — `polish(text, style, stealth) async throws -> PolishResult`. Normal mode: single OpenRouter chat completion. Stealth mode: 4 sequential OpenRouter calls per the pipeline above. Plain URLSession, no SDK.
- **SettingsStore** — @AppStorage for toggles/style/model; API key in @AppStorage too (personal device, acceptable).
- **Views** — one file per screen mirroring the mockups; teal accent for all Polish UI.

## Error handling

- No API key → Polish sheet shows inline "Add your OpenRouter key in Settings" instead of the go button.
- Transcription/polish failures → card-level retry affordance (like the reference app's "No text detected. Tap retry.").
- Stealth pipeline is sequential; any failed step fails the whole polish with a readable error; original text untouched.

## Testing

Unit tests for PolishService request assembly (prompts per style, stealth step chaining with mocked URLProtocol) and Note model behavior. UI exercised manually on device/simulator; build verified via `xcodebuild` against an iPhone simulator.

## Out of scope (v1)

Folders, search implementation beyond simple text filter, Siri shortcut, multi-language transcription, polish history (only latest polish kept), iCloud sync.
