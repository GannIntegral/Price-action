# Price-action

MetaTrader 5 Expert Advisor: **MA200 trend following + Rally-Base-Rally (RBR) demand zone buys and Drop-Base-Drop (DBD) supply zone sells**.

File: [`Experts/RBR_MA200_EA.mq5`](Experts/RBR_MA200_EA.mq5)

## Strategy

| Step | BUY (Rally-Base-Rally) | SELL (Drop-Base-Drop) |
|---|---|---|
| Trend filter | MA 200 on the M20 timeframe (SMA on close by default) | same |
| **PHASE 1** | A candle closes above the MA after the previous candle closed below it | A candle closes below the MA after the previous candle closed above it |
| **PHASE 2** | After the cross, three closed candles form **Rally → Base → Rally**: bullish, bearish, bullish, each rally longer than the base | After the cross, three closed candles form **Drop → Base → Drop**: bearish, bullish, bearish, each drop longer than the base |
| Size filter | Both rallies bigger than the average candle size of the 20 candles before the pattern | Both drops bigger than the average candle size of the 20 candles before the pattern |
| Zone | Base candle body: open (top) to close (bottom) | Base candle body: close (top) to open (bottom) |
| Entry | Buy limit at the zone, only if price has not already come back to it | Sell limit at the zone, only if price has not already come back to it |
| Stop loss | Below the base candle's low | Above the base candle's high |
| Take profit | 1:5 risk:reward | 1:5 risk:reward |

Buy and sell setups are tracked separately. After a limit order is placed, that side goes back to waiting for a new PHASE 1 cross. If a candle closes back across the MA before PHASE 2, that side's PHASE 1 is reset. Both behaviours can be changed in the inputs.

## Install

1. In MT5: **File → Open Data Folder** → `MQL5/Experts/`.
2. Copy `RBR_MA200_EA.mq5` there.
3. Open it in MetaEditor and press **F7** (Compile).
4. Attach the EA to any chart of the symbol. It reads signals from the timeframe set in the inputs (M20 by default), whatever timeframe the chart shows.
5. Enable **Algo Trading**.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| Signal timeframe | M20 | Timeframe for the MA and candle pattern |
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
| Magic number | 20020 | |
| One trade at a time | true | Skip new setups while a position or pending order is open |

The chart shows the current phase and last event in the top-left corner, and draws RBR zones as blue rectangles and DBD zones as red rectangles.

## Notes

- The EA starts in PHASE 1 when attached. It does not rebuild its state from history after a restart.
- Test it in the Strategy Tester (visual mode) and on a demo account before going live.
