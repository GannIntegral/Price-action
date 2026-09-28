//+------------------------------------------------------------------+
//|                                                RBR_MA200_EA.mq5  |
//|  MA200 trend-following + Rally-Base-Rally / Drop-Base-Drop       |
//|  supply & demand zone limit orders, on any set of timeframes,    |
//|  with CSV logging of setups, trades and every closed candle.     |
//|                                                                  |
//|  BUY  (Rally-Base-Rally)                                         |
//|  PHASE 1: a candle closes above the MA after the previous candle |
//|           closed below it (first close above, coming from below) |
//|  PHASE 2: bullish -> bearish -> bullish, rallies longer than the |
//|           base. Base open..close is the demand zone.             |
//|  ENTRY  : buy limit at the zone (if price has not reached it),   |
//|           SL below the base low, TP = 1:5 risk/reward.           |
//|                                                                  |
//|  SELL (Drop-Base-Drop) - the mirror image                        |
//|  PHASE 1: a candle closes below the MA after the previous candle |
//|           closed above it (first close below, coming from above) |
//|  PHASE 2: bearish -> bullish -> bearish, drops longer than the   |
//|           base. Base open..close is the supply zone.             |
//|  ENTRY  : sell limit at the zone (if price has not reached it),  |
//|           SL above the base high, TP = 1:5 risk/reward.          |
//|                                                                  |
//|  Every enabled timeframe runs its own copy of the strategy with  |
//|  its own magic number (base magic + timeframe index).            |
//+------------------------------------------------------------------+
#property copyright "GannIntegral"
#property version   "2.00"
#property description "MA200 trend filter + Rally-Base-Rally / Drop-Base-Drop limit orders on any set of timeframes, with CSV logging"

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

enum ENUM_ENTRY_LEVEL
  {
   ENTRY_ZONE_NEAR = 0, // Near edge (base open)
   ENTRY_ZONE_MID  = 1, // Zone middle
   ENTRY_ZONE_FAR  = 2  // Far edge (base close)
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0, // Fixed lot
   LOT_RISK_PERCENT = 1  // % of balance risked
  };

enum ENUM_TRADE_DIRECTION
  {
   DIR_BOTH      = 0, // Buy (RBR) and sell (DBD)
   DIR_BUY_ONLY  = 1, // Buy only (RBR)
   DIR_SELL_ONLY = 2  // Sell only (DBD)
  };

enum ENUM_TRADE_SCOPE
  {
   SCOPE_PER_TF = 0, // Per timeframe
   SCOPE_GLOBAL = 1  // Across all timeframes
  };

enum ENUM_PHASE
  {
   PHASE_WAIT_CROSS   = 0, // waiting for PHASE 1 (cross of the MA)
   PHASE_WAIT_PATTERN = 1  // PHASE 1 passed, waiting for PHASE 2 (RBR / DBD)
  };

//--- per-direction setup state
struct SetupState
  {
   ENUM_PHASE phase;
   datetime   crossTime;
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
   datetime        lastBarTime;
   SetupState      buy;
   SetupState      sell;
   string          barEvents;   // events since the last candle log row
   string          status;
  };

