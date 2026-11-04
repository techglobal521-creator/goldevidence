//+------------------------------------------------------------------+
//| GoldEvidenceEA.mq5                                               |
//| Evidence-based XAUUSD M5 trend-pullback system                   |
//|                                                                  |
//| NO EVIDENCE = NO TRADE.                                          |
//|  - Decisions only on closed M5 bars                              |
//|  - Mandatory boolean gates G0..G12, first failure = NO TRADE     |
//|  - Risk engine has final authority; Claude can only veto         |
//|  - Fail closed on any missing data / error                       |
//|                                                                  |
//| This is research software. It makes no claim of profitability.  |
//| Run in Strategy Tester and on demo before any live use.          |
//+------------------------------------------------------------------+
#property copyright "GoldEvidence project"
#property version   "1.00"
#property description "Evidence-based XAUUSD M5 system (rules + risk engine + optional Claude veto)"

#include <GoldEvidence/Types.mqh>

//==================================================================== inputs
input group "Mode"
input ENUM_GE_AI_MODE  InpAIMode        = GE_AI_SHADOW;   // AI mode (forced OFF in Strategy Tester)
input ENUM_GE_STRATEGY InpStrategy      = GE_STRAT_RULES; // Strategy (RANDOM = validation baseline, tester only)
input long             InpMagic         = 20261101;       // Magic number

input group "Risk (hard limits - cannot exceed project rules)"
input double InpRiskPct            = 0.5;   // Risk per trade, % of equity (max 0.5)
input double InpDailyLossPct       = 2.0;   // Daily loss limit, % of day-start equity (max 2.0)
input int    InpMaxTradesPerDay    = 5;     // Max entries per server day (max 5)
input double InpSlipBuffer         = 0.30;  // Slippage allowance added to SL distance (price units)
input double InpCommissionPerLotRT = 0.0;   // Round-trip commission per 1.00 lot (account currency)
input double InpMaxLotsHardCap     = 0.30;  // Absolute volume cap (symbol lots)
input double InpMaxDeviationPrice  = 0.20;  // Max fill deviation (price units)

input group "Strategy parameters (frozen v1 - change only via protocol)"
input double InpRR                 = 2.0;   // Reward:risk (min 2.0)
input double InpH1SlopeMin         = 0.10;  // H1 EMA50 slope over 5 bars, in ATR(H1)
input double InpSwingMinMoveAtr    = 1.0;   // ZigZag significance, in ATR of that TF
input int    InpFractalK           = 2;     // Fractal half-width (bars each side)
input int    InpPullbackLookback   = 48;    // M5 bars searched for impulse extreme
input double InpPullbackMinAtr     = 0.5;   // Min pullback depth (ATR M5)
input double InpPullbackMaxAtr     = 2.5;   // Max pullback depth (ATR M5)
input int    InpPullbackMaxAge     = 3;     // Pullback extreme within last N closed bars
input double InpRsiM5Max           = 70.0;  // Buy: RSI(M5) <= this; Sell: RSI(M5) >= 100-this
input int    InpRsiCrossBars       = 3;     // RSI 50-cross lookback (bars)
input double InpTriggerMaxRangeAtr = 2.0;   // Trigger bar range <= N * ATR(M5)
input double InpSLBufferAtr        = 0.2;   // SL buffer beyond structure (ATR M5)
input double InpSLMinAtr           = 0.75;  // Min SL distance (ATR M5)
input double InpSLMaxAtr           = 2.5;   // Max SL distance (ATR M5)
input double InpMaxSpreadFracSL    = 0.10;  // Spread <= fraction of SL distance
input int    InpMinZoneTouches     = 2;     // Min touches for a valid S/R zone
input int    InpRetestWindowM15    = 12;    // Breakout must be within last N M15 bars
input double InpZoneTolAtrH1       = 0.25;  // Zone clustering tolerance (ATR H1)
input double InpZoneMinWidthAtrH1  = 0.20;  // Min zone width (ATR H1)
input int    InpZoneLookbackH1     = 240;   // H1 bars for zone swings (~10 trading days)
input int    InpZoneLookbackM15    = 480;   // M15 bars for zone swings (~5 trading days)
input int    InpWarmupBars         = 600;   // Extra history required for EMA200 warm-up

