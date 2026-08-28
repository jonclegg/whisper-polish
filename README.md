<p align="center">
  <img src="WhisperPolish/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="104" alt="Whisper Polish app icon">
</p>

<h1 align="center">Whisper Polish</h1>

<p align="center">
  <strong>Talk naturally. Leave with words you can actually send.</strong>
</p>

<p align="center">
  A free, open-source iPhone app that transcribes voice notes on-device,<br>
  then rewrites them in the style you choose.
</p>

<p align="center">
  <a href="#why-whisper-polish">Why Whisper Polish</a> ·
  <a href="#whisper-polish-cloud">Whisper Polish Cloud</a> ·
  <a href="#build-it">Build it</a> ·
  <a href="https://yallware.com/whisper-polish/">Website</a> ·
  <a href="SECURITY.md">Security</a>
</p>

<p align="center">
  <img src="AppStore/Screenshots/iphone-65-marketing/01-talk-naturally.png" width="31%" alt="Record a voice note naturally in Whisper Polish">
  <img src="AppStore/Screenshots/iphone-65-marketing/02-clear-writing.png" width="31%" alt="Turn a rough transcript into clear writing">
  <img src="AppStore/Screenshots/iphone-65-marketing/03-match-the-moment.png" width="31%" alt="Choose a writing style for the moment">
</p>

<p align="center">
  <img src="AppStore/Screenshots/iphone-65-marketing/04-simple-cloud-plan.png" width="31%" alt="Subscribe to Whisper Polish Cloud for a monthly polish allowance">
  <img src="AppStore/Screenshots/iphone-65-marketing/05-actionable-summaries.png" width="31%" alt="Create concise and actionable summaries">
</p>

## Why Whisper Polish

Most transcription apps stop at a wall of spoken text. Whisper Polish keeps the speed and personality of a voice note, then removes the filler, false starts, and repetition that make it hard to send.

- **Private by default.** Recording and transcription happen on your iPhone.
- **Your voice, cleaned up.** Built-in styles cover email, text, Slack, summaries, and more; custom styles let you describe exactly how you want to sound.
- **Originals stay intact.** The transcript and polished version live together in the same local note.
- **No account required.** Recording and transcription work without a subscription. Cloud polish uses Whisper Polish Cloud through Apple.

## Whisper Polish Cloud

Whisper Polish is free to record and transcribe. Cloud polish is unlocked only by the Whisper Polish Cloud subscription: up to 300 cloud polishes per billing period, billed through Apple, with no provider API key.

Recording, on-device transcription, and note storage do not require a subscription.

## Under the hood

The iOS app is written in SwiftUI and stores notes locally with SwiftData. It supports Parakeet and Whisper transcription models and uses StoreKit 2 for the optional subscription.

The Cloud service is a small TypeScript/Fastify API. Each request carries an App Store-signed transaction; the server verifies the entitlement and enforces the plan allowance without introducing a separate Whisper Polish account or login.

```text
Voice or typed note
        │
        ├── on-device transcription ── local SwiftData note
        │
        └── Cloud subscription ─────── entitlement check ── OpenRouter
```

## Build it

You need macOS with Xcode 26 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45 or newer.

```sh
git clone https://github.com/jonclegg/whisper-polish.git
cd whisper-polish
brew install xcodegen
xcodegen generate
xcodebuild \
  -project WhisperPolish.xcodeproj \
  -scheme WhisperPolish \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

[`project.yml`](project.yml) is the source of truth; the generated Xcode project is intentionally ignored. Swift package versions are pinned so clean checkouts resolve the same dependencies.

The included [`WhisperPolish.storekit`](WhisperPolish.storekit) configuration provides a local version of the monthly product for StoreKit testing. A distribution build needs the matching App Store Connect product:

```text
com.jonclegg.WhisperPolish.cloud.monthly
```

### Configure the Cloud API

Distribution builds need the production HTTPS Cloud API base URL:

```sh
xcodebuild \
  -project WhisperPolish.xcodeproj \
  -scheme WhisperPolish \
  WHISPER_POLISH_API_BASE_URL=https://api.example.com \
  archive
```

See [`backend/README.md`](backend/README.md) for local development and production configuration.

## Repository map

| Path | What lives there |
|---|---|
| [`WhisperPolish/`](WhisperPolish/) | SwiftUI app, models, services, and views |
| [`Tests/`](Tests/) | iOS unit tests and opt-in integration tests |
| [`backend/`](backend/) | StoreKit-verifying Cloud API |
| [`AppStore/`](AppStore/) | Store metadata and reproducible screenshot assets |
| [`deploy/`](deploy/) | Containerized production deployment |
| [`project.yml`](project.yml) | Reproducible XcodeGen project definition |

## Contributing

Issues and pull requests are welcome. Keep changes focused, include tests when behavior changes, and never commit API keys, App Store Connect credentials, database credentials, or production environment files.

Please report security issues privately as described in [`SECURITY.md`](SECURITY.md).

## License

Whisper Polish is released under the [Apache License 2.0](LICENSE). Third-party packages and downloaded model weights remain subject to their own licenses.
