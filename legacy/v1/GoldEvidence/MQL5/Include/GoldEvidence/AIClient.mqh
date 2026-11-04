//+------------------------------------------------------------------+
//| AIClient.mqh - EA side of the Claude review                      |
//| Sends the candidate evidence to the local Python service and     |
//| returns true ONLY for a valid, matching CONFIRM.                 |
//| Anything else (timeout, HTTP error, parse error, REJECT,         |
//| mismatched id) = not confirmed. Claude can never change          |
//| direction, SL, TP or volume: those fields are not read back.     |
//| Requires: Tools > Options > Expert Advisors >                    |
//|   "Allow WebRequest for listed URL" -> http://127.0.0.1:8787     |
//| WebRequest does not run in the Strategy Tester; the EA forces    |
//| AI_OFF there.                                                    |
//+------------------------------------------------------------------+
#ifndef GE_AICLIENT_MQH
#define GE_AICLIENT_MQH

#include "Types.mqh"
#include "MarketData.mqh"
#include "Structure.mqh"

//--- JSON helpers -------------------------------------------------------
string GEJsonEsc(const string s)
  {
   string r = s;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, "\"", "\\\"");
   StringReplace(r, "\r", " ");
   StringReplace(r, "\n", " ");
   return r;
  }

string GEJStr(const string k, const string v) { return "\"" + k + "\":\"" + GEJsonEsc(v) + "\""; }
string GEJNum(const string k, const double v, const int digits = 5) { return "\"" + k + "\":" + DoubleToString(v, digits); }
string GEJInt(const string k, const long v) { return "\"" + k + "\":" + IntegerToString(v); }
string GEJBool(const string k, const bool v) { return "\"" + k + "\":" + (v ? "true" : "false"); }

string GEBarsJson(const CGETimeframe &d, const int count, const int digits)
  {
   string s = "[";
   int n = MathMin(count, d.loaded - 1);
   for(int i = n; i >= 1; i--)   // oldest first, closed bars only
     {
      s += StringFormat("[\"%s\",%s,%s,%s,%s]", TimeToString(d.rates[i].time, TIME_DATE | TIME_MINUTES),
                        DoubleToString(d.rates[i].open, digits), DoubleToString(d.rates[i].high, digits),
                        DoubleToString(d.rates[i].low, digits), DoubleToString(d.rates[i].close, digits));
      if(i > 1) s += ",";
     }
   return s + "]";
  }

string GESwingsJson(const GESwing &zz[], const int lastN, const int digits)
  {
   string s = "[";
   int n = ArraySize(zz);
   int from = MathMax(0, n - lastN);
   for(int i = from; i < n; i++)
     {
      s += StringFormat("{\"type\":\"%s\",\"price\":%s,\"time\":\"%s\"}", zz[i].isHigh ? "HIGH" : "LOW",
                        DoubleToString(zz[i].price, digits), TimeToString(zz[i].time, TIME_DATE | TIME_MINUTES));
      if(i < n - 1) s += ",";
     }
   return s + "]";
  }

string GETfJson(const CGETimeframe &d, const GEStructure &st, const GESwing &zz[], const int digits)
  {
   double slope50 = d.atr[1] > 0 ? (d.ema50[1] - d.ema50[6]) / d.atr[1] : 0.0;
   return "{" + GEJStr("structure", GEBiasStr(st.bias)) + "," +
          GEJNum("close", d.rates[1].close, digits) + "," +
          GEJNum("ema20", d.ema20[1], digits) + "," + GEJNum("ema50", d.ema50[1], digits) + "," +
          GEJNum("ema200", d.ema200[1], digits) + "," + GEJNum("slope50_atr", slope50, 3) + "," +
          GEJNum("rsi", d.rsi[1], 2) + "," + GEJNum("rsi_prev", d.rsi[2], 2) + "," +
          GEJNum("atr", d.atr[1], digits) + "," +
          "\"swings\":" + GESwingsJson(zz, 6, digits) + "}";
  }

//--- extract a top-level string value from a flat JSON object (our own service's reply)
string GEJsonGetString(const string json, const string key)
  {
   string pat = "\"" + key + "\"";
   int p = StringFind(json, pat);
   if(p < 0) return "";
   p = StringFind(json, ":", p + StringLen(pat));
   if(p < 0) return "";
   p = StringFind(json, "\"", p + 1);
   if(p < 0) return "";
   string out = "";
   for(int i = p + 1; i < StringLen(json); i++)
     {
      ushort ch = StringGetCharacter(json, i);
      if(ch == '\\' && i + 1 < StringLen(json)) { out += ShortToString(StringGetCharacter(json, i + 1)); i++; continue; }
      if(ch == '"') return out;
      out += ShortToString(ch);
     }
   return "";
  }

//--- the client ----------------------------------------------------------
class CGEAIClient
  {
private:
   string            m_url;
   string            m_token;
   int               m_timeoutMs;

public:
   void              Init(const string url, const string token, const int timeoutMs)
     {
      m_url = url; m_token = token; m_timeoutMs = timeoutMs;
     }

   //--- returns 1 = CONFIRM, 2 = REJECT/invalid, 3 = transport error
   int               Review(const string payload, const string candidateId, string &summary)
     {
      char data[], result[];
      string respHeaders;
      int len = StringToCharArray(payload, data, 0, WHOLE_ARRAY, CP_UTF8);
      ArrayResize(data, len > 0 ? len - 1 : 0);     // drop trailing NUL
      string headers = "Content-Type: application/json\r\nX-EA-Token: " + m_token + "\r\n";
      ResetLastError();
      int code = WebRequest("POST", m_url, headers, m_timeoutMs, data, result, respHeaders);
      if(code == -1)
        {
         summary = StringFormat("WebRequest failed err=%d (is the URL allowed in Options?)", GetLastError());
         return 3;
        }
      string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      if(code != 200) { summary = StringFormat("HTTP %d", code); return 3; }
      string dec = GEJsonGetString(body, "decision");
      string id  = GEJsonGetString(body, "candidate_id");
      summary    = GEJsonGetString(body, "summary");
      if(id != candidateId) { summary = "candidate_id mismatch -> REJECT"; return 2; }
      if(dec == "CONFIRM") return 1;
      return 2;
     }
  };

#endif
