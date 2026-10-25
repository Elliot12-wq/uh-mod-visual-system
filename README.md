# uh-mod-visual-system
this is the visual system that is for my modded fork.

## Backend (Cloudflare Workers)
`worker.js` + `wrangler.toml` deploy as the `banner-system` Worker (https://banner-system.elliptmal.workers.dev) with one Durable Object class (`Room`).
Deploy: push to the connected repo, or `npx wrangler deploy`.

Set these in Workers > Settings > Variables and Secrets (or `npx wrangler secret put NAME`):
- `MOD_KEYS` JSON array of one-time moderator keys, e.g. `["Nooby-abc","Nooby-def"]`
- `OWNER_KEY` owner / co-owner secret (optional; owners are also recognised by userId)
- `OWNER_IDS` JSON array of extra owner userIds (optional)
- `GITHUB_TOKEN` fine-grained token, Contents: read + write on this repo (blacklist edits)
- `GITHUB_REPO` (default `Elliot12-wq/uh-mod-visual-system`), `GITHUB_BRANCH` (default `main`), `BLACKLIST_PATH` (default `blacklist.json`)

`server.js` is the old Node/Render copy of the same API and is not used by Cloudflare.
