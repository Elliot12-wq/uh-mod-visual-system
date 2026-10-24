// Node >=18 port of worker.js (same API, in-memory rooms, no dependencies). Any Node host works.
const http = require("http");
const ID = /^\d{1,16}$/, ROOM = /^[0-9A-Za-z:_-]{1,80}$/, IMG = /^(rbxassetid:\/\/)?\d{1,19}$/;
const TTL = 75000, rooms = new Map();
const s = (v, n) => String(v ?? "").replace(/[\u0000-\u001f\u007f]/g, "").slice(0, n);
const send = (res, code, body) => { res.writeHead(code, { "Content-Type": "application/json" }); res.end(JSON.stringify(body)); };
const live = (room) => { const m = rooms.get(room) || {}, now = Date.now(); for (const k in m) if (m[k].exp < now) delete m[k]; return m; };
setInterval(() => { for (const r of [...rooms.keys()]) if (!Object.keys(live(r)).length) rooms.delete(r); }, 15000).unref();

// ---- moderator commands: kill / deanimate / kick, only against live script users, only from keyed moderators ----
// MOD_KEYS env = JSON array of one-time keys, e.g. ["Nooby-...", "Nooby-..."]. A key locks to the FIRST userId that uses it and then works for that user only.
// Claimed userIds are immune to commands. Claims are saved to mod_claims.json (best effort; some free hosts wipe files on restart).
const crypto = require("crypto");
let KEYS = []; try { KEYS = JSON.parse(process.env.MOD_KEYS || "[]"); } catch {}
const fs = require("fs"), CLAIMS_FILE = process.env.MOD_CLAIMS || "mod_claims.json";
let claims = {}; try { claims = JSON.parse(fs.readFileSync(CLAIMS_FILE, "utf8")); } catch {}
const authMod = (key, userId) => { // true when `key` is a valid key that is unclaimed (it locks to userId now) or already locked to userId
  let hit = null; for (const k of KEYS) if (same(key, k)) hit = k;
  if (!hit) return false;
  if (!claims[hit]) { claims[hit] = userId; try { fs.writeFileSync(CLAIMS_FILE, JSON.stringify(claims)); } catch {} }
  return claims[hit] === userId;
};
const isMod = (id) => Object.values(claims).includes(id);
const OWNER_KEY = process.env.OWNER_KEY || ""; // owner + co-owner secret (same value as their UhBannerConfig.OwnerKey): accepted by /mod and /verify with no one-time key
const ownerKeyOk = (key) => OWNER_KEY !== "" && same(key, OWNER_KEY);
const ACTIONS = new Set(["kill", "deanimate", "kick"]), CMD_TTL = 30000, cmds = new Map(), lastCmd = new Map(), lastVerify = new Map();
const same = (a, b) => { const x = Buffer.from(String(a)), y = Buffer.from(String(b)); return x.length === y.length && crypto.timingSafeEqual(x, y); };
setInterval(() => { const now = Date.now(); for (const [r, m] of cmds) { for (const id in m) { m[id] = m[id].filter((c) => c.exp > now); if (!m[id].length) delete m[id]; } if (!Object.keys(m).length) cmds.delete(r); } }, 15000).unref();

http.createServer((req, res) => {
  const url = new URL(req.url, "http://x"), p = url.pathname;
  if (req.method === "GET" && p === "/") return send(res, 200, { ok: true });
  if (req.method === "GET" && p === "/banners") {
    const room = url.searchParams.get("room");
    if (!ROOM.test(room || "")) return send(res, 400, { error: "bad room" });
    return send(res, 200, { banners: Object.values(live(room)).map(({ token, exp, ...pub }) => ({ ...pub, verified: isMod(String(pub.userId)) })) });
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
  if (req.method === "POST" && p === "/verify") { // key box in the UI: locks a one-time key to this userId (or re-confirms it)
    let txt = "", dead = false;
    req.on("data", (c) => { if (dead) return; txt += c; if (txt.length > 1024) { dead = true; send(res, 413, { error: "too large" }); } });
    req.on("end", () => {
      if (dead) return;
      let b; try { b = JSON.parse(txt); } catch { return send(res, 400, { error: "bad json" }); }
      const id = String(b && b.userId), now = Date.now();
      if (!ID.test(id) || typeof b.key !== "string") return send(res, 400, { error: "bad" });
      if (now - (lastVerify.get(id) || 0) < 1000) return send(res, 429, { error: "slow down" });
      lastVerify.set(id, now);
      if (!ownerKeyOk(b.key) && !authMod(b.key, id)) return send(res, 403, { error: "invalid key or already used" });
      send(res, 200, { ok: true });
    });
    return;
  }
  if (req.method === "GET" && p === "/commands") { // a script user collects (and clears) commands addressed to them; needs their banner token
    const room = url.searchParams.get("room"), id = String(url.searchParams.get("userId")), tok = url.searchParams.get("token");
    if (!ROOM.test(room || "") || !ID.test(id) || !tok) return send(res, 400, { error: "bad" });
    const mine = live(room)[id];
    if (!mine || mine.token !== tok) return send(res, 403, { error: "not claimed" });
    const m = cmds.get(room) || {}, now = Date.now(), out = (m[id] || []).filter((c) => c.exp > now).map(({ exp, ...pub }) => pub);
    delete m[id];
    return send(res, 200, { commands: out });
  }
  if (req.method === "POST" && p === "/mod") {
    let txt = "", dead = false;
    req.on("data", (c) => { if (dead) return; txt += c; if (txt.length > 2048) { dead = true; send(res, 413, { error: "too large" }); } });
    req.on("end", () => {
      if (dead) return;
      let b; try { b = JSON.parse(txt); } catch { return send(res, 400, { error: "bad json" }); }
      if (!b || !ROOM.test(b.room || "")) return send(res, 400, { error: "bad room" });
      const by = String(b.userId), target = String(b.target), now = Date.now();
      if (!ID.test(by) || !ID.test(target) || !ACTIONS.has(b.action)) return send(res, 400, { error: "bad" });
      if (!ownerKeyOk(b.key || "") && !authMod(b.key || "", by)) return send(res, 403, { error: "not a moderator / key already used by someone else" });
      if (isMod(target)) return send(res, 403, { error: "immune" });
      if (!live(b.room)[target]) return send(res, 404, { error: "target is not running the script" });
      if (now - (lastCmd.get(by) || 0) < 1500) return send(res, 429, { error: "slow down" });
      lastCmd.set(by, now);
      const m = cmds.get(b.room) || {};
      (m[target] = m[target] || []).push({ action: b.action, by: +by, ts: now, exp: now + CMD_TTL });
      cmds.set(b.room, m);
      send(res, 200, { ok: true });
    });
    return;
  }
  send(res, 404, { error: "not found" });
}).listen(process.env.PORT || 3000);
