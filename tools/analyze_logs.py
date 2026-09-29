#!/usr/bin/env python3
"""Summarise RBR_MA200_EA CSV logs: which timeframes work, and which Reward:Risk is best.

Usage:
    python3 tools/analyze_logs.py                     # newest *_trades.csv in the default log folder
    python3 tools/analyze_logs.py <folder>            # newest *_trades.csv in <folder>
    python3 tools/analyze_logs.py <file_trades.csv>   # a specific run

The matching *_setups.csv, *_candles.csv and *_settings.csv of the same run are
read too when they exist. Only the Python standard library is used.
"""
import csv
import glob
import os
import sys
from collections import Counter, defaultdict

DEFAULT_DIRS = [
    "~/.wine/drive_c/users/*/AppData/Roaming/MetaQuotes/Terminal/Common/Files/RBR_MA200_logs",
    "~/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Files/RBR_MA200_logs",
]
RR_GRID = [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10, 15, 20]
TF_ORDER = ["M1", "M2", "M3", "M4", "M5", "M6", "M10", "M12", "M15", "M20", "M30",
            "H1", "H2", "H3", "H4", "H6", "H8", "H12", "D1", "W1", "MN1"]


def find_trades_file(arg):
    if arg and os.path.isfile(arg):
        return arg
    dirs = [arg] if arg else [d for pat in DEFAULT_DIRS for d in glob.glob(os.path.expanduser(pat))]
    files = [f for d in dirs for f in glob.glob(os.path.join(d, "*_trades.csv"))]
    if not files:
        sys.exit("No *_trades.csv found. Pass the log folder or file as an argument.")
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


ANGLE_BUCKETS = ["0-10", "10-20", "20-30", "30-45", "45-60", "60+"]


def angle_bucket(a):
    for limit, name in ((10, "0-10"), (20, "10-20"), (30, "20-30"), (45, "30-45"), (60, "45-60")):
        if a < limit:
            return name
    return "60+"


def tf_key(tf):
    return TF_ORDER.index(tf) if tf in TF_ORDER else len(TF_ORDER)


def stats(rows):
    nets = [num(r["net_profit"]) for r in rows]
    rs = [num(r["r_multiple"]) for r in rows]
    wins = sum(1 for n in nets if n > 0)
    gross_win = sum(n for n in nets if n > 0)
    gross_loss = -sum(n for n in nets if n < 0)
    streak = worst = 0
    for n in nets:
        streak = streak + 1 if n <= 0 else 0
        worst = max(worst, streak)
    return {
        "n": len(rows),
        "win%": 100.0 * wins / len(rows) if rows else 0.0,
        "net": sum(nets),
        "avgR": sum(rs) / len(rs) if rs else 0.0,
        "PF": gross_win / gross_loss if gross_loss > 0 else float("inf") if gross_win > 0 else 0.0,
        "maxLossStreak": worst,
    }


def print_table(title, header, rows):
    print("\n" + title)
    widths = [max(len(str(x)) for x in col) for col in zip(header, *rows)] if rows else [len(h) for h in header]
    fmt = "  ".join("{:>%d}" % w for w in widths)
    print(fmt.format(*header))
    print(fmt.format(*["-" * w for w in widths]))
    for r in rows:
        print(fmt.format(*r))


def stats_rows(groups):
    out = []
    for key in groups:
        s = stats(groups[key])
        pf = "inf" if s["PF"] == float("inf") else "%.2f" % s["PF"]
        out.append([key, s["n"], "%.1f" % s["win%"], "%.2f" % s["net"], "%.2f" % s["avgR"], pf, s["maxLossStreak"]])
    return out


def simulate_rr(rows, rr):
    """Expectancy in R if TP had been rr x risk, using the max favourable move (MFE) of each trade.

    A trade 'wins' at rr when its MFE reached rr before it was stopped out.
    Only trades that ended at SL or TP are used (the MFE of other exits is incomplete).
    """
    total, n = 0.0, 0
    for r in rows:
        if r["reason"] not in ("SL", "TP") or r["mfe_r"] == "":
            continue
        n += 1
        total += rr if num(r["mfe_r"]) >= rr else -1.0
    return (total / n if n else None), n


