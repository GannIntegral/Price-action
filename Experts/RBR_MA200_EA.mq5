//+------------------------------------------------------------------+
//|                                                RBR_MA200_EA.mq5  |
//|  MA200 rejection + RBR/DBD base break, market entry.             |
//|                                                                  |
//|  SELL (MA200 heading down)                                       |
//|  PHASE 1: a Rally-Base-Rally approaches the falling MA from      |
//|           below and crosses it (last rally closes above the MA). |
//|  PHASE 2: a candle closes below the RBR base.                    |
//|  ENTRY  : sell at market on the open of the next candle,         |
//|           SL above the RBR high, TP = Reward:Risk (5 default).   |
//|                                                                  |
//|  BUY (MA200 heading up) - the mirror image                       |
//|  PHASE 1: a Drop-Base-Drop approaches the rising MA from above   |
//|           and crosses it (last drop closes below the MA).        |
//|  PHASE 2: a candle closes above the DBD base.                    |
//|  ENTRY  : buy at market on the open of the next candle,          |
//|           SL below the DBD low, TP = Reward:Risk.                |
//|                                                                  |
//|  MA angle: atan( MA move over N candles / ATR ) in degrees.      |
//|  45 deg = the MA moved one ATR in N candles, on any symbol and   |
//|  timeframe (chart degrees depend on zoom, this does not).        |
//|                                                                  |
//|  Every enabled timeframe runs its own copy of the strategy with  |
//|  its own magic number (base magic + timeframe index).            |
//+------------------------------------------------------------------+
#property copyright "GannIntegral"
#property version   "3.00"
#property description "MA200 rejection: RBR/DBD crossing the MA against its slope, market entry on the close beyond the base"

#include <Trade/Trade.mqh>

#define TF_COUNT    21
#define REC_PENDING 0
#define REC_OPEN    1

//--- enums
enum ENUM_CANDLE_SIZE
  {
   SIZE_BODY  = 0, // Body (open to close)
   SIZE_RANGE = 1  // Full range (high to low)
  };

enum ENUM_CROSS_MODE
  {
   CROSS_BY_CLOSE = 0, // Last rally/drop closes beyond the MA
   CROSS_BY_WICK  = 1  // Any wick of the pattern crosses the MA
  };

enum ENUM_BREAK_LEVEL
  {
   BREAK_BASE_EXTREME = 0, // Base low (sell) / base high (buy)
   BREAK_BASE_BODY    = 1  // Base body bottom (sell) / body top (buy)
  };

enum ENUM_SL_MODE
  {
   SL_PATTERN_EXTREME = 0, // RBR high (sell) / DBD low (buy)
   SL_EXTREME_SINCE   = 1  // Highest high (sell) / lowest low (buy) since the pattern
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0, // Fixed lot
   LOT_RISK_PERCENT = 1  // % of balance risked
  };

enum ENUM_TRADE_DIRECTION
  {
   DIR_BOTH      = 0, // Sell (RBR) and buy (DBD)
   DIR_BUY_ONLY  = 1, // Buy only (DBD under a rising MA)
   DIR_SELL_ONLY = 2  // Sell only (RBR under a falling MA)
  };

enum ENUM_TRADE_SCOPE
  {
   SCOPE_PER_TF = 0, // Per timeframe
   SCOPE_GLOBAL = 1  // Across all timeframes
  };

//--- a pattern that passed PHASE 1 and waits for the close beyond its base (PHASE 2)
struct Watch
  {
   bool     active;
   datetime baseTime;
   datetime crossTime;    // candle that crossed the MA (last rally/drop)
   double   baseHigh;
   double   baseLow;
   double   patHigh;      // highest high of the 3 pattern candles
   double   patLow;       // lowest low of the 3 pattern candles
   double   breakLevel;   // PHASE 2 level: close beyond it triggers the trade
   double   slRef;        // SL reference (pattern extreme, or extreme since the pattern)
   double   ma;           // MA at the cross candle
   double   angle;        // MA angle at PHASE 1 (degrees)
   int      bars;         // candles waited since PHASE 1
   double   leg1Size;
   double   baseSize;
   double   leg2Size;
   double   avgSize;
  };

//--- one enabled timeframe
struct TFContext
  {
   int             slot;        // index in g_ctx
   int             tfIndex;     // index in g_allTF (0 = M1 .. 20 = MN1)
   ENUM_TIMEFRAMES tf;
   string          name;        // "M20"
   ulong           magic;
   int             maHandle;
   int             atrHandle;
   datetime        lastBarTime;
   double          angle;       // MA angle on the last closed candle
   Watch           sell;        // RBR under a falling MA
   Watch           buy;         // DBD above a rising MA
   string          barEvents;   // events since the last candle log row
   string          status;
  };

//--- one order placed by the EA, followed until it is closed
struct TradeRec
  {
   ulong    ticket;       // order ticket = position identifier
   int      slot;         // g_ctx index of the timeframe that placed it
   bool     isBuy;
   int      state;        // REC_PENDING (sent) / REC_OPEN
   datetime baseTime;
   datetime placedTime;
   datetime fillTime;
   double   zoneTop;      // pattern base high
   double   zoneBottom;   // pattern base low
   double   entry;        // price when the order was sent
   double   sl;
   double   tp;
   double   lots;
   double   riskMoney;    // money lost if SL is hit
   double   fillPrice;
   double   mfe;          // max favourable excursion (price distance from fill)
   double   mae;          // max adverse excursion (price distance from fill)
   double   angle1;       // MA angle at PHASE 1
   double   angle2;       // MA angle at entry
   int      waitBars;     // candles between PHASE 1 and PHASE 2
   string   cancelReason;
  };

//--- inputs
input group "Timeframes (every enabled timeframe trades on its own)"
input bool InpAllTimeframes = false; // Use ALL timeframes (ignores the list below)
input bool InpTF_M1  = false; // M1
input bool InpTF_M2  = false; // M2
input bool InpTF_M3  = false; // M3
input bool InpTF_M4  = false; // M4
input bool InpTF_M5  = false; // M5
input bool InpTF_M6  = false; // M6
input bool InpTF_M10 = false; // M10
input bool InpTF_M12 = false; // M12
input bool InpTF_M15 = false; // M15
input bool InpTF_M20 = true;  // M20
input bool InpTF_M30 = false; // M30
input bool InpTF_H1  = false; // H1
input bool InpTF_H2  = false; // H2
input bool InpTF_H3  = false; // H3
input bool InpTF_H4  = false; // H4
input bool InpTF_H6  = false; // H6
input bool InpTF_H8  = false; // H8
input bool InpTF_H12 = false; // H12
input bool InpTF_D1  = false; // D1
input bool InpTF_W1  = false; // W1
input bool InpTF_MN1 = false; // MN1

input group "Trend filter"
input int                  InpMAPeriod   = 200;          // MA period
input ENUM_MA_METHOD       InpMAMethod   = MODE_SMA;     // MA method
input ENUM_APPLIED_PRICE   InpMAPrice    = PRICE_CLOSE;  // MA applied price
input ENUM_TRADE_DIRECTION InpDirection  = DIR_BOTH;     // Trade direction