//--- one order placed by the EA, followed until it is cancelled or closed
struct TradeRec
  {
   ulong    ticket;       // pending order ticket = position identifier once filled
   int      slot;         // g_ctx index of the timeframe that placed it
   bool     isBuy;
   int      state;        // REC_PENDING / REC_OPEN
   datetime baseTime;
   datetime placedTime;
   datetime fillTime;
   double   zoneTop;
   double   zoneBottom;
   double   entry;
   double   sl;
   double   tp;
   double   lots;
   double   riskMoney;    // money lost if SL is hit
   double   fillPrice;
   double   mfe;          // max favourable excursion (price distance from fill)
   double   mae;          // max adverse excursion (price distance from fill)
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

input group "Rally-Base-Rally / Drop-Base-Drop"
input ENUM_CANDLE_SIZE   InpSizeMode             = SIZE_BODY; // Candle length measured by
input bool               InpBothLegsLonger       = true;      // Both rallies/drops longer than base (false = either one)
input bool               InpAllowCrossAsLeg      = true;      // Cross candle may be the first rally/drop
input bool               InpResetOnCloseAcrossMA = true;      // Reset PHASE 1 if a candle closes back across the MA

input group "Average candle size filter (avoid sideways markets)"
input bool               InpUseAvgSizeFilter    = true;      // Rallies/drops must be above average candle size
input int                InpAvgSizePeriod       = 20;        // Candles used for the average (before the pattern)
input double             InpAvgSizeMultiplier   = 1.0;       // Rally/drop size must exceed average x this

input group "Order"
input ENUM_ENTRY_LEVEL   InpEntryLevel            = ENTRY_ZONE_NEAR; // Limit order price
input double             InpRewardRisk            = 5.0;             // Reward:Risk (TP = RR x risk)
input int                InpSLBufferPoints        = 0;               // Extra SL buffer beyond the base low/high (points)
input int                InpExpiryBars            = 0;               // Cancel pending after N bars of its timeframe (0 = never)
input bool               InpCancelOnCloseAcrossMA = true;            // Cancel pending if a candle closes across the MA against it

input group "Money management"
input ENUM_LOT_MODE      InpLotMode     = LOT_FIXED; // Lot mode
input double             InpFixedLots   = 0.10;      // Fixed lot size
input double             InpRiskPercent = 1.0;       // Risk % of balance per trade

input group "General"
input ulong              InpMagic           = 20020;         // Base magic number (+0 for M1 ... +20 for MN1)
input int                InpSlippagePoints  = 10;            // Slippage (points)
input bool               InpOneTradeAtATime = true;          // Skip new setups while a position/order exists
input ENUM_TRADE_SCOPE   InpTradeScope      = SCOPE_PER_TF;  // One trade at a time applies
input bool               InpDrawZones       = true;          // Draw zones on chart
input bool               InpDrawAllTFZones  = false;         // Draw zones of all timeframes (false = chart timeframe only)
input string             InpComment         = "RBR_MA200";   // Order comment (timeframe is appended)

input group "CSV logging (for analysis)"
input bool               InpLogTrades   = true;   // Log trades: fill, SL/TP, result, R multiple, MFE/MAE
input bool               InpLogSetups   = true;   // Log every detected RBR/DBD setup and what happened to it
input bool               InpLogCandles  = true;   // Log every closed candle: MA, phases, open trade, balance, equity
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

const string TRADES_HEADER = "ticket,timeframe,direction,pattern,base_time,placed_time,zone_top,zone_bottom,entry,sl,tp,rr_target,risk_points,lots,risk_money,status,reason,fill_time,fill_price,close_time,close_price,bars_to_fill,bars_held,profit,commission,swap,net_profit,r_multiple,mfe_r,mae_r,balance,equity";
const string SETUPS_HEADER = "detected_time,timeframe,direction,pattern,base_time,leg1_points,base_points,leg2_points,avg_points,zone_top,zone_bottom,entry,sl,tp,rr_target,lots,result";
const string CANDLES_HEADER = "log_time,timeframe,candle_time,open,high,low,close,ma,vs_ma,buy_phase,sell_phase,balance,equity,tf_open_trades,tf_pending,tf_floating,trade_ticket,trade_dir,trade_entry,trade_sl,trade_tp,trade_r_now,trade_mfe_r,trade_mae_r,events";

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpMAPeriod < 1 || InpRewardRisk <= 0.0 || InpAvgSizePeriod < 1 || InpAvgSizeMultiplier <= 0.0)
     {
      Print("Invalid inputs: MA period and average period must be >= 1, Reward:Risk and average multiplier > 0");
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
      int handle = iMA(_Symbol, g_allTF[i], InpMAPeriod, 0, InpMAMethod, InpMAPrice);
      if(handle == INVALID_HANDLE)
        {
         Print("Failed to create MA handle for ", TFName(g_allTF[i]), ", error ", GetLastError());
         ReleaseHandles();
         return INIT_FAILED;
        }
      int n = ArraySize(g_ctx);
      ArrayResize(g_ctx, n + 1);
      g_ctx[n].slot           = n;
      g_ctx[n].tfIndex        = i;
      g_ctx[n].tf             = g_allTF[i];
      g_ctx[n].name           = TFName(g_allTF[i]);
      g_ctx[n].magic          = InpMagic + (ulong)i;
      g_ctx[n].maHandle       = handle;
      g_ctx[n].lastBarTime    = 0;
      g_ctx[n].buy.phase      = PHASE_WAIT_CROSS;
      g_ctx[n].buy.crossTime  = 0;
      g_ctx[n].sell.phase     = PHASE_WAIT_CROSS;
      g_ctx[n].sell.crossTime = 0;
      g_ctx[n].barEvents      = "";
      g_ctx[n].status         = "";
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
      else
         WriteTradeRow(g_recs[i], "PENDING_AT_END", 0, 0.0, "", 0.0, 0.0, 0.0);
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
     {
      ManagePendingExpiry(g_ctx[i]);
      if(ProcessTimeframe(g_ctx[i]))
         changed = true;
     }

   if(changed)
     {
      FlushLogs();
      UpdateComment();
     }
  }

