// Nooby's uh modded reanimation - owner broadcast backend
// Run:  node broadcast_server.js
// Env:  OWNER_NAME = optional, the exact Roblox username allowed to send (default: kingbaconnon19)
//       PORT       = optional (default 3000)
// NO KEY CHECK: /send only checks that the sender's username is the owner's, so there is no
// OWNER_KEY_SHA256 to set. Anyone who knows that username can post an announcement.
// Routes: GET /poll[?after=id]   POST /send   GET /  (health check)
// Script side: set getgenv().UH_BROADCAST_URL = "https://your-host" (or edit BROADCAST_URL).

const http = require("http");

const OWNER = String(process.env.OWNER_NAME || "kingbaconnon19").trim();
const PORT = Number(process.env.PORT) || 3000;

let msgs = [], lastId = 0, lastSend = 0;

http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  const out = (code, obj) => {
    res.writeHead(code, { "Content-Type": "application/json" });
    res.end(JSON.stringify(obj));
  };

  if (req.method === "GET" && u.pathname === "/") return out(200, { ok: true });

  if (req.method === "GET" && u.pathname === "/poll") {
    const a = u.searchParams.get("after");
    return out(200, { id: lastId, msgs: a === null ? [] : msgs.filter((m) => m.id > Number(a)) });
  }

  if (req.method === "POST" && u.pathname === "/send") {
    let b = "";
    req.on("data", (d) => { b += d; if (b.length > 4096) req.destroy(); });
    req.on("error", () => {});
    req.on("end", () => {
      let j;
      try { j = JSON.parse(b); } catch { return out(400, {}); }
      if (!j || typeof j !== "object") return out(400, {});
      const nameOk = OWNER !== "" && String(j.user || "").toLowerCase() === OWNER.toLowerCase();
      if (!nameOk) return out(403, {});
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
}).listen(PORT, () => console.log("broadcast server listening on " + PORT));