input group "MA angle (trend strength)"
input int                InpAngleBars         = 10;    // Angle measured over N candles
input int                InpAngleATRPeriod    = 14;    // ATR period used to scale the angle
input double             InpMinAngle          = 0.0;   // Min MA angle in degrees (0 = any slope; 45 = MA moved 1 ATR in N candles)
input bool               InpCheckAngleAtEntry = false; // Also require the min angle at PHASE 2 (entry)

input group "PHASE 1: RBR (sell) / DBD (buy) crossing the MA against its slope"
input ENUM_CANDLE_SIZE   InpSizeMode          = SIZE_BODY;      // Candle length measured by
input bool               InpBothLegsLonger    = true;           // Both rallies/drops longer than base (false = either one)
input ENUM_CROSS_MODE    InpCrossMode         = CROSS_BY_CLOSE; // Pattern crosses the MA when
input bool               InpUseAvgSizeFilter  = true;           // Rallies/drops must be above average candle size
input int                InpAvgSizePeriod     = 20;             // Candles used for the average (before the pattern)
input double             InpAvgSizeMultiplier = 1.0;            // Rally/drop size must exceed average x this

input group "PHASE 2: close beyond the base"
input ENUM_BREAK_LEVEL   InpBreakLevel          = BREAK_BASE_EXTREME; // Candle must close beyond
input int                InpMaxWaitBars         = 30;                 // Give up after N candles without PHASE 2 (0 = never)
input bool               InpCancelBeyondPattern = true;               // Give up if a candle closes beyond the RBR high / DBD low

input group "Order (market order on the open of the candle after PHASE 2)"
input double             InpRewardRisk     = 5.0;                // Reward:Risk (TP = RR x risk)
input ENUM_SL_MODE       InpSLMode         = SL_PATTERN_EXTREME; // Stop loss behind
input int                InpSLBufferPoints = 0;                  // Extra SL buffer (points)

input group "Money management"
input ENUM_LOT_MODE      InpLotMode     = LOT_FIXED; // Lot mode
input double             InpFixedLots   = 0.10;      // Fixed lot size
input double             InpRiskPercent = 1.0;       // Risk % of balance per trade

input group "General"
input ulong              InpMagic           = 20020;         // Base magic number (+0 for M1 ... +20 for MN1)
input int                InpSlippagePoints  = 10;            // Slippage (points)
input bool               InpOneTradeAtATime = true;          // Skip new trades while a position exists
input ENUM_TRADE_SCOPE   InpTradeScope      = SCOPE_PER_TF;  // One trade at a time applies
input bool               InpDrawZones       = true;          // Draw pattern bases on chart
input bool               InpDrawAllTFZones  = false;         // Draw bases of all timeframes (false = chart timeframe only)
input string             InpComment         = "RBR_MA200";   // Order comment (timeframe is appended)

input group "CSV logging (for analysis)"
input bool               InpLogTrades   = true;   // Log trades: entry, SL/TP, result, R multiple, MFE/MAE, MA angle
input bool               InpLogSetups   = true;   // Log every PHASE 1 / PHASE 2 / give-up event
input bool               InpLogCandles  = true;   // Log every closed candle: MA, angle, state, open trade, balance, equity
input bool               InpLogToCommon = true;   // Write to Terminal\Common\Files (also used by the tester)
input string             InpLogPrefix   = "RBR";  // Log file name prefix

//--- globals
CTrade          g_trade;
TFContext       g_ctx[];
TradeRec        g_recs[];
ENUM_TIMEFRAMES g_allTF[TF_COUNT] =
  {
   PERIOD_M1, PERIOD_M2, PERIOD_M3, PERIOD_M4, PERIOD_M5, PERIOD_M6, PERIOD_M10,
   PERIOD_M12, PERIOD_M15, PERIOD_M20, PERIOD_M30, PERIOD_H1, PERIOD_H2, PERIOD_H3,
   PERIOD_H4, PERIOD_H6, PERIOD_H8, PERIOD_H12, PERIOD_D1, PERIOD_W1, PERIOD_MN1
  };
string          g_lastEvent   = "";
string          g_logBase     = "";
int             g_fhTrades    = INVALID_HANDLE;
int             g_fhSetups    = INVALID_HANDLE;
int             g_fhCandles   = INVALID_HANDLE;
int             g_statTrades  = 0;
int             g_statWins    = 0;
double          g_statNet     = 0.0;
bool            g_isTester    = false;
bool            g_showComment = true;

const string OBJ_PREFIX = "RBR_MA200_";
const string LOG_FOLDER = "RBR_MA200_logs\\";

const string TRADES_HEADER = "ticket,timeframe,direction,pattern,base_time,placed_time,zone_top,zone_bottom,entry,sl,tp,rr_target,risk_points,lots,risk_money,status,reason,fill_time,fill_price,close_time,close_price,bars_to_fill,bars_held,profit,commission,swap,net_profit,r_multiple,mfe_r,mae_r,balance,equity,angle_phase1,angle_entry,bars_waited";
const string SETUPS_HEADER = "time,timeframe,direction,pattern,result,base_time,base_high,base_low,pattern_high,pattern_low,break_level,sl_ref,ma,angle_phase1,angle_now,bars_waited,leg1_points,base_points,leg2_points,avg_points,entry,sl,tp,lots";
const string CANDLES_HEADER = "log_time,timeframe,candle_time,open,high,low,close,ma,vs_ma,ma_angle,buy_state,sell_state,balance,equity,tf_open_trades,tf_floating,trade_ticket,trade_dir,trade_entry,trade_sl,trade_tp,trade_r_now,trade_mfe_r,trade_mae_r,events";

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpMAPeriod < 1 || InpRewardRisk <= 0.0 || InpAvgSizePeriod < 1 || InpAvgSizeMultiplier <= 0.0 ||
      InpAngleBars < 1 || InpAngleATRPeriod < 1 || InpMinAngle < 0.0 || InpMinAngle >= 90.0 || InpMaxWaitBars < 0)
     {
      Print("Invalid inputs: periods must be >= 1, Reward:Risk and average multiplier > 0, " +
            "min angle 0..89, max wait bars >= 0");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_isTester    = (bool)MQLInfoInteger(MQL_TESTER);
   g_showComment = !g_isTester || (bool)MQLInfoInteger(MQL_VISUAL_MODE);

   ArrayResize(g_ctx, 0);
   ArrayResize(g_recs, 0);
   for(int i = 0; i < TF_COUNT; i++)
     {
      if(!TFSelected(i))
         continue;
      int maHandle  = iMA(_Symbol, g_allTF[i], InpMAPeriod, 0, InpMAMethod, InpMAPrice);
      int atrHandle = iATR(_Symbol, g_allTF[i], InpAngleATRPeriod);
      if(maHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
        {
         Print("Failed to create MA/ATR handle for ", TFName(g_allTF[i]), ", error ", GetLastError());
         if(maHandle != INVALID_HANDLE)
            IndicatorRelease(maHandle);
         if(atrHandle != INVALID_HANDLE)
            IndicatorRelease(atrHandle);
         ReleaseHandles();
         return INIT_FAILED;
        }
      int n = ArraySize(g_ctx);
      ArrayResize(g_ctx, n + 1);
      g_ctx[n].slot        = n;
      g_ctx[n].tfIndex     = i;
      g_ctx[n].tf          = g_allTF[i];
      g_ctx[n].name        = TFName(g_allTF[i]);
      g_ctx[n].magic       = InpMagic + (ulong)i;
      g_ctx[n].maHandle    = maHandle;
      g_ctx[n].atrHandle   = atrHandle;
      g_ctx[n].lastBarTime = 0;
      g_ctx[n].angle       = 0.0;
      g_ctx[n].sell.active = false;
      g_ctx[n].buy.active  = false;
      g_ctx[n].barEvents   = "";
      g_ctx[n].status      = "";
     }

   if(ArraySize(g_ctx) == 0)
     {
      Print("No timeframe selected - enable at least one timeframe in the inputs");
      return INIT_PARAMETERS_INCORRECT;
     }

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING &&
      (ArraySize(g_ctx) > 1 || InpDirection == DIR_BOTH))
      Print("Warning: account is not in hedging mode - trades from different timeframes/directions will net into one position");

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_statTrades = 0;
   g_statWins   = 0;
   g_statNet    = 0.0;

   OpenLogs();

   g_lastEvent = "Started on " + (string)ArraySize(g_ctx) + " timeframe(s) - waiting for PHASE 1";
   UpdateComment();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   UpdateTradeRecords();

   //--- trades still running when the EA stops are logged with their floating result
   for(int i = 0; i < ArraySize(g_recs); i++)
     {
      if(g_recs[i].state == REC_OPEN)
        {
         double price = g_recs[i].isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         WriteTradeRow(g_recs[i], "OPEN_AT_END", TimeCurrent(), price, "", FloatingProfit(g_recs[i]), 0.0, 0.0);
        }
     }

   CloseLogs();
   ReleaseHandles();
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateTradeRecords();

   bool changed = false;
   for(int i = 0; i < ArraySize(g_ctx); i++)
      if(ProcessTimeframe(g_ctx[i]))
         changed = true;

   if(changed)
     {
      FlushLogs();
      UpdateComment();
     }
  }

