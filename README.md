# Price-action

MetaTrader 5 Expert Advisor: **MA200 trend following + Rally-Base-Rally (RBR) demand zone**.

File: [`Experts/RBR_MA200_EA.mq5`](Experts/RBR_MA200_EA.mq5)

## Strategy (bullish only)

| Step | Rule |
|---|---|
| Trend filter | MA 200 on the M20 timeframe (SMA on close by default) |
| **PHASE 1** | A candle closes above the MA after the previous candle closed below it (first close above, coming from below) |
| **PHASE 2** | After the cross, three closed candles form **Rally → Base → Rally**: bullish, bearish, bullish, and each rally is longer than the base |
| Size filter | Both rallies must be bigger than the average candle size of the 20 candles before the pattern, so small candles in sideways markets are ignored |
| Zone | Base candle open (top) to close (bottom) |
| Entry | Buy limit at the zone, placed only if price has not already come back to the zone |
| Stop loss | Below the base candle's low |
| Take profit | 1:5 risk:reward |

After a buy limit is placed, the EA goes back to waiting for a new PHASE 1 cross. If a candle closes back below the MA before PHASE 2, PHASE 1 is reset. Both behaviours can be changed in the inputs.

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
| Candle length measured by | Body | Body (open–close) or full range (high–low) for the rally > base comparison |
| Both rallies longer than base | true | `false` = only one rally needs to be longer |
| Cross candle may be the first rally | true | Allow the cross candle to be the first Rally |
| Rallies above average candle size | true | Turn the sideways-market filter on or off |
| Average period | 20 | Number of candles before the pattern used for the average |
| Average multiplier | 1.0 | Rally must be bigger than average × this (e.g. 1.5 = 50% bigger) |
| Reset PHASE 1 on close below MA | true | Start over if price closes back below the MA |
| Buy limit price | Zone top | Zone top (base open), middle, or bottom (base close) |
| Reward:Risk | 5.0 | TP = entry + 5 × (entry − SL) |
| SL buffer (points) | 0 | Extra distance below the base low |
| Cancel pending after N bars | 0 | 0 = never expire |
| Cancel pending on close below MA | true | Delete the unfilled buy limit if the trend breaks |
| Lot mode | Fixed | Fixed lot or % of balance risked |
| Fixed lots / Risk % | 0.10 / 1.0 | |
| Magic number | 20020 | |
| One trade at a time | true | Skip new setups while a position or pending order is open |

The chart shows the current phase and last event in the top-left corner, and draws each RBR zone as a blue rectangle.

## Notes

- The EA starts in PHASE 1 when attached. It does not rebuild its state from history after a restart.
- Test it in the Strategy Tester (visual mode) and on a demo account before going live.
