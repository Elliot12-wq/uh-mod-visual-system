// Cloudflare Worker + Durable Object (one DO per Roblox server "room"). Poll-based live sync.
const ID = /^\d{1,16}$/, ROOM = /^[0-9A-Za-z:_-]{1,80}$/, IMG = /^(rbxassetid:\/\/)?\d{1,19}$/;
const TTL = 75000;
const s = (v, n) => String(v ?? "").replace(/[\u0000-\u001f\u007f]/g, "").slice(0, n);

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    let body = null, room = url.searchParams.get("room");
    if (req.method === "POST") {
      const txt = await req.text();
      if (txt.length > 2048) return new Response("too large", { status: 413 });
      try { body = JSON.parse(txt); } catch { return new Response("bad json", { status: 400 }); }
      room = body && body.room;
    }
    if (!ROOM.test(room || "")) return new Response("bad room", { status: 400 });
    const stub = env.ROOM.get(env.ROOM.idFromName(room));
    return stub.fetch(new Request("https://do" + url.pathname, { method: req.method, body: body ? JSON.stringify(body) : undefined }));
  },
};

export class Room {
  constructor(state) { this.st = state.storage; }
  async fetch(req) {
    const now = Date.now(), p = new URL(req.url).pathname;
    const m = (await this.st.get("m")) || {};
    for (const k in m) if (m[k].exp < now) delete m[k];
    let res;
    if (req.method === "GET" && p === "/banners") {
      res = { banners: Object.values(m).map(({ token, exp, ...pub }) => pub) };
    } else if (req.method === "POST" && (p === "/banner" || p === "/clear")) {
      const b = await req.json(), id = String(b.userId);
      const tok = typeof b.token === "string" && b.token.length >= 8 && b.token.length <= 64 ? b.token : null;
      if (!ID.test(id) || !tok) return new Response("bad", { status: 400 });
      if (m[id] && m[id].token !== tok) return new Response("claimed", { status: 403 }); // first claimant owns the id until TTL
      if (p === "/clear") delete m[id];
      else m[id] = { token: tok, exp: now + TTL, userId: +id, name: s(b.name, 40), title: s(b.title, 40), subtitle: s(b.subtitle, 40), image: IMG.test(b.image || "") ? String(b.image) : "", ts: now };
      res = { ok: true };
    } else return new Response("not found", { status: 404 });
    if (Object.keys(m).length) await this.st.put("m", m); else await this.st.deleteAll();
    return Response.json(res);
  }
}