def main():
    trades_path = find_trades_file(sys.argv[1] if len(sys.argv) > 1 else None)
    base = trades_path[: -len("_trades.csv")]
    print("Run:", os.path.basename(base))

    settings = {r["key"]: r["value"] for r in read_csv(base + "_settings.csv")}
    if settings.get("strategy") in ("MA_REJECTION_BASE_BREAK", "MA_REJECTION_CROSS_CANDLE"):
        print("Settings: RR %s | timeframes %s | min MA angle %s deg over %s candles | body > avg x%s, >= %s%% of range"
              " | break %s | SL %s | %s"
              % (settings.get("reward_risk"), settings.get("timeframes"), settings.get("min_angle"),
                 settings.get("angle_bars"), settings.get("avg_size_multiplier"), settings.get("min_body_percent"),
                 settings.get("break_level"), settings.get("sl_mode"), settings.get("direction")))
    elif settings:
        print("Settings: RR %s | entry %s | timeframes %s | avg filter %s x%s | %s"
              % (settings.get("reward_risk"), settings.get("entry_level"), settings.get("timeframes"),
                 settings.get("avg_size_filter"), settings.get("avg_size_multiplier"), settings.get("direction")))

    trades = read_csv(trades_path)
    closed = [r for r in trades if r["status"] == "CLOSED"]
    cancelled = [r for r in trades if r["status"] == "CANCELLED"]
    print("Orders: %d  closed trades: %d  cancelled: %d  still open/pending at end: %d"
          % (len(trades), len(closed), len(cancelled), len(trades) - len(closed) - len(cancelled)))
    if not closed:
        print("No closed trades yet.")

    by_tf = defaultdict(list)
    by_dir = defaultdict(list)
    by_tf_dir = defaultdict(list)
    for r in closed:
        by_tf[r["timeframe"]].append(r)
        by_dir[r["direction"]].append(r)
        by_tf_dir[r["timeframe"] + " " + r["direction"]].append(r)
    by_tf = dict(sorted(by_tf.items(), key=lambda kv: tf_key(kv[0])))
    by_tf_dir = dict(sorted(by_tf_dir.items(), key=lambda kv: (tf_key(kv[0].split()[0]), kv[0])))

    head = ["group", "trades", "win%", "net", "avgR", "PF", "maxLossStreak"]
    if closed:
        print_table("== Results by timeframe ==", head, stats_rows(by_tf) + stats_rows({"ALL": closed}))
        print_table("== Results by direction ==", head, stats_rows(by_dir))
        print_table("== Results by timeframe and direction ==", head, stats_rows(by_tf_dir))

        #--- MA angle (trend strength) at PHASE 1 and at entry: which angles are worth trading
        for col, title in (("angle_phase1", "MA angle at PHASE 1"), ("angle_entry", "MA angle at entry")):
            if not any(r.get(col) not in (None, "") for r in closed):
                continue
            by_ang = defaultdict(list)
            for r in closed:
                by_ang[angle_bucket(abs(num(r.get(col))))].append(r)
            rows = stats_rows(dict(sorted(by_ang.items(), key=lambda kv: ANGLE_BUCKETS.index(kv[0]))))
            print_table("== Results by %s (degrees, either direction) ==" % title, head, rows)

    #--- fill rate: how many limit orders were never reached
    fills = defaultdict(Counter)
    for r in trades:
        fills[r["timeframe"]]["filled" if r["fill_time"] else "not filled"] += 1
    rows = []
    has_unfilled = any(c["not filled"] for c in fills.values())
    for tf in sorted(fills, key=tf_key) if has_unfilled else []:
        c = fills[tf]
        total = c["filled"] + c["not filled"]
        rows.append([tf, total, c["filled"], "%.1f" % (100.0 * c["filled"] / total if total else 0)])
    if rows:
        print_table("== Limit order fill rate ==", ["timeframe", "orders", "filled", "fill%"], rows)

    reasons = Counter(r["reason"] for r in cancelled)
    if reasons:
        print("\nCancel reasons:", ", ".join("%s %d" % kv for kv in reasons.most_common()))

    #--- Reward:Risk simulation from MFE
    if closed:
        tested_rr = max(num(r["rr_target"]) for r in closed)
        grid = [x for x in RR_GRID if x <= tested_rr + 1e-9]
        rows = []
        for key, group in list(by_tf.items()) + [("ALL", closed)]:
            line = [key]
            best = None
            for rr in grid:
                exp, n = simulate_rr(group, rr)
                line.append("" if exp is None else "%+.2f" % exp)
                if exp is not None and (best is None or exp > best[1]):
                    best = (rr, exp)
            line.append("" if best is None else "%g" % best[0])
            rows.append(line)
        print_table("== Expectancy in R per trade for other Reward:Risk targets (from MFE) ==",
                    ["timeframe"] + ["1:%g" % x for x in grid] + ["best"], rows)
        print("   R per trade: +2.00 = on average each trade makes 2x its risk. Negative = losing.")
        print("   Only targets up to the tested RR (1:%g) can be measured, because a trade that hit TP"
              % tested_rr)
        print("   stops being tracked. To test bigger targets, run the tester with a larger Reward:Risk.")

    #--- setups: how many were filtered out and why
    setups = read_csv(base + "_setups.csv")
    if setups:
        res = defaultdict(Counter)
        for r in setups:
            res[r["timeframe"]][r["result"]] += 1
        keys = sorted({k for c in res.values() for k in c})
        rows = [[tf] + [res[tf][k] for k in keys] for tf in sorted(res, key=tf_key)]
        print_table("== Setups found and what happened to them ==", ["timeframe"] + keys, rows)

    #--- equity curve from the candle log
    candles = read_csv(base + "_candles.csv")
    if candles:
        points = sorted((r["log_time"], num(r["equity"])) for r in candles)
        peak, max_dd, max_dd_pct = None, 0.0, 0.0
        for _, eq in points:
            peak = eq if peak is None else max(peak, eq)
            dd = peak - eq
            if dd > max_dd:
                max_dd = dd
                max_dd_pct = 100.0 * dd / peak if peak else 0.0
        print("\nEquity: start %.2f  end %.2f  max drawdown %.2f (%.1f%%)"
              % (points[0][1], points[-1][1], max_dd, max_dd_pct))


if __name__ == "__main__":
    main()
