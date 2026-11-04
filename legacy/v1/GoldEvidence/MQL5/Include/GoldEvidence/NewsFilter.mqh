//+------------------------------------------------------------------+
//| NewsFilter.mqh - high-impact USD news blocking                   |
//| Live/demo: MQL5 economic calendar.                               |
//| Strategy Tester: CSV exported by Scripts/GoldEvidence/           |
//|   GE_ExportNews.mq5 (calendar is not available in the tester).   |
//| CSV format (Common\Files): time,currency,importance,name         |
//|   time = "YYYY.MM.DD HH:MI" in broker SERVER time                |
//| Fail closed: if the calendar cannot be read, trading is blocked. |
//+------------------------------------------------------------------+
#ifndef GE_NEWSFILTER_MQH
#define GE_NEWSFILTER_MQH

class CGENews
  {
private:
   bool              m_useCsv;
   datetime          m_times[];
   string            m_names[];
   int               m_beforeMin, m_afterMin, m_majorBeforeMin, m_majorAfterMin;

   bool              IsMajor(const string name)
     {
      string u = name;
      StringToUpper(u);
      return StringFind(u, "NONFARM") >= 0 || StringFind(u, "NON-FARM") >= 0 ||
             StringFind(u, "CPI") >= 0 || StringFind(u, "CONSUMER PRICE") >= 0 ||
             StringFind(u, "FOMC") >= 0 || StringFind(u, "FED INTEREST RATE") >= 0 ||
             StringFind(u, "FEDERAL FUNDS") >= 0 || StringFind(u, "INTEREST RATE DECISION") >= 0;
     }

   bool              InWindow(const datetime now, const datetime ev, const string name)
     {
      int b = IsMajor(name) ? m_majorBeforeMin : m_beforeMin;
      int a = IsMajor(name) ? m_majorAfterMin  : m_afterMin;
      return now >= ev - b * 60 && now <= ev + a * 60;
     }

public:
   bool              Init(const bool useCsv, const string csvName, const int beforeMin, const int afterMin,
                          const int majorBeforeMin, const int majorAfterMin, string &why)
     {
      m_useCsv = useCsv;
      m_beforeMin = beforeMin; m_afterMin = afterMin;
      m_majorBeforeMin = majorBeforeMin; m_majorAfterMin = majorAfterMin;
      ArrayResize(m_times, 0);
      ArrayResize(m_names, 0);
      if(!useCsv) return true;

      int h = FileOpen(csvName, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
      if(h == INVALID_HANDLE)
        {
         why = "news CSV not found in Common\\Files: " + csvName + " (run GE_ExportNews script first)";
         return false;
        }
      int n = 0;
      while(!FileIsEnding(h))
        {
         string line = FileReadString(h);
         StringTrimLeft(line);
         StringTrimRight(line);
         if(StringLen(line) < 16 || StringGetCharacter(line, 0) == '#') continue;
         string parts[];
         if(StringSplit(line, ',', parts) < 4) continue;
         if(parts[0] == "time") continue;   // header
         string imp = parts[2];
         StringToUpper(imp);
         if(imp != "HIGH") continue;
         datetime t = StringToTime(parts[0]);
         if(t <= 0) continue;
         ArrayResize(m_times, n + 1, 1024);
         ArrayResize(m_names, n + 1, 1024);
         m_times[n] = t;
         m_names[n] = parts[3];
         n++;
        }
      FileClose(h);
      if(n == 0) { why = "news CSV has no HIGH-importance rows"; return false; }
      PrintFormat("GE: loaded %d high-impact news events from %s (first %s, last %s)", n, csvName,
                  TimeToString(m_times[0]), TimeToString(m_times[n - 1]));
      return true;
     }

   //--- true = trading allowed. On any read failure returns false (fail closed).
   bool              Clear(const datetime now, string &why)
     {
      if(m_useCsv)
        {
         int n = ArraySize(m_times);
         if(n == 0) { why = "news CSV empty"; return false; }
         if(now > m_times[n - 1] + 7 * 86400) { why = "news CSV does not cover current date"; return false; }
         for(int i = 0; i < n; i++)
           {
            if(m_times[i] > now + 2 * 3600) break;
            if(InWindow(now, m_times[i], m_names[i])) { why = "news: " + m_names[i] + " @ " + TimeToString(m_times[i]); return false; }
           }
         return true;
        }

      MqlCalendarValue vals[];
      ResetLastError();
      if(!CalendarValueHistory(vals, now - 3 * 3600, now + 3 * 3600, NULL, "USD"))
        {
         int err = GetLastError();
         if(err != 0) { why = StringFormat("calendar unavailable (err %d)", err); return false; }
        }
      for(int i = 0; i < ArraySize(vals); i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev)) { why = "calendar event lookup failed"; return false; }
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;
         if(InWindow(now, vals[i].time, ev.name)) { why = "news: " + ev.name + " @ " + TimeToString(vals[i].time); return false; }
        }
      return true;
     }
  };

#endif
