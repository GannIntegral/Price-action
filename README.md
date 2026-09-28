# Price-action

MetaTrader 5 Expert Advisor: **MA200 trend following + Rally-Base-Rally (RBR) demand zone buys and Drop-Base-Drop (DBD) supply zone sells**.

File: [`Experts/RBR_MA200_EA.mq5`](Experts/RBR_MA200_EA.mq5)
Log analysis: [`tools/analyze_logs.py`](tools/analyze_logs.py)

## Strategy

| Step | BUY (Rally-Base-Rally) | SELL (Drop-Base-Drop) |
|---|---|---|
| Trend filter | MA 200 on each enabled timeframe (M20 by default, SMA on close) | same |
| **PHASE 1** | A candle closes above the MA after the previous candle closed below it | A candle closes below the MA after the previous candle closed above it |
| **PHASE 2** | After the cross, three closed candles form **Rally → Base → Rally**: bullish, bearish, bullish, each rally longer than the base | After the cross, three closed candles form **Drop → Base → Drop**: bearish, bullish, bearish, each drop longer than the base |
| Size filter | Both rallies bigger than the average candle size of the 20 candles before the pattern | Both drops bigger than the average candle size of the 20 candles before the pattern |
| Zone | Base candle body: open (top) to close (bottom) | Base candle body: close (top) to open (bottom) |
| Entry | Buy limit at the zone, only if price has not already come back to it | Sell limit at the zone, only if price has not already come back to it |
| Stop loss | Below the base candle's low | Above the base candle's high |
| Take profit | 1:5 risk:reward | 1:5 risk:reward |

Every enabled timeframe runs the strategy on its own, and buy and sell setups are tracked separately. After a limit order is placed, that side goes back to waiting for a new PHASE 1 cross. If a candle closes back across the MA before PHASE 2, that side's PHASE 1 is reset. Both behaviours can be changed in the inputs.

## Install

1. In MT5: **File → Open Data Folder** → `MQL5/Experts/`.
2. Copy `RBR_MA200_EA.mq5` there.
3. Open it in MetaEditor and press **F7** (Compile).
4. Attach the EA to any chart of the symbol. It reads signals from the timeframes enabled in the inputs (M20 by default), whatever timeframe the chart shows.
5. Enable **Algo Trading**.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| Use ALL timeframes | false | Run on all 21 MT5 timeframes (M1 … MN1), ignoring the list |
| M1 … MN1 | only M20 on | Tick each timeframe to trade. Each one has its own phases, orders and magic number |
| MA period / method / price | 200 / SMA / Close | Trend MA |
| Trade direction | Both | Both, buy only (RBR) or sell only (DBD) |
| Candle length measured by | Body | Body (open–close) or full range (high–low) for the rally/drop > base comparison |
| Both rallies/drops longer than base | true | `false` = only one needs to be longer |
| Cross candle may be the first rally/drop | true | Allow the cross candle to be the first leg |
| Rallies/drops above average candle size | true | Turn the sideways-market filter on or off |
| Average period | 20 | Number of candles before the pattern used for the average |
| Average multiplier | 1.0 | Rally/drop must be bigger than average × this (e.g. 1.5 = 50% bigger) |
| Reset PHASE 1 on close across MA | true | Start over if price closes back across the MA (below for buys, above for sells) |
| Limit order price | Near edge | Near edge (base open), middle, or far edge (base close) |
| Reward:Risk | 5.0 | TP = entry ± 5 × distance from entry to SL |
| SL buffer (points) | 0 | Extra distance below the base low (buys) / above the base high (sells) |
| Cancel pending after N bars | 0 | 0 = never expire |
| Cancel pending on close across MA | true | Delete an unfilled buy limit on a close below the MA, or a sell limit on a close above it |
| Lot mode | Fixed | Fixed lot or % of balance risked |
| Fixed lots / Risk % | 0.10 / 1.0 | |
| Base magic number | 20020 | Each timeframe uses base + its index: M1 = 20020, M20 = 20029, H1 = 20031, D1 = 20038, MN1 = 20040 |
| One trade at a time | true | Skip new setups while a position or pending order is open |
| One trade at a time applies | Per timeframe | Per timeframe (each timeframe can hold one trade) or across all timeframes |
| Draw zones of all timeframes | false | `false` = only draw zones of the chart's timeframe |
| Log trades / setups / candles | true | Which CSV files to write (see below) |
| Write to Common\Files | true | Put logs in `Terminal/Common/Files` so tester and live runs land in the same place |
| Log file name prefix | RBR | |

