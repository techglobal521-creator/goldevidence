//+------------------------------------------------------------------+
//| Structure.mqh - confirmed swings, ZigZag filter, HH/HL logic      |
//|                                                                  |
//| A bar i is a swing high if High[i] > High[i+j] and High[i-j]     |
//| for j = 1..k. It is only known k bars later, so the newest bar   |
//| that can be a swing is index k+1. This prevents look-ahead.      |
//| A ZigZag-style filter keeps only swings that move at least       |
//| minMove (= m * ATR) from the previous opposite swing.            |
//+------------------------------------------------------------------+
#ifndef GE_STRUCTURE_MQH
#define GE_STRUCTURE_MQH

#include "Types.mqh"
#include "MarketData.mqh"

//--- push helper
void GEPushSwing(GESwing &arr[], const GESwing &s)
  {
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1, 64);
   arr[n] = s;
  }

//--- raw fractal swings, returned in CHRONOLOGICAL order (oldest first)
void GEFindRawSwings(const CGETimeframe &d, const int k, const int lookback, GESwing &out[])
  {
   ArrayResize(out, 0);
   int maxI = MathMin(lookback, d.loaded - k - 1);
   for(int i = maxI; i >= k + 1; i--)
     {
      bool isH = true, isL = true;
      for(int j = 1; j <= k; j++)
        {
         if(!(d.rates[i].high > d.rates[i + j].high && d.rates[i].high > d.rates[i - j].high)) isH = false;
         if(!(d.rates[i].low  < d.rates[i + j].low  && d.rates[i].low  < d.rates[i - j].low))  isL = false;
        }
      if(isH && isL) continue;            // outside bar: ambiguous order, skip
      GESwing s;
      s.time  = d.rates[i].time;
      s.index = i;
      if(isH) { s.price = d.rates[i].high; s.isHigh = true;  GEPushSwing(out, s); }
      if(isL) { s.price = d.rates[i].low;  s.isHigh = false; GEPushSwing(out, s); }
     }
  }

//--- alternate highs/lows and drop insignificant moves
void GEZigZag(const GESwing &raw[], const double minMove, GESwing &zz[])
  {
   ArrayResize(zz, 0);
   int n = ArraySize(raw);
   for(int i = 0; i < n; i++)
     {
      int m = ArraySize(zz);
      if(m == 0) { GEPushSwing(zz, raw[i]); continue; }
      if(raw[i].isHigh == zz[m - 1].isHigh)
        {
         //--- same type: keep the more extreme one
         if((raw[i].isHigh && raw[i].price > zz[m - 1].price) ||
            (!raw[i].isHigh && raw[i].price < zz[m - 1].price))
            zz[m - 1] = raw[i];
        }
      else
        {
         if(MathAbs(raw[i].price - zz[m - 1].price) >= minMove)
            GEPushSwing(zz, raw[i]);
        }
     }
  }

//--- classify structure from a ZigZag sequence.
//--- Bullish: HH and HL and no close below the last HL since it formed.
//--- Bearish: LH and LL and no close above the last LH since it formed.
void GEClassify(const CGETimeframe &d, const GESwing &zz[], GEStructure &st)
  {
   st.bias  = 0;
   st.valid = false;
   int hFound = 0, lFound = 0;
   for(int i = ArraySize(zz) - 1; i >= 0 && (hFound < 2 || lFound < 2); i--)
     {
      if(zz[i].isHigh)
        {
         if(hFound == 0) st.lastHigh = zz[i];
         else if(hFound == 1) st.prevHigh = zz[i];
         hFound++;
        }
      else
        {
         if(lFound == 0) st.lastLow = zz[i];
         else if(lFound == 1) st.prevLow = zz[i];
         lFound++;
        }
     }
   if(hFound < 2 || lFound < 2) return;
   st.valid = true;

   bool hh = st.lastHigh.price > st.prevHigh.price;
   bool hl = st.lastLow.price  > st.prevLow.price;
   bool lh = st.lastHigh.price < st.prevHigh.price;
   bool ll = st.lastLow.price  < st.prevLow.price;

   if(hh && hl)
     {
      bool broken = false;
      for(int i = st.lastLow.index - 1; i >= 1; i--)
         if(d.rates[i].close < st.lastLow.price) { broken = true; break; }
      if(!broken) st.bias = 1;
     }
   else if(lh && ll)
     {
      bool broken = false;
      for(int i = st.lastHigh.index - 1; i >= 1; i--)
         if(d.rates[i].close > st.lastHigh.price) { broken = true; break; }
      if(!broken) st.bias = -1;
     }
  }

//--- convenience: full pipeline for one timeframe
void GEAnalyseStructure(const CGETimeframe &d, const int k, const int lookback,
                        const double minMoveAtr, GESwing &zzOut[], GEStructure &st)
  {
   GESwing raw[];
   GEFindRawSwings(d, k, lookback, raw);
   GEZigZag(raw, minMoveAtr * d.atr[1], zzOut);
   GEClassify(d, zzOut, st);
  }

string GEBiasStr(const int b) { return b > 0 ? "BULLISH" : (b < 0 ? "BEARISH" : "NEUTRAL"); }

#endif
