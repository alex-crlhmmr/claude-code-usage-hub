#!/usr/bin/env bash
# Join this device to the Claude Code telemetry hub over Tailscale.
# Performs a JSON-aware merge into ~/.claude/settings.json (python3 only).
# Idempotent, no sudo. Account identity is emitted automatically by Claude Code
# from the login; this only adds device.name + os.user and points at the hub.
set -euo pipefail

# Hub Tailscale MagicDNS name — override with --hub, env HUB_HOST, or a gitignored ./hub.conf.
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SELFDIR/hub.conf" ] && . "$SELFDIR/hub.conf"
HUB_HOST="${HUB_HOST:-YOUR-HUB.tailNNNN.ts.net}"
GRPC_PORT=4317
HTTP_PORT=4318
DEVICE_NAME=""
DRY_RUN=0
NO_VERIFY=0
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

die(){ echo "ERROR: $*" >&2; exit 1; }
usage(){ cat <<EOF
join-fleet.sh — point this device's Claude Code telemetry at the hub.
Usage: $0 [--name NAME] [--hub HOST] [--dry-run] [--no-verify]
  --name NAME   device label shown in dashboards (default: hostname -s)
  --hub  HOST   hub MagicDNS/host (default: $HUB_HOST)
  --dry-run     print the merged settings.json, write nothing
  --no-verify   skip the hub connectivity check
  -h, --help    show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name) [ $# -ge 2 ] || die "--name requires a value"; DEVICE_NAME="$2"; shift 2;;
    --hub)  [ $# -ge 2 ] || die "--hub requires a value"; HUB_HOST="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --no-verify) NO_VERIFY=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "unknown argument: $1 (see --help)";;
  esac
done

case "$HUB_HOST" in *YOUR-HUB*) die "set your hub: ./join-fleet.sh --hub <your-hub.tailXXXX.ts.net>  (run 'tailscale status' on the hub to find it, or create ./hub.conf)";; esac
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -n "$DEVICE_NAME" ] || DEVICE_NAME="$(hostname -s 2>/dev/null || hostname)"
OS_USER="$(id -un)"
ENDPOINT="http://${HUB_HOST}:${GRPC_PORT}"

echo "Device : $DEVICE_NAME"
echo "OS user: $OS_USER"
echo "Hub    : $ENDPOINT"
echo "Target : $SETTINGS"

# Connectivity check — reliable: POST to the OTLP/HTTP port. Any HTTP status (200/400/415)
# proves reachability; only a total failure (000) means unreachable. (tailscale ping's exit
# code is unreliable, so we do not use it.)
if [ "$NO_VERIFY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 6 -X POST -H 'content-type: application/json' \
    -d '{}' "http://${HUB_HOST}:${HTTP_PORT}/v1/metrics" 2>/dev/null || echo 000)
  [ "$code" = "000" ] && die "hub unreachable at ${HUB_HOST}:${HTTP_PORT} — is Tailscale up? (run: tailscale status). Re-run with --no-verify to skip."
  echo "Hub reachable (HTTP $code)."
fi

# Backup existing settings (bash side — simple and safe).
if [ -f "$SETTINGS" ] && [ "$DRY_RUN" -eq 0 ]; then
  ts=$(date +%Y%m%d%H%M%S 2>/dev/null || echo bak)
  cp -p "$SETTINGS" "${SETTINGS}.bak.${ts}" 2>/dev/null || cp "$SETTINGS" "${SETTINGS}.bak.${ts}"
  echo "Backed up -> ${SETTINGS}.bak.${ts}"
fi

# JSON-aware merge + atomic, mode-preserving write (python3).
python3 - "$SETTINGS" "$DEVICE_NAME" "$OS_USER" "$ENDPOINT" "$DRY_RUN" <<'PY'
import json, os, sys, tempfile, stat
path, dev, osu, endpoint, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
try:
    with open(path) as f:
        data = json.load(f); existed = True
except FileNotFoundError:
    data, existed = {}, False
except json.JSONDecodeError as e:
    sys.exit("settings.json is not valid JSON (%s) — fix or move it, then re-run." % e)
if not isinstance(data, dict):
    sys.exit("settings.json top-level is not an object; aborting.")
env = data.get("env", {})
if not isinstance(env, dict):
    sys.exit('"env" in settings.json is not an object; aborting.')
env.update({
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
    "OTEL_METRIC_EXPORT_INTERVAL": "10000",
    "OTEL_EXPORTER_OTLP_ENDPOINT": endpoint,
    "OTEL_RESOURCE_ATTRIBUTES": "device.name=%s,os.user=%s" % (dev, osu),
})
data["env"] = env
out = json.dumps(data, indent=2) + "\n"
if dry:
    sys.stdout.write(out); sys.exit(0)
d = os.path.dirname(os.path.abspath(path)) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        f.write(out)
    os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode) if existed else 0o600)
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise
print("Wrote telemetry env -> %s" % path)
PY

[ "$DRY_RUN" -eq 1 ] && exit 0
echo
echo "Done. RESTART Claude Code (start a fresh session) so it loads the telemetry env."
echo "Each person should run Claude Code under THEIR OWN login — attribution follows the"
echo "account a session is LAUNCHED with (a mid-session /login does not reliably re-tag)."