The chart shows the phases of every enabled timeframe, the closed trade count and the last event in the top-left corner, and draws RBR zones as blue rectangles and DBD zones as red rectangles.

## CSV logs

Each run writes a new set of files named `RBR_<symbol>_[TEST_]<date>_<time>_<id>_*.csv` to
`Terminal/Common/Files/RBR_MA200_logs/`. With Wine that is
`~/.wine/drive_c/users/<you>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/RBR_MA200_logs/`.

| File | One row per | Columns |
|---|---|---|
| `_settings.csv` | input | All inputs of the run, so runs with different settings can be compared |
| `_trades.csv` | limit order | Timeframe, direction, zone, entry, SL, TP, target RR, lots, money at risk, status (CLOSED / CANCELLED / OPEN_AT_END / PENDING_AT_END), reason (TP, SL, CLOSE_BELOW_MA, EXPIRED…), fill and close time/price, bars to fill, bars held, profit, commission, swap, net, **R multiple**, **MFE R** (best move in its favour, in R), **MAE R** (worst move against it), balance, equity |
| `_setups.csv` | detected RBR/DBD | Leg and base sizes, average size, zone, entry/SL/TP, and what happened: PLACED, or why it was skipped (SKIP_AVG_SIZE, SKIP_TRADE_OPEN, SKIP_PRICE_IN_ZONE…) |
| `_candles.csv` | closed candle per timeframe | OHLC, MA, above/below MA, buy and sell phase, balance, equity, open/pending trades on that timeframe, floating P/L, open trade's entry, SL, TP, current R, MFE/MAE, and the events of that candle |

## Analysing the logs

```bash
python3 tools/analyze_logs.py                  # newest run in the default Wine log folder
python3 tools/analyze_logs.py path/to/folder   # newest run in a folder
python3 tools/analyze_logs.py path/to/RBR_..._trades.csv
```

It prints results per timeframe, per direction and per timeframe + direction (trades, win %, net, average R,
profit factor, longest losing streak), the limit order fill rate, the reasons setups were skipped, the max
equity drawdown, and a **Reward:Risk table**: the expected R per trade if TP had been 1:1, 1:1.5, 1:2 … using
each trade's MFE. A trade counts as a win at 1:X if price moved X × risk in its favour before the stop was hit.

To find the best timeframes and RR:

1. In the Strategy Tester, set **Use ALL timeframes = true** (or tick the ones to compare) and use
   **Every tick based on real ticks**, so MFE/MAE are measured tick by tick.
2. Set **Reward:Risk** high, e.g. 10. Trades that hit TP stop being measured, so the table can only show
   targets up to the RR you tested.
3. Run `analyze_logs.py`. Drop timeframes with negative average R, then pick the RR with the best expectancy.

With all timeframes on, the M1 candle log can reach tens of MB per year of data; untick **Log candles** if you
don't need it.

With **One trade at a time applies = per timeframe**, each timeframe trades as if it ran alone, so the
per-timeframe results are not affected by the other timeframes.

## Notes

- Several timeframes and both directions need a **hedging** account. On a netting account, trades on the
  same symbol merge into one position (the EA prints a warning).
- The magic numbers changed in v2.00: M20 now uses 20029 (base 20020 + 9). Orders left by the old version are not managed.
- The EA starts in PHASE 1 when attached. It does not rebuild its state from history after a restart, and orders placed before a restart are not logged.
- Test it in the Strategy Tester (visual mode) and on a demo account before going live.