//+------------------------------------------------------------------+
//| Runs the strategy for one timeframe on each new candle.          |
//| Returns true when a new candle was processed.                    |
//+------------------------------------------------------------------+
bool ProcessTimeframe(TFContext &c)
  {
   datetime barTime = iTime(_Symbol, c.tf, 0);
   if(barTime == 0 || barTime == c.lastBarTime)
      return false;

   //--- closed candles: [1] = last closed, [2], [3] = before it,
   //--- [4] .. [3 + InpAvgSizePeriod] = candles used for the average size
   int barsNeeded = 4 + InpAvgSizePeriod;

   //--- not enough history for the MA on this timeframe (e.g. MN1 with MA200)
   if(Bars(_Symbol, c.tf) < InpMAPeriod + barsNeeded)
     {
      c.lastBarTime = barTime;
      c.status      = "  (not enough history)";
      return true;
     }

   MqlRates rates[];
   double   ma[];
   ArraySetAsSeries(rates, true);
   ArraySetAsSeries(ma, true);

   //--- data not ready yet: leave lastBarTime unchanged so the next tick retries this bar
   if(CopyRates(_Symbol, c.tf, 0, barsNeeded, rates) < barsNeeded)
      return false;
   if(CopyBuffer(c.maHandle, 0, 0, 4, ma) < 4)
      return false;
   if(rates[0].time != barTime || ma[1] == EMPTY_VALUE || ma[2] == EMPTY_VALUE)
      return false;

   c.lastBarTime = barTime;
   c.status      = "";

   bool closedBelowMA = rates[1].close < ma[1];
   bool closedAboveMA = rates[1].close > ma[1];

   //--- cancel pending orders when the trend is lost
   if(InpCancelOnCloseAcrossMA)
     {
      if(closedBelowMA)
         DeletePendingOrders(c, ORDER_TYPE_BUY_LIMIT, "CLOSE_BELOW_MA");
      if(closedAboveMA)
         DeletePendingOrders(c, ORDER_TYPE_SELL_LIMIT, "CLOSE_ABOVE_MA");
     }

   //--- reset PHASE 1 when price closes back across the MA
   if(InpResetOnCloseAcrossMA)
     {
      if(c.buy.phase == PHASE_WAIT_PATTERN && closedBelowMA)
        {
         c.buy.phase = PHASE_WAIT_CROSS;
         AddEvent(c, "BUY PHASE 1 reset (closed back below MA)");
        }
      if(c.sell.phase == PHASE_WAIT_PATTERN && closedAboveMA)
        {
         c.sell.phase = PHASE_WAIT_CROSS;
         AddEvent(c, "SELL PHASE 1 reset (closed back above MA)");
        }
     }

   //--- PHASE 1 BUY: first close above MA coming from below
   if(BuysAllowed() && rates[2].close < ma[2] && closedAboveMA)
     {
      c.buy.phase     = PHASE_WAIT_PATTERN;
      c.buy.crossTime = rates[1].time;
      AddEvent(c, "BUY PHASE 1 passed - waiting for Rally-Base-Rally");
     }

   //--- PHASE 1 SELL: first close below MA coming from above
   if(SellsAllowed() && rates[2].close > ma[2] && closedBelowMA)
     {
      c.sell.phase     = PHASE_WAIT_PATTERN;
      c.sell.crossTime = rates[1].time;
      AddEvent(c, "SELL PHASE 1 passed - waiting for Drop-Base-Drop");
     }

   //--- PHASE 2: pattern after the cross
   if(BuysAllowed() && c.buy.phase == PHASE_WAIT_PATTERN)
      CheckPattern(rates, c, true);
   if(SellsAllowed() && c.sell.phase == PHASE_WAIT_PATTERN)
      CheckPattern(rates, c, false);

   if(InpLogCandles)
      LogCandle(c, rates[1], ma[1]);
   c.barEvents = "";
   return true;
  }

