//+------------------------------------------------------------------+
//|                                                RBR_MA200_EA.mq5  |
//|  MA200 trend-following + Rally-Base-Rally / Drop-Base-Drop       |
//|  supply & demand zone limit orders                               |
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
//+------------------------------------------------------------------+
#property copyright "GannIntegral"
#property version   "1.10"
#property description "MA200 trend filter + Rally-Base-Rally buy limit / Drop-Base-Drop sell limit EA"

#include <Trade/Trade.mqh>

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

//--- inputs
input group "Trend filter"
input ENUM_TIMEFRAMES      InpTimeframe  = PERIOD_M20;   // Signal timeframe
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
input int                InpExpiryBars            = 0;               // Cancel pending after N bars (0 = never)
input bool               InpCancelOnCloseAcrossMA = true;            // Cancel pending if a candle closes across the MA against it

input group "Money management"
input ENUM_LOT_MODE      InpLotMode     = LOT_FIXED; // Lot mode
input double             InpFixedLots   = 0.10;      // Fixed lot size
input double             InpRiskPercent = 1.0;       // Risk % of balance per trade

input group "General"
input ulong              InpMagic               = 20020;        // Magic number
input int                InpSlippagePoints      = 10;           // Slippage (points)
input bool               InpOneTradeAtATime     = true;         // Skip new setups while a position/order exists
input bool               InpDrawZones           = true;         // Draw zones on chart
input string             InpComment             = "RBR_MA200";  // Order comment

