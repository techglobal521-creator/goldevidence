//+------------------------------------------------------------------+
//| GE_DataAudit.mq5 - Module 0 data audit                           |
//| Run on the chart of the symbol to audit (XAUUSD or XAUUSDc).     |
//| Writes to MQL5\Files\GoldEvidence\:                              |
//|   audit_spec.txt        symbol spec, account, server-vs-GMT      |
//|   audit_ticks_daily.csv tick count + spread stats per day        |
//|   audit_spread_hour.csv median / p90 spread by server hour       |
//|   audit_atr_monthly.csv median ATR(14) on M5 / M15 / H1 by month |
//|   audit_sizing.csv      does a 0.5% risk budget fit 1x/1.5x/2x   |
//|                         ATR(M5) stops at minimum volume?         |
//| Downloading multi-year real ticks can take a long time.          |
//+------------------------------------------------------------------+
#property script_show_inputs
#property version "1.00"

input datetime InpFrom    = D'2022.01.01 00:00';  // Audit from (server time)
input datetime InpTo      = D'2026.10.31 00:00';  // Audit to
input double   InpEquity  = 0;                    // Equity for sizing check (0 = this account's equity)
input double   InpRiskPct = 0.5;                  // Risk % for sizing check
input double   InpSlip    = 0.30;                 // Slippage buffer (price units)

#define GE_BINS 3001
string Dir = "GoldEvidence";
int    gHist[24][GE_BINS];     // spread histogram per server hour, in points

double HistPercentile(const int hour, const double q, const double pt)
  {
   long total = 0;
   for(int b = 0; b < GE_BINS; b++) total += gHist[hour][b];
   if(total == 0) return -1;
   long target = (long)MathCeil(q * total), run = 0;
   for(int b = 0; b < GE_BINS; b++) { run += gHist[hour][b]; if(run >= target) return b * pt; }
   return (GE_BINS - 1) * pt;
  }

double MedianOf(double &v[])
  {
   int n = ArraySize(v);
   if(n == 0) return 0;
   ArraySort(v);
   return n % 2 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2.0;
  }

bool WaitCalculated(const int h)
  {
   for(int i = 0; i < 300; i++) { if(BarsCalculated(h) > 0) return true; Sleep(100); }
   return false;
  }