//+------------------------------------------------------------------+
//| PHASE 2 check on the last three closed candles                   |
//|   isBuy = true : Rally-Base-Rally -> buy limit                   |
//|   isBuy = false: Drop-Base-Drop   -> sell limit                  |
//+------------------------------------------------------------------+
void CheckPattern(const MqlRates &rates[], TFContext &c, bool isBuy)
  {
   MqlRates leg1      = rates[3];
   MqlRates base      = rates[2];
   MqlRates leg2      = rates[1];
   string   side      = isBuy ? "BUY" : "SELL";
   string   pattern   = isBuy ? "RBR" : "DBD";
   datetime crossTime = isBuy ? c.buy.crossTime : c.sell.crossTime;

   //--- pattern must form after the cross
   if(InpAllowCrossAsLeg ? (leg1.time < crossTime) : (leg1.time <= crossTime))
      return;

   //--- RBR: bullish, bearish, bullish   DBD: bearish, bullish, bearish
   if(isBuy)
     {
      if(!IsBullish(leg1) || !IsBearish(base) || !IsBullish(leg2))
         return;
     }
   else
     {
      if(!IsBearish(leg1) || !IsBullish(base) || !IsBearish(leg2))
         return;
     }

   double leg1Size = CandleSize(leg1);
   double baseSize = CandleSize(base);
   double leg2Size = CandleSize(leg2);
   bool   l1Longer = leg1Size > baseSize;
   bool   l2Longer = leg2Size > baseSize;
   bool   sizeOk   = InpBothLegsLonger ? (l1Longer && l2Longer) : (l1Longer || l2Longer);
   if(!sizeOk)
      return;

   double avgSize = AverageCandleSize(rates, 4, InpAvgSizePeriod);
   double minLeg  = avgSize * InpAvgSizeMultiplier;

   //--- zone = base candle body. Near edge (base open) is the edge closest to price:
   //--- RBR base is bearish -> open is the top; DBD base is bullish -> open is the bottom
   double nearEdge   = base.open;
   double farEdge    = base.close;
   double zoneTop    = MathMax(nearEdge, farEdge);
   double zoneBottom = MathMin(nearEdge, farEdge);
   double entry;
   switch(InpEntryLevel)
     {
      case ENTRY_ZONE_MID: entry = (nearEdge + farEdge) / 2.0; break;
      case ENTRY_ZONE_FAR: entry = farEdge;                    break;
      default:             entry = nearEdge;                   break;
     }
   double sl = isBuy ? base.low  - InpSLBufferPoints * _Point
                     : base.high + InpSLBufferPoints * _Point;

   entry = NormalizePrice(entry);
   sl    = NormalizePrice(sl);
   double risk = isBuy ? entry - sl : sl - entry;
   double tp   = NormalizePrice(isBuy ? entry + InpRewardRisk * risk
                                      : entry - InpRewardRisk * risk);

   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double priceDist = isBuy ? ask - entry : entry - bid;
   double tpDist    = isBuy ? tp - entry  : entry - tp;
   double lots      = 0.0;
   ulong  ticket    = 0;
   string result    = "";

   //--- legs must be bigger than the average candle: skips choppy, sideways markets
   if(InpUseAvgSizeFilter && (leg1Size <= minLeg || leg2Size <= minLeg))
      result = "SKIP_AVG_SIZE";
   else if(risk <= 0.0 || tp <= 0.0)
      result = "SKIP_BAD_RISK";
   else if(InpOneTradeAtATime && HasOpenTrade(c))
      result = "SKIP_TRADE_OPEN";
   //--- only place the limit order if price has not reached the zone yet
   else if(isBuy ? (ask <= entry) : (bid >= entry))
      result = "SKIP_PRICE_IN_ZONE";
   else if(priceDist < minDist || risk < minDist || tpDist < minDist)
      result = "SKIP_STOPS_LEVEL";
   else
     {
      lots = CalcLots(isBuy, entry, sl);
      if(lots <= 0.0)
         result = "SKIP_LOT_SIZE";
      else
        {
         string comment = InpComment + " " + c.name;
         g_trade.SetExpertMagicNumber(c.magic);
         bool placed = isBuy ? g_trade.BuyLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment)
                             : g_trade.SellLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
         if(placed && g_trade.ResultOrder() > 0)
           {
            ticket = g_trade.ResultOrder();
            result = "PLACED";
           }
         else
            result = "FAILED_" + (string)g_trade.ResultRetcode();
        }
     }

   if(result != "SKIP_AVG_SIZE" && InpDrawZones && (InpDrawAllTFZones || c.tf == Period()))
      DrawZone(c, isBuy, base.time, zoneTop, zoneBottom, sl, tp);

   AddEvent(c, side + " " + pattern + " zone " + DoubleToString(zoneBottom, _Digits) + "-" +
            DoubleToString(zoneTop, _Digits) + " entry " + DoubleToString(entry, _Digits) + ": " + result);

   if(InpLogSetups)
      LogSetup(c, isBuy, base.time, leg1Size, baseSize, leg2Size, avgSize,
               zoneTop, zoneBottom, entry, sl, tp, lots, result);

   if(ticket > 0)
     {
      AddTradeRec(c, isBuy, ticket, base.time, zoneTop, zoneBottom, entry, sl, tp, lots);
      //--- setup consumed: wait for the next cross
      if(isBuy)
         c.buy.phase = PHASE_WAIT_CROSS;
      else
         c.sell.phase = PHASE_WAIT_CROSS;
     }
  }

