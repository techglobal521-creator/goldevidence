//+------------------------------------------------------------------+
//| Execution.mqh - order placement with mandatory SL/TP             |
//| SL and TP are sent in the same request. After the fill the       |
//| position is checked; if SL/TP are missing they are re-applied,   |
//| and if that fails the position is closed immediately.            |
//+------------------------------------------------------------------+
#ifndef GE_EXECUTION_MQH
#define GE_EXECUTION_MQH

#include <Trade/Trade.mqh>
#include "Types.mqh"

class CGEExecution
  {
private:
   CTrade            m_trade;
   string            m_sym;
   long              m_magic;

public:
   void              Init(const string sym, const long magic, const int deviationPoints)
     {
      m_sym = sym;
      m_magic = magic;
      m_trade.SetExpertMagicNumber((ulong)magic);
      m_trade.SetDeviationInPoints((ulong)deviationPoints);
      m_trade.SetTypeFillingBySymbol(sym);
      m_trade.SetAsyncMode(false);
     }

   //--- returns position identifier (>0) on success, 0 on failure
   long              Open(const GECandidate &c, string &why)
     {
      bool ok;
      if(c.dir > 0) ok = m_trade.Buy(c.lots, m_sym, 0.0, c.sl, c.tp, c.id);
      else          ok = m_trade.Sell(c.lots, m_sym, 0.0, c.sl, c.tp, c.id);
      uint rc = m_trade.ResultRetcode();
      if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED && rc != TRADE_RETCODE_DONE_PARTIAL))
        {
         why = StringFormat("order failed rc=%u %s", rc, m_trade.ResultRetcodeDescription());
         return 0;
        }
      //--- find our position and verify protection
      for(int attempt = 0; attempt < 5; attempt++)
        {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
           {
            ulong tk = PositionGetTicket(i);
            if(tk == 0) continue;
            if(PositionGetString(POSITION_SYMBOL) != m_sym || PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
            long   pid = PositionGetInteger(POSITION_IDENTIFIER);
            double sl  = PositionGetDouble(POSITION_SL);
            double tp  = PositionGetDouble(POSITION_TP);
            if(sl > 0 && tp > 0) return pid;
            //--- protection missing: re-apply once, else close
            if(m_trade.PositionModify(tk, c.sl, c.tp))
              {
               if(PositionSelectByTicket(tk) && PositionGetDouble(POSITION_SL) > 0 && PositionGetDouble(POSITION_TP) > 0) return pid;
              }
            m_trade.PositionClose(tk);
            why = "position opened without SL/TP and could not be protected -> closed";
            return 0;
           }
         Sleep(200);
        }
      why = "order reported done but position not found";
      return 0;
     }

   //--- close every position of this EA on the symbol
   int               CloseAll(const string reason)
     {
      int closed = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_sym || PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         if(m_trade.PositionClose(tk)) { closed++; PrintFormat("GE: closed position %I64u (%s)", tk, reason); }
         else PrintFormat("GE: FAILED to close position %I64u (%s) rc=%u", tk, reason, m_trade.ResultRetcode());
        }
      return closed;
     }
  };

#endif
