// Nooby-server-logger: one Durable Object holds live sessions (memory) + bans (storage).
// Events are only executed by script clients that poll /sync; nothing here controls arbitrary Roblox servers.
const TTL = 120000, EV_TTL = 120000, MAXL = 500;
const J = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });
const eq = (a, b) => { a = String(a || ""); b = String(b || ""); let d = a.length ^ b.length; for (let i = 0; i < b.length; i++) d |= (a.charCodeAt(i) || 0) ^ b.charCodeAt(i); return !!b && d === 0; };
const has = (list, uid, un) => String(list || "").toLowerCase().split(",").map(s => s.trim()).filter(Boolean).some(t => t === String(uid) || t === String(un || "").toLowerCase());
const OIDS = env => env.OWNER_IDS || "Kingbaconnon19";
const CIDS = env => env.COOWNER_IDS || "helloman1_23";
// A key is only required when the OWNER_KEY / COOWNER_KEY secret exists; otherwise the username / ID alone decides.
const roleOf = (env, uid, un, k) => {
  const ok = (key, ids) => has(ids, uid, un) && (!key || eq(k, key));
  return ok(env.OWNER_KEY, OIDS(env)) ? "owner" : ok(env.COOWNER_KEY, CIDS(env)) ? "coowner" : null;
};

// ---- Live Players viewing permission (separate from moderation /act) ----
// Authoritative sources: roles.json (owner / co-owner) + whitelist.json (verified) in the project's GitHub repo, resolved to userIds.
// Authorization is by Roblox userId only; the client-supplied name / flags are never accepted as proof. Fails closed.
const ROSTER_TTL = 60000, ROSTER_RETRY = 15000, ROSTER_STALE = 600000;
const rbase = env => `https://raw.githubusercontent.com/${env.GITHUB_REPO || "Elliot12-wq/uh-mod-visual-system"}/${env.GITHUB_BRANCH || "main"}/`;
const numIds = list => String(list || "").split(",").map(s => s.trim()).filter(s => /^\d+$/.test(s));
const secretRole = (env, uid, un, k) => { // owner / co-owner proven by a configured secret key (not by name alone)
  const r = roleOf(env, uid, un, k);
  return (r === "owner" && env.OWNER_KEY) || (r === "coowner" && env.COOWNER_KEY) ? r : null;
};

export default {
  async fetch(req, env) {
    if (req.method !== "POST") return new Response("ok");
    return env.HUB.get(env.HUB.idFromName("g")).fetch(req);
  },
};