//+------------------------------------------------------------------+
//| Trade tracking                                                   |
//+------------------------------------------------------------------+
void AddTradeRec(const TFContext &c, bool isBuy, ulong ticket, datetime baseTime,
                 double zoneTop, double zoneBottom, double entry, double sl, double tp, double lots)
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
   g_recs[n].baseTime     = baseTime;
   g_recs[n].placedTime   = TimeCurrent();
   g_recs[n].fillTime     = 0;
   g_recs[n].zoneTop      = zoneTop;
   g_recs[n].zoneBottom   = zoneBottom;
   g_recs[n].entry        = entry;
   g_recs[n].sl           = sl;
   g_recs[n].tp           = tp;
   g_recs[n].lots         = lots;
   g_recs[n].riskMoney    = MathAbs(loss);
   g_recs[n].fillPrice    = 0.0;
   g_recs[n].mfe          = 0.0;
   g_recs[n].mae          = 0.0;
   g_recs[n].cancelReason = "";
  }

void RemoveRec(int i)
  {
   int n = ArraySize(g_recs);
   for(int j = i; j < n - 1; j++)
      g_recs[j] = g_recs[j + 1];
   ArrayResize(g_recs, n - 1);
  }

void SetCancelReason(ulong ticket, const string reason)
  {
   for(int i = 0; i < ArraySize(g_recs); i++)
      if(g_recs[i].ticket == ticket)
         g_recs[i].cancelReason = reason;
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
            AddEvent(g_ctx[g_recs[i].slot], (g_recs[i].isBuy ? "BUY" : "SELL") + " limit " + (string)ticket +
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

void DeletePendingOrders(TFContext &c, const ENUM_ORDER_TYPE type, const string reason)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != c.magic ||
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != type)
         continue;
      SetCancelReason(ticket, reason);
      if(g_trade.OrderDelete(ticket))
         AddEvent(c, "pending " + (string)ticket + " cancelled: " + reason);
     }
  }

