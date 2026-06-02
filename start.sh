#!/usr/bin/env bash
# Start the no-sudo Claude Code telemetry HUB: OTel Collector + Prometheus + Grafana.
# Idempotent: skips a service whose port is already listening. setsid fully detaches;
# pidfiles track the real listener pid by port.
cd "$(dirname "$0")" || exit 1
ROOT="$(pwd)"
. ./.vers
[ -f ./.secrets.env ] && . ./.secrets.env   # GF_SECURITY_ADMIN_PASSWORD etc. (gitignored)
mkdir -p logs run local/prom-data local/grafana-data local/grafana-logs

PROM_DIR="bin/prometheus-${PROM_VER}.linux-amd64"
GRAF_DIR="bin/grafana-v${GRAF_VER}"
HUB_DNS="YOUR-HUB.tailNNNN.ts.net"   # MagicDNS — what fleet devices point at

port_up(){ (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ":$1 "; }

launch(){  # name port cmd...
  local name="$1" port="$2"; shift 2
  if port_up "$port"; then echo "$name: already up (:$port)"; return; fi
  setsid "$@" >"logs/$name.log" 2>&1 < /dev/null &
  for _ in $(seq 1 15); do
    pid=$( (ss -ltnp 2>/dev/null) | grep ":$port " | grep -oP 'pid=\K[0-9]+' | head -1)
    [ -n "$pid" ] && { echo "$pid" > "run/$name.pid"; echo "$name: started (pid $pid, :$port)"; return; }
    command sleep 1
  done
  echo "$name: launched but :$port not listening yet — see logs/$name.log"
}

launch collector 4317 "$ROOT/bin/otelcol-contrib" --config "$ROOT/otel-collector-config.yaml"

launch prometheus 9090 "$ROOT/$PROM_DIR/prometheus" \
  --config.file="$ROOT/prometheus-local.yml" \
  --storage.tsdb.path="$ROOT/local/prom-data" \
  --storage.tsdb.retention.time=365d \
  --web.listen-address="localhost:9090"

export GF_PATHS_DATA="$ROOT/local/grafana-data" GF_PATHS_LOGS="$ROOT/local/grafana-logs" \
       GF_PATHS_PROVISIONING="$ROOT/local/grafana-provisioning" \
       GF_SECURITY_ADMIN_USER="${GF_SECURITY_ADMIN_USER:-admin}" \
       GF_SECURITY_ADMIN_PASSWORD="${GF_SECURITY_ADMIN_PASSWORD:-admin}" \
       GF_AUTH_ANONYMOUS_ENABLED=true GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
launch grafana 3000 "$ROOT/$GRAF_DIR/bin/grafana" server --homepath "$ROOT/$GRAF_DIR"

echo
echo "Hub endpoints:"
echo "  Fleet OTLP (Tailscale) -> http://${HUB_DNS}:4317 (grpc)  |  :4318 (http)"
echo "  Hub-local OTLP         -> http://localhost:4317"
echo "  Prometheus             -> http://localhost:9090"
echo "  Grafana                -> http://localhost:3000  (also reachable on LAN / Tailscale :3000)"
echo "  Prometheus retention   -> 365d"
