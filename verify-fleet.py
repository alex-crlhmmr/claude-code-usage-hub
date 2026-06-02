#!/usr/bin/env python3
"""Fleet reconciliation for Claude Code telemetry.

Prints per (account x device x os_user) usage and runs integrity checks:
  1. accounts active on >1 device   (legit multi-device OR shared credential -> human review)
  2. genuine series missing device_name  (un-joined devices / pre-join data)
  3. reconciliation: grand total == sum of per-account totals  (no double counting)

Keyed on immutable user_account_uuid; uses increase() (staleness-safe). The
genuine-UUID matcher excludes synthetic probe pollution (no escaped dots needed,
so no PromQL escape hazards).

Usage: python3 verify-fleet.py [WINDOW]    (default 7d)
"""
import sys, json, urllib.parse, urllib.request, urllib.error

BASE = "http://localhost:9090/api/v1/query"
WINDOW = sys.argv[1] if len(sys.argv) > 1 else "7d"
GENUINE = 'user_account_uuid=~"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'
TOK = "claude_code_token_usage_tokens_total"
COST = "claude_code_cost_usage_USD_total"


def q(promql):
    url = BASE + "?" + urllib.parse.urlencode({"query": promql})
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return json.load(r)["data"]["result"]
    except urllib.error.HTTPError as e:
        sys.exit("PromQL rejected (HTTP %s): %s\n  %s" %
                 (e.code, e.read().decode("utf8", "replace")[:300], promql))
    except Exception as e:
        sys.exit("Cannot reach Prometheus at %s : %s" % (BASE, e))


def val(promql):
    r = q(promql)
    return float(r[0]["value"][1]) if r else 0.0


def keyed(metric, by):
    out = {}
    for r in q("sum by (%s) (increase(%s{%s}[%s]))" % (by, metric, GENUINE, WINDOW)):
        m = r["metric"]
        out[tuple(m.get(k, "") for k in by.split(", "))] = float(r["value"][1])
    return out


def main():
    print("=== Fleet usage: account x device x os_user (last %s) ===\n" % WINDOW)
    by = "user_email, device_name, os_user"
    toks, cost = keyed(TOK, by), keyed(COST, by)
    keys = sorted(set(toks) | set(cost), key=lambda k: -cost.get(k, 0))
    if not keys:
        print("  (no genuine usage in window)")
    else:
        f = "  %-28s %-22s %-12s %14s %12s"
        print(f % ("account", "device", "os_user", "tokens", "cost USD"))
        print("  " + "-" * 92)
        for k in keys:
            em, dv, ou = k
            print(f % (em, dv or "(unset)", ou or "(unset)",
                       "{:,.0f}".format(toks.get(k, 0)), "${:,.4f}".format(cost.get(k, 0))))

    print("\n=== integrity checks ===")
    # 1. fan-out: an account seen on >1 device
    fan = q("count by (user_email) (count by (user_email, device_name) "
            "(increase(%s{%s, device_name=~\".+\"}[%s]) > 0))" % (TOK, GENUINE, WINDOW))
    multi = [(r["metric"]["user_email"], int(float(r["value"][1]))) for r in fan if float(r["value"][1]) > 1]
    if multi:
        print("  [INFO] accounts on >1 device (review if unexpected — could be legit or shared creds):")
        for em, n in multi:
            print("     - %-30s %d devices" % (em, n))
    else:
        print("  [OK]   no account spans multiple devices")

    # 2. genuine series with no device_name (un-joined / pre-join)
    nodev = val("count((%s{%s}) unless (%s{%s, device_name=~\".+\"}))" % (TOK, GENUINE, TOK, GENUINE))
    print("  [%s] series missing device_name (un-joined devices): %d"
          % ("WARN" if nodev else "OK  ", int(nodev)))

    # 3. reconciliation: grand total == sum of per-account totals
    grand = val("sum(increase(%s{%s}[%s]))" % (TOK, GENUINE, WINDOW))
    byacct = sum(v for v in keyed(TOK, "user_account_uuid").values())
    tol = max(1.0, grand * 1e-6)
    print("  [%s] reconciliation: grand=%.1f  sum-by-account=%.1f  (diff %.4f, tol %.4f)"
          % ("OK  " if abs(grand - byacct) <= tol else "FAIL", grand, byacct, abs(grand - byacct), tol))


if __name__ == "__main__":
    main()