//+------------------------------------------------------------------+
//| Runs the strategy for one timeframe on the first tick of each    |
//| new candle. Returns true when a new candle was processed.        |
//+------------------------------------------------------------------+
bool ProcessTimeframe(TFContext &c)
  {
   datetime barTime = iTime(_Symbol, c.tf, 0);
   if(barTime == 0 || barTime == c.lastBarTime)
      return false;

   //--- closed candles: [1] = last closed, [2], [3] = before it,
   //--- [4] .. [3 + InpAvgSizePeriod] = candles used for the average size
   int barsNeeded = 4 + InpAvgSizePeriod;
   int maNeeded   = 4 + InpAngleBars;

   //--- not enough history for the MA on this timeframe (e.g. MN1 with MA200)
   if(Bars(_Symbol, c.tf) < InpMAPeriod + MathMax(barsNeeded, maNeeded))
     {
      c.lastBarTime = barTime;
      c.status      = "  (not enough history)";
      return true;
     }

   MqlRates rates[];
   double   ma[];
   double   atr[];
   ArraySetAsSeries(rates, true);
   ArraySetAsSeries(ma, true);
   ArraySetAsSeries(atr, true);

   //--- data not ready yet: leave lastBarTime unchanged so the next tick retries this bar
   if(CopyRates(_Symbol, c.tf, 0, barsNeeded, rates) < barsNeeded)
      return false;
   if(CopyBuffer(c.maHandle, 0, 0, maNeeded, ma) < maNeeded)
      return false;
   if(CopyBuffer(c.atrHandle, 0, 0, 2, atr) < 2)
      return false;
   if(rates[0].time != barTime || ma[1] == EMPTY_VALUE || ma[maNeeded - 1] == EMPTY_VALUE || atr[1] == EMPTY_VALUE)
      return false;

   c.lastBarTime = barTime;
   c.status      = "";
   c.angle       = MAAngle(ma, 1, atr[1]);

   if(SellsAllowed())
      StepDirection(c, rates, ma, false);
   if(BuysAllowed())
      StepDirection(c, rates, ma, true);

   if(InpLogCandles)
      LogCandle(c, rates[1], ma[1]);
   c.barEvents = "";
   return true;
  }

//+------------------------------------------------------------------+
//| MA angle in degrees at series index i: atan(MA move over N       |
//| candles / ATR). + = rising, - = falling, 45 = 1 ATR in N candles |
//+------------------------------------------------------------------+
double MAAngle(const double &ma[], int i, double atr)
  {
   if(atr <= 0.0)
      return 0.0;
   return MathArctan((ma[i] - ma[i + InpAngleBars]) / atr) * 180.0 / M_PI;
  }

//--- sells need a falling MA, buys a rising one, at least InpMinAngle steep
bool AngleOk(double angle, bool isBuy)
  {
   return isBuy ? (angle > 0.0 && angle >= InpMinAngle)
                : (angle < 0.0 && angle <= -InpMinAngle);
  }

//+------------------------------------------------------------------+
//| One direction on a new candle:                                   |
//|   1. a waiting pattern: PHASE 2 (close beyond base) -> trade,    |
//|      or give up (close beyond the pattern, too many candles)     |
//|   2. a new pattern crossing the MA -> PHASE 1 (replaces the old) |
//|   isBuy = false: RBR under a falling MA -> sell                  |
//|   isBuy = true : DBD above a rising MA  -> buy                   |
//+------------------------------------------------------------------+
void StepDirection(TFContext &c, const MqlRates &rates[], const double &ma[], bool isBuy)
  {
   Watch w;
   if(isBuy)
      w = c.buy;
   else
      w = c.sell;

   string   side    = isBuy ? "BUY" : "SELL";
   string   pattern = isBuy ? "DBD" : "RBR";
   MqlRates bar     = rates[1];

   //--- 1. pattern waiting for the close beyond its base
   if(w.active)
     {
      w.bars++;
      if(InpSLMode == SL_EXTREME_SINCE)
         w.slRef = isBuy ? MathMin(w.slRef, bar.low) : MathMax(w.slRef, bar.high);

      bool broke  = isBuy ? bar.close > w.breakLevel : bar.close < w.breakLevel;
      bool beyond = isBuy ? bar.close < w.patLow : bar.close > w.patHigh;

      if(broke)
        {
         AddEvent(c, side + " PHASE 2 passed: closed " + (isBuy ? "above " : "below ") + pattern + " base " +
                  DoubleToString(w.breakLevel, _Digits) + " after " + (string)w.bars + " candle(s)");
         OpenTrade(c, w, isBuy);
         w.active = false;
        }
      else if(InpCancelBeyondPattern && beyond)
        {
         AddEvent(c, side + " setup dropped: closed " + (isBuy ? "below the DBD low" : "above the RBR high"));
         LogSetup(c, w, isBuy, "DROPPED_CLOSE_BEYOND_PATTERN", 0.0, 0.0, 0.0, 0.0);
         w.active = false;
        }
      else if(InpMaxWaitBars > 0 && w.bars >= InpMaxWaitBars)
        {
         AddEvent(c, side + " setup dropped: no PHASE 2 after " + (string)w.bars + " candles");
         LogSetup(c, w, isBuy, "DROPPED_EXPIRED", 0.0, 0.0, 0.0, 0.0);
         w.active = false;
        }
     }

   //--- 2. new pattern crossing the MA against its slope
   Watch nw;
   ZeroMemory(nw);
   if(FindPhase1(c, rates, ma, isBuy, nw))
     {
      if(w.active)
         LogSetup(c, w, isBuy, "REPLACED_BY_NEWER", 0.0, 0.0, 0.0, 0.0);
      w = nw;
      AddEvent(c, side + " PHASE 1 passed: " + pattern + " crossed the " + (isBuy ? "rising" : "falling") +
               " MA (angle " + DoubleToString(w.angle, 1) + " deg) - waiting for a close " +
               (isBuy ? "above " : "below ") + DoubleToString(w.breakLevel, _Digits));
      LogSetup(c, w, isBuy, "PHASE1", 0.0, 0.0, 0.0, 0.0);
      if(InpDrawZones && (InpDrawAllTFZones || c.tf == Period()))
         DrawZone(c, isBuy, w);
     }

   if(isBuy)
      c.buy = w;
   else
      c.sell = w;
  }

