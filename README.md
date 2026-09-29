# Price-action

MetaTrader 5 Expert Advisor: **MA200 rejection**. A strong candle that crosses up through a falling MA200 is sold
when a later candle closes back below it; a strong candle that crosses down through a rising MA200 is bought when a
later candle closes back above it.

File: [`Experts/RBR_MA200_EA.mq5`](Experts/RBR_MA200_EA.mq5)
Log analysis: [`tools/analyze_logs.py`](tools/analyze_logs.py)

## Strategy (v3.1)

| Step | SELL | BUY |
|---|---|---|
| Trend | MA200 heading **down** (MA angle below 0°, or steeper than *Min MA angle*) | MA200 heading **up** |
| **PHASE 1** | A **cross candle**: opens below the MA and closes above it | A cross candle: opens above the MA and closes below it |
| Significant body | Body bigger than the average body of the 20 candles before it, and at least 50% of the candle's range | Same |
| **PHASE 2** | A later candle **closes below the cross candle's low** | A later candle **closes above the cross candle's high** |
| Entry | **Sell at market** on the open of the next candle | **Buy at market** on the open of the next candle |
| Stop loss | Above the cross candle high | Below the cross candle low |
| Take profit | Reward:Risk × risk (1:5 default) | Reward:Risk × risk |

While a cross candle waits for PHASE 2, a newer cross candle replaces it. A waiting setup is dropped if a candle
closes above the cross candle high (below its low for buys), or after 30 candles without PHASE 2. Every enabled
timeframe runs on its own, and sells and buys are tracked separately.

### MA angle

Degrees on a chart change when you zoom, so the EA measures the angle against volatility instead:

```
angle = atan( (MA now − MA N candles ago) / ATR ) in degrees       (N = 10, ATR 14 by default)
```

- **45°** = the MA moved **one ATR** in N candles. 0° = flat. Negative = falling, positive = rising.
- The same number means the same steepness on any symbol and timeframe.
- *Min MA angle* = 0 trades any slope in the right direction. Set e.g. 30 to trade only steep, strong trends.
- The current angle of every timeframe is shown on the chart, and the angle at PHASE 1 and at entry is written to
  the logs, so `analyze_logs.py` can show which angles are worth trading before you set a minimum.

## Install

1. In MT5: **File → Open Data Folder** → `MQL5/Experts/`.
2. Copy `RBR_MA200_EA.mq5` there.
3. Open it in MetaEditor and press **F7** (Compile).
4. Attach the EA to any chart of the symbol. It reads signals from the timeframes enabled in the inputs (M20 by
   default), whatever timeframe the chart shows.
5. Enable **Algo Trading**.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| Use ALL timeframes | false | Run on all 21 MT5 timeframes (M1 … MN1), ignoring the list |
| M1 … MN1 | only M20 on | Tick each timeframe to trade. Each one has its own setups, trades and magic number |
| MA period / method / price | 200 / SMA / Close | Trend MA |
| Trade direction | Both | Both, sell only or buy only |
| Angle measured over N candles | 10 | MA move is measured from N candles ago to the last closed candle |
| ATR period used to scale the angle | 14 | |
| Min MA angle | 0 | 0 = any slope in the trade direction. 45 = MA moved at least 1 ATR in N candles |
| Also require the min angle at entry | false | Check the angle again at PHASE 2 |
| Body bigger than the average body | true | Significant-body filter 1 |
| Average period / multiplier | 20 / 1.0 | Body must exceed the average body of the 20 candles before it × 1.0 |
| Min body % of range | 50 | Significant-body filter 2: body at least 50% of high–low (0 = off) |
| PHASE 2: candle must close beyond | Cross candle low (sell) / high (buy) | Or the cross candle's open (easier to trigger) |
| Give up after N candles | 30 | 0 = wait forever for PHASE 2 |
| Give up if a candle closes beyond the cross candle | true | Close above its high (sell) / below its low (buy) drops the setup |
| Reward:Risk | 5.0 | TP = entry ± 5 × (distance from entry to SL) |
| Stop loss behind | Cross candle high (sell) / low (buy) | Or the highest high / lowest low reached since the cross candle |
| SL buffer (points) | 0 | |
| Lot mode | Fixed | Fixed lot or % of balance risked |
| Fixed lots / Risk % | 0.10 / 1.0 | |
| Base magic number | 20020 | Each timeframe uses base + its index: M1 = 20020, M20 = 20029, H1 = 20031, D1 = 20038, MN1 = 20040 |
| One trade at a time | true | Skip a new entry while a position is open |
| One trade at a time applies | Per timeframe | Per timeframe or across all timeframes |
| Mark cross candles / all timeframes | true / false | Outlines each PHASE 1 cross candle (red = sell setup, blue = buy setup) |
| Log trades / setups / candles | true | Which CSV files to write (see below) |
| Write to Common\Files | true | Put logs in `Terminal/Common/Files` so tester and live runs land in the same place |

