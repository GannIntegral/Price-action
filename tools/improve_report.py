#!/usr/bin/env python3
"""Look for improvements to the MA rejection strategy in existing CSV logs (no new tester runs needed).

Usage:
    python3 tools/improve_report.py                      # newest run in the default Wine log folder
    python3 tools/improve_report.py A_trades.csv B_trades.csv ...   # compare several runs (e.g. symbols)

For each idea it shows the average R per trade in every group, so you can see whether a filter or
exit rule would have helped:
  - stability: first half vs second half of the run
  - candles waited between PHASE 1 and PHASE 2
  - stop size (quartiles of the stop distance)
  - cross candle body vs the average body, and body % of the candle range
  - break-even stop: move SL to entry once the trade is +X R (estimated from the candle log)

With several runs, a change is only worth making if it helps in (almost) every run: a rule that only
helps one symbol is most likely fitted to noise.
"""
import csv
import glob
import os
import sys
from collections import defaultdict

DEFAULT_DIRS = [
    "~/.wine/drive_c/users/*/AppData/Roaming/MetaQuotes/Terminal/Common/Files/RBR_MA200_logs",
    "~/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Files/RBR_MA200_logs",
]
BE_LEVELS = [1.0, 1.5, 2.0, 3.0]


def newest_trades_file():
    files = [f for pat in DEFAULT_DIRS for d in glob.glob(os.path.expanduser(pat))
             for f in glob.glob(os.path.join(d, "*_trades.csv"))]
    if not files:
        sys.exit("No *_trades.csv found. Pass the trades file(s) as arguments.")
    return max(files, key=os.path.getmtime)


def read_csv(path):
    if not os.path.isfile(path):
        return []
    with open(path, newline="", encoding="latin-1") as f:
        return list(csv.DictReader(f))


