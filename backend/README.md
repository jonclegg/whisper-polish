# Whisper Polish Cloud

The cloud service is a portable Node.js API backed by Postgres. It:

- verifies StoreKit 2 signed transactions using Apple's official server library;
- accepts only the configured Whisper Polish subscription product;
- provides at most 300 successful polish reservations per renewal transaction;
- makes idempotent requests safe to retry;
- caps notes at 8,000 UTF-8 bytes and output at 2,000 tokens;
- stops a billing period if wholesale model spend reaches $2.20, in addition to the 300-request limit;
- refuses service if the configured model's price rises above its approved ceiling;
- records request counts and provider cost without storing note text.

## Local setup

1. Start Postgres and create a database.
2. Copy `.env.example` to `.env` and replace every placeholder.
3. Download Apple's current root certificates from the Apple PKI page into `certs/`.
4. Install and run:

```sh
npm ci
set -a
source .env
set +a
npm run dev
```

The service creates its two ledger tables on startup. `GET /health` is the deployment health check.

## Required environment

- `DATABASE_URL`
- `OPENROUTER_API_KEY`
- `APP_BUNDLE_ID`
- `APP_APPLE_ID` — numeric App Store app identifier, not the bundle ID
- `APPLE_ROOT_CERTIFICATES_DIR`
- `PORT`

The production OpenRouter account should have prompt logging and training opt-ins disabled. The request also sets `provider.data_collection` to `deny`.

## Verification

```sh
npm test
npm run build
```

The Docker image runs as the unprivileged `node` user. Put TLS and request-level rate limiting at the ingress/load-balancer layer.