The chart shows the MA angle and the state of every enabled timeframe (waiting for a cross candle, or the level it
waits to be closed beyond), the closed trade count and the last event.

## CSV logs

Each run writes a new set of files named `RBR_<symbol>_[TEST_]<date>_<time>_<id>_*.csv` to
`Terminal/Common/Files/RBR_MA200_logs/`. With Wine that is
`~/.wine/drive_c/users/<you>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/RBR_MA200_logs/`.

| File | One row per | Columns |
|---|---|---|
| `_settings.csv` | input | All inputs of the run |
| `_trades.csv` | trade | Timeframe, direction, cross candle high/low, entry, SL, TP, target RR, lots, money at risk, exit reason (TP / SL / …), close time/price, bars held, profit, net, **R multiple**, **MFE R** / **MAE R** (best / worst move in R), balance, equity, **MA angle at PHASE 1 and at entry**, candles waited for PHASE 2 |
| `_setups.csv` | setup event | PHASE1, then OPENED / SKIP_… / FAILED_… (at PHASE 2), DROPPED_CLOSE_BEYOND_PATTERN, DROPPED_EXPIRED or REPLACED_BY_NEWER, with the cross candle's OHLC, break level, MA, angles, body size, average body and body % |
| `_candles.csv` | closed candle per timeframe | OHLC, MA, MA angle, buy/sell state, balance, equity, open trade's entry, SL, TP, current R, MFE/MAE, and the events of that candle |

## Analysing the logs

```bash
python3 tools/analyze_logs.py                  # newest run in the default Wine log folder
python3 tools/analyze_logs.py path/to/folder   # newest run in a folder
python3 tools/analyze_logs.py path/to/RBR_..._trades.csv
```

It prints results per timeframe, per direction, per timeframe + direction and **per MA angle** (0–10°, 10–20°,
20–30°, 30–45°, 45–60°, 60°+, at PHASE 1 and at entry): trades, win %, net, average R, profit factor and longest
losing streak. It also shows what happened to every setup, the max equity drawdown, and a **Reward:Risk table**:
the expected R per trade if TP had been 1:1, 1:1.5, 1:2 … using each trade's MFE.

To tune it:

1. Run the Strategy Tester with **Every tick based on real ticks**, **Fixed lots** and *Min MA angle* = 0.
2. In the angle table, find the angle above which average R turns clearly positive and set *Min MA angle* to it.
3. Use the Reward:Risk table to pick the target (run with a high RR, e.g. 10, to measure bigger targets).
4. Confirm the chosen settings on a different date range or symbol before trading live.

## Notes

- Several timeframes and both directions need a **hedging** account. On a netting account, trades on the
  same symbol merge into one position (the EA prints a warning).
- The EA starts with no setups when attached. It does not rebuild its state from history after a restart, and
  positions opened before a restart are not logged.
- Earlier strategies are in the git history: MA cross + RBR/DBD limit orders (v2.10) at `cc7bdf5`, RBR/DBD
  crossing the MA + base break (v3.00) at `4622e71`. E.g. `git show cc7bdf5:Experts/RBR_MA200_EA.mq5 > RBR_MA200_EA_v2.mq5`.
- Test it in the Strategy Tester (visual mode) and on a demo account before going live.
