//+------------------------------------------------------------------+
//| GE_ExportNews.mq5 - Module 0                                     |
//| Exports HIGH-importance USD calendar events to                   |
//|   <Terminal>\Common\Files\GoldEvidence_news_USD.csv              |
//| so the Strategy Tester can apply the same news filter as live.   |
//| Run on a LIVE or DEMO chart (the calendar is not available in    |
//| the tester). Times are written in broker SERVER time, which is   |
//| the time base the EA uses.                                       |
//+------------------------------------------------------------------+
#property script_show_inputs
#property version "1.00"

input datetime InpFrom = D'2020.01.01 00:00';  // From (server time)
input datetime InpTo   = D'2027.12.31 23:59';  // To (include future scheduled events)
input string   InpFile = "GoldEvidence_news_USD.csv";

void OnStart()
  {
   int h = FileOpen(InpFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE) { PrintFormat("Cannot create %s (%d)", InpFile, GetLastError()); return; }
   FileWriteString(h, "time,currency,importance,name\r\n");

   int total = 0;
   //--- request month by month to keep arrays small
   for(datetime from = InpFrom; from < InpTo; )
     {
      MqlDateTime s;
      TimeToStruct(from, s);
      s.mon += 1;
      if(s.mon > 12) { s.mon = 1; s.year += 1; }
      s.day = 1; s.hour = 0; s.min = 0; s.sec = 0;
      datetime to = MathMin(StructToTime(s), InpTo);

      MqlCalendarValue vals[];
      ResetLastError();
      if(!CalendarValueHistory(vals, from, to, NULL, "USD") && GetLastError() != 0)
        {
         PrintFormat("Calendar request failed for %s: err=%d", TimeToString(from), GetLastError());
         FileClose(h);
         return;
        }
      for(int i = 0; i < ArraySize(vals); i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev)) continue;
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;
         string name = ev.name;
         StringReplace(name, ",", ";");
         FileWriteString(h, StringFormat("%s,USD,HIGH,%s\r\n", TimeToString(vals[i].time, TIME_DATE | TIME_MINUTES), name));
         total++;
        }
      from = to;
     }
   FileClose(h);
   PrintFormat("Exported %d high-impact USD events to Common\\Files\\%s", total, InpFile);
   PrintFormat("Check: compare one known NFP release time in the file with the broker chart to confirm the time base.");
  }
