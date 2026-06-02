#!/usr/bin/env bash
# Stop the no-sudo telemetry stack (kills by listening port, robust to setsid re-parenting).
cd "$(dirname "$0")" || exit 1
for entry in collector:4317 prometheus:9090 grafana:3000; do
  name="${entry%%:*}"; port="${entry##*:}"
  pid=$( (ss -ltnp 2>/dev/null) | grep ":$port " | grep -oP 'pid=\K[0-9]+' | head -1)
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null && echo "$name stopped (pid $pid)"; else echo "$name not running"; fi
  rm -f "run/$name.pid"
done
