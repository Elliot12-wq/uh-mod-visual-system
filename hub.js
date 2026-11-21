// LiveLogHub - the single Durable Object behind the Live Player Log (global script-user registry + remote moderation).
//
//  * Identity: automatic sign-in, no profile code. The client states only its own Roblox user id; the Worker resolves the account from Roblox (real username /
//    display name), checks the ban list and issues a session bound to that user id / username. The user id / username used afterwards come from the session,
//    never from a request body. Only the SHA-256 of the session token is stored. Roles are NEVER decided here or by the client: roles.js reads roles.json
//    (owner / co-owner / verified) and whitelist.json (verified) and every request is authorised from that table. (A user id is not secret and is not proven by this
//    sign-in: anyone who sends the id of a listed account is treated as that account.)
//  * Publishing presence needs a session (every authenticated script client may publish). Viewing the roster and moderating need a session
//    AND a role (roles.js), re-checked on every request. Publishing is NOT a viewing right.
//  * The registry is ONE map keyed by Roblox user id (deduplicated). Each entry carries its live script sessions (several simultaneous
//    sessions of one account are counted once in `onlineCount`); the newest valid session is the entry's primary session and the command target.
//  * The list is a change log: clients send a cursor ("epoch.seq") and get only what changed (or an empty "no change" answer).
//    Every answer carries `onlineCount` (unique accounts with unexpired presence), `sessionCount`, `cap` and `sat` (capacity reached).
//  * Presence lives in memory and is snapshotted into at most SHARDS storage rows ("r:<n>"; only changed shards, at most once per FLUSH_GAP_MS; a leave writes its own
//    shard at once), so a heartbeat never costs a write of its own. A cold start (deploy / eviction) restores every session whose last heartbeat is still inside the
//    presence window - complete with its sid, login and capabilities - so the global count does not collapse to ~0; everything older expires exactly as it would have.
//  * Moderation commands are structured, short-lived and addressed to one target session. The target pulls them from GET /live/commands (the same short-poll
//    pattern as the banner system's /commands, a few seconds apart) and the heartbeat response still carries them as a fallback; the target acknowledges at once. Status history is stored separately from the roster.

import { loadRoleTable, roleFor, actionsFor, RANK } from "./roles.js";

const PRESENCE_TTL_MS = 240_000;     // abandoned presence disappears after ~2 missed heartbeats (client beats about every 100s)
const DEFAULT_MAX_PRESENCE = 5000;   // unique accounts; override with the MAX_PRESENCE variable (100..20000)
const MAX_TOMBS = 1000;              // removal log kept for delta answers; older cursors simply get a full snapshot
const SESSION_TTL_MS = 14 * 86_400_000;
const SESSION_TOUCH_MS = 86_400_000; // sliding expiry is written at most once a day
const MAX_SESSIONS_PER_USER = 5;     // stored login tokens per account
const MAX_SCRIPT_SESSIONS = 5;       // simultaneous live script sessions per account
const MIN_PRESENCE_GAP_MS = 15_000;
const MAX_BODY = 2048;
const CMD_TTL_MS = 45_000;           // a command must reach AND be acknowledged by the target within 45 s (fast /live/commands pull) or it finishes as EXPIRED (shown as TIMEOUT)
const REDELIVER_MS = 10_000;         // a delivered but unacknowledged command is offered again after this long (the client dedupes by id)
const CMD_KEEP_MS = 900_000;         // finished commands stay in memory this long so the moderator sees the final status
const MAX_HIST = 300;                // moderation history entries kept in storage
const LEFT_HOLD_MS = 600_000;        // a session that sent /live/presence/leave cannot be re-registered by a late / reordered request for this long
const SAT_HOLD_MS = 900_000;         // after a registration was refused for capacity, the registry reports "saturated" for this long
const GUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NAME_RE = /^[A-Za-z0-9_]{3,20}$/;
const CID_RE = /^[0-9a-f]{32}$/;
const SID_RE = /^[0-9a-f]{16,32}$/;
const SHARDS = 32;                   // registry snapshot rows: the storage write volume is bounded by this, not by the number of users
const FLUSH_GAP_MS = 45_000;         // changed shards are written at most this often
const NAME_TTL_MS = 6 * 3600_000;    // a resolved Roblox username is reused this long (sign-ins must not depend on Roblox rate limits)
const MAX_NAMES = 2000;

const ACTIONS = new Set(["kick", "kill", "deanimate", "dizzy", "hallucinate", "silenthell", "domain", "cooked", "dropbomb", "ban", "unban"]);
const ACK_STATES = new Set(["EXECUTED", "REJECTED", "FAILED", "ACTION_UNSUPPORTED"]);
const UNSUPPORTED = "ACTION NOT SUPPORTED BY CURRENT CLIENT/BACKEND AUTHORITY";

