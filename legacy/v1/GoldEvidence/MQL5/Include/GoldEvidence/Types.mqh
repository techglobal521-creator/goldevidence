//+------------------------------------------------------------------+
//| Types.mqh - shared enums and structures                          |
//| GoldEvidence EA - evidence-based XAUUSD M5 system                |
//+------------------------------------------------------------------+
#ifndef GE_TYPES_MQH
#define GE_TYPES_MQH

enum ENUM_GE_AI_MODE
  {
   GE_AI_OFF    = 0,   // AI not called (forced in Strategy Tester)
   GE_AI_SHADOW = 1,   // AI called and logged, verdict NOT enforced
   GE_AI_VETO   = 2    // AI called; anything except CONFIRM blocks the trade
  };

enum ENUM_GE_STRATEGY
  {
   GE_STRAT_RULES  = 0,  // Full rule engine (the real strategy)
   GE_STRAT_RANDOM = 1   // Random-entry baseline (validation only, never live)
  };

//--- one confirmed swing point
struct GESwing
  {
   double            price;
   datetime          time;
   int               index;   // series index at the time of detection (1 = last closed bar)
   bool              isHigh;
  };

//--- a support / resistance zone
struct GEZone
  {
   double            low;
   double            high;
   int               touches;
  };

//--- result of a structure classification on one timeframe
struct GEStructure
  {
   int               bias;        // +1 bullish, -1 bearish, 0 neutral
   bool              valid;       // enough swings to classify
   GESwing           lastHigh;    // most recent confirmed swing high
   GESwing           lastLow;     // most recent confirmed swing low
   GESwing           prevHigh;
   GESwing           prevLow;
  };

//--- a fully specified trade candidate
struct GECandidate
  {
   int               dir;          // +1 buy, -1 sell
   string            id;           // unique candidate id
   string            setupKey;     // duplicate-prevention key
   double            evalPrice;    // ask (buy) / bid (sell) at evaluation
   double            entry;
   double            sl;
   double            tp;
   double            slDist;
   double            rr;
   double            lots;
   double            riskMoney;    // planned loss at SL (account currency)
   double            worstRisk;    // incl. slippage buffer and commission
   double            riskPct;      // worstRisk / equity * 100
   double            pullbackExt;  // pullback low (buy) / rally high (sell)
   datetime          pullbackTime;
   string            location;     // SUPPORT / RESISTANCE / RETEST / RANDOM
   double            zoneLow;
   double            zoneHigh;
   int               zoneTouches;
   string            trigger;      // ENGULFING / REJECTION / MOMENTUM / RANDOM
   double            pullbackDepthAtr;
   double            spread;
   double            atrM5;
   double            atrM15;
   double            atrH1;
   double            atrPctile;
   double            nextOppDist;  // distance to next opposing zone (price), -1 if none
  };

//--- result of one evaluation (one closed M5 bar)
struct GEEval
  {
   bool              pass;
   string            failedGate;
   string            detail;
   int               dir;
  };

//--- vetoed candidate tracked as a virtual trade (AI value test)
struct GEVirtual
  {
   string            id;
   int               dir;
   double            entry;
   double            sl;
   double            tp;
   double            slDist;
   datetime          opened;
   bool              open;
  };

#endif