//+------------------------------------------------------------------+
//| PHASE 1 on the last three closed candles.                        |
//|   sell: RBR (bull, bear, bull) that started below a falling MA   |
//|         and crossed above it                                     |
//|   buy : DBD (bear, bull, bear) that started above a rising MA    |
//|         and crossed below it                                     |
//+------------------------------------------------------------------+
bool FindPhase1(const TFContext &c, const MqlRates &rates[], const double &ma[], bool isBuy, Watch &w)
  {
   //--- MA must slope in the trade direction
   if(!AngleOk(c.angle, isBuy))
      return false;

   //--- sells use a rally pattern (RBR), buys a drop pattern (DBD)
   bool rally = !isBuy;
   if(!IsPatternAt(rates, 1, rally))
      return false;

   MqlRates leg1 = rates[3];
   MqlRates base = rates[2];
   MqlRates leg2 = rates[1];

   //--- approaching the MA from the other side: first leg opens below (RBR) / above (DBD) the MA
   if(rally ? leg1.open >= ma[3] : leg1.open <= ma[3])
      return false;

   //--- ... and crossing it
   bool crossed;
   if(InpCrossMode == CROSS_BY_CLOSE)
      crossed = rally ? leg2.close > ma[1] : leg2.close < ma[1];
   else
     {
      crossed = false;
      for(int k = 1; k <= 3 && !crossed; k++)
         crossed = rally ? rates[k].high > ma[k] : rates[k].low < ma[k];
     }
   if(!crossed)
      return false;

   double avgSize = AverageCandleSize(rates, 4, InpAvgSizePeriod);
   double minLeg  = avgSize * InpAvgSizeMultiplier;
   if(InpUseAvgSizeFilter && (CandleSize(leg1) <= minLeg || CandleSize(leg2) <= minLeg))
      return false;

   w.active     = true;
   w.baseTime   = base.time;
   w.crossTime  = leg2.time;
   w.baseHigh   = base.high;
   w.baseLow    = base.low;
   w.patHigh    = MathMax(leg1.high, MathMax(base.high, leg2.high));
   w.patLow     = MathMin(leg1.low, MathMin(base.low, leg2.low));
   if(InpBreakLevel == BREAK_BASE_EXTREME)
      w.breakLevel = rally ? base.low : base.high;
   else
      w.breakLevel = rally ? MathMin(base.open, base.close) : MathMax(base.open, base.close);
   w.slRef      = rally ? w.patHigh : w.patLow;
   w.ma         = ma[1];
   w.angle      = c.angle;
   w.bars       = 0;
   w.leg1Size   = CandleSize(leg1);
   w.baseSize   = CandleSize(base);
   w.leg2Size   = CandleSize(leg2);
   w.avgSize    = avgSize;
   return true;
  }

//+------------------------------------------------------------------+
//| RBR (rally) / DBD shape with the last leg at series index i:     |
//| leg1 = [i+2], base = [i+1], leg2 = [i], legs longer than base    |
//+------------------------------------------------------------------+
bool IsPatternAt(const MqlRates &rates[], int i, bool rally)
  {
   if(rally)
     {
      if(!IsBullish(rates[i + 2]) || !IsBearish(rates[i + 1]) || !IsBullish(rates[i]))
         return false;
     }
   else
     {
      if(!IsBearish(rates[i + 2]) || !IsBullish(rates[i + 1]) || !IsBearish(rates[i]))
         return false;
     }
   double baseSize = CandleSize(rates[i + 1]);
   bool   l1Longer = CandleSize(rates[i + 2]) > baseSize;
   bool   l2Longer = CandleSize(rates[i]) > baseSize;
   return InpBothLegsLonger ? (l1Longer && l2Longer) : (l1Longer || l2Longer);
  }

//+------------------------------------------------------------------+
//| PHASE 2 passed: market order on the open of the new candle       |
//+------------------------------------------------------------------+
void OpenTrade(TFContext &c, const Watch &w, bool isBuy)
  {
   double price   = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl      = NormalizePrice(isBuy ? w.slRef - InpSLBufferPoints * _Point
                                         : w.slRef + InpSLBufferPoints * _Point);
   double risk    = isBuy ? price - sl : sl - price;
   double tp      = NormalizePrice(isBuy ? price + InpRewardRisk * risk : price - InpRewardRisk * risk);
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double lots    = 0.0;
   ulong  ticket  = 0;
   string result  = "";

   if(InpCheckAngleAtEntry && !AngleOk(c.angle, isBuy))
      result = "SKIP_ANGLE_AT_ENTRY";
   else if(risk <= 0.0 || tp <= 0.0)
      result = "SKIP_BAD_RISK";
   else if(InpOneTradeAtATime && HasOpenTrade(c))
      result = "SKIP_TRADE_OPEN";
   else if(risk < minDist || InpRewardRisk * risk < minDist)
      result = "SKIP_STOPS_LEVEL";
   else
     {
      lots = CalcLots(isBuy, price, sl);
      if(lots <= 0.0)
         result = "SKIP_LOT_SIZE";
      else
        {
         string comment = InpComment + " " + c.name;
         g_trade.SetExpertMagicNumber(c.magic);
         bool sent = isBuy ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, comment)
                           : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, comment);
         uint retcode = g_trade.ResultRetcode();
         if(sent && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED) && g_trade.ResultOrder() > 0)
           {
            ticket = g_trade.ResultOrder();
            result = "OPENED";
           }
         else
            result = "FAILED_" + (string)retcode;
        }
     }

   AddEvent(c, (isBuy ? "BUY " : "SELL ") + DoubleToString(lots, LotDigits()) + " @ " + DoubleToString(price, _Digits) +
            " SL " + DoubleToString(sl, _Digits) + " TP " + DoubleToString(tp, _Digits) + ": " + result);
   LogSetup(c, w, isBuy, result, price, sl, tp, lots);

   if(ticket > 0)
      AddTradeRec(c, isBuy, ticket, w, price, sl, tp, lots);
  }

