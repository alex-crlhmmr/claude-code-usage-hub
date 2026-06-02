# Claude Code usage telemetry hub

Self-hosted, no-sudo, no-Docker stack that tracks Claude Code **token/cost usage per
account — and, across a Tailscale fleet, per device and per OS-user.** One machine
(`YOUR-HUB`) hosts everything; other machines stream their Claude Code telemetry to it.

```
  fleet devices (Mac, Jetson, …)                 HUB  (YOUR-HUB)
  Claude Code, TELEMETRY=1        OTLP/gRPC       OTel Collector  :4317/:4318
  + device.name + os.user   ───────over──────►      └─ resource→label
  (account labels automatic)     Tailscale        Prometheus (TSDB) :9090  (365d)
                                                  Grafana :3000  (dashboard)
```

## Components (all on the hub)
| Service | Bind | Role |
|---------|------|------|
| OTel Collector | `0.0.0.0:4317` gRPC, `:4318` HTTP | Ingest from hub + fleet; promotes `device.name`→`device_name`, `os.user`→`os_user`; exposes `127.0.0.1:8889` |
| Prometheus | `127.0.0.1:9090` | TSDB, scrapes collector every 15s, **365d retention** |
| Grafana | `0.0.0.0:3000` | Dashboard `claude-code-usage`, anon view, admin pw in `.secrets.env` |

## Identity / accounting model
- **Canonical per-account key = `user_account_uuid`** (immutable; `user_email` is display-only).
- **Composite series identity = (user_account_uuid, device_name, os_user)** — orthogonal labels, so you can group by account, by device, or both.
- Account labels (`user_account_uuid`, `user_email`, `organization_id`) are emitted **automatically** by Claude Code. Only `device.name` + `os.user` are added per device.
- **Attribution follows the account a session is LAUNCHED with.** A mid-session `/login` does NOT reliably re-tag. Rule: one Claude account per person, each launches their own session.
- Irreducible case: two humans sharing ONE account AND ONE OS login → indistinguishable (data loss). Fixed only by policy (one account per person; distinct OS logins as a backstop that `os_user` then splits).

## Add a device to the fleet
On the device (must be on the `alex@` tailnet, MagicDNS on):
```bash
scp YOUR-HUB.tailNNNN.ts.net:~/otel-claude/join-fleet.sh .   # or copy it over
./join-fleet.sh                 # auto device.name=$(hostname -s), os.user=$(id -un)
./join-fleet.sh --dry-run       # preview the settings.json change first
```
Then **restart Claude Code** (new session). It streams to the hub; within ~25s it appears
on the dashboard, split by device and account. Endpoint used:
`http://YOUR-HUB.tailNNNN.ts.net:4317` (MagicDNS — survives hub IP changes).

## View / query
- Grafana:    http://localhost:3000/d/claude-code-usage  (or `:3000` over LAN/Tailscale)
- `python3 query.py [window]`            — per-account totals (default 30d)
- `python3 query.py 7d --by-device`      — per account x device x os_user
- `python3 verify-fleet.py [window]`     — fleet table + integrity checks (fan-out, un-joined, reconciliation)

Key PromQL (genuine accounts only; `<UUID>` = `user_account_uuid=~"[0-9a-f]{8}-...":`):
```promql
# per device per account
sum by (device_name, user_account_uuid, user_email) (increase(claude_code_token_usage_tokens_total{<UUID>}[1d]))
# per account across all devices
sum by (user_account_uuid, user_email) (increase(claude_code_cost_usage_USD_total{<UUID>}[1d]))
# per device, all accounts
sum by (device_name) (increase(claude_code_cost_usage_USD_total{<UUID>}[1d]))
```

## Manage
```bash
./start.sh     # idempotent; also armed via crontab @reboot
./stop.sh
```

## Security posture (honest)
- **Transport:** Tailscale (private, encrypted). The OTLP ports are `0.0.0.0` (so they keep
  working when the dynamic Tailscale IP changes), which means they are **also reachable on the
  LAN, unauthenticated.** Lock down with a **Tailscale ACL** (only tailnet members → hub:4317,4318)
  and/or a host firewall (`sudo ufw allow in on tailscale0 to any port 4317,4318` + deny elsewhere).
- Prometheus exposition (`:8889`) and Prometheus itself (`:9090`) are localhost-only.
- Grafana admin password is in `.secrets.env` (gitignored); anonymous viewing is on.

## Notes
- Only captures Claude Code on machines that have joined. No backfill of pre-telemetry usage.
- `bin/` and `dl/` (binaries, ~1.5GB) and `local/*-data` (the databases) are gitignored — re-`start.sh` re-creates runtime state; binaries re-download from `.vers`.
- `session_id` is kept as a label (forensic drilldown); fine at fleet scale. Dropping it for cardinality is a future option but risks duplicate-series at scrape, so it is intentionally not done here.
- The `docker-compose.yml` + `grafana/` dir are an unused alternate (Docker) path.