input group "Environment filters (server time - verify Exness server TZ in Module 0)"
input int    InpSessionStartHour   = 7;     // No entries before (hour)
input int    InpSessionEndHour     = 20;    // No entries at/after (hour)
input int    InpFridayEndHour      = 18;    // Friday: no entries at/after (hour)
input int    InpForceCloseHour     = 20;    // Force-close positions (pre-rollover) hour
input int    InpForceCloseMinute   = 45;    // Force-close minute
input int    InpFridayCloseHour    = 20;    // Friday force-close hour
input double InpMaxSpreadAbs       = 0.60;  // Absolute spread cap (price units)
input double InpSpreadMedianMult   = 2.0;   // Spread <= N * median spread of this hour
input int    InpSpreadLookbackBars = 5760;  // M5 bars for hourly spread median (~20 days)
input double InpVolPctMin          = 0.20;  // ATR(M5) percentile lower bound
input double InpVolPctMax          = 0.90;  // ATR(M5) percentile upper bound
input int    InpVolLookbackBars    = 5760;  // M5 bars for ATR percentile (~20 days)
input int    InpNewsBeforeMin      = 30;    // Block minutes before high-impact USD news
input int    InpNewsAfterMin       = 30;    // Block minutes after
input int    InpNewsMajorBeforeMin = 60;    // FOMC / NFP / CPI: minutes before
input int    InpNewsMajorAfterMin  = 60;    // FOMC / NFP / CPI: minutes after
input string InpNewsCsv            = "GoldEvidence_news_USD.csv"; // Tester news file (Common\Files)

input group "Claude review service"
input string InpAIUrl              = "http://127.0.0.1:8787/v1/review"; // Local service URL
input string InpAIToken            = "";    // Local EA token (NOT the Anthropic key)
input int    InpAITimeoutMs        = 20000; // WebRequest timeout (ms)
input double InpMaxPriceDriftAtr   = 0.25;  // Abort if price moved > N*ATR(M5) since evaluation

input group "Validation tools (Strategy Tester only)"
input int    InpRandomSeed         = 1;     // Random baseline seed (optimise over 1..100)
input double InpRandomProb         = 0.05;  // Random baseline: entry probability per eligible bar
input double InpRandomSLAtr        = 1.5;   // Random baseline: SL distance before buffer (ATR M5)
input bool   InpUseG4              = true;  // Ablation: M15 confirmation
input bool   InpUseG5              = true;  // Ablation: M5 pullback
input bool   InpUseG6              = true;  // Ablation: location evidence
input bool   InpUseG7              = true;  // Ablation: momentum
input bool   InpUseG8              = true;  // Ablation: trigger candle
input bool   InpUseG9              = true;  // Ablation: room to target

//==================================================================== modules
#include <GoldEvidence/MarketData.mqh>
#include <GoldEvidence/Structure.mqh>
#include <GoldEvidence/Levels.mqh>
#include <GoldEvidence/Filters.mqh>
#include <GoldEvidence/NewsFilter.mqh>
#include <GoldEvidence/Rules.mqh>
#include <GoldEvidence/Risk.mqh>
#include <GoldEvidence/Execution.mqh>
#include <GoldEvidence/Journal.mqh>
#include <GoldEvidence/AIClient.mqh>

CGETimeframe    gH1, gM15, gM5;
CGENews         gNews;
CGERisk         gRisk;
CGEExecution    gExec;
CGEJournal      gJ;
CGEAIClient     gAI;
GERuleParams    gP;
ENUM_GE_AI_MODE gAIMode;
bool            gTester, gOptim;
datetime        gLastBar = 0;
double          gLastJournaledDeal = 0;
GEVirtual       gVirt[];
double          gSumR = 0.0;
int             gNR = 0;
int             gDigits;

//==================================================================== helpers
string ModeStr()
  {
   string s = gAIMode == GE_AI_OFF ? "AI_OFF" : (gAIMode == GE_AI_SHADOW ? "AI_SHADOW" : "AI_VETO");
   if(InpStrategy == GE_STRAT_RANDOM) s += "+RANDOM";
   return s;
  }

void LogDecision(const datetime barTime, const int dir, const bool pass, const string gate, const string detail)
  {
   if(gOptim) return;          // keep optimisation runs fast
   gJ.Decision(barTime, ModeStr(), dir, pass, gate, detail);
  }

double MidSpread(MqlTick &t) { return t.ask - t.bid; }