//+------------------------------------------------------------------+
//| Trade tracking                                                   |
//+------------------------------------------------------------------+
void AddTradeRec(const TFContext &c, bool isBuy, ulong ticket, const Watch &w,
                 double entry, double sl, double tp, double lots)
  {
   double loss = 0.0;
   if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, entry, sl, loss))
      loss = 0.0;

   int n = ArraySize(g_recs);
   ArrayResize(g_recs, n + 1);
   g_recs[n].ticket       = ticket;
   g_recs[n].slot         = c.slot;
   g_recs[n].isBuy        = isBuy;
   g_recs[n].state        = REC_PENDING;
   g_recs[n].baseTime     = w.baseTime;
   g_recs[n].placedTime   = TimeCurrent();
   g_recs[n].fillTime     = 0;
   g_recs[n].zoneTop      = w.baseHigh;
   g_recs[n].zoneBottom   = w.baseLow;
   g_recs[n].entry        = entry;
   g_recs[n].sl           = sl;
   g_recs[n].tp           = tp;
   g_recs[n].lots         = lots;
   g_recs[n].riskMoney    = MathAbs(loss);
   g_recs[n].fillPrice    = 0.0;
   g_recs[n].mfe          = 0.0;
   g_recs[n].mae          = 0.0;
   g_recs[n].angle1       = w.angle;
   g_recs[n].angle2       = c.angle;
   g_recs[n].waitBars     = w.bars;
   g_recs[n].cancelReason = "";
  }

void RemoveRec(int i)
  {
   int n = ArraySize(g_recs);
   for(int j = i; j < n - 1; j++)
      g_recs[j] = g_recs[j + 1];
   ArrayResize(g_recs, n - 1);
  }

//--- selects the position opened by the given order ticket
bool SelectPositionById(ulong id)
  {
   if(PositionSelectByTicket(id) && (ulong)PositionGetInteger(POSITION_IDENTIFIER) == id)
      return true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t != 0 && (ulong)PositionGetInteger(POSITION_IDENTIFIER) == id)
         return true;
     }
   return false;
  }

double FloatingProfit(const TradeRec &r)
  {
   if(r.state == REC_OPEN && SelectPositionById(r.ticket))
      return PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   return 0.0;
  }

//--- follows every order: fill, max favourable/adverse move, and the final result
void UpdateTradeRecords()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = ArraySize(g_recs) - 1; i >= 0; i--)
     {
      ulong ticket = g_recs[i].ticket;

      if(g_recs[i].state == REC_PENDING)
        {
         if(OrderSelect(ticket))
            continue;   // still pending

         if(SelectPositionById(ticket))
           {
            g_recs[i].state     = REC_OPEN;
            g_recs[i].fillTime  = (datetime)PositionGetInteger(POSITION_TIME);
            g_recs[i].fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            AddEvent(g_ctx[g_recs[i].slot], (g_recs[i].isBuy ? "BUY" : "SELL") + " " + (string)ticket +
                     " filled @ " + DoubleToString(g_recs[i].fillPrice, _Digits));
           }
         else
           {
            if(!HistoryOrderSelect(ticket))
               continue;   // history not synchronised yet
            ENUM_ORDER_STATE st = (ENUM_ORDER_STATE)HistoryOrderGetInteger(ticket, ORDER_STATE);
            if(st == ORDER_STATE_FILLED || st == ORDER_STATE_PARTIAL)
               FinalizeClosed(i);   // filled and closed between two ticks
            else if(st == ORDER_STATE_CANCELED || st == ORDER_STATE_EXPIRED || st == ORDER_STATE_REJECTED)
               FinalizeCancelled(i, st);
            continue;
           }
        }

      if(g_recs[i].state == REC_OPEN)
        {
         if(SelectPositionById(ticket))
           {
            double move = g_recs[i].isBuy ? bid - g_recs[i].fillPrice : g_recs[i].fillPrice - ask;
            if(move > g_recs[i].mfe)
               g_recs[i].mfe = move;
            if(-move > g_recs[i].mae)
               g_recs[i].mae = -move;
           }
         else
            FinalizeClosed(i);
        }
     }
  }

void FinalizeCancelled(int i, ENUM_ORDER_STATE st)
  {
   string reason = g_recs[i].cancelReason;
   if(reason == "")
      reason = (st == ORDER_STATE_EXPIRED) ? "BROKER_EXPIRED" :
               (st == ORDER_STATE_REJECTED) ? "REJECTED" : "CANCELLED_EXTERNAL";

   WriteTradeRow(g_recs[i], "CANCELLED", TimeCurrent(), 0.0, reason, 0.0, 0.0, 0.0);
   RemoveRec(i);
  }

void FinalizeClosed(int i)
  {
   ulong id = g_recs[i].ticket;
   if(!HistorySelectByPosition(id))
      return;

   double   profit     = 0.0;
   double   commission = 0.0;
   double   swap       = 0.0;
   double   closePrice = 0.0;
   datetime closeTime  = 0;
   string   reason     = "";
   bool     closed     = false;

   int deals = HistoryDealsTotal();
   for(int d = 0; d < deals; d++)
     {
      ulong deal = HistoryDealGetTicket(d);
      if(deal == 0)
         continue;
      profit     += HistoryDealGetDouble(deal, DEAL_PROFIT);
      commission += HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
      swap       += HistoryDealGetDouble(deal, DEAL_SWAP);

      ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(dealEntry == DEAL_ENTRY_IN)
        {
         if(g_recs[i].fillTime == 0)
           {
            g_recs[i].fillTime  = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
            g_recs[i].fillPrice = HistoryDealGetDouble(deal, DEAL_PRICE);
           }
        }
      else
        {
         closed     = true;
         closeTime  = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
         closePrice = HistoryDealGetDouble(deal, DEAL_PRICE);
         reason     = DealReasonText((ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON));
        }
     }
   if(!closed)
      return;   // deals not in history yet, retry next tick

   //--- make sure the exit itself is counted in MFE / MAE
   double move = g_recs[i].isBuy ? closePrice - g_recs[i].fillPrice : g_recs[i].fillPrice - closePrice;
   if(move > g_recs[i].mfe)
      g_recs[i].mfe = move;
   if(-move > g_recs[i].mae)
      g_recs[i].mae = -move;

   double net = profit + commission + swap;
   g_statTrades++;
   if(net > 0.0)
      g_statWins++;
   g_statNet += net;

   AddEvent(g_ctx[g_recs[i].slot], (g_recs[i].isBuy ? "BUY " : "SELL ") + (string)id + " closed by " + reason +
            " net " + DoubleToString(net, 2));
   WriteTradeRow(g_recs[i], "CLOSED", closeTime, closePrice, reason, profit, commission, swap);
   RemoveRec(i);
  }

