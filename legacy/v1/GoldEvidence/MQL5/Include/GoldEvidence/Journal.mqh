//+------------------------------------------------------------------+
//| Journal.mqh - CSV journals (MQL5\Files\GoldEvidence\...)          |
//| In the Strategy Tester files are written inside the tester        |
//| agent's sandbox: <agent>\MQL5\Files\GoldEvidence\                 |
//|   decisions.csv  - every evaluated bar, gate results              |
//|   trades.csv     - every closed trade with R multiple, MAE/MFE    |
//|   virtual.csv    - AI-vetoed candidates tracked as virtual trades |
//+------------------------------------------------------------------+
#ifndef GE_JOURNAL_MQH
#define GE_JOURNAL_MQH

class CGEJournal
  {
private:
   string            m_dir;

   bool              Append(const string file, const string header, const string line)
     {
      string path = m_dir + "\\" + file;
      bool exists = FileIsExist(path);
      int h = FileOpen(path, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
      if(h == INVALID_HANDLE) { PrintFormat("GE: cannot open %s (%d)", path, GetLastError()); return false; }
      FileSeek(h, 0, SEEK_END);
      if(!exists || FileSize(h) == 0) FileWriteString(h, header + "\r\n");
      FileWriteString(h, line + "\r\n");
      FileClose(h);
      return true;
     }

public:
   void              Init(const string dir) { m_dir = dir; FolderCreate(dir); }

   static string     Esc(const string s)
     {
      string r = s;
      StringReplace(r, ",", ";");
      StringReplace(r, "\r", " ");
      StringReplace(r, "\n", " ");
      return r;
     }

   void              Decision(const datetime barTime, const string mode, const int dir, const bool pass,
                              const string gate, const string detail)
     {
      string header = "bar_time,mode,dir,pass,failed_gate,detail";
      string line = StringFormat("%s,%s,%s,%d,%s,%s", TimeToString(barTime, TIME_DATE | TIME_MINUTES), mode,
                                 dir > 0 ? "BUY" : (dir < 0 ? "SELL" : "NONE"), pass ? 1 : 0, gate, Esc(detail));
      Append("decisions.csv", header, line);
     }

   void              Trade(const string line)
     {
      string header = "position_id,symbol,dir,open_time,close_time,entry,exit,sl_dist,lots,planned_risk,worst_risk,"
                      "net_pnl,r_multiple,exit_reason,spread_at_entry,mae_r,mfe_r,ai_code,balance_after";
      Append("trades.csv", header, line);
     }

   void              Virtual(const string line)
     {
      string header = "candidate_id,dir,open_time,close_time,entry,sl,tp,result,r_multiple";
      Append("virtual.csv", header, line);
     }
  };

#endif