def num(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def run_name(path):
    name = os.path.basename(path)[: -len("_trades.csv")]
    parts = name.split("_TEST_") if "_TEST_" in name else name.rsplit("_", 3)
    return parts[0].replace("RBR_", "") if parts else name


def load_run(path):
    base = path[: -len("_trades.csv")]
    trades = [t for t in read_csv(path) if t.get("status") == "CLOSED" and t.get("r_multiple") not in (None, "")]
    for t in trades:
        t["_r"] = num(t["r_multiple"])

    #--- PHASE 1 rows of the setups log give the cross candle's body data
    phase1 = {}
    for s in read_csv(base + "_setups.csv"):
        if s.get("result") == "PHASE1":
            phase1[(s.get("timeframe"), s.get("cross_time"))] = s
    for t in trades:
        s = phase1.get((t.get("timeframe"), t.get("cross_time") or t.get("base_time")))
        if s:
            avg = num(s.get("avg_body_points"))
            t["_body_x"] = num(s.get("body_points")) / avg if avg > 0 else None
            t["_body_pct"] = num(s.get("body_pct"), None)
        else:
            t["_body_x"] = t["_body_pct"] = None

    #--- candle-by-candle path of every trade (R at each candle close, MFE so far)
    paths = defaultdict(list)
    for c in read_csv(base + "_candles.csv"):
        if c.get("trade_ticket"):
            paths[c["trade_ticket"]].append((num(c.get("trade_r_now")), num(c.get("trade_mfe_r"))))
    return {"name": run_name(path), "trades": trades, "paths": paths}


def avg_r(rows):
    return sum(t["_r"] for t in rows) / len(rows) if rows else None


def fmt(rows):
    a = avg_r(rows)
    return "%4d  %+.2f" % (len(rows), a) if a is not None else "   -      "


def print_section(title, runs, bucket_fn, order):
    print("\n== %s ==" % title)
    groups = []
    for run in runs:
        g = defaultdict(list)
        for t in run["trades"]:
            b = bucket_fn(t, run)
            if b is not None:
                g[b].append(t)
        groups.append(g)
    names = [r["name"] for r in runs] + (["ALL"] if len(runs) > 1 else [])
    width = 11
    print("%-16s" % "group" + "".join("%*s" % (width + 2, n[:width]) for n in names) + "   (trades  avg R)")
    for key in order:
        cells = [g.get(key, []) for g in groups]
        if not any(cells):
            continue
        if len(runs) > 1:
            cells.append([t for c in cells for t in c])
        print("%-16s" % key + "".join("%*s" % (width + 2, fmt(c)) for c in cells))


def bars_bucket(t, run):
    b = int(num(t.get("bars_waited"), -1))
    if b < 0:
        return None
    for limit, name in ((1, "1"), (3, "2-3"), (6, "4-6"), (15, "7-15")):
        if b <= limit:
            return name
    return "16+"


def half_bucket(t, run):
    times = sorted(x.get("close_time", "") for x in run["trades"])
    mid = times[len(times) // 2] if times else ""
    return "1st half" if t.get("close_time", "") < mid else "2nd half"


def stop_bucket(t, run):
    pts = sorted(num(x.get("risk_points")) for x in run["trades"])
    if len(pts) < 4:
        return None
    q = [pts[len(pts) * k // 4] for k in (1, 2, 3)]
    v = num(t.get("risk_points"))
    names = ["Q1 smallest", "Q2", "Q3", "Q4 largest"]
    for i, limit in enumerate(q):
        if v < limit:
            return names[i]
    return names[3]


def body_x_bucket(t, run):
    x = t.get("_body_x")
    if x is None:
        return None
    for limit, name in ((1.5, "1.0-1.5x"), (2.0, "1.5-2x"), (3.0, "2-3x")):
        if x < limit:
            return name
    return "3x+"


def body_pct_bucket(t, run):
    p = t.get("_body_pct")
    if p is None:
        return None
    for limit, name in ((60, "50-60%"), (70, "60-70%"), (85, "70-85%")):
        if p < limit:
            return name
    return "85-100%"


def break_even_r(t, path, level):
    """R of the trade if SL had moved to entry once it reached +level R (candle-close estimate)."""
    r, mfe, reason = t["_r"], num(t.get("mfe_r")), t.get("reason")
    if mfe < level:
        return r                      # never reached the level: unchanged
    if reason == "SL":
        return 0.0                    # went +level then back to the stop: must have passed entry
    if reason == "TP":
        armed = False
        for r_now, mfe_now in path:
            if mfe_now >= level:
                armed = True
            elif not armed:
                continue
            if armed and r_now <= 0.0:
                return 0.0            # closed back at/below entry after the level: break-even hit
        return r
    return r


def print_break_even(runs):
    print("\n== Break-even stop: SL moved to entry once the trade reaches +X R ==")
    names = [r["name"] for r in runs] + (["ALL"] if len(runs) > 1 else [])
    width = 11
    print("%-16s" % "rule" + "".join("%*s" % (width + 2, n[:width]) for n in names) + "   (avg R per trade)")
    rows = [("no break-even", None)] + [("BE at +%gR" % lv, lv) for lv in BE_LEVELS]
    for label, lv in rows:
        cells, total, count = [], 0.0, 0
        for run in runs:
            rs = [t["_r"] if lv is None else break_even_r(t, run["paths"].get(t["ticket"], []), lv)
                  for t in run["trades"]]
            a = sum(rs) / len(rs) if rs else None
            cells.append("%+.2f" % a if a is not None else "-")
            total += sum(rs)
            count += len(rs)
        if len(runs) > 1:
            cells.append("%+.2f" % (total / count) if count else "-")
        print("%-16s" % label + "".join("%*s" % (width + 2, c) for c in cells))
    if not any(run["paths"] for run in runs):
        print("   (no candle log: TP trades are assumed never to come back to entry - optimistic)")
    else:
        print("   Estimate from candle closes: a wick back to entry is not seen, so real results are a little lower.")


def main():
    files = sys.argv[1:] or [newest_trades_file()]
    runs = [load_run(f) for f in files]
    for run, f in zip(runs, files):
        print("Run: %-12s %4d closed trades   %s" % (run["name"], len(run["trades"]), os.path.basename(f)))

    print_section("Stability: first vs second half of the run", runs, half_bucket, ["1st half", "2nd half"])
    print_section("Candles waited from PHASE 1 to PHASE 2", runs, bars_bucket, ["1", "2-3", "4-6", "7-15", "16+"])
    print_section("Stop size (quartiles of stop distance per run)", runs, stop_bucket,
                  ["Q1 smallest", "Q2", "Q3", "Q4 largest"])
    print_section("Cross candle body vs average body", runs, body_x_bucket, ["1.0-1.5x", "1.5-2x", "2-3x", "3x+"])
    print_section("Cross candle body % of its range", runs, body_pct_bucket, ["50-60%", "60-70%", "70-85%", "85-100%"])
    print_break_even(runs)
    print("\nA group is worth filtering out only if it is clearly negative in every run, with enough trades.")


if __name__ == "__main__":
    main()
