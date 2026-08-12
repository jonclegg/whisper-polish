# Whisper Polish

Whisper Polish is a free, open-source iPhone voice-notes app. Recording and transcription run on-device. A note can then be rewritten in a chosen style using either the user's own OpenRouter API key or an optional Whisper Polish Cloud subscription.

## Features

- On-device transcription with Parakeet or Whisper
- Typed and recorded notes stored locally with SwiftData
- Built-in and custom rewrite styles
- Personal Key mode with the key stored in the iOS Keychain
- Optional monthly cloud plan with up to 300 polishes per billing period
- Fact checking with live web search in Personal Key mode

## Build the iOS app

Requirements:

- Xcode 26 or newer
- XcodeGen 2.45 or newer

```sh
brew install xcodegen
xcodegen generate
xcodebuild \
  -project WhisperPolish.xcodeproj \
  -scheme WhisperPolish \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

`project.yml` is the source of truth; the generated Xcode project is intentionally ignored. Swift package versions are pinned there so clean checkouts resolve the same dependencies.

The included `WhisperPolish.storekit` file supplies a local $4.99 monthly product for StoreKit testing. Create a matching auto-renewable subscription in App Store Connect before distribution:

`com.jonclegg.WhisperPolish.cloud.monthly`

## Cloud service

Personal Key mode talks directly to OpenRouter and does not need the backend. Subscription mode sends the App Store-signed StoreKit transaction to the service on every request; the server verifies it and enforces the plan allowance without creating a separate user account.

Build with the service's HTTPS base URL:

```sh
xcodebuild \
  -project WhisperPolish.xcodeproj \
  -scheme WhisperPolish \
  WHISPER_POLISH_API_BASE_URL=https://api.example.com \
  archive
```

See [backend/README.md](backend/README.md) for local and production configuration.

## Repository layout

- `WhisperPolish/` — SwiftUI application
- `Tests/` — iOS unit and opt-in integration tests
- `backend/` — StoreKit-verifying cloud polish API
- `project.yml` — reproducible XcodeGen project definition

## Security

Never commit OpenRouter keys, App Store Connect keys, database credentials, or production environment files. Report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

Apache License 2.0. Third-party packages and downloaded model weights remain subject to their own licenses.