//==================================================================== init
int OnInit()
  {
   gTester = (bool)MQLInfoInteger(MQL_TESTER);
   gOptim  = (bool)MQLInfoInteger(MQL_OPTIMIZATION);
   gDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //--- hard project limits
   if(InpRiskPct <= 0 || InpRiskPct > 0.5)          { Print("GE: InpRiskPct must be in (0, 0.5]"); return INIT_PARAMETERS_INCORRECT; }
   if(InpDailyLossPct <= 0 || InpDailyLossPct > 2.0) { Print("GE: InpDailyLossPct must be in (0, 2.0]"); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxTradesPerDay < 1 || InpMaxTradesPerDay > 5) { Print("GE: InpMaxTradesPerDay must be 1..5"); return INIT_PARAMETERS_INCORRECT; }
   if(InpRR < 2.0)                                   { Print("GE: InpRR must be >= 2.0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpStrategy == GE_STRAT_RANDOM && !gTester)    { Print("GE: RANDOM baseline is for the Strategy Tester only"); return INIT_FAILED; }
   if(Period() != PERIOD_M5)                          Print("GE: note - attach to any chart; logic always uses M5/M15/H1");

   //--- symbol sanity
   string sym = _Symbol;
   if(StringFind(sym, "XAU") < 0) { Print("GE: this EA is designed for XAUUSD only"); return INIT_FAILED; }
   double cs = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
   PrintFormat("GE: %s contract=%.4f vmin=%.4f vstep=%.4f vmax=%.2f digits=%d point=%g stops_level=%d acct_ccy=%s",
               sym, cs, SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP),
               SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX), gDigits, SymbolInfoDouble(sym, SYMBOL_POINT),
               (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL), AccountInfoString(ACCOUNT_CURRENCY));
   if(cs <= 0) { Print("GE: invalid contract size"); return INIT_FAILED; }

   //--- AI mode
   gAIMode = gTester ? GE_AI_OFF : InpAIMode;
   if(gTester && InpAIMode != GE_AI_OFF) Print("GE: Strategy Tester detected -> AI forced OFF (WebRequest unavailable)");
   if(gAIMode != GE_AI_OFF && StringLen(InpAIToken) < 16) { Print("GE: InpAIToken missing/too short"); return INIT_PARAMETERS_INCORRECT; }

   //--- modules
   if(!gH1.Init(sym, PERIOD_H1) || !gM15.Init(sym, PERIOD_M15) || !gM5.Init(sym, PERIOD_M5)) return INIT_FAILED;
   string why = "";
   if(!gNews.Init(gTester, InpNewsCsv, InpNewsBeforeMin, InpNewsAfterMin, InpNewsMajorBeforeMin, InpNewsMajorAfterMin, why))
     { Print("GE: news filter init failed: ", why); return INIT_FAILED; }
   gRisk.Init(sym, InpMagic);
   gExec.Init(sym, InpMagic, (int)MathMax(1, MathRound(InpMaxDeviationPrice / SymbolInfoDouble(sym, SYMBOL_POINT))));
   gJ.Init("GoldEvidence");
   gAI.Init(InpAIUrl, InpAIToken, InpAITimeoutMs);
   MathSrand((uint)InpRandomSeed);

   string k = gRisk.Prefix() + "LASTDEAL";
   gLastJournaledDeal = GlobalVariableCheck(k) ? GlobalVariableGet(k) : 0;

   gP.h1SlopeMin = InpH1SlopeMin;           gP.pullbackLookback = InpPullbackLookback;
   gP.pullbackMinAtr = InpPullbackMinAtr;   gP.pullbackMaxAtr = InpPullbackMaxAtr;
   gP.pullbackMaxAge = InpPullbackMaxAge;   gP.rsiM5Max = InpRsiM5Max;
   gP.rsiCrossBars = InpRsiCrossBars;       gP.triggerMaxRangeAtr = InpTriggerMaxRangeAtr;
   gP.slBufferAtr = InpSLBufferAtr;         gP.slMinAtr = InpSLMinAtr;
   gP.slMaxAtr = InpSLMaxAtr;               gP.rr = InpRR;
   gP.maxSpreadFracSL = InpMaxSpreadFracSL; gP.minTouches = InpMinZoneTouches;
   gP.retestWindowM15 = InpRetestWindowM15;
   gP.useG4 = InpUseG4; gP.useG5 = InpUseG5; gP.useG6 = InpUseG6;
   gP.useG7 = InpUseG7; gP.useG8 = InpUseG8; gP.useG9 = InpUseG9;

   PrintFormat("GE: initialised. mode=%s risk=%.2f%% daily=%.2f%% maxTrades=%d RR=%.2f",
               ModeStr(), InpRiskPct, InpDailyLossPct, InpMaxTradesPerDay, InpRR);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   gH1.Release(); gM15.Release(); gM5.Release();
  }

//==================================================================== tick
void OnTick()
  {
   datetime now = TimeCurrent();
   //--- protective closes are checked on every tick
   if(GEForceCloseTime(now, InpForceCloseHour * 60 + InpForceCloseMinute, InpFridayCloseHour * 60) && gRisk.HasExposure())
      gExec.CloseAll("pre-rollover / Friday close");

   datetime bt = iTime(_Symbol, PERIOD_M5, 0);
   if(bt == 0 || bt == gLastBar) return;
   gLastBar = bt;
   OnNewBar(now);
  }

void OnNewBar(const datetime now)
  {
   JournalExits(now);
   UpdateVirtual(now);
   Evaluate(now);
  }

