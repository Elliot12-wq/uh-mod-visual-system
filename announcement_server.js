// node announcement_server.js   (env: PORT optional, ROLES_URL optional)
// Global announcement backend. No key, no SHA-256, no token: the owner is read from roles.json on GitHub.
const http = require("http");
const ROLES_URL = process.env.ROLES_URL || "https://raw.githubusercontent.com/Elliot12-wq/uh-mod-visual-system/main/roles.json";
let cache = { at: 0, owners: [] };
const owners = async () => {
  if (Date.now() - cache.at < 20000) return cache.owners;
  cache.at = Date.now() - 15000;
  try {
    const r = await fetch(ROLES_URL + "?t=" + Date.now(), { headers: { "Cache-Control": "no-cache" } });
    if (r.ok) {
      const d = await r.json();
      cache = { at: Date.now(), owners: (Array.isArray(d.entries) ? d.entries : [])
        .filter(e => e && String(e.role || "").toLowerCase() === "owner")
        .map(e => ({ name: typeof e.username === "string" ? e.username.toLowerCase() : "", id: Math.floor(Number(e.userId)) || 0 })) };
    }
  } catch {}
  return cache.owners;
};
let msgs = [], lastId = 0, lastSend = 0;
http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  const out = (c, o) => { res.writeHead(c, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" }); res.end(JSON.stringify(o)); };
  if (req.method === "GET" && u.pathname === "/poll") {
    const a = u.searchParams.get("after");
    return out(200, { id: lastId, msgs: a === null ? [] : msgs.filter(m => m.id > Number(a)) });
  }
  if (req.method === "GET" && u.pathname === "/owner") {
    return owners().then(o => out(200, { owners: o.map(x => x.name).filter(Boolean) }));
  }
  if (req.method === "POST" && u.pathname === "/send") {
    let b = "";
    req.on("data", d => { b += d; if (b.length > 4096) req.destroy(); });
    req.on("end", async () => {
      let j; try { j = JSON.parse(b); } catch { return out(400, {}); }
      const name = String(j.user || "").toLowerCase(), id = Math.floor(Number(j.userId)) || 0;
      const ok = (await owners()).some(o => (o.name && o.name === name) || (o.id && o.id === id));
      if (!ok) return out(403, {});
      const text = String(j.text || "").replace(/[\u0000-\u001f<>]/g, " ").trim().slice(0, 200);
      if (!text || Date.now() - lastSend < 2000) return out(400, {});
      lastSend = Date.now();
      lastId = Math.max(Date.now(), lastId + 1);
      msgs.push({ id: lastId, text });
      msgs = msgs.slice(-50);
      out(200, { id: lastId });
    });
    return;
  }
  out(404, {});
}).listen(process.env.PORT || 3000);