string DealReasonText(ENUM_DEAL_REASON r)
  {
   switch(r)
     {
      case DEAL_REASON_SL:     return "SL";
      case DEAL_REASON_TP:     return "TP";
      case DEAL_REASON_SO:     return "STOP_OUT";
      case DEAL_REASON_EXPERT: return "EXPERT";
      case DEAL_REASON_CLIENT:
      case DEAL_REASON_MOBILE:
      case DEAL_REASON_WEB:    return "MANUAL";
      default:                 break;
     }
   return "OTHER";
  }

//+------------------------------------------------------------------+
//| Orders                                                           |
//+------------------------------------------------------------------+
bool IsOurMagic(ulong magic, ulong want)
  {
   if(want != 0)
      return magic == want;
   return magic >= InpMagic && magic < InpMagic + TF_COUNT;
  }

//--- magic 0 = any timeframe of this EA
int CountOurPositions(ulong magic)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         IsOurMagic((ulong)PositionGetInteger(POSITION_MAGIC), magic))
         count++;
     }
   return count;
  }

int CountOurPendingOrders(ulong magic)
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         IsOurMagic((ulong)OrderGetInteger(ORDER_MAGIC), magic))
         count++;
     }
   return count;
  }

bool HasOpenTrade(const TFContext &c)
  {
   ulong magic = (InpTradeScope == SCOPE_PER_TF) ? c.magic : 0;
   return CountOurPositions(magic) > 0 || CountOurPendingOrders(magic) > 0;
  }


//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool TFSelected(int i)
  {
   if(InpAllTimeframes)
      return true;
   switch(i)
     {
      case 0:  return InpTF_M1;
      case 1:  return InpTF_M2;
      case 2:  return InpTF_M3;
      case 3:  return InpTF_M4;
      case 4:  return InpTF_M5;
      case 5:  return InpTF_M6;
      case 6:  return InpTF_M10;
      case 7:  return InpTF_M12;
      case 8:  return InpTF_M15;
      case 9:  return InpTF_M20;
      case 10: return InpTF_M30;
      case 11: return InpTF_H1;
      case 12: return InpTF_H2;
      case 13: return InpTF_H3;
      case 14: return InpTF_H4;
      case 15: return InpTF_H6;
      case 16: return InpTF_H8;
      case 17: return InpTF_H12;
      case 18: return InpTF_D1;
      case 19: return InpTF_W1;
      case 20: return InpTF_MN1;
      default: break;
     }
   return false;
  }

//--- "PERIOD_M20" -> "M20"
string TFName(ENUM_TIMEFRAMES tf)
  {
   return StringSubstr(EnumToString(tf), 7);
  }

void ReleaseHandles()
  {
   for(int i = 0; i < ArraySize(g_ctx); i++)
     {
      if(g_ctx[i].maHandle != INVALID_HANDLE)
        {
         IndicatorRelease(g_ctx[i].maHandle);
         g_ctx[i].maHandle = INVALID_HANDLE;
        }
      if(g_ctx[i].atrHandle != INVALID_HANDLE)
        {
         IndicatorRelease(g_ctx[i].atrHandle);
         g_ctx[i].atrHandle = INVALID_HANDLE;
        }
     }
  }


bool BuysAllowed()  { return InpDirection != DIR_SELL_ONLY; }
bool SellsAllowed() { return InpDirection != DIR_BUY_ONLY;  }

bool IsBullish(const MqlRates &r) { return r.close > r.open; }
bool IsBearish(const MqlRates &r) { return r.close < r.open; }

double CandleSize(const MqlRates &r)
  {
   return (InpSizeMode == SIZE_BODY) ? MathAbs(r.close - r.open) : (r.high - r.low);
  }

double AverageCandleSize(const MqlRates &rates[], int start, int count)
  {
   double sum = 0.0;
   for(int i = start; i < start + count; i++)
      sum += CandleSize(rates[i]);
   return sum / count;
  }

double NormalizePrice(double price)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick > 0.0)
      price = MathRound(price / tick) * tick;
   return NormalizeDouble(price, _Digits);
  }

//--- number of decimals in the broker's lot step (0.01 -> 2, 0.001 -> 3, 1 -> 0)
int LotDigits()
  {
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int    digits = 0;
   while(digits < 8 && step > 0.0 && MathAbs(step - MathRound(step)) > 1e-8)
     {
      step *= 10.0;
      digits++;
     }
   return digits;
  }

double CalcLots(bool isBuy, double entry, double sl)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lots = InpFixedLots;
   if(InpLotMode == LOT_RISK_PERCENT)
     {
      double lossPerLot = 0.0;
      ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(!OrderCalcProfit(type, _Symbol, 1.0, entry, sl, lossPerLot) || lossPerLot >= 0.0)
        {
         Print("Could not calculate risk per lot, error ", GetLastError());
         return 0.0;
        }
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      lots = riskMoney / MathAbs(lossPerLot);
     }

   if(maxLot > 0.0)
      lots = MathMin(lots, maxLot);
   //--- round down to the lot step (small epsilon guards against 0.3/0.1 = 2.9999...)
   if(stepLot > 0.0)
      lots = MathFloor(lots / stepLot + 1e-9) * stepLot;
   lots = NormalizeDouble(lots, LotDigits());
   if(lots < minLot)
     {
      Print("Lot size ", lots, " below broker minimum ", minLot);
      return 0.0;
     }
   return lots;
  }

void AddEvent(TFContext &c, const string text)
  {
   c.barEvents += (c.barEvents == "" ? "" : " | ") + text;
   g_lastEvent  = c.name + ": " + text;
   Print(g_lastEvent);
  }


//+------------------------------------------------------------------+
//| CSV logging                                                      |
//+------------------------------------------------------------------+
string Ts(datetime t)   { return t == 0 ? "" : TimeToString(t, TIME_DATE | TIME_SECONDS); }
string Px(double v)     { return DoubleToString(v, _Digits); }
string Mn(double v)     { return DoubleToString(v, 2); }
string Rn(double v)     { return DoubleToString(v, 3); }
string Pts(double v)    { return DoubleToString(v / _Point, 1); }

string CsvText(string s)
  {
   StringReplace(s, ",", ";");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   return s;
  }

void WriteLine(int handle, const string line)
  {
   if(handle != INVALID_HANDLE)
      FileWriteString(handle, line + "\r\n");
  }

int OpenLog(const string suffix, const string header)
  {
   int flags = FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ;
   if(InpLogToCommon)
      flags |= FILE_COMMON;
   int h = FileOpen(LOG_FOLDER + g_logBase + suffix, flags);
   if(h == INVALID_HANDLE)
     {
      Print("Cannot open log file ", g_logBase + suffix, ", error ", GetLastError());
      return INVALID_HANDLE;
     }
   if(header != "")
      WriteLine(h, header);
   return h;
  }

