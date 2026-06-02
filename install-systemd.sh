#!/usr/bin/env bash
# install-systemd.sh — manage the hub via systemd --user.
# Gains over cron+setsid: Restart=always (auto-recovers a CRASHED component), plus
# clean start/stop/status. Boot-start still relies on systemd linger (already enabled).
# Migrates off the cron @reboot + setsid approach. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
. ./.vers
ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
COL_BIN="$ROOT/bin/otelcol-contrib"
PROM_BIN="$ROOT/bin/prometheus-${PROM_VER}.linux-${ARCH}/prometheus"
GRAF_DIR="$ROOT/bin/grafana-v${GRAF_VER}"
UNIT_DIR="$HOME/.config/systemd/user"

command -v systemctl >/dev/null || { echo "systemctl not found"; exit 1; }
systemctl --user is-system-running >/dev/null 2>&1 || echo "WARN: user systemd not fully running; units may not start until a user session/linger is active."
mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/cc-collector.service" <<EOF
[Unit]
Description=Claude Code telemetry - OTel Collector
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$COL_BIN --config $ROOT/otel-collector-config.yaml
Restart=always
RestartSec=3
[Install]
WantedBy=default.target
EOF

cat > "$UNIT_DIR/cc-prometheus.service" <<EOF
[Unit]
Description=Claude Code telemetry - Prometheus
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$PROM_BIN --config.file=$ROOT/prometheus-local.yml --storage.tsdb.path=$ROOT/local/prom-data --storage.tsdb.retention.time=365d --web.listen-address=localhost:9090
Restart=always
RestartSec=3
[Install]
WantedBy=default.target
EOF

# Grafana: admin password embedded from .secrets.env (unit lives outside the repo; chmod 600).
GF_PW=""
[ -f ./.secrets.env ] && { . ./.secrets.env; GF_PW="${GF_SECURITY_ADMIN_PASSWORD:-}"; }
cat > "$UNIT_DIR/cc-grafana.service" <<EOF
[Unit]
Description=Claude Code telemetry - Grafana
After=network-online.target cc-prometheus.service
Wants=network-online.target
[Service]
Type=simple
Environment=GF_PATHS_DATA=$ROOT/local/grafana-data
Environment=GF_PATHS_LOGS=$ROOT/local/grafana-logs
Environment=GF_PATHS_PROVISIONING=$ROOT/local/grafana-provisioning
Environment=GF_SECURITY_ADMIN_USER=admin
Environment=GF_AUTH_ANONYMOUS_ENABLED=true
Environment=GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
${GF_PW:+Environment="GF_SECURITY_ADMIN_PASSWORD=$GF_PW"}
ExecStart=$GRAF_DIR/bin/grafana server --homepath $GRAF_DIR
Restart=always
RestartSec=3
[Install]
WantedBy=default.target
EOF
chmod 600 "$UNIT_DIR/cc-grafana.service"

# Stop the old setsid-managed processes so systemd can own the ports.
echo "Stopping setsid-managed stack (if running)..."
./stop.sh >/dev/null 2>&1 || true

# Drop the cron @reboot line — systemd (with linger) now handles boot start.
if crontab -l 2>/dev/null | grep -q 'otel-claude/start.sh'; then
  TMP=$(mktemp); crontab -l 2>/dev/null | grep -v 'otel-claude/start.sh' > "$TMP" || true
  crontab "$TMP"; rm -f "$TMP"
  echo "Removed cron @reboot (systemd takes over boot-start)."
fi

systemctl --user daemon-reload
systemctl --user enable --now cc-collector.service cc-prometheus.service cc-grafana.service
loginctl enable-linger "$(id -un)" 2>/dev/null || echo "NOTE: run once for boot-without-login:  sudo loginctl enable-linger $(id -un)"

echo
echo "Installed + started. Manage with:"
echo "  systemctl --user status  cc-collector cc-prometheus cc-grafana"
echo "  systemctl --user restart cc-grafana"
echo "  journalctl --user -u cc-collector -f"
echo "Note: with systemd managing the stack, do NOT use start.sh/stop.sh (they'd race systemd)."