//==================================================================== evaluation
void Evaluate(const datetime now)
  {
   string sym = _Symbol;
   datetime barTime = iTime(sym, PERIOD_M5, 1);
   string why = "";

   //--- G0 data health
   if(!gH1.Load(300, InpWarmupBars, why) || !gM15.Load(InpZoneLookbackM15 + 20, InpWarmupBars, why) ||
      !gM5.Load(300, InpWarmupBars, why))
     { LogDecision(barTime, 0, false, "G0", why); return; }
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0 || tick.ask <= 0) { LogDecision(barTime, 0, false, "G0", "no tick"); return; }
   if(!gTester && (long)(now - tick.time) > 60) { LogDecision(barTime, 0, false, "G0", "stale tick"); return; }
   if(!gTester && (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)))
     { LogDecision(barTime, 0, false, "G0", "algo trading disabled"); return; }
   if(SymbolInfoInteger(sym, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
     { LogDecision(barTime, 0, false, "G0", "symbol trade mode not FULL"); return; }

   //--- G1 account state
   if(!gRisk.AccountGate(now, InpDailyLossPct, InpMaxTradesPerDay, why)) { LogDecision(barTime, 0, false, "G1", why); return; }

   //--- G2 environment
   double spread = MidSpread(tick);
   if(!GESessionOk(now, InpSessionStartHour * 60, InpSessionEndHour * 60, InpFridayEndHour * 60, why))
     { LogDecision(barTime, 0, false, "G2", why); return; }
   if(!gNews.Clear(now, why)) { LogDecision(barTime, 0, false, "G2", why); return; }
   if(spread > InpMaxSpreadAbs) { LogDecision(barTime, 0, false, "G2", StringFormat("spread %.2f > cap %.2f", spread, InpMaxSpreadAbs)); return; }
   double medSpr = GEHourlyMedianSpread(sym, now, InpSpreadLookbackBars, 30);
   if(medSpr < 0) { LogDecision(barTime, 0, false, "G2", "not enough spread history"); return; }
   if(medSpr > 0 && spread > InpSpreadMedianMult * medSpr)
     { LogDecision(barTime, 0, false, "G2", StringFormat("spread %.2f > %.1fx hourly median %.2f", spread, InpSpreadMedianMult, medSpr)); return; }
   double volPct = GEAtrPercentile(gM5.hATR, InpVolLookbackBars, now);
   if(volPct < 0) { LogDecision(barTime, 0, false, "G2", "ATR percentile unavailable"); return; }
   if(volPct < InpVolPctMin || volPct > InpVolPctMax)
     { LogDecision(barTime, 0, false, "G2", StringFormat("ATR(M5) percentile %.2f outside [%.2f, %.2f]", volPct, InpVolPctMin, InpVolPctMax)); return; }

   //--- structure on all timeframes
   GESwing zzH1[], zz15[], zz5[];
   GEStructure stH1, st15, st5;
   GEAnalyseStructure(gH1, InpFractalK, MathMin(InpZoneLookbackH1, 290), InpSwingMinMoveAtr, zzH1, stH1);
   GEAnalyseStructure(gM15, InpFractalK, InpZoneLookbackM15, InpSwingMinMoveAtr, zz15, st15);
   GEAnalyseStructure(gM5, InpFractalK, 200, InpSwingMinMoveAtr, zz5, st5);

   //--- G3 H1 bias
   string d3 = "";
   int dir = GEH1Bias(gH1, stH1, gP.h1SlopeMin, d3);
   if(dir == 0) { LogDecision(barTime, 0, false, "G3", d3); return; }

   double atr5 = gM5.atr[1], atr15 = gM15.atr[1], atrH1 = gH1.atr[1];
   double stopsLevel = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(sym, SYMBOL_POINT);

   GECandidate c;
   c.dir = dir;
   c.evalPrice = dir > 0 ? tick.ask : tick.bid;
   c.entry = c.evalPrice;
   c.spread = spread; c.atrM5 = atr5; c.atrM15 = atr15; c.atrH1 = atrH1; c.atrPctile = volPct;
   c.id = StringFormat("GE-%I64d-%s", (long)barTime, dir > 0 ? "BUY" : "SELL");
   c.nextOppDist = -1;

   if(InpStrategy == GE_STRAT_RANDOM) { RandomBaseline(c, barTime, stopsLevel, d3); return; }

   //--- G4 M15 confirmation
   string d4 = "";
   if(gP.useG4 && !GEM15Confirm(gM15, st15, dir, d4)) { LogDecision(barTime, dir, false, "G4", d4); return; }

   //--- G5 M5 pullback
   string d5 = "";
   double ext = 0, depth = 0; datetime extTime = 0;
   bool pb = GEM5Pullback(gM5, zz5, dir, gP, ext, extTime, depth, d5);
   if(gP.useG5 && !pb) { LogDecision(barTime, dir, false, "G5", d5); return; }
   if(!pb) { ext = dir > 0 ? gM5.Low(1) : gM5.High(1); extTime = gM5.Time(1); }   // ablation fallback
   c.pullbackExt = ext; c.pullbackTime = extTime; c.pullbackDepthAtr = depth;

   //--- G1b: no re-entry in the same direction until a new M5 swing forms after a losing exit
   int lossDir = 0; datetime lossTime = 0;
   if(gRisk.LastLoss(now, lossDir, lossTime) && lossDir == dir && extTime <= lossTime)
     { LogDecision(barTime, dir, false, "G1", "post-loss cooldown: no new M5 swing since last losing exit"); return; }

   //--- duplicate prevention: one trade per setup (direction + pullback bar)
   double setupKey = dir * 1e10 + (double)extTime;
   string kSetup = gRisk.Prefix() + "LASTSETUP";
   if(GlobalVariableCheck(kSetup) && GlobalVariableGet(kSetup) == setupKey)
     { LogDecision(barTime, dir, false, "G1", "setup already traded"); return; }
   c.setupKey = DoubleToString(setupKey, 0);

   //--- G6 location evidence
   GEZone zones[];
   GEBuildZones(zzH1, zz15, InpZoneTolAtrH1 * atrH1, InpZoneMinWidthAtrH1 * atrH1, zones);
   double close1 = gM5.Close(1);
   int zr = GEFindBreakoutRetest(zones, gM15, dir, ext, extTime, close1, atr5, gP.retestWindowM15, gP.minTouches);
   int zt = GEFindLevelTouch(zones, dir, ext, close1, atr5, gP.minTouches);
   int zi = zr >= 0 ? zr : zt;
   c.location = zr >= 0 ? "RETEST" : (zt >= 0 ? (dir > 0 ? "SUPPORT" : "RESISTANCE") : "NONE");
   string d6 = StringFormat("zones=%d location=%s ext=%.2f", ArraySize(zones), c.location, ext);
   if(zi >= 0) { c.zoneLow = zones[zi].low; c.zoneHigh = zones[zi].high; c.zoneTouches = zones[zi].touches;
                 d6 += StringFormat(" zone=[%.2f,%.2f] touches=%d", c.zoneLow, c.zoneHigh, c.zoneTouches); }
   else        { c.zoneLow = 0; c.zoneHigh = 0; c.zoneTouches = 0; }
   if(gP.useG6 && zi < 0) { LogDecision(barTime, dir, false, "G6", d6); return; }

   //--- G7 momentum
   string d7 = "";
   if(gP.useG7 && !GEM5Momentum(gM5, dir, gP, d7)) { LogDecision(barTime, dir, false, "G7", d7); return; }

   //--- G8 trigger candle
   string trig = "", d8 = "";
   bool tr = GEM5Trigger(gM5, dir, gP, trig, d8);
   if(gP.useG8 && !tr) { LogDecision(barTime, dir, false, "G8", d8); return; }
   c.trigger = tr ? trig : "NONE";

   //--- G10 geometry (structural SL beyond the pullback extreme and the zone)
   double structural = ext;
   if(zi >= 0) structural = dir > 0 ? MathMin(ext, c.zoneLow) : MathMax(ext, c.zoneHigh);
   string d10 = "";
   if(!GEGeometry(c, structural, spread, atr5, stopsLevel, gP, gDigits, d10)) { LogDecision(barTime, dir, false, "G10", d10); return; }

   //--- G9 room to target
   c.nextOppDist = GENextOpposingDistance(zones, dir, c.entry, gP.minTouches);
   if(gP.useG9 && c.nextOppDist >= 0 && c.nextOppDist < InpRR * c.slDist)
     { LogDecision(barTime, dir, false, "G9", StringFormat("next opposing zone %.2f away < target %.2f", c.nextOppDist, InpRR * c.slDist)); return; }

   string evidence = d3 + " || " + d4 + " || " + d5 + " || " + d6 + " || " + d7 + " || " + d8 + " || " + d10;
   ProceedToRiskAndExecution(c, barTime, now, stopsLevel, evidence, zzH1, zz15, stH1, st15, zones);
  }

//==================================================================== random baseline (tester only)
void RandomBaseline(GECandidate &c, const datetime barTime, const double stopsLevel, const string d3)
  {
   if((double)MathRand() / 32767.0 >= InpRandomProb) { LogDecision(barTime, c.dir, false, "RND", "not selected"); return; }
   double ext = c.entry - c.dir * InpRandomSLAtr * c.atrM5;
   c.location = "RANDOM"; c.trigger = "RANDOM"; c.pullbackExt = ext; c.pullbackTime = barTime;
   c.setupKey = IntegerToString((long)barTime);
   string dg = "";
   if(!GEGeometry(c, ext, c.spread, c.atrM5, stopsLevel, gP, gDigits, dg)) { LogDecision(barTime, c.dir, false, "G10", dg); return; }
   string why = "";
   if(!gRisk.SizeAndVerify(c, InpRiskPct, InpSlipBuffer, InpCommissionPerLotRT, InpMaxLotsHardCap, InpDailyLossPct, TimeCurrent(), why))
     { LogDecision(barTime, c.dir, false, "G11", why); return; }
   long pid = gExec.Open(c, why);
   if(pid <= 0) { LogDecision(barTime, c.dir, false, "EXEC", why); return; }
   gRisk.SaveMeta(pid, c, 0);
   LogDecision(barTime, c.dir, true, "EXECUTED", StringFormat("RANDOM pos=%I64d lots=%.2f entry=%.2f sl=%.2f tp=%.2f", pid, c.lots, c.entry, c.sl, c.tp));
  }

//==================================================================== risk, AI, execution
void ProceedToRiskAndExecution(GECandidate &c, const datetime barTime, const datetime now, const double stopsLevel,
                               const string evidence, GESwing &zzH1[], GESwing &zz15[],
                               const GEStructure &stH1, const GEStructure &st15, GEZone &zones[])
  {
   string why = "";
   //--- G11 risk engine
   if(!gRisk.SizeAndVerify(c, InpRiskPct, InpSlipBuffer, InpCommissionPerLotRT, InpMaxLotsHardCap, InpDailyLossPct, now, why))
     { LogDecision(barTime, c.dir, false, "G11", why); return; }

   //--- G12 AI review
   int aiCode = 0;
   string aiSummary = "";
   if(gAIMode != GE_AI_OFF)
     {
      string payload = BuildPayload(c, barTime, zzH1, zz15, stH1, st15, zones);
      aiCode = gAI.Review(payload, c.id, aiSummary);
      if(gAIMode == GE_AI_VETO && aiCode != 1)
        {
         LogDecision(barTime, c.dir, false, "G12", StringFormat("AI code=%d %s", aiCode, aiSummary));
         if(aiCode == 2) AddVirtual(c);     // a genuine REJECT is tracked for the AI value test
         return;
        }
     }

   //--- pre-send re-check with a fresh tick
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t)) { LogDecision(barTime, c.dir, false, "PRESEND", "no tick"); return; }
   double newEntry = c.dir > 0 ? t.ask : t.bid;
   double spreadNow = t.ask - t.bid;
   if(MathAbs(newEntry - c.evalPrice) > InpMaxPriceDriftAtr * c.atrM5)
     { LogDecision(barTime, c.dir, false, "PRESEND", StringFormat("price drift %.2f > %.2f", MathAbs(newEntry - c.evalPrice), InpMaxPriceDriftAtr * c.atrM5)); return; }
   if(spreadNow > InpMaxSpreadAbs || spreadNow > InpMaxSpreadFracSL * c.slDist)
     { LogDecision(barTime, c.dir, false, "PRESEND", StringFormat("spread widened to %.2f", spreadNow)); return; }
   //--- keep the structural SL, rebuild entry/TP from the live price
   c.entry  = newEntry;
   c.slDist = MathAbs(c.entry - c.sl);
   c.tp     = NormalizeDouble(c.entry + c.dir * InpRR * c.slDist, gDigits);
   if((c.dir > 0 && c.sl >= c.entry) || (c.dir < 0 && c.sl <= c.entry) ||
      c.slDist < InpSLMinAtr * c.atrM5 || c.slDist > InpSLMaxAtr * c.atrM5 || c.slDist < stopsLevel)
     { LogDecision(barTime, c.dir, false, "PRESEND", "geometry invalid at live price"); return; }
   if(gP.useG9 && c.nextOppDist >= 0)
     {
      double opp = GENextOpposingDistance(zones, c.dir, c.entry, gP.minTouches);
      if(opp >= 0 && opp < InpRR * c.slDist) { LogDecision(barTime, c.dir, false, "PRESEND", "room to target lost"); return; }
     }
   if(!gRisk.SizeAndVerify(c, InpRiskPct, InpSlipBuffer, InpCommissionPerLotRT, InpMaxLotsHardCap, InpDailyLossPct, TimeCurrent(), why))
     { LogDecision(barTime, c.dir, false, "PRESEND", why); return; }

   //--- execute
   long pid = gExec.Open(c, why);
   if(pid <= 0) { LogDecision(barTime, c.dir, false, "EXEC", why); return; }
   gRisk.SaveMeta(pid, c, aiCode);
   GlobalVariableSet(gRisk.Prefix() + "LASTSETUP", StringToDouble(c.setupKey));
   LogDecision(barTime, c.dir, true, "EXECUTED",
               StringFormat("%s pos=%I64d lots=%.2f entry=%.2f sl=%.2f tp=%.2f risk=%.2f (%.2f%%) ai=%d %s | %s",
                            c.id, pid, c.lots, c.entry, c.sl, c.tp, c.worstRisk, c.riskPct, aiCode, aiSummary, evidence));
  }