void OnStart()
  {
   string sym = _Symbol;
   FolderCreate(Dir);
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   ArrayInitialize(gHist, 0);

   //--- 1. specification ---------------------------------------------------------------
   int hs = FileOpen(Dir + "\\audit_spec.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(hs == INVALID_HANDLE) { Print("cannot write audit_spec.txt"); return; }
   FileWriteString(hs, StringFormat("symbol=%s\r\ncontract_size=%.4f\r\nvolume_min=%.4f\r\nvolume_step=%.4f\r\nvolume_max=%.2f\r\n",
                   sym, SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE), SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN),
                   SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP), SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX)));
   FileWriteString(hs, StringFormat("digits=%d\r\npoint=%g\r\ntick_size=%g\r\ntick_value=%g\r\nstops_level_points=%d\r\nfreeze_level_points=%d\r\n",
                   (int)SymbolInfoInteger(sym, SYMBOL_DIGITS), pt, SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE),
                   SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE), (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL),
                   (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL)));
   FileWriteString(hs, StringFormat("account_currency=%s\r\nleverage=%I64d\r\nequity=%.2f\r\nserver_time=%s\r\ngmt_time=%s\r\nserver_minus_gmt_hours=%.1f\r\n",
                   AccountInfoString(ACCOUNT_CURRENCY), AccountInfoInteger(ACCOUNT_LEVERAGE), AccountInfoDouble(ACCOUNT_EQUITY),
                   TimeToString(TimeTradeServer(), TIME_DATE | TIME_SECONDS), TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS),
                   (double)(TimeTradeServer() - TimeGMT()) / 3600.0));
   FileClose(hs);
   Print("GE audit: spec written");

   //--- 2. ticks per day + spread histogram per hour -----------------------------------
   int hd = FileOpen(Dir + "\\audit_ticks_daily.csv", FILE_WRITE | FILE_TXT | FILE_ANSI);
   FileWriteString(hd, "date,weekday,ticks,spread_mean,spread_max,first_tick,last_tick,flag\r\n");
   for(datetime d = InpFrom; d < InpTo; d += 86400)
     {
      MqlDateTime s;
      TimeToStruct(d, s);
      MqlTick ticks[];
      ulong fromMs = (ulong)d * 1000, toMs = (ulong)(d + 86400) * 1000 - 1;
      int n = CopyTicksRange(sym, ticks, COPY_TICKS_INFO, fromMs, toMs);
      string flag = "";
      if(n <= 0)
        {
         if(s.day_of_week >= 1 && s.day_of_week <= 5) flag = "NO_TICKS_WEEKDAY";
         if(flag != "") FileWriteString(hd, StringFormat("%s,%d,0,,,,,%s\r\n", TimeToString(d, TIME_DATE), s.day_of_week, flag));
         continue;
        }
      double sum = 0, mx = 0;
      for(int i = 0; i < n; i++)
        {
         if(ticks[i].ask <= 0 || ticks[i].bid <= 0) continue;
         double sp = ticks[i].ask - ticks[i].bid;
         sum += sp; mx = MathMax(mx, sp);
         MqlDateTime ts;
         TimeToStruct(ticks[i].time, ts);
         int bin = (int)MathMin(GE_BINS - 1, MathMax(0, MathRound(sp / pt)));
         gHist[ts.hour][bin]++;
        }
      if(n < 1000 && s.day_of_week >= 1 && s.day_of_week <= 5) flag = "LOW_TICKS";
      FileWriteString(hd, StringFormat("%s,%d,%d,%.4f,%.4f,%s,%s,%s\r\n", TimeToString(d, TIME_DATE), s.day_of_week, n, sum / n, mx,
                      TimeToString(ticks[0].time, TIME_MINUTES), TimeToString(ticks[n - 1].time, TIME_MINUTES), flag));
      if(s.day == 1) PrintFormat("GE audit: ticks processed through %s", TimeToString(d, TIME_DATE));
     }
   FileClose(hd);

   int hh = FileOpen(Dir + "\\audit_spread_hour.csv", FILE_WRITE | FILE_TXT | FILE_ANSI);
   FileWriteString(hh, "server_hour,spread_p50,spread_p90,spread_p99\r\n");
   for(int h = 0; h < 24; h++)
      FileWriteString(hh, StringFormat("%d,%.4f,%.4f,%.4f\r\n", h, HistPercentile(h, 0.50, pt), HistPercentile(h, 0.90, pt), HistPercentile(h, 0.99, pt)));
   FileClose(hh);
   Print("GE audit: tick and spread files written");

   //--- 3. ATR by month ---------------------------------------------------------------
   int hA5 = iATR(sym, PERIOD_M5, 14), hA15 = iATR(sym, PERIOD_M15, 14), hAH1 = iATR(sym, PERIOD_H1, 14);
   if(!WaitCalculated(hA5) || !WaitCalculated(hA15) || !WaitCalculated(hAH1)) { Print("ATR not calculated"); return; }
   int ha = FileOpen(Dir + "\\audit_atr_monthly.csv", FILE_WRITE | FILE_TXT | FILE_ANSI);
   int hz = FileOpen(Dir + "\\audit_sizing.csv", FILE_WRITE | FILE_TXT | FILE_ANSI);
   FileWriteString(ha, "month,atr_m5_median,atr_m15_median,atr_h1_median,close_last\r\n");
   FileWriteString(hz, "month,atr_m5,risk_budget,sl_mult,sl_dist,loss_at_min_volume,feasible,lots_at_budget\r\n");

   double eq    = InpEquity > 0 ? InpEquity : AccountInfoDouble(ACCOUNT_EQUITY);
   double budget = eq * InpRiskPct / 100.0;
   double vmin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), vstep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double price = SymbolInfoDouble(sym, SYMBOL_BID);
   double mults[3] = {1.0, 1.5, 2.0};

   for(datetime m = InpFrom; m < InpTo; )
     {
      MqlDateTime s;
      TimeToStruct(m, s);
      s.mon += 1; if(s.mon > 12) { s.mon = 1; s.year++; }
      s.day = 1; s.hour = 0; s.min = 0; s.sec = 0;
      datetime next = StructToTime(s);
      double a5[], a15[], aH1[];
      if(CopyBuffer(hA5, 0, m, next - 1, a5) <= 0) { m = next; continue; }
      CopyBuffer(hA15, 0, m, next - 1, a15);
      CopyBuffer(hAH1, 0, m, next - 1, aH1);
      double m5 = MedianOf(a5), m15 = MedianOf(a15), mh1 = MedianOf(aH1);
      MqlRates r[];
      double lastClose = CopyRates(sym, PERIOD_D1, m, next - 1, r) > 0 ? r[ArraySize(r) - 1].close : 0;
      string mon = TimeToString(m, TIME_DATE);
      mon = StringSubstr(mon, 0, 7);
      FileWriteString(ha, StringFormat("%s,%.3f,%.3f,%.3f,%.2f\r\n", mon, m5, m15, mh1, lastClose));

      for(int k = 0; k < 3; k++)
        {
         double dist = mults[k] * m5 + 0.2 * m5;              // SL incl. structural buffer
         double p = 0;
         if(!OrderCalcProfit(ORDER_TYPE_BUY, sym, vmin, price, price - dist, p)) continue;
         double lossMin = MathAbs(p) * (dist + InpSlip) / dist;
         double perLot = lossMin / vmin;
         double lots = MathFloor(budget / perLot / vstep + 1e-9) * vstep;
         FileWriteString(hz, StringFormat("%s,%.3f,%.2f,%.1f,%.3f,%.2f,%s,%.2f\r\n", mon, m5, budget, mults[k], dist, lossMin,
                         lossMin <= budget ? "YES" : "NO", lots));
        }
      m = next;
     }
   FileClose(ha);
   FileClose(hz);
   IndicatorRelease(hA5); IndicatorRelease(hA15); IndicatorRelease(hAH1);
   PrintFormat("GE audit complete. Files in MQL5\\Files\\%s\\ (equity used for sizing: %.2f %s)", Dir, eq, AccountInfoString(ACCOUNT_CURRENCY));
  }
