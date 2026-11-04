//+------------------------------------------------------------------+
//| Levels.mqh - support/resistance zones, breakout-retest detection  |
//|                                                                  |
//| Zones are clusters of confirmed swing points (H1 + M15) whose    |
//| prices lie within tol = 0.25*ATR(H1). Touches are counted as     |
//| distinct clock hours so one turning point seen on both H1 and    |
//| M15 is not double-counted. A zone needs >= 2 touches to be valid.|
//+------------------------------------------------------------------+
#ifndef GE_LEVELS_MQH
#define GE_LEVELS_MQH

#include "Types.mqh"
#include "MarketData.mqh"

void GEPushZone(GEZone &arr[], const GEZone &z)
  {
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1, 16);
   arr[n] = z;
  }

//--- build zones from two swing sequences
void GEBuildZones(const GESwing &a[], const GESwing &b[], const double tol, const double minWidth, GEZone &zones[])
  {
   ArrayResize(zones, 0);
   int na = ArraySize(a), nb = ArraySize(b), n = na + nb;
   if(n == 0) return;
   double   px[];
   datetime tm[];
   ArrayResize(px, n);
   ArrayResize(tm, n);
   for(int i = 0; i < na; i++) { px[i] = a[i].price; tm[i] = a[i].time; }
   for(int i = 0; i < nb; i++) { px[na + i] = b[i].price; tm[na + i] = b[i].time; }

   //--- simple insertion sort by price (n is small, < 200)
   for(int i = 1; i < n; i++)
     {
      double p = px[i]; datetime t = tm[i]; int j = i - 1;
      while(j >= 0 && px[j] > p) { px[j + 1] = px[j]; tm[j + 1] = tm[j]; j--; }
      px[j + 1] = p; tm[j + 1] = t;
     }

   int start = 0;
   for(int i = 1; i <= n; i++)
     {
      bool inCluster = (i < n) && (px[i] - px[start] <= tol);
      if(inCluster) continue;
      //--- cluster [start, i-1]
      GEZone z;
      z.low  = px[start];
      z.high = px[i - 1];
      //--- distinct hour buckets
      long buckets[];
      ArrayResize(buckets, 0);
      for(int k = start; k < i; k++)
        {
         long bkt = (long)tm[k] / 3600;
         bool seen = false;
         for(int q = 0; q < ArraySize(buckets); q++) if(buckets[q] == bkt) { seen = true; break; }
         if(!seen) { int s = ArraySize(buckets); ArrayResize(buckets, s + 1); buckets[s] = bkt; }
        }
      z.touches = ArraySize(buckets);
      if(z.high - z.low < minWidth)
        {
         double mid = (z.high + z.low) / 2.0;
         z.low  = mid - minWidth / 2.0;
         z.high = mid + minWidth / 2.0;
        }
      GEPushZone(zones, z);
      start = i;
     }
  }

//--- support (dir=+1) or resistance (dir=-1) touch by the pullback extreme.
//--- buy : ext in [low - 0.5*atr5, high + 0.1*atr5] and close1 > zone mid
//--- sell: ext in [low - 0.1*atr5, high + 0.5*atr5] and close1 < zone mid
int GEFindLevelTouch(const GEZone &zones[], const int dir, const double ext, const double close1,
                     const double atr5, const int minTouches)
  {
   int best = -1, bestTouches = 0;
   for(int i = 0; i < ArraySize(zones); i++)
     {
      if(zones[i].touches < minTouches) continue;
      double mid = (zones[i].low + zones[i].high) / 2.0;
      bool ok;
      if(dir > 0) ok = ext >= zones[i].low - 0.5 * atr5 && ext <= zones[i].high + 0.1 * atr5 && close1 > mid;
      else        ok = ext <= zones[i].high + 0.5 * atr5 && ext >= zones[i].low - 0.1 * atr5 && close1 < mid;
      if(ok && zones[i].touches > bestTouches) { best = i; bestTouches = zones[i].touches; }
     }
   return best;
  }

//--- breakout-retest.
//--- Breakout (buy): an M15 bar b (1..window) closes above zone.high + 0.2*atr15 with body >= 50% of range,
//---   and bar b+1 closed at/below zone.high (so b is the crossing bar).
//--- Invalidation: any later M15 close < zone.high - 0.2*atr15.
//--- Retest: M5 pullback low in [low - 0.5*atr5, high + 0.1*atr5], happened after the breakout,
//---   and the M5 trigger bar closes above zone.high.
int GEFindBreakoutRetest(const GEZone &zones[], const CGETimeframe &m15, const int dir,
                         const double ext, const datetime extTime, const double close1,
                         const double atr5, const int windowM15, const int minTouches)
  {
   double atr15 = m15.atr[1];
   for(int z = 0; z < ArraySize(zones); z++)
     {
      if(zones[z].touches < minTouches) continue;
      double lvl = dir > 0 ? zones[z].high : zones[z].low;
      for(int b = 1; b <= windowM15 && b + 1 < m15.loaded; b++)
        {
         double o = m15.rates[b].open, c = m15.rates[b].close;
         double rng = m15.rates[b].high - m15.rates[b].low;
         if(rng <= 0) continue;
         bool decisive = MathAbs(c - o) >= 0.5 * rng;
         bool crossed;
         if(dir > 0) crossed = c > lvl + 0.2 * atr15 && c > o && m15.rates[b + 1].close <= lvl;
         else        crossed = c < lvl - 0.2 * atr15 && c < o && m15.rates[b + 1].close >= lvl;
         if(!(crossed && decisive)) continue;

         bool invalid = false;
         for(int q = b - 1; q >= 1; q--)
           {
            if(dir > 0 && m15.rates[q].close < lvl - 0.2 * atr15) { invalid = true; break; }
            if(dir < 0 && m15.rates[q].close > lvl + 0.2 * atr15) { invalid = true; break; }
           }
         if(invalid) break;

         //--- the retest extreme must come after the breakout bar has closed
         if(extTime < m15.rates[b].time + PeriodSeconds(PERIOD_M15)) break;

         bool retest;
         if(dir > 0) retest = ext >= zones[z].low - 0.5 * atr5 && ext <= zones[z].high + 0.1 * atr5 && close1 > zones[z].high;
         else        retest = ext <= zones[z].high + 0.5 * atr5 && ext >= zones[z].low - 0.1 * atr5 && close1 < zones[z].low;
         if(retest) return z;
         break;   // only the most recent breakout of this zone counts
        }
     }
   return -1;
  }

//--- distance from entry to the nearest opposing zone (buy: zone.low above entry;
//--- sell: zone.high below entry). Returns -1 if none exists (e.g. at all-time highs).
double GENextOpposingDistance(const GEZone &zones[], const int dir, const double entry, const int minTouches)
  {
   double best = -1.0;
   for(int i = 0; i < ArraySize(zones); i++)
     {
      if(zones[i].touches < minTouches) continue;
      double d;
      if(dir > 0) { if(zones[i].low <= entry) continue; d = zones[i].low - entry; }
      else        { if(zones[i].high >= entry) continue; d = entry - zones[i].high; }
      if(best < 0 || d < best) best = d;
     }
   return best;
  }

#endif
