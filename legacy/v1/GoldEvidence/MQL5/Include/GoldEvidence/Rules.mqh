//+------------------------------------------------------------------+
//| Rules.mqh - mandatory gates G3..G10 (direction-generic)          |
//| dir = +1 BUY, -1 SELL. Every gate is boolean; the first failure  |
//| stops evaluation and is reported. No weighted scoring.           |
//| All values are read from CLOSED bars (index >= 1).               |
//+------------------------------------------------------------------+
#ifndef GE_RULES_MQH
#define GE_RULES_MQH

#include "Types.mqh"
#include "MarketData.mqh"
#include "Structure.mqh"
#include "Levels.mqh"

struct GERuleParams
  {
   double            h1SlopeMin;        // min |EMA50 slope| over 5 bars, in ATR(H1)
   int               pullbackLookback;  // M5 bars searched for the impulse extreme
   double            pullbackMinAtr;    // 0.5
   double            pullbackMaxAtr;    // 2.5
   int               pullbackMaxAge;    // pullback extreme must be within last N bars (3)
   double            rsiM5Max;          // 70 (buy) -> 30 for sell
   int               rsiCrossBars;      // 3
   double            triggerMaxRangeAtr;// 2.0
   double            slBufferAtr;       // 0.2
   double            slMinAtr;          // 0.75
   double            slMaxAtr;          // 2.5
   double            rr;                // 2.0
   double            maxSpreadFracSL;   // 0.10
   int               minTouches;        // 2
   int               retestWindowM15;   // 12 M15 bars = 3 hours
   bool              useG4, useG5, useG6, useG7, useG8, useG9;  // ablation switches (all true by default)
  };

bool GEBetter(const double a, const double b, const int dir) { return dir > 0 ? a > b : a < b; }

//--- G3: H1 bias. Returns +1/-1 when ALL bullish/bearish conditions hold, else 0.
int GEH1Bias(const CGETimeframe &h1, const GEStructure &st, const double slopeMin, string &detail)
  {
   double slope = (h1.ema50[1] - h1.ema50[6]) / h1.atr[1];
   detail = StringFormat("h1 struct=%s e20=%.2f e50=%.2f e200=%.2f close=%.2f slope=%.3f rsi=%.1f",
                         GEBiasStr(st.bias), h1.ema20[1], h1.ema50[1], h1.ema200[1], h1.rates[1].close, slope, h1.rsi[1]);
   if(!st.valid) { detail += " | not enough swings"; return 0; }
   for(int dir = 1; dir >= -1; dir -= 2)
     {
      if(st.bias != dir) continue;
      bool stack  = GEBetter(h1.ema20[1], h1.ema50[1], dir) && GEBetter(h1.ema50[1], h1.ema200[1], dir);
      bool above  = GEBetter(h1.rates[1].close, h1.ema200[1], dir);
      bool sloped = dir > 0 ? slope >= slopeMin : slope <= -slopeMin;
      bool mom    = GEBetter(h1.rsi[1], 50.0, dir);
      if(stack && above && sloped && mom) return dir;
      detail += StringFormat(" | stack=%d side=%d slope=%d rsi=%d", (int)stack, (int)above, (int)sloped, (int)mom);
     }
   return 0;
  }

//--- G4: M15 confirmation
bool GEM15Confirm(const CGETimeframe &m15, const GEStructure &st, const int dir, string &detail)
  {
   bool side   = GEBetter(m15.rates[1].close, m15.ema50[1], dir);
   bool stack  = GEBetter(m15.ema20[1], m15.ema50[1], dir);
   bool notOpp = st.valid && st.bias != -dir;
   //--- last opposite swing not broken by a close
   bool intact = false;
   if(st.valid)
     {
      int    refIdx   = dir > 0 ? st.lastLow.index : st.lastHigh.index;
      double refPrice = dir > 0 ? st.lastLow.price : st.lastHigh.price;
      intact = true;
      for(int i = refIdx - 1; i >= 1; i--)
         if((dir > 0 && m15.rates[i].close < refPrice) || (dir < 0 && m15.rates[i].close > refPrice)) { intact = false; break; }
     }
   bool mom = GEBetter(m15.rsi[1], 50.0, dir);
   detail = StringFormat("m15 struct=%s side=%d stack=%d intact=%d rsi=%.1f", GEBiasStr(st.bias), (int)side, (int)stack, (int)intact, m15.rsi[1]);
   return side && stack && notOpp && intact && mom;
  }