void OpenLogs()
  {
   g_logBase = "";
   if(!InpLogTrades && !InpLogSetups && !InpLogCandles)
      return;

   //--- one set of files per run; GetTickCount keeps tester runs on the same dates apart
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   string sym = _Symbol;
   StringReplace(sym, "/", "_");
   StringReplace(sym, "\\", "_");
   g_logBase = StringFormat("%s_%s_%s%04d%02d%02d_%02d%02d_%u", InpLogPrefix, sym, g_isTester ? "TEST_" : "",
                            t.year, t.mon, t.day, t.hour, t.min, GetTickCount());

   WriteSettingsFile();
   if(InpLogTrades)
      g_fhTrades = OpenLog("_trades.csv", TRADES_HEADER);
   if(InpLogSetups)
      g_fhSetups = OpenLog("_setups.csv", SETUPS_HEADER);
   if(InpLogCandles)
      g_fhCandles = OpenLog("_candles.csv", CANDLES_HEADER);

   Print("CSV logs: ", InpLogToCommon ? "Terminal\\Common\\Files\\" : "MQL5\\Files\\", LOG_FOLDER, g_logBase, "_*.csv");
  }

void CloseLogs()
  {
   if(g_fhTrades != INVALID_HANDLE)  { FileClose(g_fhTrades);  g_fhTrades  = INVALID_HANDLE; }
   if(g_fhSetups != INVALID_HANDLE)  { FileClose(g_fhSetups);  g_fhSetups  = INVALID_HANDLE; }
   if(g_fhCandles != INVALID_HANDLE) { FileClose(g_fhCandles); g_fhCandles = INVALID_HANDLE; }
  }

//--- live: flush every new candle so the files can be read while the EA runs
void FlushLogs()
  {
   if(g_isTester)
      return;
   if(g_fhTrades != INVALID_HANDLE)  FileFlush(g_fhTrades);
   if(g_fhSetups != INVALID_HANDLE)  FileFlush(g_fhSetups);
   if(g_fhCandles != INVALID_HANDLE) FileFlush(g_fhCandles);
  }


void DrawZone(const TFContext &c, bool isBuy, const Watch &w)
  {
   string   name = OBJ_PREFIX + c.name + "_" + (isBuy ? "DBD_" : "RBR_") + TimeToString(w.baseTime, TIME_DATE | TIME_MINUTES);
   datetime t2   = w.baseTime + 30 * PeriodSeconds(c.tf);

   ObjectDelete(0, name);
   if(ObjectCreate(0, name, OBJ_RECTANGLE, 0, w.baseTime, w.baseHigh, t2, w.baseLow))
     {
      ObjectSetInteger(0, name, OBJPROP_COLOR, isBuy ? clrDodgerBlue : clrOrangeRed);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetString(0, name, OBJPROP_TOOLTIP,
                      StringFormat("%s %s base\n%s on close %s %s\nSL ref %s\nMA angle %.1f deg", c.name,
                                   isBuy ? "DBD" : "RBR", isBuy ? "BUY" : "SELL", isBuy ? "above" : "below",
                                   DoubleToString(w.breakLevel, _Digits), DoubleToString(w.slRef, _Digits), w.angle));
     }
   ChartRedraw();
  }

string StateText(bool isBuy, const TFContext &c)
  {
   if(!(isBuy ? BuysAllowed() : SellsAllowed()))
      return "off";
   Watch w;
   if(isBuy)
      w = c.buy;
   else
      w = c.sell;
   if(!w.active)
      return isBuy ? "wait DBD" : "wait RBR";
   return StringFormat("%s base, wait close %s %s (%d)", isBuy ? "DBD" : "RBR", isBuy ? ">" : "<",
                       DoubleToString(w.breakLevel, _Digits), w.bars);
  }

string StateCode(bool isBuy, const TFContext &c)
  {
   if(!(isBuy ? BuysAllowed() : SellsAllowed()))
      return "OFF";
   bool active = isBuy ? c.buy.active : c.sell.active;
   if(active)
      return "WAIT_BREAK";
   return isBuy ? "WAIT_DBD" : "WAIT_RBR";
  }

void UpdateComment()
  {
   if(!g_showComment)
      return;
   string s = StringFormat("MA%d rejection EA  |  %d timeframe(s)  |  closed trades %d  wins %d  net %.2f\n",
                           InpMAPeriod, ArraySize(g_ctx), g_statTrades, g_statWins, g_statNet);
   for(int i = 0; i < ArraySize(g_ctx); i++)
      s += StringFormat("%-4s  angle %+6.1f deg  SELL: %s   BUY: %s%s\n", g_ctx[i].name, g_ctx[i].angle,
                        StateText(false, g_ctx[i]), StateText(true, g_ctx[i]), g_ctx[i].status);
   s += "Last: " + g_lastEvent;
   if(g_logBase != "")
      s += "\nLogs: " + g_logBase + "_*.csv";
   Comment(s);
  }

//--- the inputs of this run, so results of different runs can be compared
void WriteSettingsFile()
  {
   int h = OpenLog("_settings.csv", "key,value");
   if(h == INVALID_HANDLE)
      return;

   string tfs = "";
   for(int i = 0; i < ArraySize(g_ctx); i++)
      tfs += (i > 0 ? " " : "") + g_ctx[i].name;

   WriteLine(h, "strategy,MA_REJECTION_BASE_BREAK");
   WriteLine(h, "symbol," + _Symbol);
   WriteLine(h, "tester," + (string)g_isTester);
   WriteLine(h, "start_time," + Ts(TimeCurrent()));
   WriteLine(h, "timeframes," + tfs);
   WriteLine(h, "ma_period," + (string)InpMAPeriod);
   WriteLine(h, "ma_method," + EnumToString(InpMAMethod));
   WriteLine(h, "ma_price," + EnumToString(InpMAPrice));
   WriteLine(h, "direction," + EnumToString(InpDirection));
   WriteLine(h, "angle_bars," + (string)InpAngleBars);
   WriteLine(h, "angle_atr_period," + (string)InpAngleATRPeriod);
   WriteLine(h, "min_angle," + DoubleToString(InpMinAngle, 1));
   WriteLine(h, "check_angle_at_entry," + (string)InpCheckAngleAtEntry);
   WriteLine(h, "size_mode," + EnumToString(InpSizeMode));
   WriteLine(h, "both_legs_longer," + (string)InpBothLegsLonger);
   WriteLine(h, "cross_mode," + EnumToString(InpCrossMode));
   WriteLine(h, "avg_size_filter," + (string)InpUseAvgSizeFilter);
   WriteLine(h, "avg_size_period," + (string)InpAvgSizePeriod);
   WriteLine(h, "avg_size_multiplier," + DoubleToString(InpAvgSizeMultiplier, 2));
   WriteLine(h, "break_level," + EnumToString(InpBreakLevel));
   WriteLine(h, "max_wait_bars," + (string)InpMaxWaitBars);
   WriteLine(h, "cancel_beyond_pattern," + (string)InpCancelBeyondPattern);
   WriteLine(h, "reward_risk," + DoubleToString(InpRewardRisk, 2));
   WriteLine(h, "sl_mode," + EnumToString(InpSLMode));
   WriteLine(h, "sl_buffer_points," + (string)InpSLBufferPoints);
   WriteLine(h, "lot_mode," + EnumToString(InpLotMode));
   WriteLine(h, "fixed_lots," + DoubleToString(InpFixedLots, 2));
   WriteLine(h, "risk_percent," + DoubleToString(InpRiskPercent, 2));
   WriteLine(h, "one_trade_at_a_time," + (string)InpOneTradeAtATime);
   WriteLine(h, "trade_scope," + EnumToString(InpTradeScope));
   WriteLine(h, "base_magic," + (string)InpMagic);
   WriteLine(h, "margin_mode," + EnumToString((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)));
   WriteLine(h, "initial_balance," + Mn(AccountInfoDouble(ACCOUNT_BALANCE)));
   FileClose(h);
  }

