-- TwoEmoteSync.lua  (uh-mod-visual-system)
-- Consent-based two-person emote sync for the uh reanimation mod.
-- Loaded by the main script:  loadstring(game:HttpGet(Base .. "TwoEmoteSync.lua"))()(Ctx)
-- Transport: /alt live-sync backend (op "esync"), chat whisper fallback. Playback reuses the main script's dance loop.
return function(C)
local Util, UI, MainPage, Players, Player = C.Util, C.UI, C.MainPage, C.Players, C.Player
local RunService, UserInputService, TweenService, CoreGui = C.RunService, C.UserInputService, C.TweenService, C.CoreGui
local Reanimate, AnimLib, AssetGetPathFromFilename = C.Reanimate, C.AnimLib, C.AssetGetPathFromFilename
local ProtectedChat, OnPlayerChatted = C.ProtectedChat, C.OnPlayerChatted
local GetUIColor, GetUIBGColor, UITextColor = C.GetUIColor, C.GetUIBGColor, C.UITextColor
-- ===== Two Emote Sync: consent-based, chat-whisper signalling (existing ProtectedChat / OnPlayerChatted), server-time synced start =====
local T = {Gap = 4, Lead = 3, TTL = 30, Stale = 180, MaxDist = 120, Cool = {}, InCool = {}, Hist = {}, Q = {},
	LEFT = Enum.TextXAlignment.Left, B36 = "0123456789abcdefghijklmnopqrstuvwxyz"}
Util.TwoSync = T

function T.notify(t) pcall(Util.UINotify, t) end
function T.esc(s) return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
function T.busy() return T.S ~= nil or T.Out ~= nil or T.In ~= nil end
function T.sid() local s = {} for i = 1, 6 do s[i] = string.char(96 + math.random(1, 26)) end return table.concat(s) end
function T.enc(n)
	n = math.floor(n + 0.5)
	local s, a = "", math.abs(n)
	repeat local r = a % 36; s = T.B36:sub(r + 1, r + 1) .. s; a = a // 36 until a == 0
	return (n < 0 and "n" or "p") .. s
end
function T.dec(s)
	if type(s) ~= "string" or #s < 2 then return nil end
	local v = tonumber(s:sub(2), 36)
	if not v then return nil end
	return s:sub(1, 1) == "n" and -v or v
end

