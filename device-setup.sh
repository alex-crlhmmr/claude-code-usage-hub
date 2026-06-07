#!/usr/bin/env bash
# device-setup.sh — onboard THIS device to the Claude Code telemetry hub. One script, two modes:
#   (default) reliable : runs a local spool-and-forward agent — NEVER drops data on a hub/network
#                        outage (queues to disk, backfills on reconnect; survives reboots).
#   --direct           : best-effort — send straight to the hub. Lighter (no agent), but DROPS
#                        usage while the hub/network is unreachable.
# Linux (systemd --user) + macOS (launchd). No sudo. Idempotent. Re-run to switch modes.
set -euo pipefail
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SELFDIR/hub.conf" ] && . "$SELFDIR/hub.conf"
HUB_HOST="${HUB_HOST:-YOUR-HUB.tailNNNN.ts.net}"
OTEL_VER="${OTEL_VER:-0.153.0}"
AGENTDIR="$HOME/.claude-otel-agent"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
DEVICE_NAME=""; MODE="reliable"; NO_VERIFY=0; DRY_RUN=0

die(){ echo "ERROR: $*" >&2; exit 1; }
usage(){ cat <<EOF
device-setup.sh — join a device to the Claude Code telemetry hub.
Usage: $0 --hub HOST [--name NAME] [--direct] [--no-verify] [--dry-run]
  --hub HOST     hub Tailscale MagicDNS name (or set ./hub.conf / env HUB_HOST)
  --name NAME    device label (default: hostname -s)
  --direct       best-effort mode (no local agent; drops during outages)
  --reliable     spool-and-forward mode (default; never drops)
  --no-verify    skip hub connectivity check
  --dry-run      show what would change, do nothing
EOF
}

while [ $# -gt 0 ]; do case "$1" in
  --hub)     [ $# -ge 2 ] || die "--hub needs a value"; HUB_HOST="$2"; shift 2;;
  --name)    [ $# -ge 2 ] || die "--name needs a value"; DEVICE_NAME="$2"; shift 2;;
  --version) [ $# -ge 2 ] || die "--version needs a value"; OTEL_VER="$2"; shift 2;;
  --direct|--best-effort) MODE="direct"; shift;;
  --reliable) MODE="reliable"; shift;;
  --no-verify) NO_VERIFY=1; shift;;
  --dry-run) DRY_RUN=1; shift;;
  -h|--help) usage; exit 0;;
  *) die "unknown argument: $1 (see --help)";;
esac; done

case "$HUB_HOST" in *YOUR-HUB*) die "set your hub: $0 --hub <your-hub.tailXXXX.ts.net>  (run 'tailscale status' on the hub)";; esac
command -v python3 >/dev/null || die "python3 required"
command -v curl    >/dev/null || die "curl required"
[ -n "$DEVICE_NAME" ] || DEVICE_NAME="$(hostname -s 2>/dev/null || hostname)"
OS_USER="$(id -un)"

OS="$(uname -s)"; M="$(uname -m)"
case "$M" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) die "unsupported arch: $M";; esac
case "$OS" in Linux) PLAT=linux;; Darwin) PLAT=darwin;; *) die "Linux/macOS only (this is $OS; use device-setup.ps1 on Windows)";; esac

echo "Device : $DEVICE_NAME ($PLAT/$ARCH)"
echo "Hub    : $HUB_HOST:4317"
echo "Mode   : $MODE"

