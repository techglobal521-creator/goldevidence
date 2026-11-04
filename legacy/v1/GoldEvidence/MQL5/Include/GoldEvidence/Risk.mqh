//+------------------------------------------------------------------+
//| Risk.mqh - account state, daily limits and position sizing       |
//|                                                                  |
//| Risk budget   R = RiskPct% * equity                              |
//| Volume        lots = floor_step( R / lossPerLot(SL+slipBuffer) ) |
//| Verification  |OrderCalcProfit(entry->SL)| scaled by buffer      |
//|               + commission  <= R, otherwise SKIP                  |
//| Below minimum volume -> SKIP (never rounded up).                 |
//| Daily: E0 = equity at server-day start; a trade is allowed only  |
//| if (E0 - equity) + worstRisk(new) <= DailyLossPct% * E0.         |
//| State comes from deal history + terminal global variables, so a  |
//| restart cannot reset limits.                                     |
//+------------------------------------------------------------------+
#ifndef GE_RISK_MQH
#define GE_RISK_MQH

#include "Types.mqh"
#include "Filters.mqh"

class CGERisk
  {
private:
   string            m_sym;
   long              m_magic;
   string            m_prefix;

   string            DayTag(const datetime t)
     {
      MqlDateTime s;
      TimeToStruct(t, s);
      return StringFormat("%04d%02d%02d", s.year, s.mon, s.day);
     }

public:
   void              Init(const string sym, const long magic)
     {
      m_sym = sym;
      m_magic = magic;
      m_prefix = StringFormat("GE_%I64d_%I64d_", AccountInfoInteger(ACCOUNT_LOGIN), magic);
     }

   string            Prefix() { return m_prefix; }

   //--- net P/L of all closed trading deals today (account-wide, incl. manual trades)
   double            ClosedPnLToday(const datetime now)
     {
      if(!HistorySelect(GEDayStart(now), now + 60)) return 0.0;
      double sum = 0.0;
      int n = HistoryDealsTotal();
      for(int i = 0; i < n; i++)
        {
         ulong tk = HistoryDealGetTicket(i);
         if(tk == 0) continue;
         long type = HistoryDealGetInteger(tk, DEAL_TYPE);
         if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
         sum += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP) +
                HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
        }
      return sum;
     }

   //--- equity at server-day start (persisted once per day)
   double            DayStartEquity(const datetime now)
     {
      string key = m_prefix + "E0_" + DayTag(now);
      if(GlobalVariableCheck(key)) return GlobalVariableGet(key);
      double e0 = AccountInfoDouble(ACCOUNT_BALANCE) - ClosedPnLToday(now);
      GlobalVariableSet(key, e0);
      return e0;
     }

   bool              LockedToday(const datetime now)
     {
      return GlobalVariableCheck(m_prefix + "LOCK_" + DayTag(now));
     }

   void              Lock(const datetime now, const string reason)
     {
      string key = m_prefix + "LOCK_" + DayTag(now);
      if(!GlobalVariableCheck(key))
        {
         GlobalVariableSet(key, 1.0);
         PrintFormat("GE: DAILY LOCKOUT engaged: %s", reason);
        }
     }

   //--- entries made today by this EA on this symbol
   int               TradesToday(const datetime now)
     {
      if(!HistorySelect(GEDayStart(now), now + 60)) return 999;   // fail closed
      int cnt = 0;
      int n = HistoryDealsTotal();
      for(int i = 0; i < n; i++)
        {
         ulong tk = HistoryDealGetTicket(i);
         if(tk == 0) continue;
         if(HistoryDealGetInteger(tk, DEAL_MAGIC) != m_magic) continue;
         if(HistoryDealGetString(tk, DEAL_SYMBOL) != m_sym) continue;
         if(HistoryDealGetInteger(tk, DEAL_ENTRY) == DEAL_ENTRY_IN) cnt++;
        }
      return cnt;
     }

   //--- any open position or pending order on the symbol from this EA
   bool              HasExposure()
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) == m_sym && PositionGetInteger(POSITION_MAGIC) == m_magic) return true;
        }
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong tk = OrderGetTicket(i);
         if(tk == 0) continue;
         if(OrderGetString(ORDER_SYMBOL) == m_sym && OrderGetInteger(ORDER_MAGIC) == m_magic) return true;
        }
      return false;
     }

   //--- most recent losing exit by this EA in the last 7 days: direction of the closed position and exit time
   bool              LastLoss(const datetime now, int &dir, datetime &when)
     {
      dir = 0; when = 0;
      if(!HistorySelect(now - 7 * 86400, now + 60)) return false;
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong tk = HistoryDealGetTicket(i);
         if(tk == 0) continue;
         if(HistoryDealGetInteger(tk, DEAL_MAGIC) != m_magic) continue;
         if(HistoryDealGetString(tk, DEAL_SYMBOL) != m_sym) continue;
         if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         double net = HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP) +
                      HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
         if(net >= 0) return false;    // most recent exit was not a loss
         //--- the exit deal of a BUY position is a SELL deal
         dir  = HistoryDealGetInteger(tk, DEAL_TYPE) == DEAL_TYPE_SELL ? 1 : -1;
         when = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
         return true;
        }
      return false;
     }

   //--- G1 account-level gate
   bool              AccountGate(const datetime now, const double dailyLossPct, const int maxTrades, string &why)
     {
      double e0 = DayStartEquity(now);
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      double limit = e0 * dailyLossPct / 100.0;
      if(LockedToday(now)) { why = "daily lockout active"; return false; }
      if(e0 - eq >= limit)
        {
         Lock(now, StringFormat("loss %.2f >= limit %.2f", e0 - eq, limit));
         why = "daily loss limit reached";
         return false;
        }
      int t = TradesToday(now);
      if(t >= maxTrades) { why = StringFormat("max trades reached (%d)", t); return false; }
      if(HasExposure())  { why = "position or order already open"; return false; }
      return true;
     }

   //--- size the trade and verify the risk budget. Fills lots/riskMoney/worstRisk/riskPct.
   bool              SizeAndVerify(GECandidate &c, const double riskPct, const double slipBuffer,
                                   const double commissionPerLotRT, const double hardCapLots,
                                   const double dailyLossPct, const datetime now, string &why)
     {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq <= 0) { why = "equity unavailable"; return false; }
      double budget = eq * riskPct / 100.0;
      ENUM_ORDER_TYPE ot = c.dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

      //--- loss of 1.00 lot from entry to SL, via the broker's own calculation
      double p1 = 0.0;
      if(!OrderCalcProfit(ot, m_sym, 1.0, c.entry, c.sl, p1)) { why = StringFormat("OrderCalcProfit failed (%d)", GetLastError()); return false; }
      double lossPerLot = MathAbs(p1);
      if(lossPerLot <= 0 || c.slDist <= 0) { why = "invalid loss per lot"; return false; }
      double scale = (c.slDist + slipBuffer) / c.slDist;           // add slippage allowance
      double perLotWorst = lossPerLot * scale + commissionPerLotRT;

      double vmin  = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_MIN);
      double vmax  = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_MAX);
      double vstep = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_STEP);
      if(vstep <= 0) { why = "invalid volume step"; return false; }

      double raw  = budget / perLotWorst;
      double lots = MathFloor(raw / vstep + 1e-9) * vstep;
      lots = MathMin(lots, MathMin(vmax, hardCapLots));
      lots = NormalizeDouble(lots, 8);
      if(lots < vmin - 1e-12)
        {
         why = StringFormat("min volume %.2f would risk %.2f > budget %.2f -> SKIP", vmin, vmin * perLotWorst, budget);
         return false;
        }

      //--- verify with the actual volume
      double p2 = 0.0;
      if(!OrderCalcProfit(ot, m_sym, lots, c.entry, c.sl, p2)) { why = "OrderCalcProfit (verify) failed"; return false; }
      double planned = MathAbs(p2);
      double worst   = planned * scale + commissionPerLotRT * lots;
      if(worst > budget + 1e-9) { why = StringFormat("worst-case %.2f exceeds budget %.2f", worst, budget); return false; }

      //--- daily-loss projection
      double e0 = DayStartEquity(now);
      double limit = e0 * dailyLossPct / 100.0;
      if((e0 - eq) + worst > limit + 1e-9)
        { why = StringFormat("trade would breach daily limit (%.2f + %.2f > %.2f)", e0 - eq, worst, limit); return false; }

      //--- margin check
      double margin = 0.0;
      if(!OrderCalcMargin(ot, m_sym, lots, c.entry, margin)) { why = "OrderCalcMargin failed"; return false; }
      if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.5) { why = StringFormat("margin %.2f too large vs free margin", margin); return false; }

      c.lots      = lots;
      c.riskMoney = planned;
      c.worstRisk = worst;
      c.riskPct   = worst / eq * 100.0;
      return true;
     }

   //--- persist per-position metadata for the trade journal
   void              SaveMeta(const long posId, const GECandidate &c, const int aiCode)
     {
      string p = m_prefix + "P" + IntegerToString(posId) + "_";
      GlobalVariableSet(p + "risk", c.worstRisk);
      GlobalVariableSet(p + "plan", c.riskMoney);
      GlobalVariableSet(p + "sld",  c.slDist);
      GlobalVariableSet(p + "spr",  c.spread);
      GlobalVariableSet(p + "ai",   aiCode);
      GlobalVariableSet(p + "eval", c.evalPrice);
     }

   double            MetaGet(const long posId, const string field, const double def)
     {
      string k = m_prefix + "P" + IntegerToString(posId) + "_" + field;
      return GlobalVariableCheck(k) ? GlobalVariableGet(k) : def;
     }

   void              MetaDelete(const long posId)
     {
      GlobalVariablesDeleteAll(m_prefix + "P" + IntegerToString(posId) + "_");
     }
  };

#endif
