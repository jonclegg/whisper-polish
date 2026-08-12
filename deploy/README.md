# Cloud deployment

Production runs on the `whisper-polish-api` Lightsail instance in `us-east-1`.
Docker Compose keeps the API and Postgres private behind Caddy, which terminates
TLS for `api.whisper-polish.yallware.com`.

The host uses Ubuntu 24.04 with the distribution packages `docker.io` and
`docker-compose-v2`. Its static IP is attached in Lightsail and the API hostname
is an A record in the `yallware.com` Route 53 zone.

The uncommitted production `.env` must define `POSTGRES_PASSWORD` and
`OPENROUTER_API_KEY`. The OpenRouter key is sourced from AWS Secrets Manager.

From the repository root on the server:

```sh
cd deploy
docker compose up -d --build
docker compose ps
curl --fail https://api.whisper-polish.yallware.com/health
```

Back up the `deploy_postgres_data` volume before host replacement or destructive
database maintenance.
