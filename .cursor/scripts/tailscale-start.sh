#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=/var/lib/tailscale
LOG_FILE=/tmp/tailscaled.log
HOSTNAME="${TAILSCALE_HOSTNAME:-cursor-whisper-polish}"

sudo mkdir -p "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"

if ! pgrep -x tailscaled >/dev/null; then
  sudo TS_FORCE_NOISE_443=1 tailscaled \
    --tun=userspace-networking \
    --outbound-http-proxy-listen=localhost:1054 \
    --socks5-server=localhost:1055 \
    --statedir="$STATE_DIR" \
    >"$LOG_FILE" 2>&1 &
fi

for _ in $(seq 1 30); do
  if sudo tailscale status >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if [[ ! -f "${HOME}/.ssh/id_ed25519" ]]; then
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  ssh-keygen -t ed25519 -N "" -f "${HOME}/.ssh/id_ed25519" -C "cursor-cloud-agent"
fi

if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
  echo "tailscale-start: TAILSCALE_AUTHKEY is not set; tailscaled is running but not joined to the tailnet"
  exit 0
fi

if sudo tailscale status 2>&1 | grep -q '^100\.'; then
  echo "tailscale-start: already connected"
  sudo tailscale status
  exit 0
fi

sudo TS_FORCE_NOISE_443=1 tailscale up \
  --authkey="$TAILSCALE_AUTHKEY" \
  --hostname="$HOSTNAME" \
  --accept-dns=false \
  --ssh=false

sudo tailscale status