-- ===== emotes: every dance with 2+ .anim files (exactly-two = classic pair emote); entries follow the module's own Assets order =====
function T.files(m)
	local names, raw, seen = {}, {}, {}
	if type(m) == "table" and type(m.Assets) == "table" then
		for _, e in ipairs(m.Assets) do
			if type(e) == "string" then
				local n = string.split(e, "@")[1]
				if n:sub(-5) == ".anim" and not seen[n] then seen[n] = true; names[#names + 1] = n; raw[#raw + 1] = e end
			end
		end
	end
	return names, raw
end
function T.key(m) return (tostring(m.InternalName or m.Name or ""):gsub("[^%w_]", "_")) end
function T.emotes()
	local out = {}
	for _, m in ipairs(C.GetDances()) do
		local f, r = T.files(m)
		if #f >= 2 then out[#out + 1] = {m = m, files = f, raw = r, key = T.key(m), pair = #f == 2} end
	end
	table.sort(out, function(a, b)
		if a.pair ~= b.pair then return a.pair end
		return tostring(a.m.Name):lower() < tostring(b.m.Name):lower()
	end)
	return out
end
function T.find(key)
	for _, e in ipairs(T.emotes()) do if e.key == key then return e end end
end

-- ===== players: partial username / display-name matching =====
function T.matches(q)
	q = tostring(q or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local res = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= Player then
			local n, d = p.Name:lower(), p.DisplayName:lower()
			local s
			if q == "" then s = 5
			elseif n == q or d == q then s = 1
			elseif n:sub(1, #q) == q or d:sub(1, #q) == q then s = 2
			elseif n:find(q, 1, true) or d:find(q, 1, true) then s = 3 end
			if s then res[#res + 1] = {p = p, s = s} end
		end
	end
	table.sort(res, function(a, b)
		if a.s ~= b.s then return a.s < b.s end
		return a.p.Name:lower() < b.p.Name:lower()
	end)
	return res
end
function T.resolve()
	if T.Sel and T.Sel.Parent then return T.Sel end
	local q = T.Box and T.Box.Text or ""
	if q:gsub("%s", "") == "" then return nil end
	local res, exact = T.matches(q), {}
	if #res == 1 then return res[1].p end
	for _, r in ipairs(res) do if r.s == 1 then exact[#exact + 1] = r.p end end
	if #exact == 1 then return exact[1] end
	return nil
end

-- ===== transport: the existing /alt live-sync backend (op "esync", delivered by the existing /alt poll as an "esync" event); chat whisper is the fallback =====
-- backend contract: POST /alt {op="esync", target=<userId>, text=<string>} -> {relayed=true} and the target's GET /alt returns events {type="esync", from=<userId>, text=<string>}
function T.notScript(plr, sid)
	local o = T.Out
	if o and o.plr == plr and o.sid == sid then
		T.Out = nil; T.Hist[sid] = true
		T.notify(plr.DisplayName .. " is not running this script")
		T.render()
	end
end
function T.deliver(it)
	local plr, text = it.plr, it.text
	local R = Util.AltRemake
	if R and R.EsyncSend and R.EsyncReady and R.EsyncReady() and (T.NoBackend or 0) < os.clock() then
		local ok, r = R.EsyncSend(plr.UserId, text)
		if ok and type(r) == "table" and r.relayed == true then return end
		if r == "target is not running the script" then
			if it.kind == "REQ" then T.notScript(plr, text:match("^2ES REQ (%l+)")) end
			return
		end
		T.NoBackend = os.clock() + 120 -- backend lacks the op / is unreachable: stop retrying it for a while
	end
	local AF = Util.AltFling
	if AF and AF.Enabled and AF.Hide then AF.Hide[text] = true; AF.Hide["/w @" .. plr.Name .. " " .. text] = true end
	ProtectedChat("/w @" .. plr.Name .. " " .. text)
end
function T.pump()
	while #T.Q > 0 do pcall(T.deliver, table.remove(T.Q, 1)) end
	T.Pumping = false
end
function T.send(plr, kind, ...)
	T.Q[#T.Q + 1] = {plr = plr, kind = kind, text = table.concat({"2ES", kind, ...}, " ")}
	if not T.Pumping then T.Pumping = true; task.spawn(T.pump) end
end
function T.onBackend(ev)
	if type(ev) ~= "table" or type(ev.text) ~= "string" then return end
	local p = Players:GetPlayerByUserId(math.floor(tonumber(ev.from) or 0))
	if p then T.onMessage(p, ev.text) end
end

-- ===== lifecycle =====
function T.finish(reason, tell)
	local S, o, i = T.S, T.Out, T.In
	T.S, T.Out, T.In, T.Filter, T.Open = nil, nil, nil, nil, nil
	if S then
		T.Hist[S.sid] = true
		if tell then T.send(S.plr, "CAN", S.sid) end
		if S.conn then pcall(function() S.conn:Disconnect() end) end
		if S.syn and C.GetDance() == S.syn then C.SetDance(S.prev) end
		pcall(function()
			local r = S.rc and S.rc:FindFirstChild("HumanoidRootPart")
			if r then r.AssemblyLinearVelocity = Vector3.zero; r.AssemblyAngularVelocity = Vector3.zero end
		end)
	elseif tell then
		if o then T.Hist[o.sid] = true; T.send(o.plr, "CAN", o.sid)
		elseif i then T.Hist[i.sid] = true; T.send(i.plr, "DEC", i.sid) end
	end
	if reason then T.notify(reason) end
	T.render()
end

function T.watch(S)
	task.spawn(function()
		while T.S == S do
			task.wait(1)
			if T.S ~= S then return end
			local rc = Reanimate.Character
			if not S.plr.Parent then return T.finish(S.plr.DisplayName .. " left the server", false) end
			if not rc or rc ~= S.rc or not rc.Parent or not rc:FindFirstChild("HumanoidRootPart") then
				return T.finish("Your reanimated character is unavailable - sync ended", true)
			end
			if S.state == "play" and C.GetDance() ~= S.syn then return T.finish("The synced emote was stopped", true) end
			if S.state ~= "play" and os.clock() - S.seen > T.Stale then return T.finish("Two Emote Sync timed out", true) end
		end
	end)
end

function T.request(plr)
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") or plr == Player or not plr.Parent then return T.notify("Pick a player from the matches first") end
	if not Reanimate.Character then return T.notify("Reanimate first - Two Emote Sync needs your reanimated character") end
	if T.busy() then return T.notify("A Two Emote Sync request or session is already active") end
	if (T.Cool[plr.UserId] or 0) > os.clock() then return T.notify("Wait a few seconds before asking " .. plr.DisplayName .. " again") end
	T.Cool[plr.UserId] = os.clock() + 10
	local sid = T.sid()
	T.Out = {plr = plr, sid = sid}
	T.send(plr, "REQ", sid)
	T.notify("Request sent to " .. plr.DisplayName .. " - waiting for an answer")
	T.render()
	task.delay(T.TTL, function()
		if T.Out and T.Out.sid == sid then T.finish(plr.DisplayName .. " did not answer", true) end
	end)
end

function T.respond(ok)
	local i = T.In
	if not i then return end
	T.In = nil
	T.Hist[i.sid] = not ok or nil
	if not ok or not i.plr.Parent then T.Hist[i.sid] = true; T.send(i.plr, "DEC", i.sid); T.render(); return end
	if T.S or T.Out or not Reanimate.Character then
		T.Hist[i.sid] = true; T.send(i.plr, "BSY", i.sid); T.notify("Reanimate first - request declined"); T.render(); return
	end
	T.begin("guest", i.plr, i.sid, true)
end

function T.begin(role, plr, sid, ack)
	local pend = T.Out and T.Out.pos
	T.Out, T.In = nil, nil
	local rc = Reanimate.Character
	local root = rc and rc:FindFirstChild("HumanoidRootPart")
	if not root then
		T.Hist[sid] = true; T.send(plr, "CAN", sid); T.notify("Reanimate first - session cancelled"); T.render(); return
	end
	local S = {role = role, plr = plr, sid = sid, state = "align", seen = os.clock(), rc = rc, prev = C.GetDance(), myPos = root.Position, peerPos = pend}
	T.S = S
	if ack then T.send(plr, "ACC", sid) end
	T.send(plr, "POS", sid, T.enc(S.myPos.X * 10), T.enc(S.myPos.Y * 10), T.enc(S.myPos.Z * 10))
	T.watch(S)
	T.place()
	T.render()
end

-- both sides compute the same meeting point from the two exchanged positions, then stand Gap studs apart facing each other
function T.place()
	local S = T.S
	if not S or S.placed or not S.peerPos then return end
	local rc = Reanimate.Character
	local root = rc and rc:FindFirstChild("HumanoidRootPart")
	if not root or rc ~= S.rc then return T.finish("Your reanimated character is unavailable - sync ended", true) end
	local a, b = S.myPos, S.peerPos
	if (a - b).Magnitude > T.MaxDist then return T.finish("You are too far apart (" .. math.floor((a - b).Magnitude) .. " studs)", true) end
	local dir = Vector3.new(a.X - b.X, 0, a.Z - b.Z)
	if dir.Magnitude < 0.05 then dir = S.role == "host" and Vector3.xAxis or -Vector3.xAxis end
	dir = dir.Unit
	local pos = Vector3.new((a.X + b.X) / 2 + dir.X * T.Gap / 2, a.Y, (a.Z + b.Z) / 2 + dir.Z * T.Gap / 2)
	S.lock, S.placed, S.state = CFrame.lookAt(pos, pos - dir), true, "pick"
	root.CFrame = S.lock
	pcall(function() root.AssemblyLinearVelocity = Vector3.zero; root.AssemblyAngularVelocity = Vector3.zero end)
	S.conn = RunService.Heartbeat:Connect(function()
		local r = S.rc and S.rc:FindFirstChild("HumanoidRootPart")
		if r then r.CFrame = S.lock; r.AssemblyLinearVelocity = Vector3.zero end
	end)
	T.render()
end

function T.valid(S)
	local m, p = S.mine, S.peer
	return m ~= nil and p ~= nil and m.key == p.key and m.idx ~= p.idx and m.idx >= 1 and p.idx >= 1 and m.idx <= #m.e.files and p.idx <= #m.e.files
end

function T.pick(e, idx)
	local S = T.S
	if not S or S.state ~= "pick" or S.mine then return end
	if S.peer and (S.peer.key ~= e.key or S.peer.idx == idx) then return T.notify("Pick another animation of " .. tostring(S.peer.e.m.Name)) end
	S.mine, S.seen = {key = e.key, idx = idx, e = e}, os.clock()
	T.send(S.plr, "SEL", S.sid, e.key, tostring(idx), tostring(#e.files))
	T.render()
	T.tryStart()
end

function T.unpick()
	local S = T.S
	if not S or S.state ~= "pick" or not S.mine then return end
	S.mine, S.seen = nil, os.clock()
	T.send(S.plr, "CLR", S.sid)
	T.render()
end

-- the host (requester) is the single authority that starts playback; the start instant is a shared server time
function T.tryStart()
	local S = T.S
	if not S or S.role ~= "host" or S.state ~= "pick" or not T.valid(S) then return end
	local at = workspace:GetServerTimeNow() + T.Lead
	S.state = "go"
	T.send(S.plr, "GO", S.sid, T.enc(at * 1000), S.mine.key, tostring(S.mine.idx), tostring(S.peer.idx))
	T.play(at)
end

-- playback reuses the existing dance loop (the main script's current-dance slot) with a one-file synthetic dance driven by AnimLib against the shared clock
function T.play(at)
	local S = T.S
	if not S or S.state == "play" or not S.mine then return end
	S.state, S.seen = "play", os.clock()
	local file, raw = S.mine.e.files[S.mine.idx], S.mine.e.raw[S.mine.idx]
	local syn = {Name = "Two Emote Sync", Description = "Synchronised two-person emote", InternalName = "TwoEmoteSync", Hash = "TwoEmoteSync",
		Assets = {raw}, Config = function() end, LoadConfig = function() end}
	function syn.Init(rc)
		local ok, tr = pcall(AnimLib.Track.fromfile, AssetGetPathFromFilename(file))
		if not ok or type(tr) ~= "table" or type(tr.Keyframes) ~= "table" or #tr.Keyframes == 0 then
			task.defer(function() if T.S == S then T.finish(file .. " could not be read - sync ended", true) end end)
			return
		end
		local a = AnimLib.Animator.new()
		a.rig, a.track, a.speed, a.looped = rc, tr, 1, (tr.Time or 0) > 0
		syn.a = a
	end
	function syn.Update(dt, rc)
		local a = syn.a
		if a then a.rig = rc; pcall(a.Step, a, math.max(0, workspace:GetServerTimeNow() - at)) end
	end
	function syn.Destroy() syn.a = nil end
	S.syn = syn
	C.SetDance(syn)
	T.render()
end

-- ===== incoming messages =====
function T.onMessage(plr, msg)
	if plr == Player or type(msg) ~= "string" then return end
	local kind, sid, rest = msg:match("^2ES (%u+) (%l+)%s*(.-)%s*$")
	if not kind or T.Hist[sid] then return end
	local S = T.S
	if kind == "REQ" then
		if (T.InCool[plr.UserId] or 0) > os.clock() then return end
		T.InCool[plr.UserId] = os.clock() + 3
		if T.busy() or not Reanimate.Character then T.send(plr, "BSY", sid) return end
		T.In = {plr = plr, sid = sid}
		T.notify(plr.DisplayName .. " wants to sync two emotes with you")
		T.render()
		task.delay(T.TTL, function() if T.In and T.In.sid == sid then T.respond(false) end end)
	elseif kind == "ACC" then
		local o = T.Out
		if o and o.plr == plr and o.sid == sid then T.begin("host", plr, sid) end
	elseif kind == "DEC" or kind == "BSY" then
		local o = T.Out
		if o and o.plr == plr and o.sid == sid then
			T.Out = nil; T.Hist[sid] = true
			T.notify(plr.DisplayName .. (kind == "DEC" and " declined" or " is busy or not reanimated"))
			T.render()
		end
	elseif kind == "CAN" then
		local i = T.In
		if i and i.plr == plr and i.sid == sid then
			T.In = nil; T.Hist[sid] = true; T.notify(plr.DisplayName .. " cancelled the request"); T.render()
		elseif S and S.plr == plr and S.sid == sid then
			T.finish(plr.DisplayName .. " ended the session", false)
		elseif T.Out and T.Out.plr == plr and T.Out.sid == sid then
			T.Out = nil; T.Hist[sid] = true; T.notify(plr.DisplayName .. " could not join"); T.render()
		end
	elseif S and S.plr == plr and S.sid == sid then
		S.seen = os.clock()
		if kind == "POS" then
			local a, b, c = rest:match("^(%S+) (%S+) (%S+)$")
			local x, y, z = T.dec(a), T.dec(b), T.dec(c)
			if x and y and z then S.peerPos = Vector3.new(x / 10, y / 10, z / 10); T.place() end
		elseif kind == "SEL" then
			if S.state ~= "align" and S.state ~= "pick" then return end
			local key, idx, n = rest:match("^(%S+) (%d+) (%d+)$")
			idx, n = tonumber(idx), tonumber(n)
			local e = key and T.find(key)
			if not (e and idx and n and n == #e.files and idx >= 1 and idx <= n) then T.send(plr, "REJ", sid, "missing") return end
			local m = S.mine
			if m and (m.key ~= key or m.idx == idx) then
				if S.role == "host" then T.send(plr, "REJ", sid, "conflict") return end
				S.mine = nil
				T.notify(plr.DisplayName .. " picked first - choose another animation")
			end
			S.peer = {key = key, idx = idx, e = e}
			T.render()
			T.tryStart()
		elseif kind == "CLR" then
			S.peer = nil
			T.render()
		elseif kind == "REJ" then
			S.mine = nil
			T.notify(plr.DisplayName .. (rest == "missing" and " does not have that emote" or ": that choice conflicts - pick again"))
			T.render()
		elseif kind == "GO" then
			if S.role ~= "guest" or S.state ~= "pick" then return end
			local ms, key, hi, gi = rest:match("^(%S+) (%S+) (%d+) (%d+)$")
			local at = T.dec(ms)
			if not (at and S.mine and S.peer and S.mine.key == key and S.peer.key == key and S.peer.idx == tonumber(hi) and S.mine.idx == tonumber(gi)) then
				return T.finish("Selections out of sync - session ended", true)
			end
			T.play(at / 1000)
		end
	elseif kind == "POS" then
		local o = T.Out
		if o and o.plr == plr and o.sid == sid then
			local a, b, c = rest:match("^(%S+) (%S+) (%S+)$")
			local x, y, z = T.dec(a), T.dec(b), T.dec(c)
			if x and y and z then o.pos = Vector3.new(x / 10, y / 10, z / 10) end
		end
	end
end

-- ===== draggable on-screen window (existing page widgets + theme colours) =====
function T.gui()
	if T.Win and T.Win.Parent then return end
	if T.Gui then pcall(function() T.Gui:Destroy() end) end
	local parent = (gethiddengui and gethiddengui()) or CoreGui
	local gui = Util.Instance("ScreenGui", parent)
	gui.ResetOnSpawn, gui.DisplayOrder, gui.IgnoreGuiInset = false, 1000, true
	local win = Util.Instance("Frame", gui)
	win.Size, win.Position, win.BorderSizePixel, win.Active = UDim2.new(0, 320, 0, 300), UDim2.new(0.5, -160, 0.5, -150), 2, true
	Util.AddDecoStep(function(t) win.BorderColor3 = GetUIColor(t); win.BackgroundColor3 = GetUIBGColor(t) end, win)
	local head = Util.Instance("TextLabel", win)
	head.Size, head.BackgroundTransparency, head.BackgroundColor3, head.BorderSizePixel = UDim2.new(1, 0, 0, 26), 0.5, Color3.new(0, 0, 0), 0
	head.Font, head.TextSize, head.Text, head.TextColor3, head.Active = Enum.Font.Code, 14, "TWO EMOTE SYNC  (drag to move)", UITextColor.Value, true
	Util.LinkDestroyI2C(head, UITextColor.Changed:Connect(function(v) head.TextColor3 = v end))
	local dragging, start, origin
	local function isPress(i) return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch end
	head.InputBegan:Connect(function(i) if isPress(i) then dragging, start, origin = true, i.Position, win.Position end end)
	Util.LinkDestroyI2C(win, UserInputService.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - start
			win.Position = UDim2.new(origin.X.Scale, origin.X.Offset + d.X, origin.Y.Scale, origin.Y.Offset + d.Y)
		end
	end))
	Util.LinkDestroyI2C(win, UserInputService.InputEnded:Connect(function(i) if isPress(i) then dragging = false end end))
	local pg = UI.CreatePage()
	pg.Parent, pg.AnchorPoint, pg.Position, pg.Size, pg.ZIndex, pg.Interactable, pg.Visible = win, Vector2.zero, UDim2.new(0, 0, 0, 26), UDim2.new(1, 0, 1, -26), 1, true, true
	T.Gui, T.Win, T.Pg = gui, win, pg
end

function T.dyn(pg, slot, fn)
	for _, c in ipairs(T[slot] or {}) do pcall(function() c:Destroy() end) end
	local before, new = {}, {}
	for _, c in ipairs(pg:GetChildren()) do before[c] = true end
	fn()
	for _, c in ipairs(pg:GetChildren()) do if not before[c] then new[#new + 1] = c end end
	T[slot] = new
end

function T.refresh()
	local S = T.S
	if not S or S.state ~= "pick" or not T.Pg or not T.Pg.Parent then return end
	T.dyn(T.Pg, "Tmp", function()
		if not S.mine then
			local f, shown = (T.Filter or ""):lower(), 0
			for _, e in ipairs(S.peer and {S.peer.e} or T.emotes()) do
				local name = tostring(e.m.Name)
				if f == "" or name:lower():find(f, 1, true) then
					shown += 1
					if shown > 40 then break end
					local open = S.peer ~= nil or T.Open == e.key
					local row = UI.CreateButton(T.Pg, (open and "- " or "+ ") .. T.esc(name) .. "  [" .. #e.files .. " anims" .. (e.pair and ", pair" or "") .. "]", 15)
					row.Activated:Connect(function() T.Open = (T.Open == e.key) and nil or e.key; T.refresh() end)
					if open then
						for idx, file in ipairs(e.files) do
							local taken = S.peer ~= nil and S.peer.idx == idx
							local b = UI.CreateButton(T.Pg, (taken and "(taken) " or "   ") .. T.esc(file), 13)
							b.Activated:Connect(function() if not taken then T.pick(e, idx) end end)
						end
					end
				end
			end
			if shown == 0 then UI.CreateText(T.Pg, "No compatible emotes found (needs 2+ .anim files). Modules may still be loading.", 13, T.LEFT) end
		end
		UI.CreateButton(T.Pg, "End session", 16).Activated:Connect(function() T.finish("Two Emote Sync ended", true) end)
	end)
end

function T.render()
	local S, i, o = T.S, T.In, T.Out
	if not (S or i or o) then
		if T.Gui then pcall(function() T.Gui.Enabled = false end) end
		return
	end
	T.gui()
	T.Gui.Enabled = true
	T.Tmp = nil
	for _, c in ipairs(T.Pg:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
	local function txt(s, sz) return UI.CreateText(T.Pg, s, sz or 14, T.LEFT) end
	local function btn(s, f) local b = UI.CreateButton(T.Pg, s, 18); b.Activated:Connect(f); return b end
	if i then
		txt(T.esc(i.plr.DisplayName) .. " (@" .. T.esc(i.plr.Name) .. ") wants to sync two emotes with you. If you accept, your reanimated characters are moved to face each other.")
		btn("Accept", function() T.respond(true) end)
		btn("Decline", function() T.respond(false) end)
	elseif o then
		txt("Waiting for " .. T.esc(o.plr.DisplayName) .. " to accept...")
		btn("Cancel request", function() T.finish("Request cancelled", true) end)
	elseif S.state == "align" then
		txt("Positioning - waiting for " .. T.esc(S.plr.DisplayName) .. "...")
		btn("End session", function() T.finish("Two Emote Sync ended", true) end)
	elseif S.state == "pick" then
		local peerTxt = S.peer and (T.esc(S.plr.DisplayName) .. " chose " .. T.esc(S.peer.e.m.Name) .. " / " .. T.esc(S.peer.e.files[S.peer.idx]))
			or (T.esc(S.plr.DisplayName) .. " has not chosen yet")
		if S.mine then
			txt("You chose " .. T.esc(S.mine.e.m.Name) .. " / " .. T.esc(S.mine.e.files[S.mine.idx]) .. "\nWaiting for " .. T.esc(S.plr.DisplayName) .. "...", 13)
			txt(peerTxt, 13)
			btn("Change my choice", T.unpick)
		else
			txt("Facing each other. Pick your animation.\n" .. peerTxt, 13)
			local box = UI.CreateTextbox(T.Pg, T.Filter or "", "Search emotes", 16)
			box:GetPropertyChangedSignal("Text"):Connect(function() T.Filter = box.Text; T.refresh() end)
		end
		T.refresh()
	else
		txt("Playing " .. T.esc(S.mine.e.m.Name) .. "\nYou: " .. T.esc(S.mine.e.files[S.mine.idx]) .. "\n" .. T.esc(S.plr.DisplayName) .. ": " .. T.esc(S.peer.e.files[S.peer.idx]), 13)
		btn("Stop and release", function() T.finish("Two Emote Sync stopped", true) end)
	end
end

-- ===== page on the main tab: partial-name autocomplete + request =====
function T.suggest()
	if not T.Box or not T.Nav then return end
	if T.Sel and not T.Sel.Parent then T.Sel = nil end
	local res = T.matches(T.Box.Text)
	local r = T.resolve()
	T.Status.Text = r and ("Target: " .. T.esc(r.DisplayName) .. " (@" .. T.esc(r.Name) .. ")")
		or (T.Box.Text == "" and "Type part of a username or display name" or (#res == 0 and "No matching player in this server" or "Tap a match below"))
	T.dyn(T.Nav, "Match", function()
		for n, m in ipairs(res) do
			if n > 6 then break end
			local p = m.p
			local b = UI.CreateButton(T.Nav, T.esc(p.DisplayName) .. "  (@" .. T.esc(p.Name) .. ")", 15)
			b.Activated:Connect(function() T.Sel = p; T.Box.Text = p.Name; T.suggest() end)
		end
	end)
end

local pg = UI.CreatePage()
T.Nav = pg
pcall(function() Util.Search.Titles[pg] = "Two Emote Sync" end)
pg.ZIndex, pg.Position, pg.Interactable, pg.Visible = 1, UDim2.new(0.5, 360, 0.5, 0), false, false
UI.CreateButton(MainPage, "Two Emote Sync &gt;", 20).Activated:Connect(function()
	pg.Interactable, pg.Visible, MainPage.Interactable = false, true, false
	local tw = TweenService:Create(pg, TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.In), {Position = UDim2.new(0.5, 0, 0.5, 0)})
	tw:Play()
	tw.Completed:Connect(function() pg.Interactable = true; T.suggest() end)
end)
UI.CreateButton(pg, "&lt; Back", 20).Activated:Connect(function()
	pg.Interactable, MainPage.Interactable = false, false
	local tw = TweenService:Create(pg, TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), {Position = UDim2.new(0.5, 360, 0.5, 0)})
	tw:Play()
	tw.Completed:Connect(function() MainPage.Interactable = true; pg.Visible = false end)
end)
UI.CreateSeparator(pg)
UI.CreateText(pg, "Sync a two-person emote with another user of this script. They must accept before anything happens.", 13, T.LEFT)
T.Box = UI.CreateTextbox(pg, "", "Username or display name", 16)
T.Status = UI.CreateText(pg, "Type part of a username or display name", 13, T.LEFT)
UI.CreateButton(pg, "Send request", 20).Activated:Connect(function()
	local p = T.resolve()
	if not p then return T.notify("Pick a player from the matches first") end
	T.request(p)
end)
T.Box:GetPropertyChangedSignal("Text"):Connect(function()
	if T.Sel and T.Sel.Name ~= T.Box.Text then T.Sel = nil end
	T.suggest()
end)
Players.PlayerAdded:Connect(function() if pg.Visible then T.suggest() end end)
Players.PlayerRemoving:Connect(function(p)
	local S, i, o = T.S, T.In, T.Out
	if S and S.plr == p then T.finish(p.DisplayName .. " left the server", false)
	elseif i and i.plr == p then T.In = nil; T.render()
	elseif o and o.plr == p then T.Out = nil; T.notify(p.DisplayName .. " left the server"); T.render() end
	if pg.Visible then task.defer(T.suggest) end
end)
OnPlayerChatted.Event:Connect(function(plr, msg) pcall(T.onMessage, plr, msg) end)
return T
end