string BuildPayload(const GECandidate &c, const datetime barTime, GESwing &zzH1[], GESwing &zz15[],
                    const GEStructure &stH1, const GEStructure &st15, GEZone &zones[])
  {
   GESwing zz5[];
   GEStructure st5;
   GEAnalyseStructure(gM5, InpFractalK, 200, InpSwingMinMoveAtr, zz5, st5);
   string lv = "[";
   for(int i = 0; i < ArraySize(zones); i++)
     {
      lv += StringFormat("{\"low\":%s,\"high\":%s,\"touches\":%d}", DoubleToString(zones[i].low, gDigits),
                         DoubleToString(zones[i].high, gDigits), zones[i].touches);
      if(i < ArraySize(zones) - 1) lv += ",";
     }
   lv += "]";
   string s = "{";
   s += GEJStr("schema", "candidate.v1") + "," + GEJStr("candidate_id", c.id) + ",";
   s += GEJStr("server_time", TimeToString(barTime, TIME_DATE | TIME_MINUTES)) + "," + GEJStr("symbol", _Symbol) + ",";
   s += GEJStr("direction", c.dir > 0 ? "BUY" : "SELL") + ",";
   s += "\"proposal\":{" + GEJNum("entry", c.entry, gDigits) + "," + GEJNum("sl", c.sl, gDigits) + "," +
        GEJNum("tp", c.tp, gDigits) + "," + GEJNum("rr", c.rr, 2) + "," + GEJNum("risk_pct", c.riskPct, 3) + "},";
   s += "\"market\":{" + GEJNum("spread", c.spread, gDigits) + "," + GEJNum("atr_m5", c.atrM5, gDigits) + "," +
        GEJNum("atr_m15", c.atrM15, gDigits) + "," + GEJNum("atr_h1", c.atrH1, gDigits) + "," +
        GEJNum("atr_m5_pctile", c.atrPctile, 3) + "},";
   s += "\"h1\":" + GETfJson(gH1, stH1, zzH1, gDigits) + ",";
   s += "\"m15\":" + GETfJson(gM15, st15, zz15, gDigits) + ",";
   s += "\"m5\":" + GETfJson(gM5, st5, zz5, gDigits) + ",";
   s += "\"setup\":{" + GEJStr("location", c.location) + "," + GEJNum("zone_low", c.zoneLow, gDigits) + "," +
        GEJNum("zone_high", c.zoneHigh, gDigits) + "," + GEJInt("zone_touches", c.zoneTouches) + "," +
        GEJStr("trigger", c.trigger) + "," + GEJNum("pullback_extreme", c.pullbackExt, gDigits) + "," +
        GEJNum("pullback_depth_atr", c.pullbackDepthAtr, 3) + "," + GEJNum("next_opposing_zone_dist", c.nextOppDist, gDigits) + "},";
   s += "\"levels\":" + lv + ",";
   s += "\"bars\":{\"m5\":" + GEBarsJson(gM5, 48, gDigits) + ",\"m15\":" + GEBarsJson(gM15, 32, gDigits) +
        ",\"h1\":" + GEBarsJson(gH1, 48, gDigits) + "}";
   s += "}";
   return s;
  }

