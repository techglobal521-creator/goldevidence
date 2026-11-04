//+------------------------------------------------------------------+
//| Filters.mqh - environment filters (gate G2)                      |
//|   session window, Friday cut-off, spread, volatility percentile  |
//| All times are broker SERVER time (TimeCurrent()).                |
//| Exness server time must be verified in Module 0 (DataAudit).     |
//+------------------------------------------------------------------+
#ifndef GE_FILTERS_MQH
#define GE_FILTERS_MQH

int GEMinuteOfDay(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.hour * 60 + s.min;
  }

int GEDayOfWeek(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.day_of_week;   // 0 = Sunday
  }

datetime GEDayStart(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   s.hour = 0; s.min = 0; s.sec = 0;
   return StructToTime(s);
  }

//--- new entries allowed only inside [start, end) on Mon-Fri, earlier end on Friday
bool GESessionOk(const datetime t, const int startMin, const int endMin, const int fridayEndMin, string &why)
  {
   int dow = GEDayOfWeek(t);
   int m   = GEMinuteOfDay(t);
   if(dow == 0 || dow == 6) { why = "weekend"; return false; }
   if(m < startMin)         { why = StringFormat("before session start (%02d:%02d)", startMin / 60, startMin % 60); return false; }
   if(m >= endMin)          { why = StringFormat("after session end (%02d:%02d)", endMin / 60, endMin % 60); return false; }
   if(dow == 5 && m >= fridayEndMin) { why = "Friday cut-off"; return false; }
   return true;
  }

//--- true when open positions must be force-closed (pre-rollover, Friday close)
bool GEForceCloseTime(const datetime t, const int forceCloseMin, const int fridayCloseMin)
  {
   int dow = GEDayOfWeek(t);
   int m   = GEMinuteOfDay(t);
   if(m >= forceCloseMin) return true;
   if(dow == 5 && m >= fridayCloseMin) return true;
   return false;
  }

//--- median of an array (copy, sort)
double GEMedian(double &v[])
  {
   int n = ArraySize(v);
   if(n == 0) return 0.0;
   ArraySort(v);
   if(n % 2 == 1) return v[n / 2];
   return (v[n / 2 - 1] + v[n / 2]) / 2.0;
  }

//--- median M5 bar spread (price units) for the same hour-of-day over `bars` M5 bars.
//--- Note: MqlRates.spread is recorded by the broker per bar; its exact definition
//--- (e.g. minimum vs typical) varies, hence the generous multiplier applied by the caller.
//--- Returns -1 if fewer than minSamples samples (fail closed by caller).
double   gGESprMed = -1.0;
datetime gGESprHour = 0;
double GEHourlyMedianSpread(const string sym, const datetime now, const int bars, const int minSamples)
  {
   datetime hourKey = (datetime)((long)now - ((long)now % 3600));
   if(hourKey == gGESprHour) return gGESprMed;       // cached for the current clock hour
   gGESprHour = hourKey;
   gGESprMed  = -1.0;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int got = CopyRates(sym, PERIOD_M5, 1, bars, r);
   if(got <= 0) return -1.0;
   MqlDateTime sn;
   TimeToStruct(now, sn);
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   double v[];
   ArrayResize(v, 0, got / 24 + 16);
   for(int i = 0; i < got; i++)
     {
      MqlDateTime s;
      TimeToStruct(r[i].time, s);
      if(s.hour != sn.hour) continue;
      int n = ArraySize(v);
      ArrayResize(v, n + 1, got / 24 + 16);
      v[n] = r[i].spread * pt;
     }
   if(ArraySize(v) < minSamples) return -1.0;
   gGESprMed = GEMedian(v);
   return gGESprMed;
  }

//--- percentile (0..1) of the last closed ATR value within the trailing `bars` ATR values.
//--- The reference distribution is refreshed once per hour (it changes slowly) to keep
//--- multi-year backtests fast; the current value is always the last closed bar.
//--- Returns -1 on failure.
double   gGEAtrRef[];
datetime gGEAtrRefHour = 0;
double GEAtrPercentile(const int hATR, const int bars, const datetime now)
  {
   datetime hourKey = (datetime)((long)now - ((long)now % 3600));
   if(hourKey != gGEAtrRefHour || ArraySize(gGEAtrRef) == 0)
     {
      double a[];
      int got = CopyBuffer(hATR, 0, 2, bars, a);
      if(got < bars / 2) return -1.0;
      ArrayResize(gGEAtrRef, got);
      ArrayCopy(gGEAtrRef, a);
      gGEAtrRefHour = hourKey;
     }
   double cur[];
   if(CopyBuffer(hATR, 0, 1, 1, cur) != 1) return -1.0;
   int n = ArraySize(gGEAtrRef), below = 0;
   for(int i = 0; i < n; i++) if(gGEAtrRef[i] < cur[0]) below++;
   return (double)below / (double)n;
  }

#endif
