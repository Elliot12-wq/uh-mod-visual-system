// Cloudflare Worker + Durable Objects: live-sync backend for the Uh mod visual system (banners, verify keys, moderator commands, blacklist, Alt-Fling).
// One Room Durable Object per Roblox server ("placeId-jobId") holds that server's banners, commands and Alt-Fling state.
// One extra Room instance named "~meta" (a name no real room can have) holds the global state: one-time key claims, owner ids and blacklist edits.
// A third instance named "~bc" holds the owner broadcast (announcements every running copy of the script shows in its notification UI).
// API: GET /banners /commands /alt /poll   POST /banner /clear /mod /alt /verify /blacklist /unblacklist /send
// Secrets / vars (Workers > Settings > Variables and Secrets, or `wrangler secret put NAME`):
//   MOD_KEYS (JSON array of one-time keys), OWNER_KEY, OWNER_IDS (JSON array of userIds), GITHUB_TOKEN (Contents: read + write on the repo),
//   GITHUB_REPO ("owner/repo"), GITHUB_BRANCH (default main), BLACKLIST_PATH (default blacklist.json),
//   BROADCAST_KEY (optional: Bearer key for POST /send; falls back to OWNER_KEY)
const ID = /^\d{1,16}$/, ROOM = /^[0-9A-Za-z:_-]{1,80}$/, IMG = /^(rbxassetid:\/\/)?\d{1,19}$/;
const TTL = 75000, CMD_TTL = 30000, ALT_REQ_TTL = 120000, ALT_EV_TTL = 60000, BC_COOLDOWN = 2000, BC_KEEP = 50;
const ACTIONS = new Set(["kill", "deanimate", "kick"]), ALT_RESULTS = new Set(["confirmed", "unconfirmed", "failed"]);
const OWNER_NAMES = ["kingbaconnon19", "helloman1_23"];
const BROADCAST_USER = "Kingbaconnon19"; // the only account name /send accepts (same check the Lua owner panel uses)
const POST_LIMIT = { "/banner": 2048, "/clear": 2048, "/mod": 2048, "/alt": 1024, "/verify": 1024, "/blacklist": 2048, "/unblacklist": 2048, "/send": 4096 };
const GET_ROOM = new Set(["/banners", "/commands", "/alt"]);
const META_PATHS = new Set(["/verify", "/blacklist", "/unblacklist"]);
const s = (v, n) => String(v ?? "").replace(/[\u0000-\u001f\u007f]/g, "").slice(0, n);
const HEX = /^#[0-9a-fA-F]{6}$/;
const ni = (v, lo, hi, d) => { v = Math.round(Number(v)); return Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : d; };
const cleanStyle = (x) => { // per-user banner style: validated hex colours + clamped numbers only
  if (!x || typeof x !== "object") return null;
  const o = { gr: ni(x.gr, 0, 360, 90), bw: ni(x.bw, 0, 4, 2), bs: ni(x.bs, 0, 2, 2), cr: ni(x.cr, 4, 24, 14), fx: ni(x.fx, 0, 63, 63) };
  for (const k of ["a", "a2", "b1", "b2"]) if (typeof x[k] === "string" && HEX.test(x[k])) o[k] = x[k].toUpperCase();
  return o;
};
const j = (code, body) => new Response(JSON.stringify(body), { status: code, headers: { "Content-Type": "application/json" } });
const same = (a, b) => { a = String(a); b = String(b); if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0; };
const b64e = (str) => { let bin = ""; for (const x of new TextEncoder().encode(str)) bin += String.fromCharCode(x); return btoa(bin); };
const b64d = (str) => new TextDecoder().decode(Uint8Array.from(atob(str.replace(/\s/g, "")), (c) => c.charCodeAt(0)));