//==================================================================== virtual trades (AI value test)
void AddVirtual(const GECandidate &c)
  {
   int n = ArraySize(gVirt);
   ArrayResize(gVirt, n + 1);
   gVirt[n].id = c.id; gVirt[n].dir = c.dir; gVirt[n].entry = c.entry; gVirt[n].sl = c.sl;
   gVirt[n].tp = c.tp; gVirt[n].slDist = c.slDist; gVirt[n].opened = TimeCurrent(); gVirt[n].open = true;
  }

void UpdateVirtual(const datetime now)
  {
   double h = iHigh(_Symbol, PERIOD_M5, 1), l = iLow(_Symbol, PERIOD_M5, 1), cl = iClose(_Symbol, PERIOD_M5, 1);
   bool forceClose = GEForceCloseTime(now, InpForceCloseHour * 60 + InpForceCloseMinute, InpFridayCloseHour * 60);
   for(int i = 0; i < ArraySize(gVirt); i++)
     {
      if(!gVirt[i].open) continue;
      bool hitSL = gVirt[i].dir > 0 ? l <= gVirt[i].sl : h >= gVirt[i].sl;
      bool hitTP = gVirt[i].dir > 0 ? h >= gVirt[i].tp : l <= gVirt[i].tp;
      string res = ""; double r = 0;
      if(hitSL)      { res = "SL"; r = -1.0; }                 // both in one bar -> conservative loss
      else if(hitTP) { res = "TP"; r = InpRR; }
      else if(forceClose) { res = "TIME"; r = gVirt[i].dir * (cl - gVirt[i].entry) / gVirt[i].slDist; }
      if(res == "") continue;
      gVirt[i].open = false;
      gJ.Virtual(StringFormat("%s,%s,%s,%s,%.3f,%.3f,%.3f,%s,%.3f", gVirt[i].id, gVirt[i].dir > 0 ? "BUY" : "SELL",
                              TimeToString(gVirt[i].opened), TimeToString(now), gVirt[i].entry, gVirt[i].sl, gVirt[i].tp, res, r));
     }
  }

