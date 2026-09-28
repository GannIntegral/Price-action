//+------------------------------------------------------------------+
//|                                                RBR_MA200_EA.mq5  |
//|  MA200 trend-following + Rally-Base-Rally demand zone buy limit  |
//|                                                                  |
//|  PHASE 1: a candle closes above the MA after the previous candle |
//|           closed below it (first close above, coming from below) |
//|  PHASE 2: after the cross, a Rally-Base-Rally forms:             |
//|           bullish -> bearish -> bullish, both rallies longer     |
//|           than the base. Base open..close is the buy zone.       |
//|  ENTRY  : buy limit at the base zone (if price has not reached   |
//|           it yet), SL below the base low, TP = 1:5 risk/reward.  |
//+------------------------------------------------------------------+
#property copyright "GannIntegral"
#property version   "1.00"
#property description "MA200 trend filter + Rally-Base-Rally buy limit EA"

#include <Trade/Trade.mqh>

//--- enums
enum ENUM_CANDLE_SIZE
  {
   SIZE_BODY  = 0, // Body (open to close)
   SIZE_RANGE = 1  // Full range (high to low)
  };

enum ENUM_ENTRY_LEVEL
  {
   ENTRY_ZONE_TOP    = 0, // Zone top (base open)
   ENTRY_ZONE_MID    = 1, // Zone middle
   ENTRY_ZONE_BOTTOM = 2  // Zone bottom (base close)
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0, // Fixed lot
   LOT_RISK_PERCENT = 1  // % of balance risked
  };

enum ENUM_PHASE
  {
   PHASE_WAIT_CROSS = 0, // waiting for PHASE 1 (cross above MA)
   PHASE_WAIT_RBR   = 1  // PHASE 1 passed, waiting for PHASE 2 (RBR)
  };

//--- inputs
input group "Trend filter"
input ENUM_TIMEFRAMES    InpTimeframe  = PERIOD_M20;   // Signal timeframe
input int                InpMAPeriod   = 200;          // MA period
input ENUM_MA_METHOD     InpMAMethod   = MODE_SMA;     // MA method
input ENUM_APPLIED_PRICE InpMAPrice    = PRICE_CLOSE;  // MA applied price

input group "Rally-Base-Rally"
input ENUM_CANDLE_SIZE   InpSizeMode            = SIZE_BODY; // Candle length measured by
input bool               InpBothRalliesLonger   = true;      // Both rallies longer than base (false = either one)
input bool               InpAllowCrossAsRally   = true;      // Cross candle may be the first rally
input bool               InpResetOnCloseBelowMA = true;      // Reset PHASE 1 if a candle closes back below MA

input group "Order"
input ENUM_ENTRY_LEVEL   InpEntryLevel           = ENTRY_ZONE_TOP; // Buy limit price
input double             InpRewardRisk           = 5.0;            // Reward:Risk (TP = RR x risk)
input int                InpSLBufferPoints       = 0;              // Extra SL buffer below base low (points)
input int                InpExpiryBars           = 0;              // Cancel pending after N bars (0 = never)
input bool               InpCancelOnCloseBelowMA = true;           // Cancel pending if a candle closes below MA

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
ENUM_PHASE g_phase       = PHASE_WAIT_CROSS;
datetime   g_crossTime   = 0;
datetime   g_lastBarTime = 0;
string     g_lastEvent   = "";
const string OBJ_PREFIX  = "RBR_MA200_";

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpMAPeriod < 1 || InpRewardRisk <= 0.0)
     {
      Print("Invalid inputs: MA period must be >= 1 and Reward:Risk > 0");
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

   g_phase     = PHASE_WAIT_CROSS;
   g_lastEvent = "Started - waiting for PHASE 1";
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

   if(!IsNewBar())
      return;

   //--- closed candles: [1] = last closed, [2], [3] = before it
   MqlRates rates[];
   double   ma[];
   ArraySetAsSeries(rates, true);
   ArraySetAsSeries(ma, true);

   if(CopyRates(_Symbol, InpTimeframe, 0, 4, rates) < 4)
      return;
   if(CopyBuffer(g_maHandle, 0, 0, 4, ma) < 4)
      return;

   bool closedBelowMA = rates[1].close < ma[1];

   //--- cancel pending orders when trend is lost
   if(InpCancelOnCloseBelowMA && closedBelowMA)
      DeleteOurPendingOrders("candle closed below MA");

   //--- reset PHASE 1 when price closes back below the MA
   if(g_phase == PHASE_WAIT_RBR && InpResetOnCloseBelowMA && closedBelowMA)
     {
      g_phase     = PHASE_WAIT_CROSS;
      g_lastEvent = "Closed back below MA - PHASE 1 reset";
      Print(g_lastEvent);
     }

   //--- PHASE 1: first close above MA coming from below
   if(rates[2].close < ma[2] && rates[1].close > ma[1])
     {
      g_phase     = PHASE_WAIT_RBR;
      g_crossTime = rates[1].time;
      g_lastEvent = "PHASE 1 passed at " + TimeToString(g_crossTime) + " - waiting for Rally-Base-Rally";
      Print(g_lastEvent);
     }

   //--- PHASE 2: Rally-Base-Rally after the cross
   if(g_phase == PHASE_WAIT_RBR)
      CheckRallyBaseRally(rates);

   UpdateComment();
  }

