-- ===================== LIVE PLAYER LOG =====================
-- Global registry of active UH script users on the Cloudflare LiveLogHub (/live/*) + role-restricted roster + remote moderation commands.
-- Identity = automatic sign-in: this client states its own UserId, the Worker resolves the account from Roblox and issues a session token (no profile code, no manual step).
-- Roles come ONLY from roles.json (owner / co-owner / verified) and whitelist.json (verified): the Worker reads them on every request. Every signed-in script client publishes its own
-- presence (automatic; a notice and the registry page disclose exactly what is shared); only verified players / co-owners / owner can read the roster, and the Worker re-checks that on every request.
-- The active-user count comes from the Worker (unique accounts with unexpired presence), never from a client.
-- Moderation commands reach the target through a fast short poll of GET /live/commands (same pattern as the banner system's /commands poll; the heartbeat response is only a fallback); this client validates every one and acknowledges it immediately.
-- Everything here is client convenience: hiding UI is not the security boundary, the Worker is.
local okLPL, errLPL = pcall(function()
local Player = Players.LocalPlayer
local TeleportService = cloneref(game:GetService("TeleportService"))
local MarketplaceService = cloneref(game:GetService("MarketplaceService"))
local LIVE_BACKEND = "https://live-player-log-system.elliptmal.workers.dev" -- the standalone Live Player Log Worker (/live/*). nil would use the old banner Worker, which has no /live routes.
local HB_BASE, HB_JITTER = 100, 10 -- presence heartbeat (seconds), jittered. Not changed: the same heartbeat also carries commands + acknowledgements.
local CMD_POLL = 2 -- seconds between command pulls on the target (same cadence as the banner system's /commands poll; backs off to 12s on errors; the Worker expires an unanswered command after 45s)
local STALE_AFTER = 150 -- seconds without a heartbeat before an entry is shown as STALE (the Worker removes it at 240s)
local PAGE_SIZE = 40 -- roster cards drawn at once (search narrows the whole global list; "Show more" draws the next page)
local FILE = "UhhhhhhReanim/LivePlayerLog.json"
local GREEN, YELLOW, RED, GRAY = "#6EE7A0", "#FFE066", "#FF8080", "#AAAAAA"
local FINAL = {EXECUTED = true, REJECTED = true, EXPIRED = true, TARGET_OFFLINE = true, ACTION_UNSUPPORTED = true, FAILED = true}
local ACTS = {"kick", "kill", "deanimate", "dizzy", "hallucinate", "silenthell", "domain", "cooked", "dropbomb", "ban"}
-- backend lifecycle -> what the log shows: PENDING (accepted / handed over, not finished), SUCCESS (backend confirmed execution), TIMEOUT (no answer in time), FAILED (anything else)
local function shown(st)
	if st == "PENDING" or st == "DELIVERED" then return "PENDING" end
	if st == "EXECUTED" then return "SUCCESS" end
	if st == "EXPIRED" then return "TIMEOUT" end
	return "FAILED"
end
local LPL = {}
local Fallback = {}
local SID = (HttpService:GenerateGUID(false):gsub("-", "")):lower() -- one id per script run (several simultaneous runs of one account are counted once)
local function SD() if type(SaveData) == "table" then return SaveData end return Fallback end
local function notify(t) pcall(Util.Notify or Util.UINotify, t) end
local function esc(s) return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local function commas(n)
	local s, r = tostring(math.floor(tonumber(n) or 0))
	repeat s, r = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until r == 0
	return s
end
local function fmtAge(a)
	a = math.max(0, math.floor(a))
	if a < 5 then return "just now" elseif a < 60 then return a .. "s ago" end
	return math.floor(a / 60) .. "m ago"
end
local function backend() return (tostring(LIVE_BACKEND or (Util.Guard and Util.Guard.BACKEND) or "https://banner-system.elliptmal.workers.dev"):gsub("/+$", "")) end
local function guardOk() local G = Util.Guard; return G == nil or G.State == "ok" end -- security handshake must have succeeded (fail closed otherwise)
local function newId() return (HttpService:GenerateGUID(false):gsub("-", "")):lower() end

local Auth = {Token = nil, Msg = nil, Busy = false, Views = {}, Loaded = false, SignedOut = false, Fails = 0}
local Pub = {Gen = 0, Running = false, Status = "off", LastOk = nil, LastFP = nil, InFlight = false, Note = nil, Hook = nil, Acks = {}, Flushing = false, Banned = false}
local Cmd = {Seen = {}, Order = {}}
local V = {Gen = 0, IsOpen = false, Looping = false, Busy = false, CmdBusy = false, Cursor = nil, Entries = {}, Cards = {}, Interval = 45, Fails = 0, NextAt = 0, Halt = nil, ErrText = nil, ErrShown = false, LastOk = nil, ClosedAt = 0,
	Count = 0, Sessions = 0, Cap = 0, Sat = false, Role = nil, Acts = {}, ActSig = "", Cmds = {}, Filter = "", Shown = PAGE_SIZE}

-- one request: returns ok, httpStatus, decodedBody, errText. Never throws; gives up after 15s.
local function call(method, path, body, withAuth)
	local rq = request or http_request or (syn and syn.request)
	if type(rq) ~= "function" then return false, 0, nil, "this executor has no request()" end
	local headers = {["Content-Type"] = "application/json"}
	if withAuth then
		if not Auth.Token then return false, 401, nil, "not signed in" end
		headers["Authorization"] = "Bearer " .. Auth.Token
	end
	local payload
	if body ~= nil then
		local okE, enc = pcall(HttpService.JSONEncode, HttpService, body)
		if not okE then return false, 0, nil, "encode failed" end
		payload = enc
	end
	local done, res
	task.spawn(function()
		local ok, r = pcall(rq, {Url = backend() .. path, Method = method, Headers = headers, Body = payload})
		res = ok and r or false
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < 15 do task.wait(0.1) end
	if type(res) ~= "table" then return false, 0, nil, "no response" end
	local code = tonumber(res.StatusCode) or 0
	local data
	if type(res.Body) == "string" and res.Body ~= "" then
		local okJ, d = pcall(HttpService.JSONDecode, HttpService, res.Body)
		if okJ and type(d) == "table" then data = d end
	end
	return true, code, data
end
local function isBanned(ok, code, d) return ok and code == 403 and type(d) == "table" and d.err == "banned" end

local function describe(ok, code, d, err)
	if not ok then return "Cannot reach the backend (" .. tostring(err or "no response") .. ")." end
	local e = type(d) == "table" and d.err or nil
	if e == "banned" then return "This account is banned from UH script services." end
	if e == "full" then return "The global registry is at capacity right now." end
	if e == "account_invalid" then return "Roblox could not resolve this account." end
	if e == "roblox_unavailable" then return "The backend could not reach Roblox. Try again shortly." end
	if e == "roles_unavailable" then return "The role list is temporarily unavailable, so nothing is shown." end
	if code == 404 then return "The Live Player Log backend is not deployed yet." end
	if code == 429 then return "Too many requests. Wait a moment." end
	if code >= 500 then return "The backend is unavailable (HTTP " .. tostring(code) .. ")." end
	return "Unexpected backend response (HTTP " .. tostring(code) .. (e and (": " .. tostring(e)) or "") .. ")."
end

-- ---------- sign-in (automatic: no code, no profile edit, no button) ----------
-- The client only states its own UserId. The Worker resolves the real username from Roblox, binds it to the session token it issues and decides the
-- role itself from roles.json / whitelist.json on every request. Nothing a client sends about roles is ever used.
function Auth.Load()
	if Auth.Token then return true end
	if Auth.Loaded then return false end
	Auth.Loaded = true
	local okF, raw = pcall(function() return type(isfile) == "function" and isfile(FILE) and readfile(FILE) end)
	if not okF or type(raw) ~= "string" then return false end
	local okJ, d = pcall(HttpService.JSONDecode, HttpService, raw)
	if okJ and type(d) == "table" and tonumber(d.uid) == Player.UserId and type(d.token) == "string" and #d.token >= 32 and #d.token <= 128 then
		Auth.Token = d.token
		return true
	end
	return false
end
local function saveToken(tok)
	local okE, enc = pcall(HttpService.JSONEncode, HttpService, tok and {uid = Player.UserId, token = tok} or {})
	if not okE then return end
	local FS = Util.FS
	if FS and FS.Write then pcall(FS.Write, FILE, enc) elseif type(writefile) == "function" then pcall(writefile, FILE, enc) end
end
function Auth.Notify() for _, f in ipairs(Auth.Views) do pcall(f) end end
function Auth.Forget()
	Auth.Token = nil
	Auth.Loaded = true
	saveToken(nil)
	Auth.Notify()
	Auth.Login() -- an expired / revoked session is replaced automatically (does nothing after the user left the registry)
end
function Auth.Login()
	if Auth.Busy or Auth.Token or Auth.SignedOut then return end
	if not guardOk() then -- authentication is the source of truth: no sign-in (so no registration) until the script's handshake succeeded
		if not Auth.Waiting then Auth.Waiting = true; task.delay(30, function() Auth.Waiting = false; Auth.Login() end) end
		return
	end
	Auth.Busy, Auth.Msg = true, nil
	Auth.Notify()
	task.spawn(function()
		local ok, code, d, err = call("POST", "/live/auth/login", {userId = Player.UserId}, false)
		Auth.Busy = false
		if ok and code == 200 and type(d) == "table" and d.ok == true and type(d.token) == "string" and #d.token >= 32 and #d.token <= 128 then
			Auth.Token, Auth.Msg, Auth.Fails = d.token, nil, 0
			saveToken(d.token)
			Auth.Notify()
			LPL.OnSignedIn()
			return
		end
		if isBanned(ok, code, d) then LPL.OnBanned() end
		Auth.Msg = describe(ok, code, d, err)
		Auth.Notify()
		if not ok or code == 429 or code >= 500 then -- transient failure: try again quietly with backoff
			Auth.Fails += 1
			task.delay(math.min(600, 30 * 2 ^ math.min(Auth.Fails, 4)), Auth.Login)
		end
	end)
end
function Auth.Logout()
	if Auth.Busy or not Auth.Token then return end
	Auth.Busy = true
	task.spawn(function()
		Pub.Stop(true)
		local t0 = os.clock()
		while (Pub.InFlight or Pub.Leaving) and os.clock() - t0 < 20 do task.wait(0.1) end
		pcall(call, "POST", "/live/auth/logout", {}, true)
		Auth.Busy = false
		Auth.SignedOut = true -- stays out until the script starts again or the user rejoins (set before Forget so nothing signs in again)
		Auth.Forget()
		V.Wipe()
		notify("Live Player Log: you left the registry for this session.")
	end)
end
-- sign-in status + the leave / rejoin control; `want()` decides when the section is shown
function Auth.Attach(page, want)
	local info = UI.CreateText(page, "", 11, Enum.TextXAlignment.Left)
	local joinBtn = UI.CreateButton(page, "Rejoin the registry", 18)
	local outBtn = UI.CreateButton(page, "Leave the registry for this session", 18)
	local function show(x, on) local c = x.Parent; if c then c.Visible = on end end
	local function refresh()
		local tok = Auth.Token
		local on = want() == true
		local text
		if tok then text = '<font color="' .. GREEN .. '">Signed in automatically as ' .. esc(Player.Name) .. ". Nothing to verify: your role comes from the official role lists.</font>"
		elseif Auth.SignedOut then text = "You left the registry for this session. You are not listed and nothing is sent. The script signs in again automatically the next time it starts."
		elseif Auth.Busy then text = "Signing in with this Roblox account..."
		else text = "Signing in automatically with this Roblox account. Nothing to verify or paste." end
		if Auth.Msg then text = text .. '\n<font color="' .. YELLOW .. '">' .. esc(Auth.Msg) .. "</font>" end
		if info.Text ~= text then info.Text = text end
		show(info, on)
		show(joinBtn, on and not tok and Auth.SignedOut)
		show(outBtn, on and tok ~= nil)
	end
	joinBtn.Activated:Connect(function() Auth.SignedOut = false; Auth.Login() end)
	outBtn.Activated:Connect(Auth.Logout)
	Auth.Views[#Auth.Views + 1] = refresh
	refresh()
	return refresh
end

-- ---------- presence publisher (every signed-in session registers itself automatically) ----------
local placeNames = {}
local function placeName()
	local pid = game.PlaceId
	if placeNames[pid] == nil then
		local ok, info = pcall(function() return MarketplaceService:GetProductInfo(pid) end)
		placeNames[pid] = (ok and type(info) == "table" and type(info.Name) == "string" and info.Name ~= "") and info.Name or tostring(game.Name or "")
	end
	return placeNames[pid]
end
local function setPubStatus(s) Pub.Status = s; if Pub.Hook then pcall(Pub.Hook) end end
-- actions this client can really execute (advertised to the Worker, which refuses anything else as ACTION_UNSUPPORTED)
local function caps()
	local t = {"kick"}
	if type(Util.ModActions) == "table" and type(Util.ModActions.Kill) == "function" then t[#t + 1] = "kill" end
	if type(Util.ModDeanimate) == "function" then t[#t + 1] = "deanimate" end
	local F = Util.ModFx
	if type(F) == "table" and type(F.Run) == "function" then t[#t + 1] = "dizzy"; t[#t + 1] = "hallucinate"; t[#t + 1] = "silenthell" end
	if type(F) == "table" and type(F.Run) == "function" and type(F.Handles) == "function" then
		for _, x in ipairs({"domain", "cooked", "dropbomb"}) do
			local okh, h = pcall(F.Handles, x)
			if okh and h == true then t[#t + 1] = x end
		end
	end
	t[#t + 1] = "ban" -- applied by the backend; this client exits when the backend reports the ban
	return t
end
local function beat(gen)
	if Pub.Departed then return "stop" end -- this session is leaving the experience: it never registers or refreshes itself again
	local pub = game.PrivateServerId == "" and game.JobId ~= ""
	local snap = {pid = game.PlaceId, g = placeName():sub(1, 64), j = pub and game.JobId or "", pub = pub, sid = SID, dn = tostring(Player.DisplayName or ""):sub(1, 32), cap = caps(), gi = game.GameId}
	local fp = snap.pid .. "|" .. snap.g .. "|" .. snap.j .. "|" .. snap.dn
	local body = (fp == Pub.LastFP) and {t = "hb", sid = SID} or snap
	local sent = math.min(5, #Pub.Acks)
	if sent > 0 then
		body.ack = {}
		for i = 1, sent do body.ack[i] = Pub.Acks[i] end
	end
	Pub.InFlight = true
	local ok, code, d, err = call("POST", "/live/presence", body, true)
	Pub.InFlight = false
	if Pub.Gen ~= gen then return "stop" end
	if isBanned(ok, code, d) then LPL.OnBanned() return "stop" end
	if ok and code == 200 and type(d) == "table" and d.ok == true then
		Pub.LastFP, Pub.LastOk = fp, os.clock()
		for _ = 1, sent do table.remove(Pub.Acks, 1) end -- delivered acknowledgements leave the queue
		setPubStatus("on")
		if type(d.cmd) == "table" then pcall(Cmd.Receive, d.cmd) end
		return "ok"
	end
	if ok and code == 409 then Pub.LastFP = nil return "resync" end
	if ok and code == 401 then Auth.Forget(); setPubStatus("expired") return "stop" end
	if ok and code == 429 then return "slow" end
	return "fail", describe(ok, code, d, err)
end
-- target side: banner-style short poll for commands addressed to this account + script session (no waiting for the ~100s heartbeat); acknowledgements leave at once via Pub.Flush
function Cmd.StartPoll(gen)
	task.spawn(function()
		local fails = 0
		while Pub.Gen == gen and Auth.Token and not Pub.Departed and not Pub.Banned do
			local wait_ = CMD_POLL + math.random() * 0.5
			if Pub.LastOk and guardOk() then -- only once this session is registered
				local ok, code, d = call("GET", "/live/commands?sid=" .. SID, nil, true)
				if Pub.Gen ~= gen then return end
				if isBanned(ok, code, d) then LPL.OnBanned() return end
				if ok and code == 200 and type(d) == "table" and d.ok == true then
					fails = 0
					if type(d.cmd) == "table" then pcall(Cmd.Receive, d.cmd) end
				elseif ok and code == 401 then return -- the presence loop signs in again and restarts this poll
				elseif ok and (code == 409 or code == 410) then wait_ = 10 -- session not registered / already left
				elseif ok and code == 404 then wait_ = 60 -- Worker without /live/commands: the heartbeat still carries commands
				else fails += 1; wait_ = math.min(CMD_POLL + fails * 2, 12) end
			end
			task.wait(wait_)
		end
	end)
end
function Pub.Start()
	if Pub.Running or Pub.Banned or Pub.Departed or not Auth.Token then return end
	if Pub.Left ~= nil then SID, Pub.Left = newId(), nil end -- the previous session id already left the registry: a (re)join is a brand-new session
	Pub.Running = true
	Pub.Gen += 1
	local gen = Pub.Gen
	Cmd.StartPoll(gen)
	setPubStatus("starting")
	task.spawn(function()
		local fails = 0
		while Pub.Gen == gen and Auth.Token do
			local wait_
			if not guardOk() then
				setPubStatus("paused")
				wait_ = 30
			else
				local r, msg = beat(gen)
				if r == "resync" then r, msg = beat(gen) end
				if r == "stop" then break end
				if r == "ok" then fails = 0; wait_ = HB_BASE + math.random(-HB_JITTER, HB_JITTER)
				elseif r == "slow" then wait_ = HB_BASE
				else
					fails += 1
					wait_ = math.min(120, 20 * 2 ^ (math.min(fails, 4) - 1)) + math.random(0, 10) -- 20s, 40s, 80s, then about every 2 min (the Worker expires a silent session after 240s)
					Pub.ErrText = msg
					setPubStatus("error")
				end
			end
			task.wait(wait_)
		end
		if Pub.Gen == gen then Pub.Running = false end
	end)
end
-- stop sending immediately; when `remove`, also delete this session's entry (after any request already in flight has finished).
-- `leaving` = the local player is leaving the experience: no waiting for a request in flight (the Worker refuses a late request of a session that already left) and a quick retry
function Pub.Stop(remove, leaving)
	Pub.Gen += 1
	Pub.Running, Pub.LastFP = false, nil
	if not remove or not Auth.Token or Pub.Leaving or Pub.Left == true then setPubStatus("off") return end
	Pub.Leaving = true
	task.spawn(function()
		if not leaving then
			local t0 = os.clock()
			while Pub.InFlight and os.clock() - t0 < 16 do task.wait(0.1) end
		end
		local removed = false
		for attempt = 1, 2 do
			local ok, code = call("POST", "/live/presence/leave", {sid = SID}, true)
			if ok and (code == 200 or code == 401 or code == 404) then removed = true break end
			if attempt == 1 then task.wait(leaving and 0.5 or 3) end
		end
		Pub.Left = removed -- true: the Worker confirmed this session id is gone (never sent twice); false: the entry expires on its own
		Pub.Leaving = false
		Pub.Note = removed and "Your entry was removed." or "The backend could not be reached; your entry expires on its own within 4 minutes."
		setPubStatus("off")
	end)
end
-- departure of THIS client (left the game / teleporting away): one idempotent handler. Heartbeats stop, this session can never register again and ONLY this session id
-- is removed from the registry (other sessions of the account and the login stay untouched). A forced close, crash or dead network cannot send a final request:
-- the 4 minute presence expiry on the Worker stays the fallback.
function Pub.Depart(byTeleport)
	if Pub.Departed then return end
	Pub.Departed, Pub.ByTeleport = true, byTeleport == true
	Pub.Stop(true, true)
end
-- send queued acknowledgements right now (one extra request, only after a moderation command); blocks until it is sent
function Pub.FlushNow()
	local t0 = os.clock()
	while Pub.InFlight and os.clock() - t0 < 16 do task.wait(0.1) end
	if #Pub.Acks == 0 or not Auth.Token or Pub.Banned then return end
	local r = beat(Pub.Gen)
	if r == "resync" then beat(Pub.Gen) end
end
function Pub.Flush()
	if Pub.Flushing or not Auth.Token then return end
	Pub.Flushing = true
	task.spawn(function()
		for _ = 1, 3 do
			Pub.FlushNow()
			if #Pub.Acks == 0 then break end
			task.wait(2)
		end
		Pub.Flushing = false
	end)
end
-- the Worker says this account is banned from UH script/backend services: stop everything and leave (same behaviour as the existing device ban)
function LPL.OnBanned()
	if Pub.Banned then return end
	Pub.Banned = true
	Pub.Gen += 1
	Pub.Running = false
	setPubStatus("banned")
	notify("Live Player Log: this account is banned from UH script services.")
	task.delay(1.5, function() pcall(function() Player:Kick("BANNED from UH script services by the owner/co-owner.") end) end)
end
function LPL.OnSignedIn()
	Pub.Start()
	if not LPL.Told then LPL.Told = true; notify("Live Player Log: this script session is registered in the global active-user registry (Feature Center > ACTIVE USER REGISTRY).") end
	if V.IsOpen then V.Halt = nil; V.NextAt = 0; V.Kick() end
end

-- ---------- moderation commands (target side) ----------
-- Every command is validated here even though the Worker already authorised it: addressed to this account AND this script session, not expired,
-- not seen before, well-formed, known action only, and the sender's role must be allowed to use it. No code or free-form instruction is ever run.
local RANKS = {verified = 1, ["co-owner"] = 2, owner = 3}
local function myRank()
	local ok, r = pcall(function()
		local R = Util.Roles
		local role = R.Of(Player)
		if role == "owner" then return 3 elseif role == "co-owner" then return 2 end
		if R.VById[Player.UserId] or R.VByName[tostring(Player.Name):lower()] then return 1 end
		return 0
	end)
	return (ok and tonumber(r)) or 0
end
function Cmd.Receive(list)
	for i, c in ipairs(list) do
		if i > 5 then break end
		pcall(Cmd.Handle, c)
	end
end
function Cmd.Handle(c)
	if type(c) ~= "table" then return end
	local id = c.id
	if type(id) ~= "string" or #id ~= 32 or not id:match("^%x+$") then return end -- malformed: nothing to acknowledge
	local prev = Cmd.Seen[id]
	if prev ~= nil then -- duplicate delivery: never executed twice; a finished one is simply acknowledged again
		if prev ~= true then Pub.Acks[#Pub.Acks + 1] = {id = id, st = prev.st, n = prev.n}; Pub.Flush() end
		return
	end
	Cmd.Seen[id] = true
	Cmd.Order[#Cmd.Order + 1] = id
	if #Cmd.Order > 64 then Cmd.Seen[table.remove(Cmd.Order, 1)] = nil end
	local function finish(st, note)
		Cmd.Seen[id] = {st = st, n = note}
		Pub.Acks[#Pub.Acks + 1] = {id = id, st = st, n = note}
	end
	local function bad(st, note) finish(st, note); Pub.Flush() end
	local a = type(c.a) == "string" and c.a or ""
	local who = type(c.mn) == "string" and c.mn:sub(1, 20) or "a moderator"
	local rank, mu = RANKS[c.mr], tonumber(c.mu)
	if tonumber(c.tu) ~= Player.UserId or c.ts ~= SID then return bad("REJECTED", "wrong target") end
	local ttl, iat, exp = tonumber(c.ttl), tonumber(c.iat), tonumber(c.exp)
	if not (ttl and ttl > 0 and iat and exp and exp > iat) then return bad("REJECTED", "expired or malformed") end
	if not rank or not mu or mu < 1 or mu == Player.UserId then return bad("REJECTED", "unauthorized sender") end
	if not (a == "kick" or a == "kill" or a == "deanimate" or a == "dizzy" or a == "hallucinate" or a == "silenthell" or a == "domain" or a == "cooked" or a == "dropbomb") then return bad("ACTION_UNSUPPORTED", "unknown action") end
	if rank <= myRank() then return bad("REJECTED", "target outranks sender") end
	local have = {}
	for _, x in ipairs(caps()) do have[x] = true end
	if not have[a] then return bad("ACTION_UNSUPPORTED", "not available in this client") end
	local dur = tonumber(c.d)
	task.spawn(function()
		local A, F = Util.ModActions, Util.ModFx
		if a == "kick" then
			notify("Kicked by moderator " .. who .. " (script misuse)")
			finish("EXECUTED", "kick issued")
			Pub.FlushNow() -- the acknowledgement has to leave BEFORE the connection is closed
			pcall(function() Player:Kick("Kicked by moderator " .. who .. " (script misuse)") end)
			return
		elseif a == "kill" then
			notify(who .. " used Kill on you (script misuse)")
			local ok = pcall(A.Kill)
			if ok then finish("EXECUTED", "client-local reset") else finish("FAILED", "kill errored") end
		elseif a == "deanimate" then
			notify(who .. " used Deanimate on you (script misuse)")
			local ok, r = pcall(Util.ModDeanimate)
			if ok then finish("EXECUTED", r == false and "was not reanimating" or "reanimation stopped") else finish("FAILED", "deanimate errored") end
		else
			local ok, r, why = pcall(F.Run, a, who, dur)
			if ok and r then finish("EXECUTED", "temporary effect") elseif ok then finish("REJECTED", tostring(why or "refused")) else finish("FAILED", "effect errored") end
		end
		Pub.Flush()
	end)
end

-- ---------- viewer ----------
function LPL.CanView(refresh) return Util.Roles.CanUseLivePlayerLog(Player, refresh) == true end
-- local role state: read straight from the banner system's username / role lists (Roles.Of + verified lists + BannerRole). No verification step; regular users get nil.
-- Display state only: the Worker still authorises every roster / presence / moderation request itself.
function LPL.LocalRole(refresh)
	local R = Util.Roles
	if refresh then pcall(R.Fetch) end
	local ok, role = pcall(R.Of, Player)
	if ok and (role == "owner" or role == "co-owner") then return role end
	if R.CanUseLivePlayerLog(Player) then return "verified" end
	return nil
end
function V.Wipe()
	V.SrvT = nil
	V.Entries, V.Cursor, V.Count, V.Sessions, V.Sat, V.LastOk, V.Acts, V.ActSig, V.Role, V.Cmds = {}, nil, 0, 0, false, nil, {}, "", nil, {}
	V.Role = LPL.LocalRole()
	for id, c in pairs(V.Cards) do pcall(function() c.frame:Destroy() end); V.Cards[id] = nil end
end
local function newLabel(parent, size, order)
	local l = Util.Instance("TextLabel", parent)
	l.BackgroundTransparency = 1
	l.RichText = true
	l.Font = Enum.Font.Code
	l.TextSize = size
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.TextWrapped = true
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.LayoutOrder = order
	return l
end
local function newButton(parent, text, order, color)
	local b = Util.Instance("TextButton", parent)
	b.AutoButtonColor = true
	b.BackgroundColor3 = color or Color3.fromRGB(52, 56, 74)
	b.BorderSizePixel = 0
	b.Size = UDim2.new(1 / 3, -3, 1, 0)
	b.Font = Enum.Font.Code
	b.TextSize = 12
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Text = text
	b.LayoutOrder = order
	Util.Instance("UICorner", b).CornerRadius = UDim.new(0, 5)
	return b
end
local function newRow(parent, order)
	local r = Util.Instance("Frame", parent)
	r.BackgroundTransparency = 1
	r.Size = UDim2.new(1, 0, 0, 30)
	r.LayoutOrder = order
	local rl = Util.Instance("UIListLayout", r)
	rl.FillDirection = Enum.FillDirection.Horizontal
	rl.Padding = UDim.new(0, 4)
	rl.SortOrder = Enum.SortOrder.LayoutOrder
	return r
end
local function copyText(txt, what)
	if type(setclipboard) == "function" then pcall(setclipboard, txt); notify((what or "Copied") .. ".") else notify((txt:gsub("\n", "  "))) end
end
local function gameUrl(e)
	if e.p <= 0 then return nil end
	if e.j ~= "" then return "https://www.roblox.com/games/start?placeId=" .. e.p .. "&gameInstanceId=" .. e.j end
	return "https://www.roblox.com/games/" .. e.p
end
local joinedAt = 0
local function joinEntry(e)
	if e.p <= 0 then return end
	local link = gameUrl(e)
	if e.p ~= game.PlaceId or e.j == "" then copyText(link, "Game link copied, paste it in a browser to join " .. e.n) return end -- other game / private server: the link is the way in
	if e.j == game.JobId then notify("You are already in that server.") return end
	if os.clock() - joinedAt < 20 then notify("A join is already in progress.") return end
	joinedAt = os.clock()
	local TA = Util.TeleportAutoExec
	if TA and TA.Arm then pcall(TA.Arm) end
	local conn
	local function undo(msg)
		joinedAt = 0
		if conn then pcall(function() conn:Disconnect() end); conn = nil end
		if TA and TA.Abort then pcall(TA.Abort) end
		if msg then notify(msg) end
	end
	local okC, c = pcall(function()
		return TeleportService.TeleportInitFailed:Connect(function(plr, result, msg)
			if plr == Player then undo(("Could not join [%s]: %s"):format(tostring(result), tostring(msg))); copyText(link, "Game link copied instead") end
		end)
	end)
	if okC then conn = c end
	task.delay(25, function() if conn then pcall(function() conn:Disconnect() end); conn = nil end end)
	local ok, err = pcall(function() TeleportService:TeleportToPlaceInstance(e.p, e.j, Player) end)
	if not ok then undo(nil); copyText(link, "Could not teleport (" .. tostring(err) .. "), game link copied") end
end
local function copyIds(e)
	copyText("UserId: " .. e.id .. "\nPlaceId: " .. e.p .. (e.j ~= "" and ("\nJobId: " .. e.j) or ""), "Copied")
end
local function profileUrl(e) return "https://www.roblox.com/users/" .. e.id .. "/profile" end

-- one moderation command from this moderator (the Worker authorises it again from the signed-in session; nothing here is trusted)
function V.SendCommand(e, act)
	if V.CmdBusy or not Auth.Token then return end
	V.CmdBusy = true
	task.spawn(function()
		local ok, code, d, err = call("POST", "/live/mod/command", {tu = e.id, a = act}, true)
		V.CmdBusy = false
		local label = act:upper() .. " on " .. e.n
		if ok and code == 200 and type(d) == "table" and d.ok == true and type(d.id) == "string" then
			local st = tostring(d.st)
			V.Cmds[d.id] = {st = st, a = act, tn = e.n, note = tostring(d.note or ""), t = os.clock(), noted = FINAL[st] == true}
			notify(label .. ": " .. shown(st) .. (V.Cmds[d.id].note ~= "" and (" (" .. V.Cmds[d.id].note .. ")") or ""))
			V.Interval, V.NextAt = 20, os.clock() + 20
			if not FINAL[st] then V.Watch() end
		elseif isBanned(ok, code, d) then LPL.OnBanned()
		elseif ok and code == 401 then Auth.Forget(); V.Halt = "auth"
		elseif ok and type(d) == "table" and (d.err == "target_offline" or d.st == "TARGET_OFFLINE") then
			-- the Worker has no valid live session for this account (it left, or its session is still being re-established): not executed, nothing was delivered, nobody else is targeted
			if type(d.id) == "string" then V.Cmds[d.id] = {st = "TARGET_OFFLINE", a = act, tn = e.n, note = "target not connected", t = os.clock(), noted = true} end
			notify(label .. ": " .. e.n .. " is no longer connected (it left the game, or its session is being re-established). Nothing was sent. Refreshing the list.")
			V.Entries[e.id] = nil -- never keep an actionable card for an account without a valid session; a fresh snapshot brings it back only if the Worker lists it
			local oc = V.Cards[e.id]
			if oc then pcall(function() oc.frame:Destroy() end); V.Cards[e.id] = nil end
			local t0 = os.clock()
			while V.Busy and os.clock() - t0 < 10 do task.wait(0.1) end
			V.Cursor, V.Halt, V.NextAt = nil, nil, 0 -- the old cursor cannot be trusted: full snapshot now (the poll loop retries if one is still running)
			V.Poll()
		elseif ok and type(d) == "table" then
			if type(d.id) == "string" and type(d.st) == "string" and V.Cmds[d.id] == nil then -- rejected / failed by the backend (or an already open duplicate): show its real status
				V.Cmds[d.id] = {st = d.st, a = act, tn = e.n, note = tostring(d.note or ""), t = os.clock(), noted = FINAL[d.st] == true}
				if not FINAL[d.st] then V.Watch() end
			end
			if d.msg then notify(label .. ": " .. tostring(d.msg))
			elseif d.st then notify(label .. ": " .. shown(tostring(d.st)))
			else notify(label .. ": FAILED (" .. tostring(d.err or ("HTTP " .. code)) .. ")") end
		elseif not ok then -- the backend did not answer within the request timeout
			V.Cmds["local" .. newId()] = {st = "EXPIRED", a = act, tn = e.n, note = "backend did not respond", t = os.clock(), noted = true}
			notify(label .. ": TIMEOUT (" .. describe(ok, code, d, err) .. ")")
		else
			notify(label .. ": FAILED (" .. describe(ok, code, d, err) .. ")")
		end
		V.Render()
	end)
end
-- while one of my commands is still open: ask the backend for its status every 3s (instead of the slow roster loop); anything still unanswered after ~50s shows TIMEOUT
function V.Watch()
	if V.Watching then return end
	V.Watching = true
	task.spawn(function()
		local t0 = os.clock()
		while V.IsOpen and V.OpenCmds() and os.clock() - t0 < 55 do
			task.wait(3)
			if not V.IsOpen then break end
			V.Poll(); V.Render()
		end
		for _, x in pairs(V.Cmds) do
			if not FINAL[x.st] and os.clock() - x.t >= 50 then x.st, x.note, x.noted = "EXPIRED", "no response in time", true end
		end
		V.Watching = false
		if V.IsOpen then V.Render() end
	end)
end

local SHORT = {kick = "KICK", kill = "KILL", deanimate = "DEAN", dizzy = "DIZZ", hallucinate = "HALL", silenthell = "HELL", ban = "BAN"}
local function modButton(c, parent, act, order)
	local b = newButton(parent, SHORT[act] or act:upper(), order, act == "ban" and Color3.fromRGB(122, 40, 44) or nil)
	b.Size, b.TextSize = UDim2.new(0, 40, 1, 0), 10
	local armed = 0
	b.Activated:Connect(function()
		local e = c.e
		if not e then return end
		if act == "ban" then -- two taps: BAN removes the account from every UH backend service
			if os.clock() - armed > 4 then
				armed = os.clock()
				b.Text = "SURE?"
				task.delay(4, function() if b.Parent and b.Text == "SURE?" then b.Text = "BAN" end end)
				return
			end
			armed = 0
			b.Text = "BAN"
		end
		V.SendCommand(e, act)
	end)
	return b
end
local function headLabel(parent, size, y)
	local l = Util.Instance("TextLabel", parent)
	l.BackgroundTransparency = 1
	l.RichText = true
	l.Font = Enum.Font.Code
	l.TextSize = size
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.TextWrapped = false
	l.Position = UDim2.new(0, 48, 0, y)
	l.Size = UDim2.new(1, -48, 0, 20)
	return l
end
local function makeCard(list)
	local c = {open = false}
	local f = Util.Instance("Frame", list)
	f.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	f.BackgroundTransparency = 0.12
	f.BorderSizePixel = 0
	f.Size = UDim2.new(1, -10, 0, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	Util.Instance("UICorner", f).CornerRadius = UDim.new(0, 6)
	local pad = Util.Instance("UIPadding", f)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 8), UDim.new(0, 8)
	local lay = Util.Instance("UIListLayout", f)
	lay.Padding = UDim.new(0, 5)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	c.frame = f
	local head = Util.Instance("TextButton", f) -- tap the header to open / close the profile + actions
	head.BackgroundTransparency = 1
	head.AutoButtonColor = false
	head.Text = ""
	head.Size = UDim2.new(1, 0, 0, 42)
	head.LayoutOrder = 1
	local av = Util.Instance("ImageLabel", head)
	av.BackgroundColor3 = Color3.fromRGB(34, 36, 46)
	av.BorderSizePixel = 0
	av.Size = UDim2.new(0, 40, 0, 40)
	Util.Instance("UICorner", av).CornerRadius = UDim.new(0, 6)
	c.avatar = av
	c.title = headLabel(head, 14, 0)
	c.sub = headLabel(head, 11, 21)
	c.strip = Util.Instance("Frame", head) -- mod actions, right next to the display name
	c.strip.BackgroundTransparency = 1
	c.strip.AnchorPoint = Vector2.new(1, 0)
	c.strip.Position = UDim2.new(1, 0, 0, 1)
	c.strip.Size = UDim2.new(0, 0, 0, 18)
	local sl = Util.Instance("UIListLayout", c.strip)
	sl.FillDirection = Enum.FillDirection.Horizontal
	sl.HorizontalAlignment = Enum.HorizontalAlignment.Right
	sl.Padding = UDim.new(0, 3)
	sl.SortOrder = Enum.SortOrder.LayoutOrder
	c.acts = {}
	for i, a in ipairs(ACTS) do c.acts[a] = modButton(c, c.strip, a, i) end
	c.join = newButton(head, "JOIN", 0, Color3.fromRGB(40, 110, 70))
	c.join.AnchorPoint = Vector2.new(1, 0)
	c.join.Position = UDim2.new(1, 0, 0, 22)
	c.join.Size = UDim2.new(0, 56, 0, 18)
	c.join.TextSize = 11
	c.join.Activated:Connect(function() if c.e then joinEntry(c.e) end end)
	local more = Util.Instance("Frame", f)
	more.BackgroundTransparency = 1
	more.Size = UDim2.new(1, 0, 0, 0)
	more.AutomaticSize = Enum.AutomaticSize.Y
	more.LayoutOrder = 2
	more.Visible = false
	local ml = Util.Instance("UIListLayout", more)
	ml.Padding = UDim.new(0, 5)
	ml.SortOrder = Enum.SortOrder.LayoutOrder
	c.more = more
	c.info = newLabel(more, 12, 1)
	c.rowA = newRow(more, 2)
	c.link = newButton(c.rowA, "COPY LINK", 1)
	c.copy = newButton(c.rowA, "COPY IDs", 2)
	c.prof = newButton(c.rowA, "PROFILE", 3)
	c.link.Activated:Connect(function() local l = c.e and gameUrl(c.e); if l then copyText(l, "Game link copied") end end)
	c.copy.Activated:Connect(function() if c.e then copyIds(c.e) end end)
	c.prof.Activated:Connect(function() if c.e then copyText(profileUrl(c.e), "Profile link copied") end end)
	head.Activated:Connect(function()
		c.open = not c.open
		more.Visible = c.open
		c.sig = nil
		V.Render()
	end)
	return c
end
local function paintCard(c, e, now)
	local age = now - e.seen
	local stale = age > STALE_AFTER
	local canJoin = e.j ~= "" and e.p > 0
	local me = e.id == Player.UserId
	local sig = table.concat({e.n, e.d, e.g, e.p, e.j, e.ns, stale and 1 or 0, math.floor(age / 10), c.open and 1 or 0, V.ActSig, me and 1 or 0}, "|")
	if c.sig == sig then return end
	c.sig = sig
	local img = "rbxthumb://type=AvatarHeadShot&id=" .. e.id .. "&w=48&h=48" -- resolved by the Roblox engine and cached by it: no request of ours
	if c.avatar.Image ~= img then c.avatar.Image = img end
	local status = stale and ('<font color="' .. YELLOW .. '">STALE</font>') or ('<font color="' .. GREEN .. '">ACTIVE</font>')
	local named = e.d ~= "" and e.d ~= e.n
	c.title.Text = "<b>" .. esc(named and e.d or e.n) .. "</b>" .. (named and (' <font color="' .. GRAY .. '">@' .. esc(e.n) .. "</font>") or "")
	c.sub.Text = status .. (e.ns > 1 and (" x" .. e.ns) or "") .. ' <font color="' .. GRAY .. '">' .. (e.g ~= "" and esc(e.g) or "unknown experience") .. " - " .. fmtAge(age) .. "</font>"
	local showJoin = e.p > 0 and not me
	c.join.Visible = showJoin
	local n = 0
	for _, a in ipairs(ACTS) do
		local on = V.Acts[a] == true and not me
		c.acts[a].Visible = on
		if on then n += 1 end
	end
	c.strip.Size = UDim2.new(0, math.max(0, n * 43 - 3), 0, 18)
	c.title.Size = UDim2.new(1, -(48 + (n > 0 and (n * 43 + 1) or 0)), 0, 20)
	c.sub.Size = UDim2.new(1, -(48 + (showJoin and 60 or 0)), 0, 20)
	if not c.open then return end
	c.info.Text = '<font color="' .. GRAY .. '">Username</font> ' .. esc(e.n)
		.. '\n<font color="' .. GRAY .. '">Display</font> ' .. esc(e.d ~= "" and e.d or e.n)
		.. '\n<font color="' .. GRAY .. '">UserId</font> ' .. e.id
		.. '\n<font color="' .. GRAY .. '">Profile</font> roblox.com/users/' .. e.id .. "/profile"
		.. '\n<font color="' .. GRAY .. '">Game</font> ' .. (e.g ~= "" and esc(e.g) or "unknown experience")
		.. '\n<font color="' .. GRAY .. '">PlaceId</font> ' .. e.p
		.. '\n<font color="' .. GRAY .. '">Server</font> ' .. (canJoin and (esc(e.j:sub(1, 8)) .. "...") or "not shared / private")
		.. '\n<font color="' .. GRAY .. '">Sessions</font> ' .. e.ns .. '\n<font color="' .. GRAY .. '">Last seen</font> ' .. fmtAge(age)
		.. '\n<font color="' .. GRAY .. '">Session start</font> ' .. fmtAge(now - e.st)
		.. (e.gi > 0 and ('\n<font color="' .. GRAY .. '">Universe</font> ' .. e.gi) or "")
end
-- live: the newest request succeeded and is recent. stale: the last good data is kept but the newest refresh failed or is overdue. unavailable: nothing was ever retrieved.
local function dataState(now)
	if not V.LastOk then return V.ErrText and "unavailable" or "loading" end
	if V.ErrText or now - V.LastOk > V.Interval + 45 then return "stale" end
	return "live"
end
local function overviewText(now)
	local st = dataState(now)
	local reg
	if V.Halt then reg = '<font color="' .. GRAY .. '">PAUSED</font>'
	elseif st == "unavailable" then reg = '<font color="' .. RED .. '">UNAVAILABLE - no data yet (retrying)</font>'
	elseif st == "stale" then reg = '<font color="' .. YELLOW .. '">STALE - showing the last successful sync' .. (V.ErrText and " (retrying)" or "") .. "</font>"
	elseif V.Sat then reg = '<font color="' .. YELLOW .. '">SATURATED - capacity ' .. commas(V.Cap) .. " reached, the total is a lower bound</font>"
	elseif st == "live" then reg = '<font color="' .. GREEN .. '">LIVE</font>'
	else reg = "loading..." end
	if V.Refreshing then reg = reg .. " - refreshing..." end
	local known = (V.LastOk and st ~= "live") and (' <font color="' .. YELLOW .. '">(last known)</font>') or ""
	local cnt = V.LastOk and (commas(V.Count) .. (V.Sat and "+" or "")) or "-"
	local last = V.LastOk and (fmtAge(now - V.LastOk) .. (V.SrvT and (" (" .. os.date("!%H:%M:%S", math.floor(V.SrvT / 1000)) .. " UTC)") or "")) or "-"
	return "<b>GLOBAL SCRIPT USAGE</b>\nACTIVE SCRIPT USERS: <b>" .. cnt .. "</b>" .. known
		.. '\n<font color="' .. GRAY .. '">Active sessions: ' .. (V.LastOk and commas(V.Sessions) or "-")
		.. "\nLast registry update: " .. last
		.. "\nActive script users = unique accounts with a session refreshed in the last 4 minutes. Active sessions = individual script sessions. All servers and experiences.</font>\nRegistry: " .. reg
end
local function statusLine()
	if V.Halt == "auth" then return '<font color="' .. YELLOW .. '">Signing in automatically. The list loads as soon as the session is ready.</font>' end
	if V.Halt == "denied" then return '<font color="' .. RED .. '">The server did not authorize this account for the Live Player Log.</font>' end
	if V.Halt == "gate" then return '<font color="' .. RED .. '">Only verified players, co-owners and the owner can use the Live Player Log.</font>' end
	if V.ErrText then return '<font color="' .. RED .. '">' .. esc(V.ErrText) .. "</font>" end
	return ""
end
local function cmdLines()
	local arr = {}
	for id, x in pairs(V.Cmds) do arr[#arr + 1] = x end
	table.sort(arr, function(a, b) return a.t > b.t end)
	local out = {}
	for i = 1, math.min(5, #arr) do
		local x = arr[i]
		local col = x.st == "EXECUTED" and GREEN or ((x.st == "PENDING" or x.st == "DELIVERED") and YELLOW or RED)
		out[#out + 1] = "<b>" .. esc(x.a:upper()) .. "</b> " .. esc(x.tn) .. ': <font color="' .. col .. '">' .. esc(shown(x.st)) .. "</font>" .. (x.note ~= "" and (' <font color="' .. GRAY .. '">' .. esc(x.note) .. "</font>") or "")
	end
	return table.concat(out, "\n")
end
function V.Render()
	if not V.IsOpen or not V.list then return end
	local now = os.clock()
	local q = V.Filter
	local arr = {}
	for id, e in pairs(V.Entries) do
		if q == "" or e.n:lower():find(q, 1, true) or e.d:lower():find(q, 1, true) or e.g:lower():find(q, 1, true) or tostring(id):find(q, 1, true) then arr[#arr + 1] = e end
	end
	table.sort(arr, function(a, b) local x, y = a.n:lower(), b.n:lower(); if x ~= y then return x < y end return a.id < b.id end)
	local shown = {}
	for rank = 1, math.min(#arr, V.Shown) do
		local e = arr[rank]
		shown[e.id] = true
		local c = V.Cards[e.id]
		if not c then c = makeCard(V.list); V.Cards[e.id] = c end
		c.e = e
		if c.frame.LayoutOrder ~= rank then c.frame.LayoutOrder = rank end
		paintCard(c, e, now)
	end
	for id, c in pairs(V.Cards) do
		if not shown[id] then pcall(function() c.frame:Destroy() end); V.Cards[id] = nil end
	end
	local nTotal = 0
	for _ in pairs(V.Entries) do nTotal += 1 end
	if V.empty then V.empty.Parent.Visible = (#arr == 0 and V.Halt == nil and V.LastOk ~= nil) end
	if V.empty then
		local t = (nTotal > 0 and q ~= "") and '<font color="' .. GRAY .. '">No active script user matches your search.</font>' or '<font color="' .. GRAY .. '">No other script users are registered right now.</font>'
		if V.empty.Text ~= t then V.empty.Text = t end
	end
	if V.list.Parent then V.list.Parent.Visible = #arr > 0 end
	if V.moreBtn then
		V.moreBtn.Parent.Visible = #arr > V.Shown
		local t = "Show more (" .. (#arr - V.Shown) .. " left)"
		if V.moreBtn.Text ~= t then V.moreBtn.Text = t end
	end
	local ov = overviewText(now)
	if V.overview and V.overview.Text ~= ov then V.overview.Text = ov end
	local st = statusLine()
	if V.status and V.status.Text ~= st then V.status.Text = st end
	if V.cmdText then
		local t = cmdLines()
		if V.cmdText.Text ~= t then V.cmdText.Text = t end
		V.cmdText.Parent.Visible = t ~= ""
	end
	if V.unban then
		local on = V.Acts.ban == true
		V.unban.box.Parent.Parent.Visible = on
		V.unban.btn.Parent.Visible = on
	end
end
local function applyMeta(d)
	V.SrvT = tonumber(d.t) or V.SrvT -- the registry's own clock at the moment of the answer
	if tonumber(d.onlineCount) then V.Count = math.max(0, math.floor(d.onlineCount)) end -- unique accounts, counted by the Worker
	if tonumber(d.sessionCount) then V.Sessions = math.max(0, math.floor(d.sessionCount)) end
	if tonumber(d.cap) then V.Cap = math.floor(d.cap) end
	V.Sat = d.sat == 1
	V.Role = LPL.LocalRole() -- role state comes from the banner role lists, not from the Worker reply
	if type(d.acts) == "table" then
		V.Acts = {}
		local names = {}
		for _, a in ipairs(d.acts) do if type(a) == "string" then V.Acts[a] = true; names[#names + 1] = a end end
		table.sort(names)
		V.ActSig = table.concat(names, ",")
	end
	if type(d.mc) == "table" then
		for _, m in ipairs(d.mc) do
			if type(m) == "table" and type(m[1]) == "string" then
				local st = tostring(m[2])
				local x = V.Cmds[m[1]]
				local isNew = x == nil
				if isNew then x = {t = os.clock()}; V.Cmds[m[1]] = x end
				x.st, x.a, x.tn, x.note = st, tostring(m[3]), tostring(m[4]), tostring(m[5] or "")
				if isNew then x.noted = FINAL[st] == true
				elseif FINAL[st] and not x.noted then
					x.noted = true
					notify(x.a:upper() .. " on " .. x.tn .. ": " .. shown(st) .. (x.note ~= "" and (" (" .. x.note .. ")") or ""))
				end
			end
		end
	end
end
function V.OpenCmds()
	local now = os.clock()
	for _, x in pairs(V.Cmds) do if not FINAL[x.st] and now - x.t < 330 then return true end end
	return false
end
-- returns changed (visible content), needFull (a heartbeat for an entry we never received)
function V.Apply(d)
	local now = os.clock()
	local changed, needFull = false, false
	if d.full == true then V.Entries = {}; changed = true end
	for _, id in ipairs(type(d.rm) == "table" and d.rm or {}) do
		id = math.floor(tonumber(id) or 0)
		if V.Entries[id] then V.Entries[id] = nil; changed = true end
	end
	for _, u in ipairs(type(d.up) == "table" and d.up or {}) do
		local id = type(u) == "table" and math.floor(tonumber(u.u) or 0) or 0
		if id > 0 and type(u.n) == "string" then
			local j = type(u.j) == "string" and #u.j == 36 and u.j:match("^[%x%-]+$") and u.j or ""
			V.Entries[id] = {id = id, n = u.n:sub(1, 20), d = type(u.d) == "string" and u.d:sub(1, 32) or "", p = math.max(0, math.floor(tonumber(u.p) or 0)), g = type(u.g) == "string" and u.g:sub(1, 64) or "", j = j,
				ns = math.max(1, math.floor(tonumber(u.ns) or 1)), seen = now - (tonumber(u.a) or 0),
		gi = math.max(0, math.floor(tonumber(u.gi) or 0)), st = now - math.max(0, tonumber(u.s) or 0)}
			changed = true
		end
	end
	for _, t in ipairs(type(d.tc) == "table" and d.tc or {}) do
		local id = type(t) == "table" and math.floor(tonumber(t[1]) or 0) or 0
		local e = V.Entries[id]
		if e then e.seen = now - (tonumber(t[2]) or 0) elseif id > 0 then needFull = true end
	end
	return changed, needFull
end
local function pollBody()
	if V.Busy then return end
	if not LPL.CanView() then V.Wipe(); V.Halt = "gate" return end -- permission lost: drop everything cached
	if not guardOk() then V.ErrText = "Security connection unavailable - paused."; V.NextAt = os.clock() + 30 return end
	if not Auth.Token and not Auth.Load() then V.Wipe(); V.Halt = "auth"; Auth.Login(); Auth.Notify() return end
	V.Busy = true
	local ok, code, d, err = call("GET", "/live/list" .. (V.Cursor and ("?c=" .. V.Cursor) or ""), nil, true)
	V.Busy = false
	if not V.IsOpen then return end -- page closed while waiting: discard
	local now = os.clock()
	if ok and code == 200 and type(d) == "table" and d.ok == true and type(d.e) == "string" and tonumber(d.s) then
		local before = V.Count
		applyMeta(d) -- onlineCount comes with every answer, also the "nothing changed" ones
		local changed, needFull = false, false
		if d.nc ~= 1 then changed, needFull = V.Apply(d) end
		if V.Count ~= before then changed = true end
		V.Cursor = (not needFull) and (d.e .. "." .. tostring(math.floor(d.s))) or nil
		V.Fails, V.ErrText, V.ErrShown, V.LastOk, V.Halt = 0, nil, false, now, nil
		V.Interval = (changed or needFull) and 30 or math.min(90, V.Interval + 15)
		if V.OpenCmds() then V.Interval = math.min(V.Interval, 20) end -- a command of mine is still in flight: look for its status a little sooner
		V.NextAt = now + (needFull and 2 or V.Interval)
		return
	end
	if ok and code == 304 then -- unchanged cursor: the roster AND the count we already hold are still correct
		V.Fails, V.ErrText, V.ErrShown, V.LastOk = 0, nil, false, now
		V.Interval = math.min(90, V.Interval + 15)
		if V.OpenCmds() then V.Interval = math.min(V.Interval, 20) end
		V.NextAt = now + V.Interval
		return
	end
	if isBanned(ok, code, d) then LPL.OnBanned() return end
	if ok and code == 401 then V.Wipe(); V.Halt = "auth"; Auth.Forget() return end -- token expired / revoked (Forget signs in again automatically)
	if ok and code == 403 then V.Wipe(); V.Halt = "denied" return end -- the server says no: nothing stays cached
	V.Fails += 1
	local wait_ = math.min(300, 15 * 2 ^ math.min(V.Fails, 5))
	V.NextAt = now + wait_
	V.ErrText = describe(ok, code, d, err) .. " Retrying in " .. math.floor(wait_) .. "s."
	if not V.ErrShown then V.ErrShown = true; notify("Live Player Log: connection problem. Retrying quietly in the background.") end
end
function V.Poll() pollBody(); V.Refreshing = false end
function V.Kick()
	if not V.IsOpen or V.Looping then return end
	V.Looping = true
	V.Gen += 1
	local gen = V.Gen
	task.spawn(function()
		while V.Gen == gen and V.IsOpen do
			if not V.Halt and os.clock() >= V.NextAt then V.Poll() end
			if V.Gen ~= gen then break end
			V.Render()
			if V.Halt then break end -- no session yet / authorization problem: stop polling until the session is ready or the user retries
			task.wait(10)
		end
		if V.Gen == gen then V.Looping = false end
	end)
end
function V.Open()
	if not LPL.CanView(true) then V.Wipe(); V.Halt = "gate"; return false end
	V.IsOpen, V.Looping, V.Halt, V.Refreshing = true, false, nil, false
	if os.clock() - V.ClosedAt > 600 then V.Cursor = nil; V.Entries = {} end -- closed for a long time: take a fresh snapshot
	V.Interval, V.NextAt, V.Fails, V.Shown = 30, 0, 0, PAGE_SIZE
	V.Render()
	V.Kick()
	return true
end
function V.Close()
	V.IsOpen, V.Looping = false, false
	V.Gen += 1
	V.ClosedAt = os.clock()
end

function LPL.AttachViewer(page, closeFn)
	local C, L = Enum.TextXAlignment.Center, Enum.TextXAlignment.Left
	UI.CreateButton(page, "&lt; Back", 20).Activated:Connect(closeFn)
	UI.CreateText(page, "<b>LIVE PLAYER LOG</b>", 15, C)
	UI.CreateText(page, '<font color="' .. GRAY .. '">Every authenticated UH script user, in every server and experience. Visible to verified players, co-owners and the owner only.</font>', 10, C)
	V.overview = UI.CreateText(page, "", 12, L)
	V.status = UI.CreateText(page, "", 11, L)
	local refreshBtn = UI.CreateButton(page, "Refresh now", 18)
	Auth.Attach(page, function() return V.Halt == "auth" or Auth.Token == nil end)
	UI.CreateSeparator(page)
	local search = UI.CreateTextbox(page, "", "Search username, display name, UserId or game", 12)
	search:GetPropertyChangedSignal("Text"):Connect(function()
		V.Filter = (search.Text:lower():gsub("^%s+", ""):gsub("%s+$", ""))
		V.Shown = PAGE_SIZE
		V.Render()
	end)
	V.cmdText = UI.CreateText(page, "", 11, L)
	V.cmdText.Parent.Visible = false
	V.empty = UI.CreateText(page, "", 12, C)
	V.empty.Parent.Visible = false
	V.list = UI.CreateCanvas(page)
	local ll = V.list:FindFirstChildOfClass("UIListLayout")
	if ll then ll.Padding = UDim.new(0, 6) end
	V.list.Parent.Visible = false
	V.moreBtn = UI.CreateButton(page, "Show more", 18)
	V.moreBtn.Parent.Visible = false
	V.moreBtn.Activated:Connect(function() V.Shown += PAGE_SIZE; V.Render() end)
	UI.CreateSeparator(page)
	local histBtn = UI.CreateButton(page, "Moderation history", 18)
	V.hist = UI.CreateText(page, "", 11, L)
	V.hist.Parent.Visible = false
	local ubBox = UI.CreateTextbox(page, "", "UserId to UNBAN from UH services (owner / co-owner)", 11)
	local ubBtn = UI.CreateButton(page, "Remove UH services ban", 18)
	V.unban = {box = ubBox, btn = ubBtn}
	ubBox.Parent.Parent.Visible = false
	ubBtn.Parent.Visible = false
	local lastManual = 0
	refreshBtn.Activated:Connect(function()
		if os.clock() - lastManual < 8 or V.Busy then return end -- coalesce rapid taps
		lastManual = os.clock()
		if not LPL.CanView() then V.Wipe(); V.Halt = "gate"; V.Render() return end
		V.Halt = nil
		V.NextAt = 0
		V.Cursor, V.Refreshing = nil, true -- ask the registry for the complete list; the numbers on screen stay until the answer arrives
		V.Render()
		if V.IsOpen then if V.Looping then task.spawn(function() V.Poll(); V.Render() end) else V.Kick() end end
	end)
	histBtn.Activated:Connect(function()
		if V.HistBusy or not Auth.Token then return end
		V.HistBusy = true
		task.spawn(function()
			local ok, code, d, err = call("GET", "/live/mod/history", nil, true)
			V.HistBusy = false
			if ok and code == 200 and type(d) == "table" and type(d.h) == "table" then
				local lines = {}
				for _, h in ipairs(d.h) do
					if type(h) == "table" then
						lines[#lines + 1] = os.date("!%m-%d %H:%M", math.floor((tonumber(h.iat) or 0) / 1000)) .. " <b>" .. esc(tostring(h.a or "?"):upper()) .. "</b> " .. esc(tostring(h.mn or "?")) .. " (" .. esc(tostring(h.mr or "?")) .. ") > " .. esc(tostring(h.tn or h.tu or "?"))
							.. ' <font color="' .. GRAY .. '">' .. esc(tostring(h.st or "?")) .. (h.note and (" - " .. esc(tostring(h.note))) or "") .. "</font>"
					end
				end
				V.hist.Text = #lines > 0 and table.concat(lines, "\n") or "No moderation events recorded."
				V.hist.Parent.Visible = true
			else
				notify("Moderation history: " .. describe(ok, code, d, err))
			end
		end)
	end)
	ubBtn.Activated:Connect(function()
		local uid = tonumber(ubBox.Text)
		if not uid or uid < 1 then notify("Enter the UserId to unban.") return end
		if V.CmdBusy or not Auth.Token then return end
		V.CmdBusy = true
		task.spawn(function()
			local ok, code, d, err = call("POST", "/live/mod/command", {tu = math.floor(uid), a = "unban"}, true)
			V.CmdBusy = false
			if ok and code == 200 and type(d) == "table" and d.ok == true then
				notify("UNBAN: " .. tostring(d.st) .. " (" .. tostring(d.note or "") .. ")")
				ubBox.Text = ""
			elseif ok and type(d) == "table" then notify("UNBAN: " .. tostring(d.st or d.err or ("HTTP " .. code)))
			else notify("UNBAN: " .. describe(ok, code, d, err)) end
		end)
	end)
	Auth.Views[#Auth.Views + 1] = function() if V.IsOpen and V.Halt == "auth" and Auth.Token then V.Halt = nil; V.NextAt = 0; V.Kick() end end
	page:GetPropertyChangedSignal("Visible"):Connect(function()
		if page.Visible then
			if not V.Open() then V.Render(); pcall(closeFn) end
		else
			V.Close()
		end
	end)
end

-- ---------- registry page (information + status; no switch: registration is automatic while the script runs) ----------
local EXPLAIN = "While this script runs, your session is automatically listed in the <b>global registry of active UH script users</b> and counted in the active-user total. Verified players, co-owners and the owner can see, in the Live Player Log: your <b>Roblox username, display name and UserId</b>, the <b>experience</b> you are in (name + PlaceId) and the <b>public server ID</b> of that server (they can join it). Authorized moderators can also send your script a moderation action (kick, kill, deanimate, dizzy, hallucinate, Silent Hell) and the owner / co-owner can ban you from UH script services.\nNo IP address, device ID or other personal data is collected. Private server IDs are never shared. You can leave the registry for the current session below."
function LPL.AttachShare(page, closeFn)
	local C, L = Enum.TextXAlignment.Center, Enum.TextXAlignment.Left
	UI.CreateButton(page, "&lt; Back", 20).Activated:Connect(closeFn)
	UI.CreateText(page, "<b>ACTIVE USER REGISTRY</b>", 15, C)
	UI.CreateText(page, '<font color="' .. GRAY .. '">Automatic while the script is running.</font>', 10, C)
	UI.CreateSeparator(page)
	UI.CreateText(page, EXPLAIN, 12, L)
	local status = UI.CreateText(page, "", 12, L)
	local function statusText()
		if Pub.Banned then return '<font color="' .. RED .. '">This account is banned from UH script services.</font>' end
		if not Auth.Token then return '<font color="' .. YELLOW .. '">' .. (Auth.SignedOut and "You left the registry for this session. You are not listed and nothing is sent." or "Signing in automatically. You are listed as soon as the session is ready.") .. "</font>" .. (Pub.Note and ("\n" .. esc(Pub.Note)) or "") end
		local s = Pub.Status
		if s == "on" and Pub.LastOk then return '<font color="' .. GREEN .. '">Registered.</font> Last update ' .. fmtAge(os.clock() - Pub.LastOk) .. "." end
		if s == "error" then return '<font color="' .. RED .. '">The last registry update failed: ' .. esc(Pub.ErrText or "unknown error") .. " Retrying with backoff.</font>" end
		if s == "paused" then return '<font color="' .. YELLOW .. '">Paused until the security connection is available.</font>' end
		if s == "expired" then return '<font color="' .. YELLOW .. '">Your session expired. Signing in again automatically.</font>' end
		return "Registering..."
	end
	local function roleLine() local r = V.Role; return r and ('<font color="' .. GREEN .. '">Role: ' .. (r == "co-owner" and "Co-Owner" or (r:sub(1, 1):upper() .. r:sub(2))) .. "</font>\n") or "" end
	local function paint() if page.Visible ~= false then local t = roleLine() .. statusText(); if status.Text ~= t then status.Text = t end end end
	Auth.Attach(page, function() return true end)
	Pub.Hook = paint
	Auth.Views[#Auth.Views + 1] = paint
	paint()
	page:GetPropertyChangedSignal("Visible"):Connect(function() if page.Visible then paint() end end)
end

task.spawn(function() V.Role = LPL.LocalRole(true); Auth.Notify() end) -- role recognised from the banner lists at start
-- automatic registration: ~10 s after the script starts this session signs in on its own (saved session, otherwise a fresh sign-in) and registers,
-- with a visible notice (LPL.OnSignedIn). The Worker decides the role from roles.json / whitelist.json; ordinary users simply get no roster access.
task.delay(10, function()
	if Auth.Load() then LPL.OnSignedIn() else Auth.Login() end
end)

-- local player departure: only the LOCAL player's removal counts (another player leaving the server never reaches Pub.Depart)
Players.PlayerRemoving:Connect(function(p) if p == Player then Pub.Depart(false) end end)
pcall(function()
	Player.OnTeleport:Connect(function(state)
		if state == Enum.TeleportState.InProgress then
			Pub.Depart(true)
		elseif state == Enum.TeleportState.Failed and Pub.Departed and Pub.ByTeleport then
			Pub.Departed, Pub.ByTeleport = false, false -- the teleport did not happen: still here, so register again as a brand-new session (Pub.Start rotates the id)
			task.spawn(function()
				local t0 = os.clock()
				while Pub.Leaving and os.clock() - t0 < 20 do task.wait(0.1) end
				if Auth.Token and not Auth.SignedOut and not Pub.Departed then Pub.Start() end
			end)
		end
	end)
end)

Util.LivePlayerLog = LPL
