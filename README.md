# Claude Code usage telemetry hub

Self-hosted, no-Docker, no-sudo stack that tracks **Claude Code token/cost usage per account**
— and across a Tailscale fleet, **per device and per OS-user**. One machine hosts everything
(collector + database + dashboards); other machines stream their Claude Code telemetry to it.

```
  fleet devices (Mac / Linux / Windows)            HUB (one host, e.g. YOUR-HUB)
  Claude Code, TELEMETRY=1        OTLP/gRPC        OTel Collector  :4317 / :4318
  + device.name + os.user   ───── over ─────►         └─ resource → label
  (account labels automatic)     Tailscale         Prometheus (TSDB) :9090   (365d)
                                                    Grafana  :3000   (dashboard)
```

---

## A. Set up the hub (do this on ONE machine)

Linux host, no sudo needed for the stack itself:

```bash
git clone <this-repo> otel-claude && cd otel-claude
./setup-hub.sh
```

`setup-hub.sh` downloads the three binaries (user-space), generates a Grafana admin password
(`.secrets.env`), starts everything, and arms **reboot + logout persistence**. It prints your
hub's Tailscale name and the exact join command to give your devices. Re-running is safe.

Manage it later: `./start.sh` (idempotent) · `./stop.sh`.
Requirements: Linux, `curl`, `python3`, `tar`, and Tailscale installed/logged-in.

---

## B. Join a device to the fleet

The device must be on the **same tailnet** as the hub (with MagicDNS). Replace `HUB` with your
hub's Tailscale name (from `tailscale status`, e.g. `YOUR-HUB.tailNNNN.ts.net`).

**macOS / Linux:**
```bash
scp HUB:~/otel-claude/join-fleet.sh .
./join-fleet.sh --hub HUB            # add --dry-run to preview first
```

**Windows (PowerShell):**
```powershell
# copy join-fleet.ps1 from the hub, then:
.\join-fleet.ps1 -Hub HUB            # add -DryRun to preview first
```
(Or use WSL / Git Bash and run `join-fleet.sh`.)

**Any OS — foolproof manual way:** add this `env` block to your Claude Code settings file
(`~/.claude/settings.json` on macOS/Linux, `%USERPROFILE%\.claude\settings.json` on Windows),
filling in your device name and the hub:
```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://HUB:4317",
    "OTEL_RESOURCE_ATTRIBUTES": "device.name=MY-DEVICE,os.user=MY-LOGIN"
  }
}
```

**After joining, restart Claude Code** (start a fresh session). Within ~25s the device appears
on the dashboard, split by device and account. Each person should run Claude Code under **their
own login** — attribution follows the account a session is *launched* with.

---

## C. Persistence — what survives reboot / logout

| Layer | Survives reboot? | Survives logout? | How |
|-------|:----------------:|:----------------:|-----|
| **Joined device** (the telemetry config) | ✅ all OSes | ✅ all OSes | It's in `settings.json`, read at every Claude Code launch — not shell env |
| **Hub** (collector + Prometheus + Grafana) | ✅ | ✅ | `cron @reboot` (reboot) + `systemd` **linger** (logout) + detached `setsid` procs |
| **Database** (metrics) | ✅ | ✅ | Prometheus TSDB on disk (`local/prom-data`), 365d retention |

Notes:
- **Joined device** persistence is the same on macOS / Linux / Windows because it's a config file.
  Only the *join method* differs (`.sh` vs `.ps1` vs manual block above).
- **Hub logout-survival needs linger** (`setup-hub.sh` enables it; if it printed a sudo note, run
  `sudo loginctl enable-linger <user>` once).
- `cron @reboot` only restarts the hub at *boot*. It does **not** auto-restart a process that
  crashes mid-run; re-run `./start.sh` (idempotent) if a component dies.

---

## D. Identity / accounting model
- Per-account key = **`user_account_uuid`** (immutable; `user_email` is display-only).
- Series identity = **(user_account_uuid, device_name, os_user)** — orthogonal labels; group by any.
- Account labels are emitted automatically by Claude Code; only `device.name` + `os.user` are added.
- Irreducible case: two humans sharing ONE account AND ONE OS login → indistinguishable. Fix by
  policy (one Claude account per person; distinct OS logins, which `os_user` then separates).

## E. View / query
- Grafana: `http://localhost:3000/d/claude-code-usage` (also LAN/Tailscale `:3000`).
- `python3 query.py [window]` — per-account totals (default 30d).
- `python3 query.py 7d --by-device` — per account × device × os_user.
- `python3 verify-fleet.py [window]` — fleet table + integrity checks (fan-out, un-joined, reconciliation).

## F. Security posture (honest)
- Transport is **Tailscale** (private, encrypted). The OTLP ports (`4317/4318`) bind `0.0.0.0` so
  they survive the hub's dynamic Tailscale IP changing — which means they're **also reachable,
  unauthenticated, on the LAN**. Lock down with a **Tailscale ACL** (tailnet members → hub only)
  and/or a host firewall: `sudo ufw allow in on tailscale0 to any port 4317,4318 proto tcp` then
  deny those ports elsewhere.
- Prometheus exposition (`:8889`) and Prometheus (`:9090`) are localhost-only.
- Grafana admin password lives in `.secrets.env` (gitignored); anonymous *viewing* is enabled.

## G. Notes
- `bin/`, `dl/` (binaries, ~1.5GB) and `local/*-data` (databases) are gitignored — `setup-hub.sh`
  re-downloads binaries from `.vers`; runtime state regenerates.
- `session_id` is kept as a label (forensic drilldown); fine at fleet scale.
- `docker-compose.yml` + `grafana/` are an unused alternate (Docker) path.
