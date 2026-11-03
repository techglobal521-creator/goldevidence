//+------------------------------------------------------------------+
//| EvidenceGold_v3.mq5                                              |
//| Setup B only: H1 Donchian-48 breakout, D1 SMA200 trend filter,   |
//| 2xATR(14) stop, opposite Donchian-24 exit, 120 h time stop.      |
//| Independent risk engine. No AI, no external dependencies.        |
//| Spec: project doc claude/v3.1-spec.md (2026-11-03)               |
//+------------------------------------------------------------------+
#property copyright "GoldEvidence"
#property version   "3.00"

#include <Trade\Trade.mqh>

//--- Strategy (must match the validated Python Setup B; do not optimise)
input group "Setup B (fixed - reproduction parameters)"
input int     InpEntryLookback   = 48;    // Entry channel (H1 bars)
input int     InpExitLookback    = 24;    // Exit channel (H1 bars)
input int     InpAtrPeriod       = 14;    // ATR period (H1)
input double  InpAtrStopMult     = 2.0;   // Stop = mult x ATR
input int     InpTrendMaPeriod   = 200;   // D1 SMA period
input int     InpMaxHoldHours    = 120;   // Time stop (hours since entry)
input double  InpSafetyTP_R      = 8.0;   // Safety TP in R (exit is channel/time)
input bool    InpAllowShorts     = true;  // Shorts were positive in research

//--- Risk engine
input group "Risk engine"
input double  InpRiskPct         = 0.5;   // Risk per trade, % of equity
input double  InpDailyLossPct    = 1.0;   // Block new entries after this daily loss
input double  InpWeeklyLossPct   = 3.0;   // Block new entries after this weekly loss
input double  InpReviewDDPct     = 12.0;  // Peak-to-equity DD: review flag (log only)
input double  InpHardStopDDPct   = 20.0;  // Peak-to-equity DD: stop trading permanently
input int     InpPerfWindow      = 50;    // Rolling trades for performance stop
input double  InpPerfMinMeanR    = -0.10; // Stop if rolling mean R below this
input int     InpMaxTradesPerDay = 5;

//--- Filters
input group "Filters"
input double  InpMaxSpreadFrac   = 0.10;  // Max spread as fraction of stop distance
input int     InpMaxSpreadPts    = 600;   // Absolute max spread (points)
input bool    InpUseERFilter     = false; // Pre-registered regime filter (walk-forward only)
input int     InpERPeriod        = 20;    // Efficiency ratio period (D1)
input double  InpERMin           = 0.15;  // No entry below this ER

//--- Misc
input group "Misc"
input long    InpMagic           = 30031103;
input string  InpJournalFile     = "GoldEvidence_v3_journal.csv";
input int     InpSlippagePts     = 50;

CTrade   trade;
int      hAtr = INVALID_HANDLE;
int      hMa  = INVALID_HANDLE;
datetime lastBarTime = 0;
string   gvPrefix;
double   rHistory[];
bool     loggedReview = false;

//+------------------------------------------------------------------+
//| Helpers: global-variable persistence                             |
//+------------------------------------------------------------------+
double GVGet(const string k, const double def)
  {
   string n = gvPrefix + k;
   if(GlobalVariableCheck(n)) return GlobalVariableGet(n);
   return def;
  }
void GVSet(const string k, const double v) { GlobalVariableSet(gvPrefix + k, v); }

//+------------------------------------------------------------------+
//| Journal                                                          |
//+------------------------------------------------------------------+
void Journal(const string event, const string dir, const double price, const double sl,
             const double tp, const double vol, const double atr, const double riskMoney,
             const string note)
  {
   if(MQLInfoInteger(MQL_OPTIMIZATION)) return;
   int fh = FileOpen(InpJournalFile, FILE_COMMON|FILE_READ|FILE_WRITE|FILE_CSV|FILE_SHARE_READ|FILE_ANSI, ',');
   if(fh == INVALID_HANDLE) { Print("Journal open failed ", GetLastError()); return; }
   if(FileSize(fh) == 0)
      FileWrite(fh, "time","event","dir","price","sl","tp","volume","atr","risk_money","equity","note");
   FileSeek(fh, 0, SEEK_END);
   FileWrite(fh, TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES), event, dir,
             DoubleToString(price, _Digits), DoubleToString(sl, _Digits), DoubleToString(tp, _Digits),
             DoubleToString(vol, 2), DoubleToString(atr, _Digits), DoubleToString(riskMoney, 2),
             DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), note);
   FileClose(fh);
  }

