# Claude Code → OpenTelemetry → Prometheus → Grafana

Self-hosted, local-only usage tracking for Claude Code on this machine.
Captures token usage **tagged by account** (`user.email`, account uuid, org id, model),
so usage on this shared box can be split per account going forward.

## Pieces
- **OTel Collector** receives OTLP from Claude Code on `localhost:4317`, exposes Prometheus metrics on `:8889`.
- **Prometheus** scrapes the collector and stores the time series.
- **Grafana** (http://localhost:3000) visualizes it. Anonymous viewing is on; admin login is `admin` / `admin`.

Claude Code is already wired to this — `~/.claude/settings.json` sets
`CLAUDE_CODE_ENABLE_TELEMETRY=1` and `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317`.

## Start (Docker path)
If Docker isn't installed yet, install it once (run in the Claude prompt with the `!` prefix so it's interactive for the password):

    ! sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 && sudo usermod -aG docker $USER

Log out/in (or `newgrp docker`) so the group takes effect, then:

    cd ~/otel-claude
    docker compose up -d
    docker compose logs -f collector   # watch metrics arrive

Then **start a fresh Claude Code session** (env vars are read at launch) and do anything.
Within ~10s the collector log shows `claude_code.token.usage` records.

## View
- Grafana:    http://localhost:3000  (add panels using the queries below)
- Prometheus: http://localhost:9090  (quick ad-hoc queries)
- Raw feed:   http://localhost:8889/metrics

## Key metric
`claude_code_token_usage_tokens_total` — counter of tokens, with labels including:
`user_email`, `model`, `type` (input/output/cacheRead/cacheCreation), `session_id`, plus account/org ids.

### PromQL — tokens per account, per day
    sum by (user_email) (increase(claude_code_token_usage_tokens_total[1d]))

### Tokens per account split by type
    sum by (user_email, type) (increase(claude_code_token_usage_tokens_total[1d]))

### Cost per account, per day (USD)
    sum by (user_email) (increase(claude_code_cost_usage_USD_total[1d]))

### Output tokens only (the real "work" signal), per account
    sum by (user_email) (increase(claude_code_token_usage_tokens_total{type="output"}[1d]))

## Stop / reset
    docker compose down            # stop, keep data
    docker compose down -v         # stop and wipe stored metrics

## Notes
- This only sees Claude Code launched **on this machine**. Other machines need their own setup.
- Metric/label names are normalized by the Prometheus exporter (dots → underscores). If a query
  returns nothing, check the exact names at http://localhost:8889/metrics first.
- Historical usage (before telemetry was enabled) is NOT backfilled — tracking starts now.