void WriteTradeRow(const TradeRec &r, const string status, datetime closeTime, double closePrice,
                   const string reason, double profit, double commission, double swap)
  {
   if(g_fhTrades == INVALID_HANDLE)
      return;

   int    psec     = PeriodSeconds(g_ctx[r.slot].tf);
   double riskDist = MathAbs(r.entry - r.sl);
   double net      = profit + commission + swap;
   string toFill   = (r.fillTime > 0) ? (string)((long)(r.fillTime - r.placedTime) / psec) : "";
   string held     = (r.fillTime > 0 && closeTime > 0) ? (string)((long)(closeTime - r.fillTime) / psec) : "";
   bool   filled   = r.fillTime > 0;

   string row = (string)r.ticket + "," +
                g_ctx[r.slot].name + "," +
                (r.isBuy ? "BUY" : "SELL") + "," +
                (r.isBuy ? "DBD" : "RBR") + "," +
                Ts(r.baseTime) + "," +
                Ts(r.placedTime) + "," +
                Px(r.zoneTop) + "," +
                Px(r.zoneBottom) + "," +
                Px(r.entry) + "," +
                Px(r.sl) + "," +
                Px(r.tp) + "," +
                DoubleToString(InpRewardRisk, 2) + "," +
                Pts(riskDist) + "," +
                DoubleToString(r.lots, LotDigits()) + "," +
                Mn(r.riskMoney) + "," +
                status + "," +
                CsvText(reason) + "," +
                Ts(r.fillTime) + "," +
                (filled ? Px(r.fillPrice) : "") + "," +
                Ts(closeTime) + "," +
                (closePrice > 0.0 ? Px(closePrice) : "") + "," +
                toFill + "," +
                held + "," +
                Mn(profit) + "," +
                Mn(commission) + "," +
                Mn(swap) + "," +
                Mn(net) + "," +
                (filled && r.riskMoney > 0.0 ? Rn(net / r.riskMoney) : "") + "," +
                (filled && riskDist > 0.0 ? Rn(r.mfe / riskDist) : "") + "," +
                (filled && riskDist > 0.0 ? Rn(r.mae / riskDist) : "") + "," +
                Mn(AccountInfoDouble(ACCOUNT_BALANCE)) + "," +
                Mn(AccountInfoDouble(ACCOUNT_EQUITY)) + "," +
                DoubleToString(r.angle1, 2) + "," +
                DoubleToString(r.angle2, 2) + "," +
                (string)r.waitBars;
   WriteLine(g_fhTrades, row);
   if(!g_isTester)
      FileFlush(g_fhTrades);
  }

//--- one row per setup event: PHASE1, OPENED / SKIP_* / FAILED_*, DROPPED_*, REPLACED_BY_NEWER
void LogSetup(const TFContext &c, const Watch &w, bool isBuy, const string result,
              double entry, double sl, double tp, double lots)
  {
   if(g_fhSetups == INVALID_HANDLE)
      return;
   string row = Ts(TimeCurrent()) + "," +
                c.name + "," +
                (isBuy ? "BUY" : "SELL") + "," +
                (isBuy ? "DBD" : "RBR") + "," +
                result + "," +
                Ts(w.baseTime) + "," +
                Px(w.baseHigh) + "," +
                Px(w.baseLow) + "," +
                Px(w.patHigh) + "," +
                Px(w.patLow) + "," +
                Px(w.breakLevel) + "," +
                Px(w.slRef) + "," +
                Px(w.ma) + "," +
                DoubleToString(w.angle, 2) + "," +
                DoubleToString(c.angle, 2) + "," +
                (string)w.bars + "," +
                Pts(w.leg1Size) + "," +
                Pts(w.baseSize) + "," +
                Pts(w.leg2Size) + "," +
                Pts(w.avgSize) + "," +
                (entry > 0.0 ? Px(entry) : "") + "," +
                (sl > 0.0 ? Px(sl) : "") + "," +
                (tp > 0.0 ? Px(tp) : "") + "," +
                (lots > 0.0 ? DoubleToString(lots, LotDigits()) : "");
   WriteLine(g_fhSetups, row);
  }

void LogCandle(const TFContext &c, const MqlRates &bar, double ma)
  {
   if(g_fhCandles == INVALID_HANDLE)
      return;

   //--- trades of this timeframe: count, floating P/L and details of the first open one
   int    openCount = 0;
   double floating  = 0.0;
   string tTicket = "", tDir = "", tEntry = "", tSL = "", tTP = "", tRNow = "", tMfe = "", tMae = "";
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = 0; i < ArraySize(g_recs); i++)
     {
      if(g_recs[i].slot != c.slot || g_recs[i].state != REC_OPEN)
         continue;
      if(!SelectPositionById(g_recs[i].ticket))
         continue;
      openCount++;
      floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(openCount > 1)
         continue;

      double riskDist = MathAbs(g_recs[i].entry - g_recs[i].sl);
      double move     = g_recs[i].isBuy ? bid - g_recs[i].fillPrice : g_recs[i].fillPrice - ask;
      tTicket = (string)g_recs[i].ticket;
      tDir    = g_recs[i].isBuy ? "BUY" : "SELL";
      tEntry  = Px(g_recs[i].fillPrice);
      tSL     = Px(PositionGetDouble(POSITION_SL));
      tTP     = Px(PositionGetDouble(POSITION_TP));
      if(riskDist > 0.0)
        {
         tRNow = Rn(move / riskDist);
         tMfe  = Rn(g_recs[i].mfe / riskDist);
         tMae  = Rn(g_recs[i].mae / riskDist);
        }
     }

   string row = Ts(TimeCurrent()) + "," +
                c.name + "," +
                Ts(bar.time) + "," +
                Px(bar.open) + "," +
                Px(bar.high) + "," +
                Px(bar.low) + "," +
                Px(bar.close) + "," +
                Px(ma) + "," +
                (bar.close > ma ? "ABOVE" : (bar.close < ma ? "BELOW" : "ON")) + "," +
                DoubleToString(c.angle, 2) + "," +
                StateCode(true, c) + "," +
                StateCode(false, c) + "," +
                Mn(AccountInfoDouble(ACCOUNT_BALANCE)) + "," +
                Mn(AccountInfoDouble(ACCOUNT_EQUITY)) + "," +
                (string)openCount + "," +
                Mn(floating) + "," +
                tTicket + "," +
                tDir + "," +
                tEntry + "," +
                tSL + "," +
                tTP + "," +
                tRNow + "," +
                tMfe + "," +
                tMae + "," +
                CsvText(c.barEvents);
   WriteLine(g_fhCandles, row);
  }
//+------------------------------------------------------------------+
