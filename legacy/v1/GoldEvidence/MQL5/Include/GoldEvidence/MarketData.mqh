//+------------------------------------------------------------------+
//| MarketData.mqh - bars and indicator buffers per timeframe        |
//| All arrays are series-ordered: index 0 = forming bar,            |
//| index 1 = last CLOSED bar. Signal logic only reads index >= 1.   |
//+------------------------------------------------------------------+
#ifndef GE_MARKETDATA_MQH
#define GE_MARKETDATA_MQH

class CGETimeframe
  {
public:
   string            symbol;
   ENUM_TIMEFRAMES   tf;
   int               hE20, hE50, hE200, hRSI, hATR;
   MqlRates          rates[];
   double            ema20[], ema50[], ema200[], rsi[], atr[];
   int               loaded;

                     CGETimeframe() : hE20(INVALID_HANDLE), hE50(INVALID_HANDLE), hE200(INVALID_HANDLE),
                                      hRSI(INVALID_HANDLE), hATR(INVALID_HANDLE), loaded(0) {}
                    ~CGETimeframe() { Release(); }

   bool              Init(const string sym, const ENUM_TIMEFRAMES timeframe)
     {
      symbol = sym;
      tf     = timeframe;
      hE20   = iMA(sym, tf, 20, 0, MODE_EMA, PRICE_CLOSE);
      hE50   = iMA(sym, tf, 50, 0, MODE_EMA, PRICE_CLOSE);
      hE200  = iMA(sym, tf, 200, 0, MODE_EMA, PRICE_CLOSE);
      hRSI   = iRSI(sym, tf, 14, PRICE_CLOSE);
      hATR   = iATR(sym, tf, 14);
      if(hE20 == INVALID_HANDLE || hE50 == INVALID_HANDLE || hE200 == INVALID_HANDLE ||
         hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE)
        {
         PrintFormat("GE: indicator handle creation failed on %s, err=%d", EnumToString(tf), GetLastError());
         return false;
        }
      ArraySetAsSeries(rates, true);
      ArraySetAsSeries(ema20, true);
      ArraySetAsSeries(ema50, true);
      ArraySetAsSeries(ema200, true);
      ArraySetAsSeries(rsi, true);
      ArraySetAsSeries(atr, true);
      return true;
     }

   void              Release()
     {
      if(hE20 != INVALID_HANDLE)  { IndicatorRelease(hE20);  hE20 = INVALID_HANDLE; }
      if(hE50 != INVALID_HANDLE)  { IndicatorRelease(hE50);  hE50 = INVALID_HANDLE; }
      if(hE200 != INVALID_HANDLE) { IndicatorRelease(hE200); hE200 = INVALID_HANDLE; }
      if(hRSI != INVALID_HANDLE)  { IndicatorRelease(hRSI);  hRSI = INVALID_HANDLE; }
      if(hATR != INVALID_HANDLE)  { IndicatorRelease(hATR);  hATR = INVALID_HANDLE; }
     }

   //--- load `count` bars. Requires `minHistory` extra bars for EMA200 warm-up.
   //--- Returns false (fail closed) on any shortfall.
   bool              Load(const int count, const int minHistory, string &why)
     {
      loaded = 0;
      int available = Bars(symbol, tf);
      if(available < count + minHistory)
        {
         why = StringFormat("%s history %d < required %d", EnumToString(tf), available, count + minHistory);
         return false;
        }
      if(BarsCalculated(hE20) < count || BarsCalculated(hE50) < count || BarsCalculated(hE200) < count ||
         BarsCalculated(hRSI) < count || BarsCalculated(hATR) < count)
        {
         why = StringFormat("%s indicators not calculated yet", EnumToString(tf));
         return false;
        }
      if(CopyRates(symbol, tf, 0, count, rates) != count)          { why = EnumToString(tf) + " CopyRates failed"; return false; }
      if(CopyBuffer(hE20, 0, 0, count, ema20) != count)            { why = EnumToString(tf) + " EMA20 copy failed"; return false; }
      if(CopyBuffer(hE50, 0, 0, count, ema50) != count)            { why = EnumToString(tf) + " EMA50 copy failed"; return false; }
      if(CopyBuffer(hE200, 0, 0, count, ema200) != count)          { why = EnumToString(tf) + " EMA200 copy failed"; return false; }
      if(CopyBuffer(hRSI, 0, 0, count, rsi) != count)              { why = EnumToString(tf) + " RSI copy failed"; return false; }
      if(CopyBuffer(hATR, 0, 0, count, atr) != count)              { why = EnumToString(tf) + " ATR copy failed"; return false; }
      for(int i = 1; i < MathMin(count, 10); i++)
        {
         if(atr[i] <= 0.0 || ema200[i] <= 0.0 || rates[i].close <= 0.0)
           { why = EnumToString(tf) + " invalid indicator values"; return false; }
        }
      loaded = count;
      return true;
     }

   //--- helpers on closed bars
   double            Close(const int i) const { return rates[i].close; }
   double            Open(const int i)  const { return rates[i].open; }
   double            High(const int i)  const { return rates[i].high; }
   double            Low(const int i)   const { return rates[i].low; }
   datetime          Time(const int i)  const { return rates[i].time; }
  };

#endif
