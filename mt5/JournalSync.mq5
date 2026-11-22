//+------------------------------------------------------------------+
//|  JournalSync.mq5 — Envía tus operaciones cerradas al Trading      |
//|  Journal automáticamente.                                         |
//|                                                                  |
//|  1) En la app: Ajustes → Conectar cuenta MT5 → Generar código.    |
//|  2) Herramientas → Opciones → Asesores Expertos → marca          |
//|     "Permitir WebRequest para las URL" y agrega estas 2:         |
//|        https://securetoken.googleapis.com                        |
//|        https://firestore.googleapis.com                          |
//|  3) Arrastra JournalSync a un gráfico y pega el código.          |
//|                                                                  |
//|  Solo LEE el historial: no abre, cierra ni modifica operaciones. |
//+------------------------------------------------------------------+
#property copyright "Trading Journal"
#property version   "2.00"
#property strict

input string CodigoConexion = "";   // Código de conexión (de la app: Ajustes → Conectar cuenta MT5)
input int    DiasHistorial  = 90;   // Días de historial a enviar al conectar

// Proyecto Firebase del journal (datos públicos de la app web)
const string API_KEY = "AIzaSyBvMv1TXHtabehe4ERSrec8bdy63y371wI";
const string PROJECT = "trading-journal-15208";

string   g_idToken = "", g_refresh = "", g_uid = "", g_accId = "", g_code = "";
datetime g_tokenTime = 0;
bool     g_dirty = true;
string   g_sentKeys[], g_sentSigs[];

//+------------------------------------------------------------------+
int OnInit()
{
   g_code = Trim(CodigoConexion); StringToUpper(g_code);
   LoadAuth();
   if(g_refresh == "" && g_code == "")
   { Alert("JournalSync: pega el código de la app (Ajustes → Conectar cuenta MT5)."); return(INIT_PARAMETERS_INCORRECT); }
   EventSetTimer(30);
   Comment("JournalSync: conectando…");
   LoadSent();
   Sync();
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason) { EventKillTimer(); Comment(""); }
void OnTimer() { Sync(); }
void OnTradeTransaction(const MqlTradeTransaction &t, const MqlTradeRequest &rq, const MqlTradeResult &rs)
{ if(t.type == TRADE_TRANSACTION_DEAL_ADD) g_dirty = true; }

//──────────────────────────── utilidades ───────────────────────────
string Trim(string s) { StringTrimLeft(s); StringTrimRight(s); return s; }
// Extrae el texto de "key": "valor" (primera aparición desde 'from')
string JsonStr(const string json, const string key, int from = 0)
{
   int k = StringFind(json, "\"" + key + "\"", from); if(k < 0) return "";
   int c = StringFind(json, ":", k);                    if(c < 0) return "";
   int q1 = StringFind(json, "\"", c + 1);              if(q1 < 0) return "";
   int q2 = StringFind(json, "\"", q1 + 1);             if(q2 < 0) return "";
   return StringSubstr(json, q1 + 1, q2 - q1 - 1);
}
// Valor de texto de un campo Firestore: "campo": {"stringValue": "..."}
string FsStr(const string json, const string field)
{
   int k = StringFind(json, "\"" + field + "\""); if(k < 0) return "";
   return JsonStr(json, "stringValue", k);
}
int Http(const string method, const string url, const string headers, const string body, string &resp)
{
   char data[], res[]; string rh;
   if(StringLen(body) > 0)
   {
      int n = StringToCharArray(body, data, 0, -1, CP_UTF8);
      if(n > 0) ArrayResize(data, n - 1);
   }
   ResetLastError();
   int st = WebRequest(method, url, headers, 15000, data, res, rh);
   resp = CharArrayToString(res, 0, -1, CP_UTF8);
   if(st == -1)
   {
      int err = GetLastError();
      if(err == 4014)
         Comment("JournalSync: ❌ Falta permitir las URL en Herramientas → Opciones → Asesores Expertos:\n" +
                 "https://securetoken.googleapis.com\nhttps://firestore.googleapis.com");
      else Comment("JournalSync: ⚠️ Sin conexión (error " + IntegerToString(err) + "). Reintentando…");
   }
   return st;
}
string Docs() { return "https://firestore.googleapis.com/v1/projects/" + PROJECT + "/databases/(default)/documents"; }