void ManagePendingExpiry(TFContext &c)
  {
   if(InpExpiryBars <= 0)
      return;
   long maxAge = (long)InpExpiryBars * PeriodSeconds(c.tf);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != c.magic)
         continue;
      datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if((long)(TimeCurrent() - setup) < maxAge)
         continue;
      string reason = "EXPIRED_" + (string)InpExpiryBars + "_BARS";
      SetCancelReason(ticket, reason);
      if(g_trade.OrderDelete(ticket))
         AddEvent(c, "pending " + (string)ticket + " cancelled: " + reason);
     }
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
      if(g_ctx[i].maHandle != INVALID_HANDLE)
        {
         IndicatorRelease(g_ctx[i].maHandle);
         g_ctx[i].maHandle = INVALID_HANDLE;
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

void DrawZone(const TFContext &c, bool isBuy, datetime baseTime, double top, double bottom, double sl, double tp)
  {
   string   name = OBJ_PREFIX + c.name + "_" + (isBuy ? "RBR_" : "DBD_") + TimeToString(baseTime, TIME_DATE | TIME_MINUTES);
   datetime t2   = baseTime + 30 * PeriodSeconds(c.tf);

   ObjectDelete(0, name);
   if(ObjectCreate(0, name, OBJ_RECTANGLE, 0, baseTime, top, t2, bottom))
     {
      ObjectSetInteger(0, name, OBJPROP_COLOR, isBuy ? clrDodgerBlue : clrOrangeRed);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetString(0, name, OBJPROP_TOOLTIP,
                      StringFormat("%s %s zone\nSL %s\nTP %s", c.name, isBuy ? "RBR demand" : "DBD supply",
                                   DoubleToString(sl, _Digits), DoubleToString(tp, _Digits)));
     }
   ChartRedraw();
  }

string PhaseText(bool isBuy, const TFContext &c)
  {
   if(!(isBuy ? BuysAllowed() : SellsAllowed()))
      return "off";
   ENUM_PHASE phase = isBuy ? c.buy.phase : c.sell.phase;
   datetime   cross = isBuy ? c.buy.crossTime : c.sell.crossTime;
   if(phase == PHASE_WAIT_CROSS)
      return "wait cross";
   return "wait " + (isBuy ? "RBR" : "DBD") + " (cross " + TimeToString(cross, TIME_DATE | TIME_MINUTES) + ")";
  }

string PhaseCode(bool isBuy, const TFContext &c)
  {
   if(!(isBuy ? BuysAllowed() : SellsAllowed()))
      return "OFF";
   ENUM_PHASE phase = isBuy ? c.buy.phase : c.sell.phase;
   if(phase == PHASE_WAIT_CROSS)
      return "WAIT_CROSS";
   return isBuy ? "WAIT_RBR" : "WAIT_DBD";
  }

void UpdateComment()
  {
   if(!g_showComment)
      return;
   string s = StringFormat("RBR/DBD MA%d EA  |  %d timeframe(s)  |  closed trades %d  wins %d  net %.2f\n",
                           InpMAPeriod, ArraySize(g_ctx), g_statTrades, g_statWins, g_statNet);
   for(int i = 0; i < ArraySize(g_ctx); i++)
      s += StringFormat("%-4s  BUY: %s   SELL: %s%s\n", g_ctx[i].name,
                        PhaseText(true, g_ctx[i]), PhaseText(false, g_ctx[i]), g_ctx[i].status);
   s += "Last: " + g_lastEvent;
   if(g_logBase != "")
      s += "\nLogs: " + g_logBase + "_*.csv";
   Comment(s);
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

//--- the inputs of this run, so results of different runs can be compared
void WriteSettingsFile()
  {
   int h = OpenLog("_settings.csv", "key,value");
   if(h == INVALID_HANDLE)
      return;

   string tfs = "";
   for(int i = 0; i < ArraySize(g_ctx); i++)
      tfs += (i > 0 ? " " : "") + g_ctx[i].name;

   WriteLine(h, "symbol," + _Symbol);
   WriteLine(h, "tester," + (string)g_isTester);
   WriteLine(h, "start_time," + Ts(TimeCurrent()));
   WriteLine(h, "timeframes," + tfs);
   WriteLine(h, "ma_period," + (string)InpMAPeriod);
   WriteLine(h, "ma_method," + EnumToString(InpMAMethod));
   WriteLine(h, "ma_price," + EnumToString(InpMAPrice));
   WriteLine(h, "direction," + EnumToString(InpDirection));
   WriteLine(h, "size_mode," + EnumToString(InpSizeMode));
   WriteLine(h, "both_legs_longer," + (string)InpBothLegsLonger);
   WriteLine(h, "allow_cross_as_leg," + (string)InpAllowCrossAsLeg);
   WriteLine(h, "reset_on_close_across_ma," + (string)InpResetOnCloseAcrossMA);
   WriteLine(h, "avg_size_filter," + (string)InpUseAvgSizeFilter);
   WriteLine(h, "avg_size_period," + (string)InpAvgSizePeriod);
   WriteLine(h, "avg_size_multiplier," + DoubleToString(InpAvgSizeMultiplier, 2));
   WriteLine(h, "entry_level," + EnumToString(InpEntryLevel));
   WriteLine(h, "reward_risk," + DoubleToString(InpRewardRisk, 2));
   WriteLine(h, "sl_buffer_points," + (string)InpSLBufferPoints);
   WriteLine(h, "expiry_bars," + (string)InpExpiryBars);
   WriteLine(h, "cancel_on_close_across_ma," + (string)InpCancelOnCloseAcrossMA);
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
                (r.isBuy ? "RBR" : "DBD") + "," +
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
                Mn(AccountInfoDouble(ACCOUNT_EQUITY));
   WriteLine(g_fhTrades, row);
   if(!g_isTester)
      FileFlush(g_fhTrades);
  }

void LogSetup(const TFContext &c, bool isBuy, datetime baseTime, double leg1Size, double baseSize,
              double leg2Size, double avgSize, double zoneTop, double zoneBottom,
              double entry, double sl, double tp, double lots, const string result)
  {
   if(g_fhSetups == INVALID_HANDLE)
      return;
   string row = Ts(TimeCurrent()) + "," +
                c.name + "," +
                (isBuy ? "BUY" : "SELL") + "," +
                (isBuy ? "RBR" : "DBD") + "," +
                Ts(baseTime) + "," +
                Pts(leg1Size) + "," +
                Pts(baseSize) + "," +
                Pts(leg2Size) + "," +
                Pts(avgSize) + "," +
                Px(zoneTop) + "," +
                Px(zoneBottom) + "," +
                Px(entry) + "," +
                Px(sl) + "," +
                Px(tp) + "," +
                DoubleToString(InpRewardRisk, 2) + "," +
                (lots > 0.0 ? DoubleToString(lots, LotDigits()) : "") + "," +
                result;
   WriteLine(g_fhSetups, row);
  }

void LogCandle(const TFContext &c, const MqlRates &bar, double ma)
  {
   if(g_fhCandles == INVALID_HANDLE)
      return;

   //--- trades of this timeframe: counts, floating P/L and details of the first open one
   int    openCount = 0;
   int    pendCount = 0;
   double floating  = 0.0;
   string tTicket = "", tDir = "", tEntry = "", tSL = "", tTP = "", tRNow = "", tMfe = "", tMae = "";
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = 0; i < ArraySize(g_recs); i++)
     {
      if(g_recs[i].slot != c.slot)
         continue;
      if(g_recs[i].state == REC_PENDING)
        {
         pendCount++;
         continue;
        }
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
                PhaseCode(true, c) + "," +
                PhaseCode(false, c) + "," +
                Mn(AccountInfoDouble(ACCOUNT_BALANCE)) + "," +
                Mn(AccountInfoDouble(ACCOUNT_EQUITY)) + "," +
                (string)openCount + "," +
                (string)pendCount + "," +
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