//--- G5: M5 pullback. Fills ext (pullback low for buy / rally high for sell) and its time.
bool GEM5Pullback(const CGETimeframe &m5, const GESwing &zz5[], const int dir, const GERuleParams &p,
                  double &ext, datetime &extTime, double &depthAtr, string &detail)
  {
   double atr5 = m5.atr[1];
   int L = MathMin(p.pullbackLookback, m5.loaded - 2);
   //--- impulse extreme in trend direction
   int ie = 1;
   for(int i = 2; i <= L; i++) if(GEBetter(dir > 0 ? m5.rates[i].high : m5.rates[i].low,
                                            dir > 0 ? m5.rates[ie].high : m5.rates[ie].low, dir)) ie = i;
   if(ie < 2) { detail = "impulse extreme is the trigger bar (no pullback)"; return false; }
   double impulse = dir > 0 ? m5.rates[ie].high : m5.rates[ie].low;
   //--- pullback extreme after the impulse
   int pe = 1;
   for(int i = 2; i <= ie - 1; i++)
     {
      double v  = dir > 0 ? m5.rates[i].low : m5.rates[i].high;
      double vb = dir > 0 ? m5.rates[pe].low : m5.rates[pe].high;
      if(GEBetter(vb, v, dir)) pe = i;   // buy: lower low wins; sell: higher high wins
     }
   ext     = dir > 0 ? m5.rates[pe].low : m5.rates[pe].high;
   extTime = m5.rates[pe].time;
   depthAtr = MathAbs(impulse - ext) / atr5;
   detail = StringFormat("impulse=%.2f@%d ext=%.2f@%d depth=%.2fATR", impulse, ie, ext, pe, depthAtr);
   if(pe > p.pullbackMaxAge) { detail += " | pullback extreme too old"; return false; }
   if(depthAtr < p.pullbackMinAtr || depthAtr > p.pullbackMaxAtr) { detail += " | depth out of range"; return false; }

   //--- last M5 swing (HL for buy / LH for sell) formed before the impulse must hold on closes
   double ref = 0; bool found = false;
   for(int i = ArraySize(zz5) - 1; i >= 0; i--)
     {
      if(zz5[i].index <= ie) continue;                      // must precede the impulse extreme
      if(dir > 0 && !zz5[i].isHigh) { ref = zz5[i].price; found = true; break; }
      if(dir < 0 &&  zz5[i].isHigh) { ref = zz5[i].price; found = true; break; }
     }
   if(!found) { detail += " | no prior M5 swing for structure"; return false; }
   for(int i = ie; i >= 1; i--)
      if((dir > 0 && m5.rates[i].close < ref) || (dir < 0 && m5.rates[i].close > ref))
        { detail += StringFormat(" | close broke M5 swing %.2f", ref); return false; }
   detail += StringFormat(" ref_swing=%.2f", ref);
   return true;
  }

//--- G7: momentum on M5
bool GEM5Momentum(const CGETimeframe &m5, const int dir, const GERuleParams &p, string &detail)
  {
   bool crossed = false;
   for(int j = 1; j <= p.rsiCrossBars; j++)
     {
      if(dir > 0 && m5.rsi[j] > 50.0 && m5.rsi[j + 1] <= 50.0) crossed = true;
      if(dir < 0 && m5.rsi[j] < 50.0 && m5.rsi[j + 1] >= 50.0) crossed = true;
     }
   bool rising = dir > 0 ? (m5.rsi[1] >= 50.0 && m5.rsi[1] > m5.rsi[2]) : (m5.rsi[1] <= 50.0 && m5.rsi[1] < m5.rsi[2]);
   bool notExhausted = dir > 0 ? m5.rsi[1] <= p.rsiM5Max : m5.rsi[1] >= 100.0 - p.rsiM5Max;
   detail = StringFormat("rsi5=%.1f prev=%.1f crossed=%d rising=%d", m5.rsi[1], m5.rsi[2], (int)crossed, (int)rising);
   return (crossed || rising) && notExhausted;
  }