//──────────────────────────── conexión ─────────────────────────────
// Archivo local con: código usado | cuenta del journal | token de sesión
string AuthFile() { return "JournalSync_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".auth"; }
void LoadAuth()
{
   int fh = FileOpen(AuthFile(), FILE_READ | FILE_TXT | FILE_ANSI); if(fh == INVALID_HANDLE) return;
   string savedCode = FileReadString(fh), acc = FileReadString(fh), tok = FileReadString(fh);
   FileClose(fh);
   // Si se pegó un código nuevo, se usa el nuevo; si no, se reutiliza la conexión guardada
   if(g_code == "" || g_code == savedCode) { g_accId = acc; g_refresh = tok; g_code = savedCode; }
}
void SaveAuth()
{
   int fh = FileOpen(AuthFile(), FILE_WRITE | FILE_TXT | FILE_ANSI); if(fh == INVALID_HANDLE) return;
   FileWriteString(fh, g_code + "\n" + g_accId + "\n" + g_refresh + "\n"); FileClose(fh);
}
string AuthHdr() { return "Authorization: Bearer " + g_idToken + "\r\nContent-Type: application/json\r\n"; }
bool Refresh()
{
   string resp;
   int st = Http("POST", "https://securetoken.googleapis.com/v1/token?key=" + API_KEY,
                 "Content-Type: application/x-www-form-urlencoded\r\n",
                 "grant_type=refresh_token&refresh_token=" + g_refresh, resp);
   if(st != 200)
   {
      if(st > 0) Comment("JournalSync: ❌ La conexión ya no es válida. Genera un código nuevo en la app.");
      return false;
   }
   g_idToken = JsonStr(resp, "id_token"); g_uid = JsonStr(resp, "user_id");
   string nr = JsonStr(resp, "refresh_token"); if(nr != "" && nr != g_refresh) { g_refresh = nr; SaveAuth(); }
   g_tokenTime = TimeLocal();
   return g_idToken != "" && g_uid != "";
}
// Canjea el código de un solo uso que generó la app
bool Claim()
{
   string resp;
   int st = Http("GET", Docs() + "/links/" + g_code + "?key=" + API_KEY, "", "", resp);
   if(st == 404 || st == 403)
   { Comment("JournalSync: ❌ Código inválido o ya usado. Genera uno nuevo en la app."); return false; }
   if(st != 200) return false;
   g_refresh = FsStr(resp, "token"); g_accId = FsStr(resp, "acc");
   if(g_refresh == "" || g_accId == "") { Comment("JournalSync: ❌ Código incompleto. Genera uno nuevo en la app."); return false; }
   if(!Refresh()) return false;
   // El código se borra para que no se pueda volver a usar (y la app muestra "MT5 conectado")
   string r2; Http("POST", Docs() + "/links/" + g_code, AuthHdr() + "X-HTTP-Method-Override: DELETE\r\n", "", r2);
   SaveAuth();
   Print("JournalSync: conectado a la cuenta del journal '", g_accId, "'.");
   return true;
}
bool EnsureToken()
{
   if(g_idToken != "" && TimeLocal() - g_tokenTime < 3000) return true;
   if(g_refresh == "") return Claim();
   return Refresh();
}

//──────────────────────────── días ya enviados (evita reenviar) ────
string SentFile() { return "JournalSync_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".sent"; }
void LoadSent()
{
   ArrayResize(g_sentKeys, 0); ArrayResize(g_sentSigs, 0);
   int fh = FileOpen(SentFile(), FILE_READ | FILE_TXT | FILE_ANSI); if(fh == INVALID_HANDLE) return;
   while(!FileIsEnding(fh))
   {
      string line = FileReadString(fh); int p = StringFind(line, "=");
      if(p > 0)
      {
         int n = ArraySize(g_sentKeys); ArrayResize(g_sentKeys, n + 1); ArrayResize(g_sentSigs, n + 1);
         g_sentKeys[n] = StringSubstr(line, 0, p); g_sentSigs[n] = StringSubstr(line, p + 1);
      }
   }
   FileClose(fh);
}
void SaveSent()
{
   int fh = FileOpen(SentFile(), FILE_WRITE | FILE_TXT | FILE_ANSI); if(fh == INVALID_HANDLE) return;
   for(int i = 0; i < ArraySize(g_sentKeys); i++) FileWriteString(fh, g_sentKeys[i] + "=" + g_sentSigs[i] + "\n");
   FileClose(fh);
}
string GetSent(string k) { for(int i = 0; i < ArraySize(g_sentKeys); i++) if(g_sentKeys[i] == k) return g_sentSigs[i]; return ""; }
void   SetSent(string k, string v)
{
   for(int i = 0; i < ArraySize(g_sentKeys); i++) if(g_sentKeys[i] == k) { g_sentSigs[i] = v; return; }
   int n = ArraySize(g_sentKeys); ArrayResize(g_sentKeys, n + 1); ArrayResize(g_sentSigs, n + 1);
   g_sentKeys[n] = k; g_sentSigs[n] = v;
}

//──────────────────────────── resumen por día ──────────────────────
struct Pos { long id; double net; datetime lastExit; int side; bool tp; bool sl; bool closed; };
struct Day { string key; double pnl; int trades; int buys; int sells; bool tp; bool sl; };

string DayKey(datetime t) { string s = TimeToString(t, TIME_DATE); StringReplace(s, ".", "-"); return s; }

int BuildDays(Day &days[])
{
   ArrayResize(days, 0);
   if(!HistorySelect(TimeCurrent() - (DiasHistorial + 30) * 86400, TimeCurrent() + 86400)) return 0;
   Pos ps[]; int np = 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = HistoryDealGetTicket(i); if(tk == 0) continue;
      long type = HistoryDealGetInteger(tk, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;      // ignora depósitos, etc.
      long pid   = HistoryDealGetInteger(tk, DEAL_POSITION_ID);
      long entry = HistoryDealGetInteger(tk, DEAL_ENTRY);
      double net = HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_COMMISSION)
                 + HistoryDealGetDouble(tk, DEAL_SWAP)   + HistoryDealGetDouble(tk, DEAL_FEE);
      datetime t = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
      int k = -1; for(int j = 0; j < np; j++) if(ps[j].id == pid) { k = j; break; }
      if(k < 0)
      {
         ArrayResize(ps, np + 1); k = np++;
         ps[k].id = pid; ps[k].net = 0; ps[k].lastExit = 0; ps[k].side = 0;
         ps[k].tp = false; ps[k].sl = false; ps[k].closed = false;
      }
      ps[k].net += net;
      if(entry == DEAL_ENTRY_IN) ps[k].side = (type == DEAL_TYPE_BUY ? 1 : -1);
      else
      {
         ps[k].closed = true; if(t > ps[k].lastExit) ps[k].lastExit = t;
         if(ps[k].side == 0) ps[k].side = (type == DEAL_TYPE_BUY ? -1 : 1);
         string cm = HistoryDealGetString(tk, DEAL_COMMENT);
         if(StringFind(cm, "[tp") >= 0) ps[k].tp = true;
         if(StringFind(cm, "[sl") >= 0) ps[k].sl = true;
      }
   }
   // Posiciones cerradas, agrupadas por día de cierre (igual que el importador)
   datetime minDay = TimeCurrent() - DiasHistorial * 86400;
   int nd = 0;
   for(int j = 0; j < np; j++)
   {
      if(!ps[j].closed || ps[j].lastExit < minDay) continue;
      string key = DayKey(ps[j].lastExit);
      int d = -1; for(int x = 0; x < nd; x++) if(days[x].key == key) { d = x; break; }
      if(d < 0)
      {
         ArrayResize(days, nd + 1); d = nd++;
         days[d].key = key; days[d].pnl = 0; days[d].trades = 0; days[d].buys = 0; days[d].sells = 0;
         days[d].tp = false; days[d].sl = false;
      }
      days[d].pnl += ps[j].net; days[d].trades++;
      if(ps[j].side > 0) days[d].buys++; else days[d].sells++;
      if(ps[j].tp) days[d].tp = true;
      if(ps[j].sl) days[d].sl = true;
   }
   return nd;
}

//──────────────────────────── sincronización ───────────────────────
void Sync()
{
   if(!EnsureToken()) return;
   if(!g_dirty) { Status(); return; }

   Day days[]; int nd = BuildDays(days);
   int sent = 0;
   for(int i = 0; i < nd; i++)
   {
      double pnl = MathRound(days[i].pnl * 100.0) / 100.0;
      string side = (days[i].buys >= days[i].sells ? "buy" : "sell");
      string tags = "";
      if(days[i].tp) tags += "{\"stringValue\":\"tp\"}";
      if(days[i].sl) tags += (tags == "" ? "" : ",") + "{\"stringValue\":\"sl\"}";
      string sig = DoubleToString(pnl, 2) + "|" + IntegerToString(days[i].trades) + "|" + side + "|" + tags;
      string docId = g_accId + "__" + days[i].key;
      if(GetSent(docId) == sig) continue;

      // Solo se actualizan P&L, trades, lado y tags: notas y pantallazos del journal se mantienen
      string body = "{\"fields\":{";
      body += "\"acc\":{\"stringValue\":\"" + g_accId + "\"},";
      body += "\"date\":{\"stringValue\":\"" + days[i].key + "\"},";
      body += "\"updated\":{\"integerValue\":\"" + IntegerToString((long)TimeGMT() * 1000) + "\"},";
      body += "\"day\":{\"mapValue\":{\"fields\":{";
      body += "\"pnl\":{\"doubleValue\":" + DoubleToString(pnl, 2) + "},";
      body += "\"trades\":{\"integerValue\":\"" + IntegerToString(days[i].trades) + "\"},";
      body += "\"side\":{\"stringValue\":\"" + side + "\"},";
      body += "\"tags\":{\"arrayValue\":{" + (tags == "" ? "" : "\"values\":[" + tags + "]") + "}},";
      body += "\"src\":{\"stringValue\":\"mt5\"}";
      body += "}}}}}";
      string mask = "?updateMask.fieldPaths=acc&updateMask.fieldPaths=date&updateMask.fieldPaths=updated";
      mask += "&updateMask.fieldPaths=day.pnl&updateMask.fieldPaths=day.trades&updateMask.fieldPaths=day.side";
      mask += "&updateMask.fieldPaths=day.tags&updateMask.fieldPaths=day.src";
      string resp;
      int st = Http("POST", Docs() + "/users/" + g_uid + "/days/" + docId + mask,
                    AuthHdr() + "X-HTTP-Method-Override: PATCH\r\n", body, resp);
      if(st == 401 || st == 403) { g_idToken = ""; return; }   // sesión vencida: se renueva en el próximo ciclo
      if(st != 200) { Comment("JournalSync: ⚠️ Error al enviar " + days[i].key + " (" + IntegerToString(st) + ")"); return; }
      SetSent(docId, sig); sent++;
   }
   if(sent > 0) SaveSent();
   g_dirty = false;
   Status();
   if(sent > 0) Print("JournalSync: ", sent, " día(s) enviados al journal.");
}
void Status()
{
   Comment("JournalSync: ✅ Conectado a tu Trading Journal · " + TimeToString(TimeLocal(), TIME_MINUTES) +
           "\nSolo lee el historial. Cada operación cerrada aparece sola en el journal.");
}
//+------------------------------------------------------------------+
