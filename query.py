#!/usr/bin/env python3
"""Per-account Claude Code usage from Prometheus.

Staleness-safe: uses increase() over a window (NOT an instant sum of cumulative
counters, which under-reports as short-lived per-session series age out of the
collector's metric_expiration / Prometheus' lookback-delta windows).

Keyed on the IMMUTABLE user_account_uuid (survives email/display renames);
user_email is shown for readability only. A genuine-UUID filter drops the
synthetic probe pollution left in the TSDB by design/test runs.

Usage:
  python3 query.py            # default window 30d
  python3 query.py 7d         # custom window (Prometheus duration: 30m,6h,7d,...)
  python3 query.py 24h --by-device   # also break down per device_name/os_user
"""
import sys, json, urllib.parse, urllib.request

BASE = "http://localhost:9090/api/v1/query"

args = [a for a in sys.argv[1:] if not a.startswith("-")]
flags = [a for a in sys.argv[1:] if a.startswith("-")]
WINDOW = args[0] if args else "30d"
BY_DEVICE = "--by-device" in flags

# Genuine Claude accounts carry a real UUID; this matcher excludes synthetic/probe
# series (fake or absent UUID) so totals are not inflated by test pollution.
GENUINE = 'user_account_uuid=~"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'


def q(promql):
    url = BASE + "?" + urllib.parse.urlencode({"query": promql})
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return json.load(r)["data"]["result"]
    except urllib.error.HTTPError as e:
        sys.exit("Prometheus rejected query (HTTP %s): %s\n  query: %s" %
                 (e.code, e.read().decode("utf8", "replace")[:300], promql))
    except Exception as e:
        sys.exit("Cannot reach Prometheus at %s : %s" % (BASE, e))


def rollup(metric, by, extra=""):
    sel = GENUINE + ((", " + extra) if extra else "")
    promql = "sum by (%s) (increase(%s{%s}[%s]))" % (by, metric, sel, WINDOW)
    out = {}
    for r in q(promql):
        m = r["metric"]
        out[tuple(m.get(k, "") for k in by.split(", "))] = float(r["value"][1])
    return out


def main():
    print("=== Per-account Claude Code usage (last %s, staleness-safe) ===\n" % WINDOW)
    by = "user_account_uuid, user_email"
    toks = rollup("claude_code_token_usage_tokens_total", by)
    outp = rollup("claude_code_token_usage_tokens_total", by, 'type="output"')
    cost = rollup("claude_code_cost_usage_USD_total", by)

    keys = sorted(set(toks) | set(cost) | set(outp), key=lambda k: -cost.get(k, 0))
    if not keys:
        print("  (no genuine account usage in the last %s)" % WINDOW)
        return
    fmt = "  %-34s %16s %16s %13s"
    print(fmt % ("account", "total tokens", "output tokens", "cost USD"))
    print("  " + "-" * 80)
    for k in keys:
        _uuid, email = k
        print(fmt % (email, "{:,.0f}".format(toks.get(k, 0)),
                     "{:,.0f}".format(outp.get(k, 0)), "${:,.4f}".format(cost.get(k, 0))))
    print("  " + "-" * 80)
    print(fmt % ("TOTAL (%d accounts)" % len(keys),
                 "{:,.0f}".format(sum(toks.values())),
                 "{:,.0f}".format(sum(outp.values())),
                 "${:,.4f}".format(sum(cost.values()))))

    if BY_DEVICE:
        print("\n=== Per account x device x os_user (last %s) ===\n" % WINDOW)
        byd = "user_email, device_name, os_user"
        td = rollup("claude_code_token_usage_tokens_total", byd)
        cd = rollup("claude_code_cost_usage_USD_total", byd)
        ks = sorted(set(td) | set(cd), key=lambda k: -cd.get(k, 0))
        if not ks:
            print("  (no device-tagged series yet — devices set OTEL_RESOURCE_ATTRIBUTES on join)")
        else:
            f2 = "  %-26s %-20s %-12s %14s %12s"
            print(f2 % ("account", "device", "os_user", "tokens", "cost USD"))
            print("  " + "-" * 86)
            for k in ks:
                email, dev, osu = k
                print(f2 % (email, dev or "(unset)", osu or "(unset)",
                            "{:,.0f}".format(td.get(k, 0)), "${:,.4f}".format(cd.get(k, 0))))


if __name__ == "__main__":
    main()