export default {
  async fetch(req, env) {
    const url = new URL(req.url), p = url.pathname;
    if (req.method === "GET" && p === "/") return j(200, { ok: true });
    let stub, init = { method: req.method };
    if (req.method === "POST" && POST_LIMIT[p]) {
      const txt = await req.text();
      if (txt.length > POST_LIMIT[p]) return j(413, { error: "too large" });
      let b; try { b = JSON.parse(txt); } catch { return j(400, { error: "bad json" }); }
      if (!b || typeof b !== "object") return j(400, { error: "bad json" });
      if (META_PATHS.has(p)) stub = env.ROOM.get(env.ROOM.idFromName("~meta"));
      else if (p === "/send") { // owner broadcast: checked here so a bad caller never wakes the Durable Object
        const key = env.BROADCAST_KEY || env.OWNER_KEY || "", tok = (req.headers.get("Authorization") || "").replace(/^Bearer /, "");
        if (key === "" || !same(tok, key) || b.user !== BROADCAST_USER) return j(403, {});
        stub = env.ROOM.get(env.ROOM.idFromName("~bc"));
      } else {
        const room = typeof b.room === "string" ? b.room : "";
        if (!ROOM.test(room)) return j(400, { error: "bad room" });
        stub = env.ROOM.get(env.ROOM.idFromName(room));
      }
      init.body = JSON.stringify(b);
    } else if (req.method === "GET" && GET_ROOM.has(p)) {
      const room = url.searchParams.get("room");
      if (!ROOM.test(room || "")) return j(400, { error: "bad room" });
      stub = env.ROOM.get(env.ROOM.idFromName(room));
    } else if (req.method === "GET" && p === "/poll") stub = env.ROOM.get(env.ROOM.idFromName("~bc"));
    else return j(404, { error: "not found" });
    return stub.fetch("https://do" + p + url.search, init);
  },
};

export class Room {
  constructor(state, env) {
    this.st = state.storage; this.env = env;
    this.dirty = false; this.blLock = Promise.resolve();
    this.lastCmd = new Map(); this.lastAlt = new Map(); this.lastVerify = new Map();
    this.mods = { ids: new Set(), at: 0 }; this.lastBc = 0;
    state.blockConcurrencyWhile(async () => {
      const g = await this.st.get(["m", "c", "a", "claims", "owners", "bc"]);
      this.bc = g.get("bc") || { last: 0, msgs: [] }; // "~bc" only: owner broadcast, last id + the newest BC_KEEP announcements [{id, text}]
      this.m = g.get("m") || {}; // banners: userId -> {token, exp, ...}
      this.c = g.get("c") || {}; // moderator commands: userId -> [{action, by, ts, exp}]
      this.a = g.get("a") || { pend: {}, rel: {}, ev: {} }; // Alt-Fling: pending requests, relationships, queued events
      this.claims = g.get("claims") || {}; // meta only: one-time key -> userId it locked to
      this.own = g.get("owners") || { ids: [], at: 0 }; // meta only: resolved owner ids
    });
  }

  async fetch(req) {
    const p = new URL(req.url).pathname;
    if (META_PATHS.has(p) || p.startsWith("/_/")) return this.meta(req, p);
    if (p === "/poll" || p === "/send") return this.broadcast(req, p);
    this.sweep();
    try { return await this.route(req, p); } finally { await this.persist(); }
  }

  async alarm() { this.sweep(); this.dirty = true; await this.persist(); }