//--- globals
CTrade     g_trade;
int        g_maHandle    = INVALID_HANDLE;
SetupState g_buy;
SetupState g_sell;
datetime   g_lastBarTime = 0;
string     g_lastEvent   = "";
const string OBJ_PREFIX  = "RBR_MA200_";

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpMAPeriod < 1 || InpRewardRisk <= 0.0 || InpAvgSizePeriod < 1 || InpAvgSizeMultiplier <= 0.0)
     {
      Print("Invalid inputs: MA period and average period must be >= 1, Reward:Risk and average multiplier > 0");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_maHandle = iMA(_Symbol, InpTimeframe, InpMAPeriod, 0, InpMAMethod, InpMAPrice);
   if(g_maHandle == INVALID_HANDLE)
     {
      Print("Failed to create MA handle, error ", GetLastError());
      return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_buy.phase      = PHASE_WAIT_CROSS;
   g_buy.crossTime  = 0;
   g_sell.phase     = PHASE_WAIT_CROSS;
   g_sell.crossTime = 0;
   g_lastBarTime    = 0;
   g_lastEvent      = "Started - waiting for PHASE 1";
   UpdateComment();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_maHandle != INVALID_HANDLE)
      IndicatorRelease(g_maHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ManagePendingExpiry();

   datetime barTime = iTime(_Symbol, InpTimeframe, 0);
   if(barTime == 0 || barTime == g_lastBarTime)
      return;

   //--- closed candles: [1] = last closed, [2], [3] = before it,
   //--- [4] .. [3 + InpAvgSizePeriod] = candles used for the average size
   int      barsNeeded = 4 + InpAvgSizePeriod;
   MqlRates rates[];
   double   ma[];
   ArraySetAsSeries(rates, true);
   ArraySetAsSeries(ma, true);

   //--- data not ready yet: leave g_lastBarTime unchanged so the next tick retries this bar
   if(CopyRates(_Symbol, InpTimeframe, 0, barsNeeded, rates) < barsNeeded)
      return;
   if(CopyBuffer(g_maHandle, 0, 0, 4, ma) < 4)
      return;
   if(rates[0].time != barTime)
      return;

   g_lastBarTime = barTime;

   bool closedBelowMA = rates[1].close < ma[1];
   bool closedAboveMA = rates[1].close > ma[1];

   //--- cancel pending orders when the trend is lost
   if(InpCancelOnCloseAcrossMA)
     {
      if(closedBelowMA)
         DeleteOurPendingOrders(ORDER_TYPE_BUY_LIMIT, "candle closed below MA");
      if(closedAboveMA)
         DeleteOurPendingOrders(ORDER_TYPE_SELL_LIMIT, "candle closed above MA");
     }

   //--- reset PHASE 1 when price closes back across the MA
   if(InpResetOnCloseAcrossMA)
     {
      if(g_buy.phase == PHASE_WAIT_PATTERN && closedBelowMA)
        {
         g_buy.phase = PHASE_WAIT_CROSS;
         g_lastEvent = "BUY: closed back below MA - PHASE 1 reset";
         Print(g_lastEvent);
        }
      if(g_sell.phase == PHASE_WAIT_PATTERN && closedAboveMA)
        {
         g_sell.phase = PHASE_WAIT_CROSS;
         g_lastEvent  = "SELL: closed back above MA - PHASE 1 reset";
         Print(g_lastEvent);
        }
     }

   //--- PHASE 1 BUY: first close above MA coming from below
   if(BuysAllowed() && rates[2].close < ma[2] && closedAboveMA)
     {
      g_buy.phase     = PHASE_WAIT_PATTERN;
      g_buy.crossTime = rates[1].time;
      g_lastEvent     = "BUY PHASE 1 passed at " + TimeToString(g_buy.crossTime) + " - waiting for Rally-Base-Rally";
      Print(g_lastEvent);
     }

   //--- PHASE 1 SELL: first close below MA coming from above
   if(SellsAllowed() && rates[2].close > ma[2] && closedBelowMA)
     {
      g_sell.phase     = PHASE_WAIT_PATTERN;
      g_sell.crossTime = rates[1].time;
      g_lastEvent      = "SELL PHASE 1 passed at " + TimeToString(g_sell.crossTime) + " - waiting for Drop-Base-Drop";
      Print(g_lastEvent);
     }

   //--- PHASE 2: pattern after the cross
   if(BuysAllowed() && g_buy.phase == PHASE_WAIT_PATTERN)
      CheckPattern(rates, true, g_buy);
   if(SellsAllowed() && g_sell.phase == PHASE_WAIT_PATTERN)
      CheckPattern(rates, false, g_sell);

   UpdateComment();
  }

//+------------------------------------------------------------------+
//| PHASE 2 check on the last three closed candles                   |
//|   isBuy = true : Rally-Base-Rally -> buy limit                   |
//|   isBuy = false: Drop-Base-Drop   -> sell limit                  |
//+------------------------------------------------------------------+
void CheckPattern(const MqlRates &rates[], bool isBuy, SetupState &st)
  {
   MqlRates leg1 = rates[3];
   MqlRates base = rates[2];
   MqlRates leg2 = rates[1];
   string   side = isBuy ? "BUY" : "SELL";
   string   name = isBuy ? "RBR" : "DBD";

   //--- pattern must form after the cross
   if(InpAllowCrossAsLeg ? (leg1.time < st.crossTime) : (leg1.time <= st.crossTime))
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

   double baseSize = CandleSize(base);
   bool l1Longer   = CandleSize(leg1) > baseSize;
   bool l2Longer   = CandleSize(leg2) > baseSize;
   bool sizeOk     = InpBothLegsLonger ? (l1Longer && l2Longer) : (l1Longer || l2Longer);
   if(!sizeOk)
      return;

   //--- legs must be bigger than the average candle: skips choppy, sideways markets
   if(InpUseAvgSizeFilter)
     {
      double avgSize = AverageCandleSize(rates, 4, InpAvgSizePeriod);
      double minLeg  = avgSize * InpAvgSizeMultiplier;
      if(CandleSize(leg1) <= minLeg || CandleSize(leg2) <= minLeg)
        {
         g_lastEvent = name + " ignored: legs not above average size (" +
                       DoubleToString(minLeg, _Digits) + ")";
         Print(g_lastEvent);
         return;
        }
     }

   //--- zone = base candle body. Near edge (base open) is the edge closest to price:
   //--- RBR base is bearish -> open is the top; DBD base is bullish -> open is the bottom
   double nearEdge = base.open;
   double farEdge  = base.close;
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
   if(risk <= 0.0)
      return;
   double tp = NormalizePrice(isBuy ? entry + InpRewardRisk * risk
                                    : entry - InpRewardRisk * risk);
   if(tp <= 0.0)
      return;

   g_lastEvent = side + " PHASE 2 passed (" + name + ") - zone " + DoubleToString(zoneBottom, _Digits) +
                 " - " + DoubleToString(zoneTop, _Digits);
   Print(g_lastEvent);

   if(InpDrawZones)
      DrawZone(isBuy, base.time, zoneTop, zoneBottom, sl, tp);

   if(InpOneTradeAtATime && (CountOurPositions() > 0 || CountOurPendingOrders() > 0))
     {
      g_lastEvent += " | skipped: trade already open";
      Print("Setup skipped: a position or pending order already exists");
      return;
     }

   //--- only place the limit order if price has not reached the zone yet
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(isBuy ? (ask <= entry) : (bid >= entry))
     {
      g_lastEvent += " | skipped: price already in zone";
      Print("Setup skipped: price already touched the zone (",
            isBuy ? "Ask " : "Bid ", DoubleToString(isBuy ? ask : bid, _Digits), ")");
      return;
     }

   double minDist   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double priceDist = isBuy ? ask - entry : entry - bid;
   double tpDist    = isBuy ? tp - entry  : entry - tp;
   if(priceDist < minDist || risk < minDist || tpDist < minDist)
     {
      g_lastEvent += " | skipped: too close to price (stops level)";
      Print("Setup skipped: entry/SL/TP violate broker stops level");
      return;
     }

   double lots = CalcLots(isBuy, entry, sl);
   if(lots <= 0.0)
     {
      g_lastEvent += " | skipped: invalid lot size";
      return;
     }

   bool placed = isBuy ? g_trade.BuyLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpComment)
                       : g_trade.SellLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpComment);
   if(placed)
     {
      g_lastEvent = StringFormat("%s LIMIT %s @ %s  SL %s  TP %s", side,
                                 DoubleToString(lots, LotDigits()),
                                 DoubleToString(entry, _Digits),
                                 DoubleToString(sl, _Digits),
                                 DoubleToString(tp, _Digits));
      Print(g_lastEvent);
      //--- setup consumed: wait for the next cross
      st.phase = PHASE_WAIT_CROSS;
     }
   else
     {
      g_lastEvent = side + "Limit failed: " + g_trade.ResultRetcodeDescription();
      Print(g_lastEvent);
     }
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
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

int CountOurPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         count++;
     }
   return count;
  }

int CountOurPendingOrders()
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagic)
         count++;
     }
   return count;
  }

void DeleteOurPendingOrders(const ENUM_ORDER_TYPE type, const string reason)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic ||
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != type)
         continue;
      if(g_trade.OrderDelete(ticket))
        {
         g_lastEvent = "Pending order " + (string)ticket + " cancelled: " + reason;
         Print(g_lastEvent);
        }
     }
  }

void ManagePendingExpiry()
  {
   if(InpExpiryBars <= 0)
      return;
   long maxAge = (long)InpExpiryBars * PeriodSeconds(InpTimeframe);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if((long)(TimeCurrent() - setup) >= maxAge && g_trade.OrderDelete(ticket))
        {
         g_lastEvent = "Pending order " + (string)ticket + " expired after " + (string)InpExpiryBars + " bars";
         Print(g_lastEvent);
        }
     }
  }

void DrawZone(bool isBuy, datetime baseTime, double top, double bottom, double sl, double tp)
  {
   string   name = OBJ_PREFIX + (isBuy ? "RBR_" : "DBD_") + TimeToString(baseTime, TIME_DATE | TIME_MINUTES);
   datetime t2   = baseTime + 30 * PeriodSeconds(InpTimeframe);

   ObjectDelete(0, name);
   if(ObjectCreate(0, name, OBJ_RECTANGLE, 0, baseTime, top, t2, bottom))
     {
      ObjectSetInteger(0, name, OBJPROP_COLOR, isBuy ? clrDodgerBlue : clrOrangeRed);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetString(0, name, OBJPROP_TOOLTIP,
                      StringFormat("%s zone\nSL %s\nTP %s", isBuy ? "RBR demand" : "DBD supply",
                                   DoubleToString(sl, _Digits), DoubleToString(tp, _Digits)));
     }
   ChartRedraw();
  }

string PhaseText(bool isBuy, const SetupState &st)
  {
   bool allowed = isBuy ? BuysAllowed() : SellsAllowed();
   if(!allowed)
      return "disabled";
   if(st.phase == PHASE_WAIT_CROSS)
      return "Waiting for PHASE 1 (close " + (isBuy ? "above" : "below") + " MA" + (string)InpMAPeriod + ")";
   return "PHASE 1 passed (" + TimeToString(st.crossTime) + ") - waiting for PHASE 2 (" +
          (isBuy ? "Rally-Base-Rally" : "Drop-Base-Drop") + ")";
  }

void UpdateComment()
  {
   Comment("RBR/DBD MA", InpMAPeriod, " EA  [", EnumToString(InpTimeframe), "]\n",
           "BUY:   ", PhaseText(true, g_buy), "\n",
           "SELL:  ", PhaseText(false, g_sell), "\n",
           "Last:  ", g_lastEvent);
  }
//+------------------------------------------------------------------+