//==================================================================== trade journal
struct GEExitInfo
  {
   ulong             ticket;
   long              posId;
   datetime          time;
   double            price;
   long              reason;
  };

void JournalExits(const datetime now)
  {
   if(!HistorySelect(now - 30 * 86400, now + 60)) return;
   GEExitInfo ex[];
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0 || (double)tk <= gLastJournaledDeal) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      int m = ArraySize(ex);
      ArrayResize(ex, m + 1);
      ex[m].ticket = tk;
      ex[m].posId  = HistoryDealGetInteger(tk, DEAL_POSITION_ID);
      ex[m].time   = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
      ex[m].price  = HistoryDealGetDouble(tk, DEAL_PRICE);
      ex[m].reason = HistoryDealGetInteger(tk, DEAL_REASON);
     }
   for(int e = 0; e < ArraySize(ex); e++)
     {
      if(!HistorySelectByPosition(ex[e].posId)) continue;
      double net = 0, entry = 0, lots = 0; datetime ot = 0; int dir = 0;
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong tk = HistoryDealGetTicket(i);
         net += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP) +
                HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
         if(HistoryDealGetInteger(tk, DEAL_ENTRY) == DEAL_ENTRY_IN)
           {
            entry = HistoryDealGetDouble(tk, DEAL_PRICE);
            lots  = HistoryDealGetDouble(tk, DEAL_VOLUME);
            ot    = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
            dir   = HistoryDealGetInteger(tk, DEAL_TYPE) == DEAL_TYPE_BUY ? 1 : -1;
           }
        }
      double plan  = gRisk.MetaGet(ex[e].posId, "plan", 0);
      double worst = gRisk.MetaGet(ex[e].posId, "risk", 0);
      double sld   = gRisk.MetaGet(ex[e].posId, "sld", 0);
      double spr   = gRisk.MetaGet(ex[e].posId, "spr", 0);
      int    ai    = (int)gRisk.MetaGet(ex[e].posId, "ai", -1);
      string rStr  = plan > 0 ? DoubleToString(net / plan, 3) : "";
      if(plan > 0) { gSumR += net / plan; gNR++; }

      //--- MAE / MFE from M1 bars, in R
      string maeStr = "", mfeStr = "";
      MqlRates m1[];
      if(sld > 0 && ot > 0 && CopyRates(_Symbol, PERIOD_M1, ot, ex[e].time, m1) > 0)
        {
         double hi = m1[0].high, lo = m1[0].low;
         for(int q = 1; q < ArraySize(m1); q++) { hi = MathMax(hi, m1[q].high); lo = MathMin(lo, m1[q].low); }
         double mae = dir > 0 ? entry - lo : hi - entry;
         double mfe = dir > 0 ? hi - entry : entry - lo;
         maeStr = DoubleToString(mae / sld, 3);
         mfeStr = DoubleToString(mfe / sld, 3);
        }
      string reason = ex[e].reason == DEAL_REASON_SL ? "SL" : (ex[e].reason == DEAL_REASON_TP ? "TP" :
                      (ex[e].reason == DEAL_REASON_EXPERT ? "EA_CLOSE" : (ex[e].reason == DEAL_REASON_SO ? "STOP_OUT" : "OTHER")));
      gJ.Trade(StringFormat("%I64d,%s,%s,%s,%s,%.3f,%.3f,%.3f,%.4f,%.2f,%.2f,%.2f,%s,%s,%.3f,%s,%s,%d,%.2f",
                            ex[e].posId, _Symbol, dir > 0 ? "BUY" : "SELL", TimeToString(ot, TIME_DATE | TIME_MINUTES),
                            TimeToString(ex[e].time, TIME_DATE | TIME_MINUTES), entry, ex[e].price, sld, lots, plan, worst,
                            net, rStr, reason, spr, maeStr, mfeStr, ai, AccountInfoDouble(ACCOUNT_BALANCE)));
      gLastJournaledDeal = (double)ex[e].ticket;
      GlobalVariableSet(gRisk.Prefix() + "LASTDEAL", gLastJournaledDeal);
      gRisk.MetaDelete(ex[e].posId);
     }
  }

//==================================================================== tester metric
//--- Custom optimisation criterion = mean R per trade (used for the random baseline
//--- distribution and robustness grids - NOT for picking "best" parameters).
double OnTester()
  {
   datetime now = TimeCurrent();
   JournalExits(now);
   return gNR > 0 ? gSumR / gNR : 0.0;
  }
//+------------------------------------------------------------------+