//+------------------------------------------------------------------+
//| R history (persisted so restarts keep the performance stop)      |
//+------------------------------------------------------------------+
string RFile() { return "GoldEvidence_v3_R_" + IntegerToString(InpMagic) + ".csv"; }

void LoadRHistory()
  {
   ArrayResize(rHistory, 0);
   if(MQLInfoInteger(MQL_TESTER)) return;              // tester: always start clean
   int fh = FileOpen(RFile(), FILE_COMMON|FILE_READ|FILE_CSV|FILE_ANSI);
   if(fh == INVALID_HANDLE) return;
   while(!FileIsEnding(fh))
     {
      string s = FileReadString(fh);
      if(StringLen(s) == 0) continue;
      int n = ArraySize(rHistory);
      ArrayResize(rHistory, n + 1);
      rHistory[n] = StringToDouble(s);
     }
   FileClose(fh);
  }

void AppendR(const double r)
  {
   int n = ArraySize(rHistory);
   ArrayResize(rHistory, n + 1);
   rHistory[n] = r;
   if(MQLInfoInteger(MQL_TESTER)) return;
   int fh = FileOpen(RFile(), FILE_COMMON|FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(fh == INVALID_HANDLE) return;
   FileSeek(fh, 0, SEEK_END);
   FileWrite(fh, DoubleToString(r, 4));
   FileClose(fh);
  }

//+------------------------------------------------------------------+
//| Position lookup                                                  |
//+------------------------------------------------------------------+
bool GetOurPosition(ulong &ticket)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
        { ticket = t; return true; }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Day / week state                                                 |
//+------------------------------------------------------------------+
int DayKey(const datetime t)  { return (int)(t / 86400); }
int WeekKey(const datetime t)
  {
   MqlDateTime d; TimeToStruct(t, d);
   int dow = (d.day_of_week + 6) % 7;                  // Monday = 0
   return DayKey(t) - dow;
  }

void UpdateRiskState()
  {
   datetime now = TimeCurrent();
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if((int)GVGet("dayKey", -1) != DayKey(now))
     { GVSet("dayKey", DayKey(now)); GVSet("dayStartEq", eq); GVSet("tradesToday", 0); }
   if((int)GVGet("weekKey", -1) != WeekKey(now))
     { GVSet("weekKey", WeekKey(now)); GVSet("weekStartEq", eq); }
   if(eq > GVGet("peakEq", 0)) GVSet("peakEq", eq);
  }

// Returns "" if new entries are allowed, otherwise the reason.
string RiskGateReason()
  {
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double peak = GVGet("peakEq", eq);
   double dd   = peak > 0 ? 100.0 * (peak - eq) / peak : 0;

   if(GVGet("hardStop", 0) > 0) return "HARD_STOP_ACTIVE";
   if(dd >= InpHardStopDDPct)
     {
      GVSet("hardStop", 1);
      Journal("HARD_STOP", "", 0, 0, 0, 0, 0, 0, StringFormat("DD %.1f%% >= %.1f%%", dd, InpHardStopDDPct));
      return "HARD_STOP_DD";
     }
   if(dd >= InpReviewDDPct && !loggedReview)
     {
      loggedReview = true;
      Journal("REVIEW_FLAG", "", 0, 0, 0, 0, 0, 0, StringFormat("DD %.1f%%", dd));
     }

   int n = ArraySize(rHistory);
   if(n >= InpPerfWindow)
     {
      double s = 0;
      for(int i = n - InpPerfWindow; i < n; i++) s += rHistory[i];
      double mean = s / InpPerfWindow;
      if(mean < InpPerfMinMeanR)
        {
         GVSet("hardStop", 1);
         Journal("PERF_STOP", "", 0, 0, 0, 0, 0, 0, StringFormat("rolling mean %.3fR", mean));
         return "PERF_STOP";
        }
     }

   double dayStart = GVGet("dayStartEq", eq), weekStart = GVGet("weekStartEq", eq);
   if(dayStart > 0 && 100.0 * (dayStart - eq) / dayStart >= InpDailyLossPct)  return "DAILY_LOSS_LOCK";
   if(weekStart > 0 && 100.0 * (weekStart - eq) / weekStart >= InpWeeklyLossPct) return "WEEKLY_LOSS_LOCK";
   if((int)GVGet("tradesToday", 0) >= InpMaxTradesPerDay) return "MAX_TRADES_DAY";
   return "";
  }

//+------------------------------------------------------------------+
//| Indicator reads (bar 1 = last completed bar)                     |
//+------------------------------------------------------------------+
bool ReadBuf(const int h, const int shift, double &v)
  {
   double b[];
   if(CopyBuffer(h, 0, shift, 1, b) != 1) return false;
   v = b[0];
   return v > 0 && v != EMPTY_VALUE;
  }

double EfficiencyRatioD1()
  {
   double c[];
   ArraySetAsSeries(c, true);
   if(CopyClose(_Symbol, PERIOD_D1, 1, InpERPeriod + 1, c) != InpERPeriod + 1) return -1;
   double net = MathAbs(c[0] - c[InpERPeriod]), path = 0;
   for(int i = 0; i < InpERPeriod; i++) path += MathAbs(c[i] - c[i + 1]);
   return path > 0 ? net / path : 0;
  }

//+------------------------------------------------------------------+
//| Position sizing via OrderCalcProfit                              |
//+------------------------------------------------------------------+
double SizePosition(const ENUM_ORDER_TYPE type, const double price, const double sl,
                    const double riskMoney, double &lossAtVol, string &why)
  {
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double pnl;
   if(!OrderCalcProfit(type, _Symbol, vmin, price, sl, pnl)) { why = "CALC_PROFIT_FAILED"; return 0; }
   double lossMin = -pnl;
   if(lossMin <= 0) { why = "BAD_LOSS_CALC"; return 0; }
   if(lossMin > riskMoney)
     {
      why = StringFormat("MIN_LOT_OVER_BUDGET loss %.2f > budget %.2f", lossMin, riskMoney);
      return 0;
     }
   double vol = MathFloor((riskMoney / (lossMin / vmin)) / step) * step;
   vol = MathMax(vmin, MathMin(vol, vmax));
   if(!OrderCalcProfit(type, _Symbol, vol, price, sl, pnl)) { why = "CALC_PROFIT_FAILED"; return 0; }
   lossAtVol = -pnl;
   while(lossAtVol > riskMoney && vol - step >= vmin)   // never exceed budget
     {
      vol -= step;
      OrderCalcProfit(type, _Symbol, vol, price, sl, pnl);
      lossAtVol = -pnl;
     }
   if(lossAtVol > riskMoney) { why = "OVER_BUDGET_AFTER_ROUNDING"; return 0; }
   double margin;
   if(OrderCalcMargin(type, _Symbol, vol, price, margin) &&
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9)
     { why = "INSUFFICIENT_MARGIN"; return 0; }
   return NormalizeDouble(vol, 2);
  }

//+------------------------------------------------------------------+
//| Exit management on each new H1 bar                               |
//+------------------------------------------------------------------+
void ManagePosition(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;
   long     ptype  = PositionGetInteger(POSITION_TYPE);
   datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
   double   close1 = iClose(_Symbol, PERIOD_H1, 1);
   string   reason = "";

   if(TimeCurrent() - opened >= (long)InpMaxHoldHours * 3600) reason = "TIME_STOP";
   else if(ptype == POSITION_TYPE_BUY)
     {
      int idx = iLowest(_Symbol, PERIOD_H1, MODE_LOW, InpExitLookback, 2);
      if(idx >= 0 && close1 < iLow(_Symbol, PERIOD_H1, idx)) reason = "CHANNEL_EXIT";
     }
   else
     {
      int idx = iHighest(_Symbol, PERIOD_H1, MODE_HIGH, InpExitLookback, 2);
      if(idx >= 0 && close1 > iHigh(_Symbol, PERIOD_H1, idx)) reason = "CHANNEL_EXIT";
     }

   if(reason != "")
     {
      if(trade.PositionClose(ticket, InpSlippagePts))
         Journal("EXIT_REQ", ptype == POSITION_TYPE_BUY ? "BUY" : "SELL",
                 iClose(_Symbol, PERIOD_H1, 1), 0, 0, 0, 0, 0, reason);
      else
         Journal("EXIT_FAIL", "", 0, 0, 0, 0, 0, 0, reason + " rc=" + IntegerToString(trade.ResultRetcode()));
     }
  }

//+------------------------------------------------------------------+
//| Entry evaluation on each new H1 bar                              |
//+------------------------------------------------------------------+
void EvaluateEntry()
  {
   if(Bars(_Symbol, PERIOD_H1) < InpEntryLookback + 5) return;
   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   int hiIdx = iHighest(_Symbol, PERIOD_H1, MODE_HIGH, InpEntryLookback, 2);
   int loIdx = iLowest(_Symbol, PERIOD_H1, MODE_LOW, InpEntryLookback, 2);
   if(hiIdx < 0 || loIdx < 0) return;
   double chHigh = iHigh(_Symbol, PERIOD_H1, hiIdx);
   double chLow  = iLow(_Symbol, PERIOD_H1, loIdx);

   int dir = 0;
   if(close1 > chHigh) dir = 1;
   else if(close1 < chLow && InpAllowShorts) dir = -1;
   if(dir == 0) return;                                 // no signal, nothing to log
   string sdir = dir > 0 ? "BUY" : "SELL";

   double atr, ma, d1close = iClose(_Symbol, PERIOD_D1, 1);
   if(!ReadBuf(hAtr, 1, atr) || !ReadBuf(hMa, 1, ma) || d1close <= 0)
     { Journal("REJECT", sdir, close1, 0, 0, 0, 0, 0, "DATA_UNAVAILABLE"); return; }

   // D1 trend filter
   if(dir > 0 && d1close <= ma) { Journal("REJECT", sdir, close1, 0, 0, 0, atr, 0, "D1_BELOW_SMA200"); return; }
   if(dir < 0 && d1close >= ma) { Journal("REJECT", sdir, close1, 0, 0, 0, atr, 0, "D1_ABOVE_SMA200"); return; }

   // Optional pre-registered regime filter
   if(InpUseERFilter)
     {
      double er = EfficiencyRatioD1();
      if(er < InpERMin) { Journal("REJECT", sdir, close1, 0, 0, 0, atr, 0, StringFormat("ER %.3f < %.2f", er, InpERMin)); return; }
     }

   // Risk gate
   string gate = RiskGateReason();
   if(gate != "") { Journal("REJECT", sdir, close1, 0, 0, 0, atr, 0, gate); return; }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = dir > 0 ? ask : bid;
   double dist  = InpAtrStopMult * atr;

   // Spread filter
   double spread = ask - bid;
   long spreadPts = (long)MathRound(spread / _Point);
   if(spread > InpMaxSpreadFrac * dist || spreadPts > InpMaxSpreadPts)
     { Journal("REJECT", sdir, price, 0, 0, 0, atr, 0, StringFormat("SPREAD %d pts", spreadPts)); return; }

   double sl = NormalizeDouble(dir > 0 ? price - dist : price + dist, _Digits);
   double tp = NormalizeDouble(dir > 0 ? price + InpSafetyTP_R * dist : price - InpSafetyTP_R * dist, _Digits);

   long stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopsLvl > 0 && dist < stopsLvl * _Point)
     { Journal("REJECT", sdir, price, sl, tp, 0, atr, 0, "STOP_INSIDE_STOPS_LEVEL"); return; }

   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0;
   double loss = 0; string why = "";
   ENUM_ORDER_TYPE otype = dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double vol = SizePosition(otype, price, sl, riskMoney, loss, why);
   if(vol <= 0) { Journal("REJECT", sdir, price, sl, tp, 0, atr, riskMoney, why); return; }

   bool ok = dir > 0 ? trade.Buy(vol, _Symbol, 0, sl, tp, "GEv3 B long")
                     : trade.Sell(vol, _Symbol, 0, sl, tp, "GEv3 B short");
   if(ok && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_PLACED))
     {
      GVSet("tradesToday", GVGet("tradesToday", 0) + 1);
      GVSet("openRiskMoney", loss);                    // actual money at risk, for R calc
      Journal("ENTRY", sdir, trade.ResultPrice(), sl, tp, vol, atr, loss,
              StringFormat("ch %.2f/%.2f D1 %.2f vs SMA %.2f", chHigh, chLow, d1close, ma));
     }
   else
      Journal("ORDER_FAIL", sdir, price, sl, tp, vol, atr, loss, "rc=" + IntegerToString(trade.ResultRetcode()));
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpRiskPct <= 0 || InpRiskPct > 1.0) { Print("Risk must be in (0,1]%"); return INIT_PARAMETERS_INCORRECT; }
   gvPrefix = "GEv3_" + IntegerToString(InpMagic) + "_";
   if(MQLInfoInteger(MQL_TESTER)) GlobalVariablesDeleteAll(gvPrefix);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);

   hAtr = iATR(_Symbol, PERIOD_H1, InpAtrPeriod);
   hMa  = iMA(_Symbol, PERIOD_D1, InpTrendMaPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(hAtr == INVALID_HANDLE || hMa == INVALID_HANDLE) { Print("Indicator handle failed"); return INIT_FAILED; }

   LoadRHistory();
   UpdateRiskState();

   // Feasibility report: what does the minimum lot risk right now?
   double atr;
   if(ReadBuf(hAtr, 1, atr))
     {
      double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), pnl;
      double p = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, vmin, p, p - InpAtrStopMult * atr, pnl))
        {
         double eq = AccountInfoDouble(ACCOUNT_EQUITY);
         PrintFormat("Feasibility: ATR %.2f stop %.2f | min lot %.2f loses %.2f = %.2f%% of equity %.2f (budget %.2f%%) | contract %.2f",
                     atr, InpAtrStopMult * atr, vmin, -pnl, 100.0 * -pnl / eq, eq, InpRiskPct,
                     SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE));
        }
     }
   Journal("INIT", "", 0, 0, 0, 0, 0, 0, StringFormat("v3.00 risk %.2f%% magic %I64d", InpRiskPct, InpMagic));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hAtr != INVALID_HANDLE) IndicatorRelease(hAtr);
   if(hMa  != INVALID_HANDLE) IndicatorRelease(hMa);
  }

void OnTick()
  {
   datetime bt = iTime(_Symbol, PERIOD_H1, 0);
   if(bt == 0 || bt == lastBarTime) return;            // act once per completed H1 bar
   lastBarTime = bt;

   UpdateRiskState();
   ulong ticket;
   if(GetOurPosition(ticket)) ManagePosition(ticket);
   else                       EvaluateEntry();
  }

//+------------------------------------------------------------------+
//| Record R of each closed position                                 |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   long posId = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(!HistorySelectByPosition(posId)) return;
   double net = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
           + HistoryDealGetDouble(d, DEAL_COMMISSION);
     }
   double riskMoney = GVGet("openRiskMoney", 0);
   double r = riskMoney > 0 ? net / riskMoney : 0;
   AppendR(r);
   Journal("CLOSED", "", HistoryDealGetDouble(trans.deal, DEAL_PRICE), 0, 0,
           HistoryDealGetDouble(trans.deal, DEAL_VOLUME), 0, riskMoney,
           StringFormat("net %.2f R %.3f pos %I64d", net, r, posId));
  }
//+------------------------------------------------------------------+