if [ "$NO_VERIFY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 6 -X POST -H 'content-type: application/json' -d '{}' "http://${HUB_HOST}:4318/v1/metrics" 2>/dev/null || echo 000)
  [ "$code" = "000" ] && die "hub unreachable at ${HUB_HOST}:4318 — is Tailscale up? (tailscale status). --no-verify to skip."
  echo "Hub reachable (HTTP $code)."
fi

if [ "$MODE" = reliable ]; then ENDPOINT="http://localhost:4317"; else ENDPOINT="http://${HUB_HOST}:4317"; fi

# ---- reliable mode: install the local spool-and-forward agent ----
if [ "$MODE" = reliable ] && [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$AGENTDIR/queue"
  BIN="$AGENTDIR/otelcol-contrib"
  if [ ! -x "$BIN" ]; then
    url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VER}/otelcol-contrib_${OTEL_VER}_${PLAT}_${ARCH}.tar.gz"
    echo "Downloading local agent..."; curl -fsSL -m 300 -o "$AGENTDIR/dl.tgz" "$url"
    tar xzf "$AGENTDIR/dl.tgz" -C "$AGENTDIR" otelcol-contrib && rm -f "$AGENTDIR/dl.tgz"
  fi
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
    tls: { insecure: true }
    sending_queue:
      enabled: true
      storage: file_storage/queue
      queue_size: 100000
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 60s
      max_elapsed_time: 0
service:
  extensions: [file_storage/queue]
  pipelines:
    metrics: { receivers: [otlp], processors: [batch], exporters: [otlp/hub] }
    logs:    { receivers: [otlp], processors: [batch], exporters: [otlp/hub] }
  telemetry:
    metrics: { level: none }
EOF
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
    echo "Agent: systemd --user 'claude-otel-agent' (Restart=always)."
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
    echo "Agent: launchd 'com.claudecode.otelagent' (KeepAlive)."
  fi
fi

# ---- if switching to --direct, stop any previously-installed local agent ----
if [ "$MODE" = direct ] && [ "$DRY_RUN" -eq 0 ]; then
  if [ "$PLAT" = linux ]; then systemctl --user disable --now claude-otel-agent.service 2>/dev/null || true
  else launchctl unload "$HOME/Library/LaunchAgents/com.claudecode.otelagent.plist" 2>/dev/null || true; fi
fi

# ---- point Claude Code at the chosen endpoint (+ device identity) ----
[ "$DRY_RUN" -eq 0 ] && [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S 2>/dev/null || echo bak)" 2>/dev/null || true
python3 - "$SETTINGS" "$DEVICE_NAME" "$OS_USER" "$ENDPOINT" "$DRY_RUN" <<'PY'
import json,os,sys,tempfile,stat
path,dev,osu,endpoint,dry = sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5]=="1"
try: d=json.load(open(path)); existed=True
except FileNotFoundError: d,existed={},False
except json.JSONDecodeError as e: sys.exit("settings.json invalid JSON (%s)"%e)
env=d.get("env",{})
if not isinstance(env,dict): sys.exit('"env" is not an object in settings.json')
env.update({
 "CLAUDE_CODE_ENABLE_TELEMETRY":"1","OTEL_METRICS_EXPORTER":"otlp","OTEL_LOGS_EXPORTER":"otlp",
 "OTEL_EXPORTER_OTLP_PROTOCOL":"grpc","OTEL_METRIC_EXPORT_INTERVAL":"10000",
 "OTEL_EXPORTER_OTLP_ENDPOINT":endpoint,
 "OTEL_RESOURCE_ATTRIBUTES":"device.name=%s,os.user=%s"%(dev,osu)})
d["env"]=env
out=json.dumps(d,indent=2)+"\n"
if dry: sys.stdout.write(out); sys.exit(0)
dd=os.path.dirname(os.path.abspath(path)) or "."; os.makedirs(dd,exist_ok=True)
fd,tmp=tempfile.mkstemp(dir=dd,prefix=".settings.",suffix=".tmp")
with os.fdopen(fd,"w") as f: f.write(out)
os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode) if existed else 0o600); os.replace(tmp,path)
print("Pointed Claude Code at %s"%endpoint)
PY

[ "$DRY_RUN" -eq 1 ] && exit 0
echo
echo "Done ($MODE). RESTART Claude Code (fresh session) so it loads the telemetry env."
if [ "$MODE" = reliable ]; then
  echo "Flow: Claude -> local agent (spools to $AGENTDIR/queue) -> hub. Outages delay, never drop."
  echo "Check agent:  $( [ "$PLAT" = linux ] && echo 'systemctl --user is-active claude-otel-agent' || echo 'launchctl list | grep otelagent' )"
else
  echo "Flow: Claude -> hub directly (best-effort). Re-run without --direct for outage-proof spooling."
fi
echo "Run Claude Code under YOUR OWN login — attribution follows the launch account."
