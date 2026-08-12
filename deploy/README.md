# Cloud deployment

Production runs on the `whisper-polish-api` Lightsail instance in `us-east-1`.
Docker Compose keeps the API and Postgres private behind Caddy, which terminates
TLS for `api.whisper-polish.yallware.com`.

The host uses Ubuntu 24.04 with the distribution packages `docker.io` and
`docker-compose-v2`. Its static IP is attached in Lightsail and the API hostname
is an A record in the `yallware.com` Route 53 zone.

The uncommitted production `.env` must define `POSTGRES_PASSWORD`,
`OPENROUTER_API_KEY`, `AWS_ACCESS_KEY_ID`, and `AWS_SECRET_ACCESS_KEY`. The AWS
identity is restricted to sending email from `alerts@yallware.com` only to
`jon@yallware.com`.

The API checks the OpenRouter key every five minutes. It emails on the first
provider failure, on recovery, and when the key's remaining spend allowance falls below $25.
Repeated failures and low-balance checks are suppressed until recovery.

From the repository root on the server:

```sh
cd deploy
docker compose up -d --build
docker compose ps
curl --fail https://api.whisper-polish.yallware.com/health
```

Back up the `deploy_postgres_data` volume before host replacement or destructive
database maintenance.
