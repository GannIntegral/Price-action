#!/usr/bin/env python3
"""Rank MT5 optimization results (with a forward period) across several symbols.

Export from the MT5 Strategy Tester (right-click the table -> Export to XML) into one folder:
    <SYMBOL>_opt.xml   the "Optimization Results" tab (the period the optimizer tuned on)
    <SYMBOL>_fwd.xml   the "Forward Results" tab   (the last part it never tuned on)

Usage:
    python3 tools/opt_report.py              # reads ~/opt_results
    python3 tools/opt_report.py <folder>

It prints, for every combination of optimized inputs (e.g. MA period x min angle):
  - a heat map per symbol of the forward profit factor, to see whether good settings form a plateau
    (neighbours also good) or are isolated spikes (luck)
  - a ranking by the WORST forward profit factor across symbols, so a setting only ranks high
    when it held up on every symbol in the period it was not tuned on
Only the Python standard library is used.
"""
import glob
import os
import sys
import xml.etree.ElementTree as ET

NS = "{urn:schemas-microsoft-com:office:spreadsheet}"
MIN_TRADES = 20        # forward results with fewer trades are marked unreliable
BASELINE = {"InpMAPeriod": "200", "InpMinAngle": "0"}


def read_sheet(path):
    """Rows of the first worksheet as a list of dicts keyed by the header row."""
    root = ET.parse(path).getroot()
    deposit = None
    for el in root.iter():
        if el.tag.endswith("Deposit") and el.text:
            try:
                deposit = float(el.text.split()[0])
            except ValueError:
                pass
    table = root.find(".//%sWorksheet/%sTable" % (NS, NS))
    rows = []
    for row in table.findall(NS + "Row"):
        values, col = [], 0
        for cell in row.findall(NS + "Cell"):
            idx = cell.get(NS + "Index")
            if idx:                                   # sparse row: jump to column
                while col < int(idx) - 1:
                    values.append("")
                    col += 1
            data = cell.find(NS + "Data")
            values.append(data.text if data is not None and data.text is not None else "")
            col += 1
        rows.append(values)
    if not rows:
        return [], deposit
    header = rows[0]
    return [dict(zip(header, r)) for r in rows[1:] if any(r)], deposit


def num(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def norm(v):
    """'200' and '200.0' are the same input value."""
    f = num(v, None)
    if f is None:
        return v
    return str(int(f)) if f == int(f) else ("%g" % f)


def load(folder):
    data = {}          # symbol -> {"opt": {key: row}, "fwd": {key: row}}
    inputs = None
    deposit = None
    for kind in ("opt", "fwd"):
        for path in sorted(glob.glob(os.path.join(folder, "*_%s.xml" % kind))):
            sym = os.path.basename(path)[: -len("_%s.xml" % kind)]
            rows, dep = read_sheet(path)
            deposit = deposit or dep
            if not rows:
                continue
            cols = [c for c in rows[0] if c.startswith("Inp")]
            inputs = inputs or cols
            data.setdefault(sym, {"opt": {}, "fwd": {}})
            for r in rows:
                key = tuple(norm(r.get(c, "")) for c in inputs)
                data[sym][kind][key] = r
    return data, inputs or [], deposit


def pf_cell(row):
    if row is None:
        return "   -  "
    pf = num(row.get("Profit Factor"))
    trades = int(num(row.get("Trades")))
    return "%5.2f%s" % (pf, "*" if trades < MIN_TRADES else " ")


def print_heatmaps(data, inputs, symbols):
    if len(inputs) != 2:
        return
    a, b = inputs
    keys = set(k for s in symbols for kind in ("opt", "fwd") for k in data[s][kind])
    rows_v = sorted({k[0] for k in keys}, key=lambda v: num(v, 0))
    cols_v = sorted({k[1] for k in keys}, key=lambda v: num(v, 0))
    for sym in symbols:
        for kind, label in (("opt", "tuning period"), ("fwd", "FORWARD period")):
            if not data[sym][kind]:
                continue
            print("\n== %s - profit factor, %s (rows %s, columns %s) ==" % (sym, label, a, b))
            print("%10s" % a + "".join("%9s" % c for c in cols_v))
            for rv in rows_v:
                print("%10s" % rv + "".join("%9s" % pf_cell(data[sym][kind].get((rv, cv))) for cv in cols_v))


def main():
    folder = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/opt_results")
    data, inputs, deposit = load(folder)
    if not data:
        sys.exit("No <SYMBOL>_opt.xml / <SYMBOL>_fwd.xml files in %s" % folder)
    symbols = sorted(data)
    print("Folder: %s" % folder)
    print("Symbols: %s   optimized inputs: %s   deposit: %s" % (", ".join(symbols), ", ".join(inputs), deposit))
    missing = [s for s in symbols if not data[s]["fwd"]]
    if missing:
        print("No forward file for: %s (ranking uses forward results only)" % ", ".join(missing))

    print_heatmaps(data, inputs, symbols)

    #--- ranking by the worst forward profit factor across symbols
    fsyms = [s for s in symbols if data[s]["fwd"]]
    keys = set(k for s in fsyms for k in data[s]["fwd"])
    ranked = []
    for k in keys:
        fwd = [data[s]["fwd"].get(k) for s in fsyms]
        if any(r is None for r in fwd):
            continue
        pfs = [num(r.get("Profit Factor")) for r in fwd]
        profit = sum(num(r.get("Profit")) for r in fwd)
        trades = sum(int(num(r.get("Trades"))) for r in fwd)
        ranked.append((min(pfs), sum(pfs) / len(pfs), profit, trades, k))
    ranked.sort(key=lambda x: (x[0], x[1]), reverse=True)

    print("\n== Ranking by the WORST forward profit factor across %s ==" % ", ".join(fsyms))
    head = "%-24s" % " / ".join(i.replace("Inp", "") for i in inputs)
    head += "".join("%16s" % ("%s opt>fwd" % s[:7]) for s in fsyms)
    head += "%9s%9s%12s%8s" % ("min PF", "mean PF", "fwd profit", "trades")
    print(head)
    for mn, mean, profit, trades, k in ranked[:25]:
        label = " / ".join(k)
        if all(BASELINE.get(i) == v for i, v in zip(inputs, k)):
            label += "  <- now"
        line = "%-24s" % label
        for s in fsyms:
            line += "%16s" % ("%s>%s" % (pf_cell(data[s]["opt"].get(k)).strip(), pf_cell(data[s]["fwd"].get(k)).strip()))
        line += "%9.2f%9.2f%12.0f%8d" % (mn, mean, profit, trades)
        print(line)

    base = [r for r in ranked if all(BASELINE.get(i) == v for i, v in zip(inputs, r[4]))]
    if base:
        pos = ranked.index(base[0]) + 1
        print("\nCurrent setting (%s) ranks #%d of %d" % (
            ", ".join("%s=%s" % (i, v) for i, v in zip(inputs, base[0][4])), pos, len(ranked)))
    print("* = fewer than %d forward trades (unreliable).  opt>fwd = profit factor in the tuning period > forward period."
          % MIN_TRADES)
    print("Prefer a setting whose neighbours in the heat maps are also good, over an isolated best cell.")


if __name__ == "__main__":
    main()