//+------------------------------------------------------------------+
//| PHASE 2 check on the last three closed candles                   |
//+------------------------------------------------------------------+
void CheckRallyBaseRally(const MqlRates &rates[])
  {
   MqlRates rally1 = rates[3];
   MqlRates base   = rates[2];
   MqlRates rally2 = rates[1];

   //--- pattern must form after the cross
   if(InpAllowCrossAsRally ? (rally1.time < g_crossTime) : (rally1.time <= g_crossTime))
      return;

   if(!IsBullish(rally1) || !IsBearish(base) || !IsBullish(rally2))
      return;

   double baseSize = CandleSize(base);
   bool r1Longer   = CandleSize(rally1) > baseSize;
   bool r2Longer   = CandleSize(rally2) > baseSize;
   bool sizeOk     = InpBothRalliesLonger ? (r1Longer && r2Longer) : (r1Longer || r2Longer);
   if(!sizeOk)
      return;

   //--- base zone: open (top) to close (bottom) of the bearish base candle
   double zoneTop    = base.open;
   double zoneBottom = base.close;
   double entry;
   switch(InpEntryLevel)
     {
      case ENTRY_ZONE_MID:    entry = (zoneTop + zoneBottom) / 2.0; break;
      case ENTRY_ZONE_BOTTOM: entry = zoneBottom;                    break;
      default:                entry = zoneTop;                       break;
     }
   double sl = base.low - InpSLBufferPoints * _Point;

   entry = NormalizePrice(entry);
   sl    = NormalizePrice(sl);
   double risk = entry - sl;
   if(risk <= 0.0)
      return;
   double tp = NormalizePrice(entry + InpRewardRisk * risk);

   g_lastEvent = "PHASE 2 passed - base zone " + DoubleToString(zoneBottom, _Digits) +
                 " - " + DoubleToString(zoneTop, _Digits);
   Print(g_lastEvent);

   if(InpDrawZones)
      DrawZone(base.time, zoneTop, zoneBottom, sl, tp);

   if(InpOneTradeAtATime && (CountOurPositions() > 0 || CountOurPendingOrders() > 0))
     {
      g_lastEvent += " | skipped: trade already open";
      Print("Setup skipped: a position or pending order already exists");
      return;
     }

   //--- only place the buy limit if price has not reached the zone yet
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= entry)
     {
      g_lastEvent += " | skipped: price already in zone";
      Print("Setup skipped: price already touched the zone (Ask ", DoubleToString(ask, _Digits), ")");
      return;
     }

   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(ask - entry < minDist || risk < minDist || tp - entry < minDist)
     {
      g_lastEvent += " | skipped: too close to price (stops level)";
      Print("Setup skipped: entry/SL/TP violate broker stops level");
      return;
     }

   double lots = CalcLots(entry, sl);
   if(lots <= 0.0)
     {
      g_lastEvent += " | skipped: invalid lot size";
      return;
     }

   if(g_trade.BuyLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpComment))
     {
      g_lastEvent = StringFormat("BUY LIMIT %.2f @ %s  SL %s  TP %s", lots,
                                 DoubleToString(entry, _Digits),
                                 DoubleToString(sl, _Digits),
                                 DoubleToString(tp, _Digits));
      Print(g_lastEvent);
      //--- setup consumed: wait for the next cross
      g_phase = PHASE_WAIT_CROSS;
     }
   else
     {
      g_lastEvent = "BuyLimit failed: " + g_trade.ResultRetcodeDescription();
      Print(g_lastEvent);
     }
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, InpTimeframe, 0);
   if(t == 0 || t == g_lastBarTime)
      return false;
   g_lastBarTime = t;
   return true;
  }

bool IsBullish(const MqlRates &r) { return r.close > r.open; }
bool IsBearish(const MqlRates &r) { return r.close < r.open; }

double CandleSize(const MqlRates &r)
  {
   return (InpSizeMode == SIZE_BODY) ? MathAbs(r.close - r.open) : (r.high - r.low);
  }

double NormalizePrice(double price)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick > 0.0)
      price = MathRound(price / tick) * tick;
   return NormalizeDouble(price, _Digits);
  }

double CalcLots(double entry, double sl)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lots = InpFixedLots;
   if(InpLotMode == LOT_RISK_PERCENT)
     {
      double lossPerLot = 0.0;
      if(!OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, entry, sl, lossPerLot) || lossPerLot >= 0.0)
        {
         Print("Could not calculate risk per lot, error ", GetLastError());
         return 0.0;
        }
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      lots = riskMoney / MathAbs(lossPerLot);
     }

   if(stepLot > 0.0)
      lots = MathFloor(lots / stepLot) * stepLot;
   if(lots < minLot)
     {
      Print("Lot size ", lots, " below broker minimum ", minLot);
      return 0.0;
     }
   return NormalizeDouble(MathMin(lots, maxLot), 2);
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

void DeleteOurPendingOrders(const string reason)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
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

void DrawZone(datetime baseTime, double top, double bottom, double sl, double tp)
  {
   string   name = OBJ_PREFIX + TimeToString(baseTime, TIME_DATE | TIME_MINUTES);
   datetime t2   = baseTime + 30 * PeriodSeconds(InpTimeframe);

   ObjectDelete(0, name);
   if(ObjectCreate(0, name, OBJ_RECTANGLE, 0, baseTime, top, t2, bottom))
     {
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetString(0, name, OBJPROP_TOOLTIP,
                      StringFormat("RBR zone\nSL %s\nTP %s",
                                   DoubleToString(sl, _Digits), DoubleToString(tp, _Digits)));
     }
   ChartRedraw();
  }

void UpdateComment()
  {
   string phase = (g_phase == PHASE_WAIT_CROSS)
                  ? "Waiting for PHASE 1 (close above MA" + (string)InpMAPeriod + ")"
                  : "PHASE 1 passed (" + TimeToString(g_crossTime) + ") - waiting for PHASE 2 (Rally-Base-Rally)";
   Comment("RBR MA", InpMAPeriod, " EA  [", EnumToString(InpTimeframe), "]\n",
           "State: ", phase, "\n",
           "Last:  ", g_lastEvent);
  }
//+------------------------------------------------------------------+