//--- G8: trigger candle on the last closed M5 bar
bool GEM5Trigger(const CGETimeframe &m5, const int dir, const GERuleParams &p, string &name, string &detail)
  {
   double o = m5.rates[1].open, h = m5.rates[1].high, l = m5.rates[1].low, c = m5.rates[1].close;
   double po = m5.rates[2].open, ph = m5.rates[2].high, pl = m5.rates[2].low, pc = m5.rates[2].close;
   double range = h - l, body = MathAbs(c - o);
   name = "";
   detail = StringFormat("range=%.2f body=%.2f atr=%.2f", range, body, m5.atr[1]);
   if(range <= 0) { detail += " | zero range"; return false; }
   if(range > p.triggerMaxRangeAtr * m5.atr[1]) { detail += " | trigger bar too large"; return false; }
   if(dir > 0)
     {
      double lowerWick = MathMin(o, c) - l;
      if(c > o && body >= 0.5 * range && pc < po && c > po && o <= pc) name = "ENGULFING";
      else if(lowerWick >= 2.0 * body && lowerWick >= 0.5 * range && c >= l + range * 2.0 / 3.0) name = "REJECTION";
      else if(c > ph && body >= 0.6 * range && c > o) name = "MOMENTUM";
     }
   else
     {
      double upperWick = h - MathMax(o, c);
      if(c < o && body >= 0.5 * range && pc > po && c < po && o >= pc) name = "ENGULFING";
      else if(upperWick >= 2.0 * body && upperWick >= 0.5 * range && c <= l + range / 3.0) name = "REJECTION";
      else if(c < pl && body >= 0.6 * range && c < o) name = "MOMENTUM";
     }
   detail += " trigger=" + (name == "" ? "none" : name);
   return name != "";
  }

//--- G10: trade geometry. entry = ask (buy) / bid (sell)
bool GEGeometry(GECandidate &c, const double structuralExt, const double spread, const double atr5,
                const double stopsLevelPrice, const GERuleParams &p, const int digits, string &detail)
  {
   double buffer = MathMax(p.slBufferAtr * atr5, 2.0 * spread);
   if(c.dir > 0) c.sl = structuralExt - buffer;
   else          c.sl = structuralExt + buffer;
   c.sl     = NormalizeDouble(c.sl, digits);
   c.slDist = MathAbs(c.entry - c.sl);
   c.rr     = p.rr;
   c.tp     = NormalizeDouble(c.entry + c.dir * p.rr * c.slDist, digits);
   detail = StringFormat("entry=%.2f sl=%.2f tp=%.2f sld=%.2f (%.2fATR) spread=%.2f", c.entry, c.sl, c.tp, c.slDist,
                         c.slDist / atr5, spread);
   if(c.dir > 0 && c.sl >= c.entry) { detail += " | SL not below entry"; return false; }
   if(c.dir < 0 && c.sl <= c.entry) { detail += " | SL not above entry"; return false; }
   if(c.slDist < p.slMinAtr * atr5) { detail += " | SL too tight"; return false; }
   if(c.slDist > p.slMaxAtr * atr5) { detail += " | SL too wide"; return false; }
   if(c.slDist < stopsLevelPrice || p.rr * c.slDist < stopsLevelPrice) { detail += " | inside broker stop level"; return false; }
   if(spread > p.maxSpreadFracSL * c.slDist) { detail += " | spread > 10% of SL"; return false; }
   return true;
  }

#endif