export class Hub {
  constructor(state, env) {
    this.st = state;
    this.envv = env;
    this.s = new Map();   // uid -> session
    this.q = new Map();   // uid -> events
    this.ver = 1;
    this.n = 1;
    this.bans = null;
    this.rost = null;     // { ids:Set, ok:ms of last good load, at:ms of last attempt }
    this.nameIds = new Map(); // lowercase username -> userId
  }
  async roster(now) { // owner / co-owner (roles.json) + verified (whitelist.json) -> Set of userIds; cached 60 s
    const r = this.rost;
    if (r && now - r.at < (r.good ? ROSTER_TTL : ROSTER_RETRY)) return r;
    const prev = r || { ids: new Set(), ok: 0 };
    const next = { ids: prev.ids, ok: prev.ok, at: now, good: false };
    this.rost = next;
    try {
      const ids = new Set(), names = new Set();
      for (const f of ["roles.json", "whitelist.json"]) {
        const res = await fetch(rbase(this.envv) + f + "?t=" + now, { cf: { cacheTtl: 0 } });
        if (!res.ok) throw new Error(f + " " + res.status);
        const d = await res.json();
        for (const x of Array.isArray(d && d.entries) ? d.entries : []) {
          if (!x || typeof x !== "object") continue;
          if (f === "roles.json" && !["owner", "co-owner"].includes(String(x.role || "").toLowerCase())) continue;
          const id = Math.floor(Number(x.userId)) || 0, n = typeof x.username === "string" ? x.username.toLowerCase() : "";
          if (id > 0) ids.add(String(id));
          if (/^[0-9a-z_]{3,20}$/.test(n)) names.add(n);
        }
      }
      const todo = [...names].filter(n => !this.nameIds.has(n)).slice(0, 100);
      if (todo.length) {
        const res = await fetch("https://users.roblox.com/v1/usernames/users", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ usernames: todo, excludeBannedUsers: false }) });
        const d = await res.json();
        for (const u of (d && d.data) || []) this.nameIds.set(String(u.requestedUsername || u.name).toLowerCase(), String(u.id));
      }
      for (const n of names) if (this.nameIds.has(n)) ids.add(this.nameIds.get(n));
      this.rost = { ids, ok: now, at: now, good: names.size === 0 || [...names].every(n => this.nameIds.has(n)) };
    } catch {}
    return this.rost;
  }
  // Dedicated viewing permission. Verified / owner / co-owner only; independent of moderation (/act).
  async canViewLiveLog(uid, un, k, now) {
    try {
      if (numIds(this.envv.OWNER_IDS).includes(uid) || numIds(this.envv.COOWNER_IDS).includes(uid)) return true;
      if (secretRole(this.envv, uid, un, k)) return true;
      const r = await this.roster(now);
      return now - r.ok < ROSTER_STALE && r.ids.has(uid);
    } catch { return false; }
  }
  sweep(now) {
    for (const [u, s] of this.s) if (now - s.t > TTL) { this.s.delete(u); this.ver++; }
    for (const [u, l] of this.q) { const f = l.filter(e => now - e.t < EV_TTL); f.length ? this.q.set(u, f) : this.q.delete(u); }
  }
  async fetch(req) {
    const now = Date.now();
    let b; try { b = await req.json(); } catch { return J({ err: "bad" }, 400); }
    const path = new URL(req.url).pathname, uid = String(b.u || "").replace(/\D/g, "").slice(0, 16);
    if (!uid) return J({ err: "uid" }, 400);
    if (!this.bans) this.bans = (await this.st.storage.get("bans")) || {};
    this.sweep(now);

    if (path === "/act") {
      const role = roleOf(this.envv, uid, b.n, b.k);
      if (!role) return J({ err: "denied" }, 403);
      const x = String(b.x || "").replace(/\D/g, ""), t = b.t;
      if (!x || !["kill", "deanimate", "kick", "ban", "unban"].includes(t)) return J({ err: "bad" }, 400);
      const tgt = this.s.get(x);
      if (tgt && tgt.role && (role !== "owner" || tgt.role === "owner")) return J({ err: "protected" }, 403);
      if (has(OIDS(this.envv), x, tgt && tgt.un) || (role !== "owner" && has(CIDS(this.envv), x, tgt && tgt.un))) return J({ err: "protected" }, 403);
      if (t === "unban") { delete this.bans[x]; await this.st.storage.put("bans", this.bans); return J({ ok: 1 }); }
      if (t === "ban") { this.bans[x] = { by: uid, t: now }; await this.st.storage.put("bans", this.bans); }
      else if (!tgt) return J({ err: "offline" }, 404);
      const ev = { id: this.n++, k: t === "ban" ? "kick" : t, f: b.n || uid, r: role, t: now };
      if (tgt || t === "ban") { const l = this.q.get(x) || []; l.push(ev); this.q.set(x, l); }
      return J({ ok: 1 });
    }

    // /sync: heartbeat + ack + list + count + events + moderator presence in one round trip
    if (this.bans[uid]) return J({ ban: 1 });
    if (b.off) { if (this.s.delete(uid)) this.ver++; return J({ ok: 1 }); }
    const un = String(b.n || "").slice(0, 40), role = roleOf(this.envv, uid, un, b.k);
    const old = this.s.get(uid), jid = String(b.j || "").slice(0, 64);
    const gn = String(b.g || "").slice(0, 80);
    if (!old || old.jid !== jid || old.role !== role || old.gn !== gn) this.ver++;
    this.s.set(uid, { uid, un, dn: String(b.d || un).slice(0, 40), pid: String(b.p || "").slice(0, 20), jid, gn, role, t: now });
    if (Array.isArray(b.a) && b.a.length) { const l = this.q.get(uid); if (l) { const f = l.filter(e => !b.a.includes(e.id)); f.length ? this.q.set(uid, f) : this.q.delete(uid); } }
    // Everyone gets own events + own role + the permission result; the log data (c / v / m / l) is only ever built for authorized viewers.
    const lv = await this.canViewLiveLog(uid, un, b.k, now);
    const r = { e: this.q.get(uid) || [], r: role, lv: lv ? 1 : 0 };
    if (lv) {
      r.c = this.s.size; r.v = this.ver; r.m = {};
      for (const s of this.s.values()) if (s.role) r.m[s.role === "owner" ? "o" : "c"] = [s.jid, s.un];
      if (b.w && b.v !== this.ver) { r.l = []; for (const s of this.s.values()) { if (r.l.length >= MAXL) break; r.l.push([s.uid, s.un, s.dn, s.pid, s.jid, s.gn]); } }
    }
    return J(r);
  }
}