const enc = new TextEncoder();

function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "private, no-store", Vary: "Authorization", ...headers },
  });
}
const fail = (status, err, extra = {}) => json({ ok: false, err, ...extra }, status);

function randomHex(bytes) {
  const a = crypto.getRandomValues(new Uint8Array(bytes));
  return Array.from(a, (b) => b.toString(16).padStart(2, "0")).join("");
}
function randomToken() {
  const a = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...a)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
async function sha256hex(s) {
  const d = await crypto.subtle.digest("SHA-256", enc.encode(s));
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, "0")).join("");
}
function cleanText(v, max) {
  return String(v ?? "").replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, "").trim().slice(0, max);
}
function bearer(request) {
  const h = request.headers.get("Authorization") || "";
  return h.startsWith("Bearer ") ? h.slice(7).trim() : "";
}
async function readJson(request) {
  const text = await request.text();
  if (text.length > MAX_BODY) return null;
  try {
    const v = JSON.parse(text || "{}");
    return v && typeof v === "object" && !Array.isArray(v) ? v : null;
  } catch {
    return null;
  }
}
const disp = (r) => [r.d, r.pid, r.g, r.j].join("|"); // what a roster entry shows (content), as opposed to its heartbeat age

export class LiveLogHub {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.ready = state.blockConcurrencyWhile(() => this.load());
  }

  async load() {
    this.epoch = randomHex(4);       // new epoch on every cold start => clients holding an old cursor receive a full snapshot
    this.seq = 1;
    this.tombFloor = 0;              // newest removal that fell out of the log
    this.tombs = [];                 // [{u, rev}] removals, oldest first
    this.pres = new Map();           // userId -> {u, n, d, pid, g, j, seen, rev, crev, last, ses: Map(sid -> session), main: sid, ns}
    this.sess = new Map();           // sha256(token) -> login-session record (read-through cache of storage)
    this.rate = new Map();           // best-effort in-memory rate limits
    this.bans = new Map();           // userId -> {u, n, by, bn, at, r}   (UH script/backend services ban, NOT a Roblox ban)
    this.cmds = new Map();           // commandId -> command (recent, any status)
    this.open = new Map();           // commandId -> command that is still PENDING / DELIVERED
    this.left = new Map();           // "sid:tokenHash" -> expiry; sessions that already left (blocks late full snapshots from re-creating them)
    this.names = new Map();          // userId -> {n, d, at}: resolved Roblox names (cache)
    this.dirty = new Set();          // registry shards changed since they were last written
    this.flushAt = 0;
    this.hkeys = [];                 // storage keys of the moderation history, oldest first
    this.fullAt = 0;
    this.lastPurge = 0;
    this.maxPres = Math.min(20000, Math.max(100, Math.floor(Number(this.env.MAX_PRESENCE)) || DEFAULT_MAX_PRESENCE));
    const now = Date.now();

    // cold start: the registry is rebuilt from the "r:" shard rows (see flush / restore). Rows of the previous format ("p:") carry no real session and are cleared.
    // Sessions whose last heartbeat is older than the presence window and banned accounts are not restored.
    const stale = [...(await this.state.storage.list({ prefix: "p:" })).keys()];
    for (let i = 0; i < stale.length; i += 100) await this.state.storage.delete(stale.slice(i, i + 100));
    const legacy = [...(await this.state.storage.list({ prefix: "c:" })).keys()]; // leftovers of the removed profile-code sign-in
    for (let i = 0; i < legacy.length; i += 100) await this.state.storage.delete(legacy.slice(i, i + 100));
    for (const [, v] of await this.state.storage.list({ prefix: "b:" })) if (v && typeof v.u === "number") this.bans.set(v.u, v);
    for (const [k, v] of await this.state.storage.list({ prefix: "h:" })) {
      if (!v || typeof v.id !== "string") continue;
      this.hkeys.push(k);
      const c = { ...v, hk: k };
      this.cmds.set(c.id, c);
      if (c.st === "PENDING" || c.st === "DELIVERED") {
        if (c.exp > now) this.open.set(c.id, c);
        else { c.st = "EXPIRED"; c.fin = now; await this.putCmd(c); }
      }
    }
    for (const [, arr] of await this.state.storage.list({ prefix: "r:" })) { // bans are loaded above
      if (!Array.isArray(arr)) continue;
      for (const v of arr) {
        const rec = this.restore(v, now);
        if (rec && !this.bans.has(rec.u) && this.pres.size < this.maxPres) this.pres.set(rec.u, rec);
      }
    }
    for (let i = 0; i < SHARDS; i++) this.dirty.add(i); // the first flush rewrites every shard without the sessions that expired meanwhile
  }

  async fetch(request) {
    await this.ready;
    const url = new URL(request.url);
    try {
      switch (`${request.method} ${url.pathname}`) {
        case "POST /live/auth/login": return await this.authLogin(request);
        case "POST /live/auth/logout": return await this.authLogout(request);
        case "POST /live/presence": return await this.presence(request);
        case "POST /live/presence/leave": return await this.leave(request);
        case "GET /live/list": return await this.list(request, url);
        case "GET /live/commands": return await this.commands(request, url);
        case "POST /live/mod/command": return await this.command(request);
        case "GET /live/mod/history": return await this.history(request);
        default: return fail(404, "not_found");
      }
    } catch (err) {
      console.error("live-log error", err && err.stack || err);
      return fail(500, "internal");
    } finally {
      await this.flush(Date.now()); // changed registry shards are written here (rate-limited; a storage error never fails the request)
    }
  }

  // ---------- helpers ----------
  hit(key, max, windowMs) {
    const now = Date.now();
    let r = this.rate.get(key);
    if (!r || now - r.t > windowMs) r = { t: now, n: 0 };
    r.n++;
    this.rate.set(key, r);
    if (this.rate.size > 5000) for (const [k, v] of this.rate) if (now - v.t > windowMs) this.rate.delete(k);
    return r.n <= max;
  }

  async session(request) {
    const token = bearer(request);
    if (token.length < 32 || token.length > 128) return null;
    const h = await sha256hex(token);
    let s = this.sess.get(h);
    if (!s) {
      s = await this.state.storage.get("s:" + h);
      if (s) this.sess.set(h, s);
    }
    if (!s) return null;
    const now = Date.now();
    if (s.x < now) { await this.dropSession(h, s); return null; }
    if (now - s.t > SESSION_TOUCH_MS) {
      s.t = now; s.x = now + SESSION_TTL_MS;
      await this.state.storage.put("s:" + h, s);
    }
    return { h, u: s.u, n: s.n, d: s.d || "" };
  }

  /** session + ban check. Returns {s} or {res} (a ready error response). */
  async need(request) {
    const s = await this.session(request);
    if (!s) return { res: fail(401, "unauthorized") };
    if (this.bans.has(s.u)) return { res: fail(403, "banned") };
    return { s };
  }

  /** session + ban + viewer role (re-checked against the role table on EVERY call). Returns {s, role} or {res}. */
  async needViewer(request) {
    const a = await this.need(request);
    if (a.res) return a;
    const table = await loadRoleTable(this.env);
    if (!table) return { res: fail(503, "roles_unavailable") }; // cannot establish who is allowed => return nothing
    const role = roleFor(table, a.s.u, a.s.n);
    if (!role) return { res: fail(403, "forbidden") };
    return { s: a.s, role, table };
  }

  async dropSession(h, s) {
    this.sess.delete(h);
    await this.state.storage.delete("s:" + h);
    const key = "ui:" + s.u;
    const idx = ((await this.state.storage.get(key)) || []).filter((x) => x !== h);
    if (idx.length) await this.state.storage.put(key, idx); else await this.state.storage.delete(key);
  }

  touch() { return ++this.seq; }

  removePresence(uid) {
    if (!this.pres.delete(uid)) return false;
    this.mark(uid);
    this.tombs.push({ u: uid, rev: ++this.seq });
    while (this.tombs.length > MAX_TOMBS) this.tombFloor = this.tombs.shift().rev;
    return true;
  }

  mark(uid) { this.dirty.add(uid % SHARDS); }

  /** what is stored of one account: its sessions with everything needed to keep serving them after a cold start (private server ids are never in `j`) */
  row(rec) {
    const ss = [];
    for (const [k, x] of rec.ses) ss.push({ k, at: x.at, seen: x.seen, pid: x.pid, g: x.g, j: x.j, gi: x.gi, cap: [...x.cap], h: x.h });
    return { u: rec.u, n: rec.n, d: rec.d, ss };
  }

  /** rebuilds an account from its stored row; only sessions still inside the presence window come back (older ones are what expiry would have removed anyway) */
  restore(v, now) {
    if (!v || !Number.isSafeInteger(v.u) || v.u < 1 || !Array.isArray(v.ss)) return null;
    const ses = new Map();
    for (const x of v.ss.slice(0, MAX_SCRIPT_SESSIONS)) {
      if (!x || typeof x.k !== "string" || !SID_RE.test(x.k) || typeof x.seen !== "number" || !(now - x.seen <= PRESENCE_TTL_MS)) continue;
      ses.set(x.k, {
        at: Number(x.at) || x.seen, seen: x.seen, last: x.seen, pid: Number(x.pid) || 0, g: cleanText(x.g, 64),
        j: typeof x.j === "string" && GUID_RE.test(x.j) ? x.j : "", gi: Number(x.gi) || 0,
        cap: new Set((Array.isArray(x.cap) ? x.cap : []).filter((a) => ACTIONS.has(a))), h: typeof x.h === "string" ? x.h : "",
      });
    }
    if (!ses.size) return null;
    const rec = { u: v.u, n: cleanText(v.n, 20), d: cleanText(v.d, 32), pid: 0, g: "", j: "", seen: 0, rev: 0, crev: 0, last: now, ses, main: "", ns: 0 };
    this.refreshMain(rec);
    return rec;
  }

  /** writes the changed shards (all of them at most every FLUSH_GAP_MS, or just shard `only` right away). Never throws: on a storage error the shards stay dirty. */
  async flush(now, only = -1) {
    if (only >= 0 ? !this.dirty.has(only) : (!this.dirty.size || now - this.flushAt < FLUSH_GAP_MS)) return;
    const idx = only >= 0 ? [only] : [...this.dirty];
    if (only < 0) this.flushAt = now;
    for (const i of idx) this.dirty.delete(i);
    const rows = new Map(idx.map((i) => [i, []]));
    for (const rec of this.pres.values()) rows.get(rec.u % SHARDS)?.push(this.row(rec));
    const put = {}, del = [];
    for (const [i, arr] of rows) { if (arr.length) put["r:" + i] = arr; else del.push("r:" + i); }
    try {
      if (Object.keys(put).length) await this.state.storage.put(put);
      if (del.length) await this.state.storage.delete(del);
    } catch (err) {
      console.error("live-log flush", err && err.stack || err);
      for (const i of idx) this.dirty.add(i);
    }
  }

  /** the entry shows its NEWEST valid session; an older / stale session can never replace a newer one */
  refreshMain(rec) {
    let main = null, seen = 0;
    for (const [sid, x] of rec.ses) {
      if (x.seen > seen) seen = x.seen;
      if (!main || x.at > main[1].at) main = [sid, x];
    }
    rec.seen = seen;
    rec.main = main[0];
    rec.pid = main[1].pid; rec.g = main[1].g; rec.j = main[1].j; rec.gi = main[1].gi;
    rec.ns = rec.ses.size;
  }

  /** removes the entry's sessions matching `match`; the account leaves the registry only when no valid session remains */
  async leaveSessions(uid, match) {
    const rec = this.pres.get(uid);
    if (!rec) return;
    let cut = false;
    for (const [sid, x] of rec.ses) if (match(sid, x)) { rec.ses.delete(sid); cut = true; }
    if (!cut) return;
    const now = Date.now();
    if (!rec.ses.size) { // last session gone: the account leaves the registry (change log + count) and its persisted row is deleted
      this.removePresence(uid);
      await this.reroute(uid, now);
      return;
    }
    this.refreshMain(rec); // another valid session becomes the primary one
    rec.rev = rec.crev = this.touch();
    this.mark(uid);
    await this.reroute(uid, now);
  }

  /** open commands of `uid` addressed to a session that no longer exists (left / expired / logged out). A still-PENDING one moves to the account's current
   *  primary session when that session can run it; everything else is finished truthfully. A command never leaves its own target account and is never
   *  left waiting for a session that is gone (nor for a later rejoin). */
  async reroute(uid, now) {
    if (!this.open.size) return;
    const rec = this.pres.get(uid);
    const main = rec && rec.main !== "" ? rec.ses.get(rec.main) : null;
    for (const c of [...this.open.values()]) {
      if (c.tu !== uid || (rec && rec.ses.has(c.ts))) continue;
      if (c.st === "PENDING" && main && main.cap.has(c.a)) { c.ts = rec.main; await this.putCmd(c); this.touch(); continue; }
      await this.finish(c, "TARGET_OFFLINE", c.st === "DELIVERED" ? "session ended before it acknowledged" : "target session left", now);
    }
  }

  async purge(now, force = false) {
    if (force || now - this.lastPurge >= 10_000) {
      this.lastPurge = now;
      const gone = [], cut = [];
      for (const rec of this.pres.values()) {
        let dead = false;
        for (const [sid, x] of rec.ses) if (now - x.seen > PRESENCE_TTL_MS) { rec.ses.delete(sid); dead = true; }
        if (!rec.ses.size) gone.push(rec.u); else if (dead) cut.push(rec);
      }
      for (const uid of gone) this.removePresence(uid);
      for (const rec of cut) {
        this.refreshMain(rec);
        rec.rev = rec.crev = this.touch();
        this.mark(rec.u);
      }
      for (const [k, t] of this.left) if (t <= now) this.left.delete(k);
      for (const uid of gone) await this.reroute(uid, now); // expired sessions: their commands are re-routed or finished, never stranded
      for (const rec of cut) await this.reroute(rec.u, now);
      for (const c of [...this.open.values()]) if (c.exp <= now) await this.finish(c, "EXPIRED", "", now);
      for (const [id, c] of this.cmds) if (!this.open.has(id) && now - (c.fin || c.iat) > CMD_KEEP_MS) this.cmds.delete(id);
    }
  }

  // ---------- sign-in: automatic, no profile code ----------
  async authLogin(request) {
    const b = await readJson(request);
    const uid = b && Number.isSafeInteger(b.userId) ? b.userId : 0;
    if (uid < 1 || uid > 1e12) return fail(400, "bad_request");
    if (this.bans.has(uid)) return fail(403, "banned");
    if (!this.hit("lig", 240, 60_000)) return fail(429, "slow");

    // the username / display name come from Roblox for that user id, never from the client. A recent lookup of the same id is reused and an older one is the
    // fallback when Roblox cannot be reached, so registering does not hinge on Roblox rate limits.
    const now = Date.now();
    let who = this.names.get(uid);
    if (!who || now - who.at > NAME_TTL_MS) {
      let u = null;
      for (let i = 0; i < 2 && !u; i++) {
        if (i) await new Promise((r) => setTimeout(r, 400));
        try {
          const res = await fetch(`https://users.roblox.com/v1/users/${uid}`, {
            headers: { Accept: "application/json" },
            cf: { cacheTtl: 0, cacheEverything: false },
          });
          if (res.ok) u = await res.json();
        } catch { u = null; }
      }
      if (u) {
        if (typeof u !== "object" || u.id !== uid || typeof u.name !== "string" || !NAME_RE.test(u.name)) return fail(422, "account_invalid");
        who = { n: u.name, d: cleanText(u.displayName, 32), at: now };
        if (this.names.size >= MAX_NAMES) this.names.delete(this.names.keys().next().value);
        this.names.set(uid, who);
      } else if (!who) return fail(503, "roblox_unavailable");
    }

    // issue a session bound to the resolved user id / username (the token is shown once; only its hash is stored)
    const token = randomToken();
    const h = await sha256hex(token);
    const rec = { u: uid, n: who.n, d: who.d, c: now, t: now, x: now + SESSION_TTL_MS };
    const idxKey = "ui:" + uid;
    const idx = (await this.state.storage.get(idxKey)) || [];
    idx.push(h);
    while (idx.length > MAX_SESSIONS_PER_USER) {
      const old = idx.shift();
      this.sess.delete(old);
      await this.state.storage.delete("s:" + old);
    }
    await this.state.storage.put({ ["s:" + h]: rec, [idxKey]: idx });
    this.sess.set(h, rec);
    return json({ ok: true, token, uid, name: who.n, display: who.d });
  }

  async authLogout(request) {
    const s = await this.session(request);
    if (!s) return fail(401, "unauthorized");
    await this.leaveSessions(s.u, (_sid, x) => x.h === s.h); // every live script session that used this login leaves the registry
    await this.flush(Date.now(), s.u % SHARDS);
    await this.dropSession(s.h, { u: s.u });
    return json({ ok: true });
  }

  // ---------- presence (publisher) ----------
  async presence(request) {
    const a = await this.need(request);
    if (a.res) return a.res;
    const s = a.s;
    const b = await readJson(request);
    if (!b) return fail(400, "bad_request");
    const now = Date.now();
    if (!this.hit("pr:" + s.u, 40, 60_000)) return fail(429, "slow");
    await this.purge(now);

    // one script run = one session id. Older clients without a sid fall back to their login token.
    const sid = typeof b.sid === "string" && SID_RE.test(b.sid.toLowerCase()) ? b.sid.toLowerCase() : s.h.slice(0, 16);
    if ((this.left.get(sid + ":" + s.h) || 0) > now) return fail(410, "left"); // this session already left: a late / reordered request cannot bring it back
    let rec = this.pres.get(s.u);
    let ses = rec && rec.ses.get(sid);
    const acks = Array.isArray(b.ack) ? b.ack.slice(0, 5) : [];
    if (acks.length && ses) await this.applyAcks(s.u, sid, acks, now); // acknowledgements are never rate-limited by the heartbeat gap
    else if (ses && now - ses.last < MIN_PRESENCE_GAP_MS) return fail(429, "slow", { retry: Math.ceil((MIN_PRESENCE_GAP_MS - (now - ses.last)) / 1000) });

    if (b.t === "hb") { // heartbeat: only refreshes an existing session (a missing one asks the client to send its full state)
      if (!ses) return fail(409, "resync");
      ses.seen = ses.last = rec.seen = now;
      ses.h = s.h; // a new sign-in of the same script run keeps its session
      rec.rev = this.touch();
      this.mark(s.u);
      return json({ ok: true, ...(await this.deliver(s.u, sid, now)) });
    }

    const pid = Number.isSafeInteger(b.pid) && b.pid > 0 && b.pid < 1e14 ? b.pid : 0;
    if (!pid) return fail(400, "bad_request");
    const g = cleanText(b.g, 64);
    const gi = Number.isSafeInteger(b.gi) && b.gi > 0 && b.gi < 1e14 ? b.gi : 0; // UniverseId of the experience (pid is the PlaceId)
    const shareJob = b.pub === true && typeof b.j === "string" && GUID_RE.test(b.j);
    const j = shareJob ? b.j.toLowerCase() : "";
    const dn = cleanText(b.dn, 32) || s.d; // display name: presentation only, never identity
    const cap = new Set((Array.isArray(b.cap) ? b.cap.slice(0, 16) : []).filter((x) => typeof x === "string" && ACTIONS.has(x)));
    if (!rec && this.pres.size >= this.maxPres) { this.fullAt = now; return fail(503, "full"); }

    const isNew = !rec;
    if (isNew) rec = { u: s.u, n: s.n, d: dn, pid, g, j, seen: now, rev: 0, crev: 0, last: now, ses: new Map(), main: "", ns: 0 };
    const d0 = isNew ? "" : disp(rec), ns0 = rec.ns;
    rec.ses.delete(""); // placeholder left by a cold start
    if (!ses) {
      if (rec.ses.size >= MAX_SCRIPT_SESSIONS) { // drop the least recently seen session to make room
        let oldest = null;
        for (const [k, x] of rec.ses) if (!oldest || x.seen < oldest[1].seen) oldest = [k, x];
        if (oldest) rec.ses.delete(oldest[0]);
      }
      ses = { at: now, seen: now, last: now, pid, g, j, gi, cap, h: s.h };
      rec.ses.set(sid, ses);
    } else {
      Object.assign(ses, { seen: now, last: now, pid, g, j, gi, cap, h: s.h }); // `at` (session start) never moves: a late request cannot make a session "newer"
    }
    rec.n = s.n; rec.d = dn;
    this.refreshMain(rec);
    const rev = this.touch();
    rec.rev = rev; rec.last = now;
    const contentChanged = isNew || disp(rec) !== d0;
    if (contentChanged || rec.ns !== ns0) rec.crev = rev;
    this.pres.set(s.u, rec);
    this.mark(s.u);
    return json({ ok: true, ...(await this.deliver(s.u, sid, now)) });
  }

  async leave(request) {
    const a = await this.need(request);
    if (a.res) return a.res;
    const b = (await readJson(request)) || {};
    const sid = typeof b.sid === "string" && SID_RE.test(b.sid.toLowerCase()) ? b.sid.toLowerCase() : a.s.h.slice(0, 16);
    if (!this.hit("lv:" + a.s.u, 20, 60_000)) return fail(429, "slow");
    if (this.left.size < 20000) this.left.set(sid + ":" + a.s.h, Date.now() + LEFT_HOLD_MS); // set first: a request already in flight cannot re-create the session
    await this.leaveSessions(a.s.u, (id) => id === sid); // idempotent: a second leave finds nothing to remove
    await this.flush(Date.now(), a.s.u % SHARDS);
    return json({ ok: true });
  }

  // ---------- list (viewer) ----------
  async list(request, url) {
    const v = await this.needViewer(request); // authorization is decided here, on every request, from the signed-in session identity
    if (v.res) return v.res;
    const { s, role } = v;

    const now = Date.now();
    await this.purge(now, true); // expiry is evaluated now, so onlineCount only ever counts unexpired presence

    let sessions = 0;
    for (const p of this.pres.values()) sessions += p.ses.size;
    const meta = { e: this.epoch, s: this.seq, t: now, onlineCount: this.pres.size, sessionCount: sessions, cap: this.maxPres, role, acts: actionsFor(role) };
    if (this.pres.size >= this.maxPres || now - this.fullAt < SAT_HOLD_MS) meta.sat = 1; // the total is a lower bound, never present it as complete

    const [e, q] = String(url.searchParams.get("c") || "").split(".");
    const since = e === this.epoch && /^\d{1,12}$/.test(q || "") ? Number(q) : -1;
    const etag = `"${this.epoch}.${this.seq}"`;
    const headers = { ETag: etag };
    if (request.headers.get("If-None-Match") === etag) return new Response(null, { status: 304, headers: { ...headers, "Cache-Control": "private, no-store" } });
    if (since === this.seq) return json({ ok: true, nc: 1, ...meta }, 200, headers);

    const full = since < 0 || since < this.tombFloor || since > this.seq;
    const age = (p) => Math.max(0, Math.floor((now - p.seen) / 1000));
    const sage = (p) => { const m = p.ses.get(p.main); return m ? Math.max(0, Math.floor((now - m.at) / 1000)) : 0; }; // age of the newest session
    const up = [], tc = [], rm = [], mc = [];
    for (const p of this.pres.values()) {
      if (full || p.crev > since) up.push({ u: p.u, n: p.n, d: p.d || undefined, p: p.pid, g: p.g, j: p.j || undefined, a: age(p), ns: p.ns > 1 ? p.ns : undefined, gi: p.gi || undefined, s: sage(p) });
      else if (p.rev > since) tc.push([p.u, age(p)]);
    }
    if (!full) for (const t of this.tombs) if (t.rev > since && !this.pres.has(t.u)) rm.push(t.u);
    for (const c of this.cmds.values()) if (c.mu === s.u && now - c.iat < 600_000) mc.push([c.id, c.st, c.a, c.tn, c.note || ""]);

    const body = { ok: true, ...meta };
    if (full) body.full = true;
    if (up.length) body.up = up;
    if (tc.length) body.tc = tc;
    if (rm.length) body.rm = rm;
    if (mc.length) body.mc = mc.slice(-12);
    return json(body, 200, headers);
  }

  // ---------- moderation ----------
  async putCmd(c) {
    const { hk, ...row } = c;
    await this.state.storage.put(hk, row);
  }

  /** stores a new history entry (separate from the roster) and makes it visible to its moderator */
  async record(c) {
    c.hk = "h:" + String(c.iat).padStart(13, "0") + ":" + c.id.slice(0, 8);
    this.hkeys.push(c.hk);
    const old = [];
    while (this.hkeys.length > MAX_HIST) old.push(this.hkeys.shift());
    await this.putCmd(c);
    if (old.length) await this.state.storage.delete(old);
    this.cmds.set(c.id, c);
    if (c.st === "PENDING") this.open.set(c.id, c);
    this.touch();
  }

  async finish(c, st, note, now) {
    c.st = st; c.fin = now;
    if (note) c.note = note;
    this.open.delete(c.id);
    this.touch();
    await this.putCmd(c);
  }

  /** commands for this exact target session, piggybacked on its heartbeat response */
  async deliver(uid, sid, now) {
    if (!this.open.size) return {};
    const out = [];
    for (const c of this.open.values()) {
      if (c.tu !== uid || c.ts !== sid || c.exp <= now) continue;
      if (c.st === "DELIVERED" && now - c.dat < REDELIVER_MS) continue; // already handed over; wait for the acknowledgement
      if (c.st === "PENDING") { c.st = "DELIVERED"; this.touch(); }
      c.dat = now;
      await this.putCmd(c);
      out.push({ id: c.id, tu: c.tu, ts: c.ts, mu: c.mu, mn: c.mn, mr: c.mr, a: c.a, iat: c.iat, exp: c.exp, ttl: c.exp - now, r: c.r || undefined, d: c.d || undefined });
    }
    return out.length ? { cmd: out } : {};
  }

  /** target side, banner-style short poll: only commands addressed to THIS account AND this script session are handed over (same deliver() as the heartbeat) */
  async commands(request, url) {
    const a = await this.need(request);
    if (a.res) return a.res;
    const s = a.s;
    if (!this.hit("cp:" + s.u, 200, 60_000)) return fail(429, "slow");
    const sid = (url.searchParams.get("sid") || "").toLowerCase();
    if (!SID_RE.test(sid)) return fail(400, "bad_request");
    const now = Date.now();
    if ((this.left.get(sid + ":" + s.h) || 0) > now) return fail(410, "left");
    await this.purge(now); // rate-limited inside: unanswered commands finish as EXPIRED on time
    const rec = this.pres.get(s.u);
    if (!rec || !rec.ses.has(sid)) return fail(409, "resync");
    if (!this.open.size) return json({ ok: true });
    return json({ ok: true, ...(await this.deliver(s.u, sid, now)) });
  }

  /** acknowledgements from the target client; only the addressed session may answer for its command */
  async applyAcks(uid, sid, acks, now) {
    for (const x of acks) {
      if (!x || typeof x !== "object" || typeof x.id !== "string" || !CID_RE.test(x.id)) continue;
      const c = this.open.get(x.id);
      if (!c || c.tu !== uid || c.ts !== sid) continue;
      await this.finish(c, ACK_STATES.has(x.st) ? x.st : "FAILED", cleanText(x.n, 40), now);
    }
  }

  async command(request) {
    const v = await this.needViewer(request); // role from the role table, never from the request
    if (v.res) return v.res;
    const { s, role, table } = v;
    const b = await readJson(request);
    if (!b) return fail(400, "bad_request");
    if (!this.hit("cm:" + s.u, 12, 60_000)) return fail(429, "slow");

    const now = Date.now();
    await this.purge(now, true); // expiry is evaluated now: an expired session can never be offered as a live target
    const action = typeof b.a === "string" ? b.a.toLowerCase() : "";
    const tu = Number.isSafeInteger(b.tu) ? b.tu : 0;
    if (tu < 1 || tu === s.u) return fail(400, "bad_target");
    const d = Number.isFinite(b.d) ? Math.min(120, Math.max(5, Math.floor(b.d))) : 0;
    const c = { id: randomHex(16), tu, tn: "", ts: "", mu: s.u, mn: s.n, mr: role, a: cleanText(action, 12), r: cleanText(b.r, 80), d: (action === "dizzy" || action === "hallucinate") ? d : 0, iat: now, exp: now + CMD_TTL_MS, st: "PENDING" };
    const reject = async (st, err, status, note, extra = {}) => {
      c.st = st; c.fin = now; if (note) c.note = note;
      await this.record(c);
      return fail(status, err, { id: c.id, st, ...(st === "ACTION_UNSUPPORTED" ? { msg: UNSUPPORTED } : {}), ...extra });
    };

    if (!ACTIONS.has(action)) return reject("ACTION_UNSUPPORTED", "ACTION_UNSUPPORTED", 422);
    const allowed = actionsFor(role);
    if (!allowed.includes(action === "unban" ? "ban" : action)) return reject("REJECTED", "forbidden_action", 403, "role not permitted"); // BAN: owner / co-owner only

    if (action === "unban") { // reverse a UH services ban (owner / co-owner); the target does not have to be online
      const ban = this.bans.get(tu);
      c.tn = ban ? ban.n : "";
      if (!ban) return reject("FAILED", "not_banned", 404, "no ban on record");
      this.bans.delete(tu);
      await this.state.storage.delete("b:" + tu);
      c.st = "EXECUTED"; c.fin = now; c.note = "ban removed";
      await this.record(c);
      return json({ ok: true, id: c.id, st: c.st, note: c.note });
    }

    const rec = this.pres.get(tu); // target must be an active, authenticated script user - nobody else can ever be addressed
    if (!rec) return reject("TARGET_OFFLINE", "target_offline", 409, "target is not connected");
    c.tn = rec.n;
    if ((RANK[roleFor(table, tu, rec.n)] || 0) >= (RANK[role] || 0)) return reject("REJECTED", "target_protected", 403, "target outranks or equals you");

    if (action === "ban") { // backend-authoritative: takes effect at once for every UH backend service, the client exits on its next request
      const ban = { u: tu, n: rec.n, by: s.u, bn: s.n, at: now, r: c.r };
      this.bans.set(tu, ban);
      await this.state.storage.put("b:" + tu, ban);
      this.removePresence(tu);
      for (const o of [...this.open.values()]) if (o.tu === tu) await this.finish(o, "REJECTED", "target banned", now);
      c.st = "EXECUTED"; c.fin = now; c.note = "backend ban applied";
      await this.record(c);
      return json({ ok: true, id: c.id, st: c.st, note: c.note });
    }

    const ses = rec.ses.get(rec.main); // the newest valid session of the account
    if (!ses || rec.main === "") return reject("TARGET_OFFLINE", "target_offline", 409, "session not re-established yet");
    if (!ses.cap.has(action)) return reject("ACTION_UNSUPPORTED", "ACTION_UNSUPPORTED", 422, "target client lacks this action");
    for (const o of this.open.values()) if (o.tu === tu && o.a === action && o.exp > now) return fail(409, "duplicate", { id: o.id, st: o.st });
    if (!this.hit("ct:" + tu, 6, 60_000)) return fail(429, "slow");

    c.ts = rec.main;
    await this.record(c); // PENDING: accepted by the backend, NOT yet delivered or executed
    return json({ ok: true, id: c.id, st: "PENDING", ttl: Math.floor(CMD_TTL_MS / 1000) });
  }

  async history(request) {
    const v = await this.needViewer(request);
    if (v.res) return v.res;
    if (!this.hit("hi:" + v.s.u, 10, 60_000)) return fail(429, "slow");
    const rows = await this.state.storage.list({ prefix: "h:", reverse: true, limit: 40 });
    const h = [];
    for (const [, c] of rows) h.push({ id: c.id, tu: c.tu, tn: c.tn, mu: c.mu, mn: c.mn, mr: c.mr, a: c.a, r: c.r || undefined, iat: c.iat, st: c.st, note: c.note || undefined });
    return json({ ok: true, h });
  }
}
