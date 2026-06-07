#!/usr/bin/env bash
# setup-hub.sh — bootstrap a Claude Code telemetry HUB from scratch (Linux, no sudo for the stack).
# Downloads OTel Collector + Prometheus + Grafana (user-space), starts them, and arms
# reboot + logout persistence (cron @reboot + systemd linger). Idempotent: safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

# --- versions (edit .vers to pin) ---
[ -f .vers ] && . ./.vers
OTEL_VER="${OTEL_VER:-0.153.0}"; PROM_VER="${PROM_VER:-3.12.0}"; GRAF_VER="${GRAF_VER:-10.2.3}"
printf 'OTEL_VER=%s\nPROM_VER=%s\nGRAF_VER=%s\n' "$OTEL_VER" "$PROM_VER" "$GRAF_VER" > .vers

# --- platform ---
[ "$(uname -s)" = "Linux" ] || { echo "This bootstrap targets Linux. For a macOS/Windows hub, download the darwin/windows build of each tool and adjust paths in start.sh."; exit 1; }
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64;;
  aarch64|arm64) ARCH=arm64;;
  *) echo "unsupported arch: $(uname -m)"; exit 1;;
esac
command -v curl >/dev/null || { echo "curl required"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }
echo "Platform linux/$ARCH | otel=$OTEL_VER prom=$PROM_VER grafana=$GRAF_VER"

mkdir -p bin dl logs run local/prom-data local/grafana-data local/grafana-logs

fetch(){ [ -s "$2" ] && return 0; echo "  downloading $(basename "$2")..."; curl -fsSL -m 300 -o "$2" "$1"; }

if [ ! -x bin/otelcol-contrib ]; then
  fetch "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VER}/otelcol-contrib_${OTEL_VER}_linux_${ARCH}.tar.gz" dl/otel.tgz
  tar xzf dl/otel.tgz -C bin otelcol-contrib
fi
if [ ! -x "bin/prometheus-${PROM_VER}.linux-${ARCH}/prometheus" ]; then
  fetch "https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.linux-${ARCH}.tar.gz" dl/prom.tgz
  tar xzf dl/prom.tgz -C bin
fi
if [ ! -x "bin/grafana-v${GRAF_VER}/bin/grafana" ]; then
  fetch "https://dl.grafana.com/oss/release/grafana-${GRAF_VER}.linux-${ARCH}.tar.gz" dl/grafana.tgz
  tar xzf dl/grafana.tgz -C bin
fi
echo "Binaries ready."

# --- Grafana admin password (generated once, gitignored) ---
if [ ! -f .secrets.env ]; then
  PW=$( (openssl rand -base64 18 2>/dev/null || head -c 18 /dev/urandom | base64) | tr -d '/+=' | cut -c1-20)
  printf "# Gitignored. Sourced by start.sh. Do NOT commit.\nexport GF_SECURITY_ADMIN_PASSWORD='%s'\n" "$PW" > .secrets.env
  chmod 600 .secrets.env
  echo "Generated Grafana admin password -> .secrets.env (applied on first Grafana init)."
fi

chmod +x start.sh stop.sh device-setup.sh query.py verify-fleet.py install-systemd.sh 2>/dev/null || true

# --- start + persistence: prefer systemd --user (auto-restart on crash + boot), else setsid+cron ---
if systemctl --user is-system-running >/dev/null 2>&1; then
  echo "Using systemd --user (Restart=always crash recovery + boot via linger)."
  ./install-systemd.sh
else
  echo "systemd --user unavailable; falling back to setsid + cron @reboot."
  ./start.sh
  TMP=$(mktemp); crontab -l 2>/dev/null | grep -v 'otel-claude/start.sh' > "$TMP" || true
  echo "@reboot $ROOT/start.sh >> $ROOT/logs/boot.log 2>&1" >> "$TMP"
  crontab "$TMP" && rm -f "$TMP" && echo "Armed cron @reboot (survives reboot)."
  loginctl enable-linger "$(id -un)" 2>/dev/null && echo "Enabled linger (survives logout)." \
    || echo "NOTE: for logout-survival run once:  sudo loginctl enable-linger $(id -un)"
fi

HUB_DNS="$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null || true)"
echo
echo "HUB READY."
if [ -n "$HUB_DNS" ]; then
  echo "  Tailscale hub name: $HUB_DNS"
  echo "  Devices join with:  ./device-setup.sh --hub $HUB_DNS   (Windows: .\\device-setup.ps1 -Hub $HUB_DNS)"
else
  echo "  Find this hub's Tailscale name with: tailscale status   then devices: ./device-setup.sh --hub <name>"
fi
echo "  Grafana: http://localhost:3000  (admin password in .secrets.env)"
