# Security Policy

Please do not open a public issue for a vulnerability that could expose API keys, subscription entitlements, note contents, or cloud spending. Send a private report through GitHub Security Advisories for this repository with reproduction steps and impact.

No production secret belongs in this repository. User-provided OpenRouter keys are stored in the iOS Keychain and are never sent to the Whisper Polish backend.
