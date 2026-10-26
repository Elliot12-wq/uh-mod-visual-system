// banner_auth.js — drop next to worker.js (Cloudflare Worker, ES module).
// Secrets (never in the repo / client):  wrangler secret put OWNER_KEY_SHA256   -> 8c9e86574d07250ac6a5b203d4f8c68bc5a2b6ae30754506723f16edcc9345ec
//                                         wrangler secret put MOD_KEY_SHA256     -> optional, a different hash for verified moderators (falls back to OWNER_KEY_SHA256)
//
// Client proof = sha256( sha256(key) | claimantUserId | room | path | ts | nonce | bind )   (body fields: ts, nonce, proof)
//   path  bind
//   /banner, /clear           ""
//   /mod                      "<target>:<action>"
//   /blacklist, /unblacklist  "<userId being (un)blacklisted>"    (claimant = body.byId)
//
// Wiring (in worker.js):
//   import { verifyProof } from "./banner_auth.js";
//   // /banner and /clear: a request that claims an owner / co-owner / verified userId MUST carry a valid proof. Reject, don't downgrade.
//   const tier = ownerIds.has(uid) ? "owner" : verifiedIds.has(uid) ? "mod" : null;   // ownerIds = roles.json, verifiedIds = whitelist.json
//   if (tier && !(await verifyProof(env, { userId: uid, room: b.room, path: "/banner", bind: "", ts: b.ts, nonce: b.nonce, proof: b.proof }, tier)))
//     return json({ error: "bad proof" }, 403);
//   // /mod: tier = owner|mod is required, bind = `${b.target}:${b.action}`.   /blacklist + /unblacklist: tier "owner" only, userId = b.byId, bind = String(b.userId).
//   // Drop every old `key` comparison.

const enc = new TextEncoder();
const seen = new Map(); // nonce -> time (per isolate; use KV / a Durable Object if you need strict cross-isolate replay protection)

async function sha256Hex(s) {
  const d = await crypto.subtle.digest("SHA-256", enc.encode(s));
  return [...new Uint8Array(d)].map(x => x.toString(16).padStart(2, "0")).join("");
}
function safeEq(a, b) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

// tier: "owner" (owner / co-owner) | "mod" (verified)
export async function verifyProof(env, { userId, room, path, bind = "", ts, nonce, proof }, tier = "owner") {
  const H = String((tier === "mod" && env.MOD_KEY_SHA256) || env.OWNER_KEY_SHA256 || "").toLowerCase();
  ts = String(ts ?? ""); nonce = String(nonce ?? ""); proof = String(proof ?? "");
  if (!/^[0-9a-f]{64}$/.test(H) || !/^\d{9,12}$/.test(ts) || !/^[0-9a-f]{16,96}$/.test(nonce) || !/^[0-9a-f]{64}$/.test(proof)) return false;
  const now = Date.now();
  if (Math.abs(now / 1000 - Number(ts)) > 120 || seen.has(nonce)) return false;
  const want = await sha256Hex([H, userId, room, path, ts, nonce, bind].join("|"));
  if (!safeEq(want, proof)) return false;
  seen.set(nonce, now);
  for (const [k, t] of seen) if (now - t > 300000) seen.delete(k);
  return true;
}
