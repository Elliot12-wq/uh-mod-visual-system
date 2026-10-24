// Node >=18 port of worker.js (same API, in-memory rooms, no dependencies). Any Node host works.
const http = require("http");
const ID = /^\d{1,16}$/, ROOM = /^[0-9A-Za-z:_-]{1,80}$/, IMG = /^(rbxassetid:\/\/)?\d{1,19}$/;
const TTL = 75000, rooms = new Map();
const s = (v, n) => String(v ?? "").replace(/[\u0000-\u001f\u007f]/g, "").slice(0, n);
const send = (res, code, body) => { res.writeHead(code, { "Content-Type": "application/json" }); res.end(JSON.stringify(body)); };
const live = (room) => { const m = rooms.get(room) || {}, now = Date.now(); for (const k in m) if (m[k].exp < now) delete m[k]; return m; };
setInterval(() => { for (const r of [...rooms.keys()]) if (!Object.keys(live(r)).length) rooms.delete(r); }, 15000).unref();

http.createServer((req, res) => {
  const url = new URL(req.url, "http://x"), p = url.pathname;
  if (req.method === "GET" && p === "/") return send(res, 200, { ok: true });
  if (req.method === "GET" && p === "/banners") {
    const room = url.searchParams.get("room");
    if (!ROOM.test(room || "")) return send(res, 400, { error: "bad room" });
    return send(res, 200, { banners: Object.values(live(room)).map(({ token, exp, ...pub }) => pub) });
  }
  if (req.method === "POST" && (p === "/banner" || p === "/clear")) {
    let txt = "", dead = false;
    req.on("data", (c) => { if (dead) return; txt += c; if (txt.length > 2048) { dead = true; send(res, 413, { error: "too large" }); } });
    req.on("end", () => {
      if (dead) return;
      let b; try { b = JSON.parse(txt); } catch { return send(res, 400, { error: "bad json" }); }
      if (!b || !ROOM.test(b.room || "")) return send(res, 400, { error: "bad room" });
      const m = live(b.room), id = String(b.userId), now = Date.now();
      const tok = typeof b.token === "string" && b.token.length >= 8 && b.token.length <= 64 ? b.token : null;
      if (!ID.test(id) || !tok) return send(res, 400, { error: "bad" });
      if (m[id] && m[id].token !== tok) return send(res, 403, { error: "claimed" }); // first claimant owns the id until TTL
      if (p === "/clear") delete m[id];
      else m[id] = { token: tok, exp: now + TTL, userId: +id, name: s(b.name, 40), title: s(b.title, 40), subtitle: s(b.subtitle, 40), image: IMG.test(b.image || "") ? String(b.image) : "", ts: now };
      rooms.set(b.room, m);
      send(res, 200, { ok: true });
    });
    return;
  }
  send(res, 404, { error: "not found" });
}).listen(process.env.PORT || 3000);
