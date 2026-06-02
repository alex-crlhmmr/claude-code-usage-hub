#!/usr/bin/env bash
# install-device-agent.sh — "RELIABLE MODE" for one device.
#
# Runs a tiny local OTel Collector on THIS device. Claude Code sends to it (localhost);
# it spools telemetry to disk (file_storage) and forwards to the hub, retrying forever.
# Result: a hub/network outage DELAYS delivery but does not DROP data (survives reboots).
#
# Linux (systemd --user) and macOS (launchd). No sudo. Idempotent.
set -euo pipefail
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SELFDIR/hub.conf" ] && . "$SELFDIR/hub.conf"
HUB_HOST="${HUB_HOST:-YOUR-HUB.tailNNNN.ts.net}"
OTEL_VER="${OTEL_VER:-0.153.0}"
AGENTDIR="$HOME/.claude-otel-agent"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
DEVICE_NAME=""

while [ $# -gt 0 ]; do case "$1" in
  --hub)     [ $# -ge 2 ] || { echo "--hub needs a value"; exit 1; }; HUB_HOST="$2"; shift 2;;
  --name)    [ $# -ge 2 ] || { echo "--name needs a value"; exit 1; }; DEVICE_NAME="$2"; shift 2;;
  --version) [ $# -ge 2 ] || { echo "--version needs a value"; exit 1; }; OTEL_VER="$2"; shift 2;;
  -h|--help) echo "usage: $0 [--hub HOST] [--name NAME] [--version OTEL_VER]"; exit 0;;
  *) echo "unknown arg: $1"; exit 1;;
esac; done

case "$HUB_HOST" in *YOUR-HUB*) echo "ERROR: set your hub: $0 --hub <your-hub.tailXXXX.ts.net>  (tailscale status)"; exit 1;; esac
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }
command -v curl    >/dev/null || { echo "curl required"; exit 1; }
[ -n "$DEVICE_NAME" ] || DEVICE_NAME="$(hostname -s 2>/dev/null || hostname)"
OS_USER="$(id -un)"

OS="$(uname -s)"; M="$(uname -m)"
case "$M" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) echo "unsupported arch: $M"; exit 1;; esac
case "$OS" in Linux) PLAT=linux;; Darwin) PLAT=darwin;; *) echo "Linux/macOS only (this is $OS)"; exit 1;; esac

echo "Device : $DEVICE_NAME ($PLAT/$ARCH)"
echo "Hub    : $HUB_HOST:4317"
echo "Agent  : $AGENTDIR"

mkdir -p "$AGENTDIR/queue"
BIN="$AGENTDIR/otelcol-contrib"
if [ ! -x "$BIN" ]; then
  url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VER}/otelcol-contrib_${OTEL_VER}_${PLAT}_${ARCH}.tar.gz"
  echo "Downloading local agent..."
  curl -fsSL -m 300 -o "$AGENTDIR/dl.tgz" "$url"
  tar xzf "$AGENTDIR/dl.tgz" -C "$AGENTDIR" otelcol-contrib && rm -f "$AGENTDIR/dl.tgz"
fi

# Local agent config: receive on localhost, spool to disk, forward to hub forever.
cat > "$AGENTDIR/config.yaml" <<EOF
extensions:
  file_storage/queue:
    directory: $AGENTDIR/queue
    timeout: 10s
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 127.0.0.1:4317 }
      http: { endpoint: 127.0.0.1:4318 }
processors:
  batch: { timeout: 5s }
exporters:
  otlp/hub:
    endpoint: ${HUB_HOST}:4317
    tls: { insecure: true }            # Tailscale already encrypts the link
    sending_queue:
      enabled: true
      storage: file_storage/queue      # persistent: survives agent/device restarts
      queue_size: 100000
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 60s
      max_elapsed_time: 0              # retry forever — never give up on a batch
service:
  extensions: [file_storage/queue]
  pipelines:
    metrics: { receivers: [otlp], processors: [batch], exporters: [otlp/hub] }
    logs:    { receivers: [otlp], processors: [batch], exporters: [otlp/hub] }
  telemetry:
    metrics: { level: none }
EOF

# Install as an always-on service (Restart=always / KeepAlive) so it's up when Claude exports.
if [ "$PLAT" = linux ]; then
  UD="$HOME/.config/systemd/user"; mkdir -p "$UD"
  cat > "$UD/claude-otel-agent.service" <<EOF
[Unit]
Description=Claude Code local telemetry agent (spool + forward to hub)
After=network-online.target
[Service]
Type=simple
ExecStart=$BIN --config $AGENTDIR/config.yaml
Restart=always
RestartSec=3
[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now claude-otel-agent.service
  loginctl enable-linger "$(id -un)" 2>/dev/null || true
  echo "Service: systemd --user 'claude-otel-agent' (Restart=always, linger)."
else
  PL="$HOME/Library/LaunchAgents/com.claudecode.otelagent.plist"; mkdir -p "$(dirname "$PL")"
  cat > "$PL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.claudecode.otelagent</string>
  <key>ProgramArguments</key><array>
    <string>$BIN</string><string>--config</string><string>$AGENTDIR/config.yaml</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$AGENTDIR/agent.log</string>
  <key>StandardErrorPath</key><string>$AGENTDIR/agent.log</string>
</dict></plist>
EOF
  launchctl unload "$PL" 2>/dev/null || true
  launchctl load -w "$PL"
  echo "Service: launchd 'com.claudecode.otelagent' (KeepAlive)."
fi

# Point Claude Code at the LOCAL agent (was: the hub directly). Keep device identity.
[ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo bak)" 2>/dev/null || true
python3 - "$SETTINGS" "$DEVICE_NAME" "$OS_USER" <<'PY'
import json,os,sys,tempfile,stat
path,dev,osu=sys.argv[1],sys.argv[2],sys.argv[3]
try: d=json.load(open(path)); existed=True
except FileNotFoundError: d,existed={},False
env=d.get("env",{})
if not isinstance(env,dict): sys.exit('"env" is not an object in settings.json')
env.update({
 "CLAUDE_CODE_ENABLE_TELEMETRY":"1","OTEL_METRICS_EXPORTER":"otlp","OTEL_LOGS_EXPORTER":"otlp",
 "OTEL_EXPORTER_OTLP_PROTOCOL":"grpc","OTEL_METRIC_EXPORT_INTERVAL":"10000",
 "OTEL_EXPORTER_OTLP_ENDPOINT":"http://localhost:4317",   # -> local agent, not the hub
 "OTEL_RESOURCE_ATTRIBUTES":"device.name=%s,os.user=%s"%(dev,osu)})
d["env"]=env
dd=os.path.dirname(os.path.abspath(path)) or "."; os.makedirs(dd,exist_ok=True)
fd,tmp=tempfile.mkstemp(dir=dd,prefix=".settings.",suffix=".tmp")
with os.fdopen(fd,"w") as f: f.write(json.dumps(d,indent=2)+"\n")
os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode) if existed else 0o600); os.replace(tmp,path)
print("Pointed Claude Code at the local agent (http://localhost:4317).")
PY

echo
echo "RELIABLE MODE installed. Now RESTART Claude Code so it sends to the local agent."
echo "Flow: Claude Code -> local agent (spools to $AGENTDIR/queue) -> hub ($HUB_HOST)."
echo "During an outage the queue grows on disk and drains automatically when the hub returns."
