# App Store Connect submission

## App

- Name: Whisper Polish
- Apple ID: 6800487416
- Bundle ID: com.jonclegg.WhisperPolish
- SKU: whisper-polish-ios
- Primary category: Productivity
- Secondary category: Utilities
- Price: Free
- Copyright: 2026 Jonathan Clegg
- Availability: All supported countries and regions

The English (U.S.) listing copy lives in `Metadata/en-US/`. Upload the five customer-facing
files in `Screenshots/iphone-65-marketing/` in filename order. They are reproducibly rendered
from the raw simulator captures with:

```sh
swift AppStore/Scripts/render-marketing-screenshots.swift AppStore
```

## Subscription

- Group: Whisper Polish Cloud
- Group ID: 22303471
- Product ID: com.jonclegg.WhisperPolish.cloud.monthly
- Subscription Apple ID: 6800487749
- Duration: 1 month
- U.S. price: $4.99
- Included usage: 300 cloud polishes per billing period
- Family Sharing: Off

Use `Screenshots/iphone-65/04-cloud-plan.png` as the subscription review screenshot.

## App review notes

Whisper Polish does not require an account. Recording and transcription work on-device.
The optional Personal Key mode requires a user-provided OpenRouter API key. The optional
Whisper Polish Cloud mode is unlocked by the auto-renewable subscription and includes 300
cloud polishes per month. No reviewer credentials are required.

## App privacy answers

The backend retains generated polished output for idempotent retries and associates it
with Apple subscription transaction identifiers. Based on Apple's current definitions,
declare:

- Other User Content: collected for App Functionality, linked to the user, not used for tracking.
- Purchase History: collected for App Functionality, linked to the user, not used for tracking.

Audio recordings and transcription remain on-device. Personal-key requests go directly
to OpenRouter and are governed by the user's OpenRouter account settings.

Privacy policy URL: https://yallware.com/whisper-polish/privacy/

## Age rating

Answer "None" or "No" for every content descriptor and capability unless App Store
Connect adds a new question that materially describes the app. The expected rating is 4+.

## Release controls

- Use manual release for version 1.0.
- Do not submit for review until the production Cloud API URL is configured in the archive,
  a signed distribution build is uploaded, the subscription metadata is complete, and the
  public website URLs return 200.