  // ===== global state (the "~meta" instance) =====
  async owners() { // owner / co-owner ids: names resolved through the Roblox users API at most every 10 min (OWNER_IDS adds ids by hand)
    const now = Date.now();
    if (now - this.own.at > 600000) {
      this.own.at = now - 540000; // on failure, retry in ~60 s
      try {
        const r = await fetch("https://users.roblox.com/v1/usernames/users", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ usernames: OWNER_NAMES, excludeBannedUsers: false }) });
        const d = await r.json(), ids = ((d && d.data) || []).map((u) => String(u.id));
        if (ids.length) this.own = { ids, at: now };
      } catch {}
      await this.st.put("owners", this.own);
    }
    const set = new Set(this.own.ids);
    try { for (const id of JSON.parse(this.env.OWNER_IDS || "[]")) set.add(String(id)); } catch {}
    return set;
  }
  async modIds() { return new Set([...Object.values(this.claims).map(String), ...(await this.owners())]); }
  async ownerOk(id, key) { const k = this.env.OWNER_KEY || ""; return (await this.owners()).has(String(id)) || (k !== "" && same(key || "", k)); }
  async authModKey(key, userId) { // true when `key` is a valid one-time key that is unclaimed (it locks to userId now) or already locked to userId
    let keys = []; try { keys = JSON.parse(this.env.MOD_KEYS || "[]"); } catch {}
    if (!Array.isArray(keys)) keys = [];
    let hit = null; for (const k of keys) if (same(key || "", k)) hit = k;
    if (!hit) return false;
    if (!this.claims[hit]) { this.claims[hit] = userId; await this.st.put("claims", this.claims); }
    return this.claims[hit] === userId;
  }
  async modAuth(id, key) { return (await this.ownerOk(id, key)) || (await this.authModKey(key, String(id))); }
  locked(fn) { const run = this.blLock.then(fn); this.blLock = run.catch(() => {}); return run; } // one blacklist edit at a time (GitHub needs the latest sha)
  async editBlacklist(mutate) { // mutate(entries) -> new entries, or null for "nothing to change"; resolves to the resulting entries
    const e = this.env, repo = e.GITHUB_REPO || "Elliot12-wq/uh-mod-visual-system", branch = e.GITHUB_BRANCH || "main", path = e.BLACKLIST_PATH || "blacklist.json";
    const api = `https://api.github.com/repos/${repo}/contents/${path}`;
    const headers = { Authorization: `Bearer ${e.GITHUB_TOKEN}`, Accept: "application/vnd.github+json", "User-Agent": "uh-mod-visual-system", "X-GitHub-Api-Version": "2022-11-28" };
    const r = await fetch(`${api}?ref=${encodeURIComponent(branch)}`, { headers });
    let sha, entries = [];
    if (r.status === 200) { const d = await r.json(); sha = d.sha; try { const parsed = JSON.parse(b64d(d.content)); if (Array.isArray(parsed.entries)) entries = parsed.entries; } catch {} }
    else if (r.status !== 404) throw new Error("github read " + r.status);
    const next = mutate(entries);
    if (next === null) return entries;
    const put = await fetch(api, { method: "PUT", headers: { ...headers, "Content-Type": "application/json" }, body: JSON.stringify({ message: "blacklist update", branch, sha, content: b64e(JSON.stringify({ entries: next }, null, 2) + "\n") }) });
    if (!put.ok) throw new Error("github write " + put.status);
    return next;
  }

  async meta(req, p) {
    if (p === "/_/mods") return j(200, { ids: [...(await this.modIds())] });
    const b = await req.json(), now = Date.now();
    if (p === "/_/auth") { // used by room instances: mode "owner" (owner id / owner key) or anything else = moderator (owner or one-time key)
      const ok = b.mode === "owner" ? await this.ownerOk(b.userId, b.key) : await this.modAuth(String(b.userId), b.key);
      return j(200, { ok });
    }
    if (p === "/verify") { // key box in the UI: locks a one-time key to this userId (or re-confirms it)
      const id = String(b.userId);
      if (!ID.test(id) || typeof b.key !== "string") return j(400, { error: "bad" });
      if (now - (this.lastVerify.get(id) || 0) < 1000) return j(429, { error: "slow down" });
      this.lastVerify.set(id, now);
      if (!(await this.modAuth(id, b.key))) return j(403, { error: "invalid key or already used" });
      return j(200, { ok: true });
    }
    if (p === "/blacklist" || p === "/unblacklist") { // owner / co-owner: add or remove a blacklist.json entry through the GitHub contents API
      const by = String(b.byId), target = String(b.userId);
      if (!ID.test(by) || !ID.test(target)) return j(400, { error: "bad" });
      if (!(await this.ownerOk(by, b.key))) return j(403, { error: "owner / co-owner only" });
      if (!this.env.GITHUB_TOKEN) return j(503, { error: "GITHUB_TOKEN is not set on the backend" });
      if (p === "/blacklist" && (target === by || (await this.modIds()).has(target))) return j(403, { error: "immune" });
      if (now - (this.lastCmd.get("bl" + by) || 0) < 1000) return j(429, { error: "slow down" });
      this.lastCmd.set("bl" + by, now);
      const mutate = p === "/blacklist"
        ? (list) => list.some((x) => String(x.userId) === target) ? null : [...list, { userId: +target, username: s(b.username, 40), by: s(b.by, 40), reason: s(b.reason, 100), ts: now }]
        : (list) => { const next = list.filter((x) => String(x.userId) !== target); return next.length === list.length ? null : next; };
      try { return j(200, { ok: true, entries: await this.locked(() => this.editBlacklist(mutate)) }); }
      catch (err) { return j(502, { error: String((err && err.message) || err).slice(0, 120) }); }
    }
    return j(404, { error: "not found" });
  }

  // ===== owner broadcast (the "~bc" instance; /send was already authorised by the front Worker) =====
  async broadcast(req, p) {
    const bc = this.bc, now = Date.now();
    if (p === "/poll") { // no `after` = just report the newest id (a fresh client starts from "now" and never replays history)
      const after = new URL(req.url).searchParams.get("after");
      return j(200, { id: bc.last, msgs: after === null ? [] : bc.msgs.filter((m) => m.id > Number(after)) });
    }
    const b = await req.json();
    const text = String(b.text || "").replace(/[\u0000-\u001f<>]/g, " ").trim().slice(0, 200);
    if (!text || now - this.lastBc < BC_COOLDOWN) return j(400, {});
    this.lastBc = now;
    bc.last = Math.max(now, bc.last + 1);
    bc.msgs = [...bc.msgs, { id: bc.last, text }].slice(-BC_KEEP);
    await this.st.put("bc", bc);
    return j(200, { id: bc.last });
  }

  // ===== room state =====
  metaStub() { return this.env.ROOM.get(this.env.ROOM.idFromName("~meta")); }
  async modSet(force) { // claimed moderators + owners (cached 15 s; `force` for the immunity check on a command)
    if (force || Date.now() - this.mods.at > 15000) {
      try { const d = await (await this.metaStub().fetch("https://do/_/mods")).json(); this.mods = { ids: new Set((d.ids || []).map(String)), at: Date.now() }; }
      catch { this.mods.at = Date.now() - 10000; }
    }
    return this.mods.ids;
  }
  async metaAuth(userId, key) {
    try { return (await (await this.metaStub().fetch("https://do/_/auth", { method: "POST", body: JSON.stringify({ mode: "mod", userId: String(userId), key: key || "" }) })).json()).ok === true; }
    catch { return false; }
  }
  sweep() {
    const now = Date.now(), a = this.a;
    let ch = false;
    for (const k in this.m) if (this.m[k].exp < now) { delete this.m[k]; ch = true; }
    for (const id in this.c) { const f = this.c[id].filter((x) => x.exp > now); if (f.length !== this.c[id].length) ch = true; if (f.length) this.c[id] = f; else delete this.c[id]; }
    for (const k in a.pend) if (a.pend[k].exp < now || !this.m[a.pend[k].from] || !this.m[a.pend[k].to]) { delete a.pend[k]; ch = true; }
    for (const k in a.rel) if (!this.m[a.rel[k].flinger] || !this.m[a.rel[k].served]) { delete a.rel[k]; ch = true; } // a relationship needs BOTH players live
    for (const id in a.ev) { const f = a.ev[id].filter((x) => x.exp > now); if (f.length !== a.ev[id].length) ch = true; if (f.length) a.ev[id] = f; else delete a.ev[id]; }
    if (ch) this.dirty = true;
  }
  async persist() {
    if (!this.dirty) return;
    this.dirty = false;
    const a = this.a;
    if (!Object.keys(this.m).length && !Object.keys(this.c).length && !Object.keys(a.pend).length && !Object.keys(a.rel).length && !Object.keys(a.ev).length) await this.st.deleteAll();
    else { await this.st.put({ m: this.m, c: this.c, a }); await this.st.setAlarm(Date.now() + 300000); }
  }
  altPush(id, e) { const now = Date.now(); (this.a.ev[id] = this.a.ev[id] || []).push({ ...e, ts: now, exp: now + ALT_EV_TTL }); this.dirty = true; }

  async route(req, p) {
    const url = new URL(req.url), now = Date.now(), m = this.m, a = this.a;

    if (req.method === "GET" && p === "/banners") {
      const mods = await this.modSet();
      return j(200, { banners: Object.values(m).map(({ token, exp, ...pub }) => ({ ...pub, verified: mods.has(String(pub.userId)) })) });
    }

    if (req.method === "POST" && (p === "/banner" || p === "/clear")) {
      const b = await req.json(), id = String(b.userId);
      const tok = typeof b.token === "string" && b.token.length >= 8 && b.token.length <= 64 ? b.token : null;
      if (!ID.test(id) || !tok) return j(400, { error: "bad" });
      if (m[id] && m[id].token !== tok) return j(403, { error: "claimed" }); // first claimant owns the id until TTL
      if (p === "/clear") delete m[id];
      else m[id] = { token: tok, exp: now + TTL, userId: +id, name: s(b.name, 40), title: s(b.title, 40), subtitle: s(b.subtitle, 40), image: IMG.test(b.image || "") ? String(b.image) : "", style: cleanStyle(b.style), ts: now };
      this.dirty = true;
      return j(200, { ok: true });
    }

    if (req.method === "GET" && p === "/commands") { // a script user collects (and clears) commands addressed to them; needs their banner token
      const id = String(url.searchParams.get("userId")), tok = url.searchParams.get("token");
      if (!ID.test(id) || !tok) return j(400, { error: "bad" });
      if (!m[id] || m[id].token !== tok) return j(403, { error: "not claimed" });
      const out = (this.c[id] || []).map(({ exp, ...pub }) => pub);
      if (this.c[id]) { delete this.c[id]; this.dirty = true; }
      return j(200, { commands: out });
    }

    if (req.method === "POST" && p === "/mod") { // kill / deanimate / kick, only against live script users, only from moderators
      const b = await req.json(), by = String(b.userId), target = String(b.target);
      if (!ID.test(by) || !ID.test(target) || !ACTIONS.has(b.action)) return j(400, { error: "bad" });
      if (!(await this.metaAuth(by, b.key))) return j(403, { error: "not a moderator / key already used by someone else" });
      if ((await this.modSet(true)).has(target)) return j(403, { error: "immune" });
      if (!m[target]) return j(404, { error: "target is not running the script" });
      if (now - (this.lastCmd.get(by) || 0) < 1500) return j(429, { error: "slow down" });
      this.lastCmd.set(by, now);
      (this.c[target] = this.c[target] || []).push({ action: b.action, by: +by, ts: now, exp: now + CMD_TTL });
      this.dirty = true;
      return j(200, { ok: true });
    }

    // ---- Alt-Fling: Served User requests, consent, relationships, fling events (identity = the caller's live banner token, same check as /commands) ----
    // pend/rel keys are "flingerId>servedId": the REQUESTER is the Alt Flinger, the TARGET is the Served User.
    if (req.method === "GET" && p === "/alt") { // my relationships + incoming / outgoing requests (state) and my queued events (drained on read)
      const id = String(url.searchParams.get("userId")), tok = url.searchParams.get("token");
      if (!ID.test(id) || !tok) return j(400, { error: "bad" });
      if (!m[id] || m[id].token !== tok) return j(403, { error: "not claimed" });
      const nm = (x) => (m[x] && m[x].name) || "", rels = [], pending = [], out = [];
      for (const k in a.rel) { const r = a.rel[k]; if (r.flinger === id || r.served === id) rels.push({ flinger: +r.flinger, served: +r.served, fname: nm(r.flinger), sname: nm(r.served), ts: r.ts }); }
      for (const k in a.pend) { const r = a.pend[k]; if (r.to === id) pending.push({ from: +r.from, name: nm(r.from), ts: r.ts }); else if (r.from === id) out.push({ to: +r.to, name: nm(r.to), ts: r.ts }); }
      const events = (a.ev[id] || []).map(({ exp, ...pub }) => pub);
      if (a.ev[id]) { delete a.ev[id]; this.dirty = true; }
      return j(200, { rels, pending, out, events });
    }
    if (req.method === "POST" && p === "/alt") { // op: request | respond | end | fling | result (see AltFling.lua)
      const b = await req.json(), me = String(b.userId), tgt = String(b.target);
      if (!ID.test(me) || !ID.test(tgt) || typeof b.token !== "string") return j(400, { error: "bad" });
      if (!m[me] || m[me].token !== b.token) return j(403, { error: "not claimed" });
      if (me === tgt) return j(400, { error: "self" });
      if (!m[tgt]) return j(404, { error: "target is not running the script" });
      if (now - (this.lastAlt.get(me) || 0) < 400) return j(429, { error: "slow down" });
      this.lastAlt.set(me, now);
      const mine = m[me], other = m[tgt], asFlinger = me + ">" + tgt, asServed = tgt + ">" + me;
      if (b.op === "request") { // me = Alt Flinger asking tgt to be my Served User
        if (a.rel[asFlinger]) return j(409, { error: "already active" });
        if (a.pend[asFlinger]) return j(409, { error: "already pending" });
        a.pend[asFlinger] = { from: me, to: tgt, ts: now, exp: now + ALT_REQ_TTL };
        this.dirty = true;
        return j(200, { ok: true });
      }
      if (b.op === "respond") { // me = Served User answering tgt's request
        if (!a.pend[asServed]) return j(404, { error: "no pending request" });
        delete a.pend[asServed];
        if (b.accept === true) {
          a.rel[asServed] = { flinger: tgt, served: me, ts: now };
          const ev = { type: "accepted", flinger: +tgt, served: +me, fname: other.name, sname: mine.name };
          this.altPush(tgt, ev); this.altPush(me, ev);
        } else this.altPush(tgt, { type: "declined", by: +me, name: mine.name });
        this.dirty = true;
        return j(200, { ok: true });
      }
      if (b.op === "end") { // either side
        const k = a.rel[asFlinger] ? asFlinger : a.rel[asServed] ? asServed : null;
        if (!k) return j(404, { error: "no relationship" });
        const r = a.rel[k]; delete a.rel[k];
        this.altPush(tgt, { type: "ended", flinger: +r.flinger, served: +r.served, by: +me, name: mine.name, sname: m[r.served] ? m[r.served].name : "" });
        this.dirty = true;
        return j(200, { ok: true });
      }
      if (b.op === "fling") { // me = Served User -> tgt = my Alt Flinger
        if (!a.rel[asServed]) return j(403, { error: "no active relationship" });
        const victim = s(b.victim, 40);
        if (!victim) return j(400, { error: "no victim" });
        this.altPush(tgt, { type: "fling", cid: s(b.cid, 24), victim, served: +me, sname: mine.name });
        return j(200, { ok: true });
      }
      if (b.op === "result") { // me = Alt Flinger reporting to tgt (Served User); only what the flinger's client actually established
        if (!a.rel[asFlinger]) return j(403, { error: "no active relationship" });
        if (!ALT_RESULTS.has(b.result)) return j(400, { error: "bad result" });
        this.altPush(tgt, { type: "result", cid: s(b.cid, 24), victim: s(b.victim, 40), method: s(b.method, 40), result: b.result, detail: s(b.detail, 80), flinger: +me, fname: mine.name });
        return j(200, { ok: true });
      }
      return j(400, { error: "bad op" });
    }

    return j(404, { error: "not found" });
  }
}
