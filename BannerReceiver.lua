-- BannerReceiver.lua | polls the backend, sanitises banner data, one banner per player, follows respawns
return function(Env, UI)
	local Players, RS, HS = Env.Players, Env.RunService, Env.HttpService
	local R = {Banners = {}, Running = false, Kicked = false}
	local conns, thumbs = {}, {}

	-- Verified users, matched by userId (resolved once from the username; until then the REAL in-game name is used, never the sent payload).
	-- tag = rank chip text, logo = rotating 3D triangle, color = accent override. An entry of {} = plain verified (check badge only).
	local VERIFIED = {
		-- OWNER / CO-OWNER are not hardcoded: roles.json in the GitHub repo lists them (Env.Roles), applyRoles below adds them here
		-- moderator whitelist (plain "Verified" banner, check badge only; they can kick / kill / deanimate misusing script users).
		-- Whitelisted accounts are Verified straight away, no key needed. One per line, lower-case username:
		-- more verified players are NOT listed here: they live in whitelist.json on GitHub (Env.Base .. "whitelist.json"), fetched at start + every 60s (see applyWhitelist below)
	}
	local roleIds, resolved, nameIds = {}, {}, {}
	local function resolveName(name, r)
		task.spawn(function()
			local ok, id = pcall(Players.GetUserIdFromNameAsync, Players, name)
			if ok and id and VERIFIED[name] == r then roleIds[id] = r; resolved[name] = true; nameIds[name] = id end
		end)
	end
	for name, r in pairs(VERIFIED) do resolveName(name, r) end

	-- OWNER / CO-OWNER: identities come from roles.json (Env.Roles); only the look of each rank is defined here.
	local ROLE_STYLE = {
		["owner"] = {tag = "OWNER", logo = true, color = Color3.fromRGB(255, 190, 50)},
		["co-owner"] = {tag = "CO-OWNER", color = Color3.fromRGB(170, 120, 255)},
	}
	local roleRemote = {names = {}, ids = {}} -- what the last roles.json contributed
	local function applyRoles(entries)
		local names, ids = {}, {}
		for _, e in ipairs(entries or {}) do
			local st = ROLE_STYLE[e.role]
			if st then
				if e.username then names[e.username:lower()] = st end
				if e.userId then ids[e.userId] = st end
			end
		end
		for n in pairs(roleRemote.names) do -- removed from the file (or rank changed) -> the old rank goes away
			if names[n] ~= VERIFIED[n] then
				VERIFIED[n] = nil; resolved[n] = nil
				if nameIds[n] then roleIds[nameIds[n]] = nil; nameIds[n] = nil end
			end
		end
		for id, st in pairs(roleRemote.ids) do
			if ids[id] ~= st and roleIds[id] == st then roleIds[id] = nil end
		end
		for n, st in pairs(names) do
			if VERIFIED[n] ~= st then VERIFIED[n] = st; resolved[n] = nil; resolveName(n, st) end
		end
		for id, st in pairs(ids) do roleIds[id] = st end
		roleRemote.names, roleRemote.ids = names, ids
	end
	local function fetchRoles()
		local RL = Env.Roles
		if not RL then return end
		pcall(RL.Fetch, Env.Base)
		pcall(applyRoles, RL.Entries)
	end
	if Env.Roles then pcall(applyRoles, Env.Roles.Entries) end -- already fetched at startup: tags are there from the first frame

	-- Remote whitelist: whitelist.json on GitHub = {"entries": [{"username": "SomeName"}, {"userId": 123456}]}. Entries only ever become plain "Verified"
	-- (check badge + moderator tools, no key needed): the file can never grant OWNER / CO-OWNER or any rank tag, and can't override the names hardcoded above.
	local remote = {names = {}, ids = {}} -- what the last successful fetch contributed
	local function dropId(id) local r = roleIds[id]; if r and not r.tag then roleIds[id] = nil end end
	local function applyWhitelist(entries)
		local names, ids = {}, {}
		for _, e in ipairs(entries) do
			if type(e) == "table" then
				local n = type(e.username) == "string" and e.username:lower() or nil
				if n and #n >= 3 and #n <= 20 and n:match("^[%w_]+$") and (not VERIFIED[n] or remote.names[n]) and not roleRemote.names[n] then names[n] = true end
				local id = math.floor(tonumber(e.userId) or 0)
				if id > 0 and (not roleIds[id] or remote.ids[id]) then ids[id] = true end
			end
		end
		for n in pairs(remote.names) do -- removed from the file -> no longer whitelisted
			if not names[n] and not roleRemote.names[n] then
				VERIFIED[n] = nil; resolved[n] = nil
				if nameIds[n] then dropId(nameIds[n]); nameIds[n] = nil end
			end
		end
		for id in pairs(remote.ids) do if not ids[id] then dropId(id) end end
		for n in pairs(names) do
			if not VERIFIED[n] then local r = {}; VERIFIED[n] = r; resolveName(n, r) end
		end
		for id in pairs(ids) do if not roleIds[id] then roleIds[id] = {} end end
		remote.names, remote.ids = names, ids
	end
	local lastWL
	local function fetchWhitelist()
		if not Env.Base then return end
		local ok, body, st = pcall(function()
			if Env.Http then return Env.Http.Get(Env.Base .. "whitelist.json?t=" .. math.floor(os.time() / 60), "whitelist.json") end
			return game:HttpGet(Env.Base .. "whitelist.json?t=" .. os.time())
		end)
		if not ok or type(body) ~= "string" then return end
		if st == 304 and lastWL then -- file unchanged: re-apply the parsed copy (keeps the interplay with roles.json identical, no download / decode)
			pcall(applyWhitelist, lastWL)
			return
		end
		local ok2, data = pcall(HS.JSONDecode, HS, body)
		if ok2 and type(data) == "table" and type(data.entries) == "table" then lastWL = data.entries; pcall(applyWhitelist, data.entries) end
	end
	local function rawRole(uid) -- whitelisted by username (protected from kill / kick / blacklist)
		if roleIds[uid] then return roleIds[uid] end
		local p = Players:GetPlayerByUserId(uid)
		local n = p and p.Name:lower()
		if n and VERIFIED[n] and not resolved[n] then return VERIFIED[n] end
	end
	local function roleOf(uid) -- OWNER / CO-OWNER and plain "Verified" players: whitelisted = verified, no key
		return rawRole(uid)
	end
	function R.IsWhitelisted(uid) return rawRole(uid) ~= nil end

	-- OWNER-only override of verified immunity. OWNER = the "owner" rank of roles.json (only roles.json styles carry tag "OWNER": whitelist.json can never grant a tag).
	-- Plain verified moderators can be moderated by the OWNER and nobody else; OWNER / CO-OWNER targets and self-targeting stay blocked for everyone.
	local function isOwner(uid) local r = uid and roleOf(uid); return r ~= nil and r.tag == "OWNER" end
	function R.IsOwner(uid) return isOwner(tonumber(uid)) end
	function R.CanTarget(uid) -- may THIS viewer moderate that player at all? (rights per action are checked separately)
		uid = tonumber(uid)
		if not uid or uid == Env.Player.UserId then return false end
		local r = rawRole(uid)
		if not r then return true end -- ordinary user
		return r.tag == nil and isOwner(Env.Player.UserId) -- plain verified moderator: OWNER only; OWNER / CO-OWNER: immune
	end
	function R.CanBeModeratedBy(by) -- recipient side: may a command from `by` act on THIS account?
		by = tonumber(by)
		if not by or by == Env.Player.UserId or not roleOf(by) then return false end -- sender must be OWNER / CO-OWNER / verified
		local me = rawRole(Env.Player.UserId)
		if not me then return true end -- ordinary user: existing rule
		if me.tag then return false end -- OWNER / CO-OWNER recipients are immune
		return isOwner(by) and Players:GetPlayerByUserId(by) ~= nil -- plain verified recipient: only an OWNER (roles.json) who is in this server
	end

	R.RoleOf = roleOf
	local function clean(s, n) return (tostring(s or ""):gsub("%c", "")):sub(1, n) end
	-- per-user banner style: only well-formed hex colours + clamped numbers ever reach the UI (never raw payload data)
	local function hex(v) v = tostring(v or ""); return v:match("^#%x%x%x%x%x%x$") and v:upper() or nil end
	local function num(v, lo, hi, d) v = tonumber(v); if not v then return d end; return math.clamp(math.floor(v + 0.5), lo, hi) end
	local function cleanStyle(s)
		if type(s) ~= "table" then return nil end
		local st = {a = hex(s.a), a2 = hex(s.a2), b1 = hex(s.b1), b2 = hex(s.b2), gr = num(s.gr, 0, 360, 90), bw = num(s.bw, 0, 4, 2), bs = num(s.bs, 0, 2, 2), cr = num(s.cr, 4, 24, 14), fx = num(s.fx, 0, 63, 63)}
		st.key = table.concat({st.a or "", st.a2 or "", st.b1 or "", st.b2 or "", st.gr, st.bw, st.bs, st.cr, st.fx}, ",")
		return st
	end
	local function headshot(uid)
		if thumbs[uid] == nil then
			local ok, url = pcall(Players.GetUserThumbnailAsync, Players, uid, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
			thumbs[uid] = ok and url or ""
		end
		return thumbs[uid]
	end
	-- Inline moderation buttons drawn beside a banner (order = grid order in BannerUI). `mod` = verified moderators + owner / co-owner (kill / deanimate / kick,
	-- relayed through ModTools); `ban` = owner / co-owner only (blacklist). Same rights as the tap-a-banner menu, just one tap closer.
	local ACTS = {
		{key = "kill", label = "Kill", color = Color3.fromRGB(214, 92, 48), mod = true},
		{key = "deanimate", label = "Deanimate", color = Color3.fromRGB(96, 110, 210), mod = true},
		{key = "kick", label = "Kick", color = Color3.fromRGB(196, 146, 38), mod = true},
		{key = "ban", label = "Ban", color = Color3.fromRGB(190, 50, 60), ban = true},
	}
	local function actionsFor(uid) -- the buttons THIS viewer may use on that player's banner; nothing on yourself or on OWNER / CO-OWNER; verified moderators only for the OWNER (R.CanTarget)
		if not R.CanTarget(uid) then return nil end
		local me = roleOf(Env.Player.UserId)
		if not me then return nil end
		local owner = me.tag == "OWNER" or me.tag == "CO-OWNER" -- owner / co-owner always SEE every button; a tap reports what is missing (module) via R.Block
		local mod = owner or (R.CanModerate and R.CanModerate())
		local bl = owner or (R.CanBlacklist and R.CanBlacklist())
		local list = {}
		for _, a in ipairs(ACTS) do
			if (a.mod and mod) or (a.ban and bl) then list[#list + 1] = a end
		end
		if #list == 0 then return nil end
		return list
	end
	local function sanitize(uid, d)
		local img = tostring(d.image or "")
		if img:match("^%d+$") then img = "rbxassetid://" .. img elseif not img:match("^rbxassetid://%d+$") then img = "" end
		if img == "" then img = headshot(uid) end
		local name = clean(d.name, 40)
		local title = clean(d.title, 40)
		local acts = actionsFor(uid)
		local keys = {}
		for _, a in ipairs(acts or {}) do keys[#keys + 1] = a.key end
		return {userId = uid, title = title ~= "" and title or name, subtitle = clean(d.subtitle, 40), image = img, role = roleOf(uid),
			acts = acts, actKey = table.concat(keys, ","), style = cleanStyle(d.style)}
	end
	local function sig(o) return o.title .. "|" .. o.subtitle .. "|" .. o.image .. "|" .. (o.role and (o.role.tag or "v") or "") .. "|" .. o.actKey end

	local function targetPart(uid)
		local char
		if uid == Env.Player.UserId then
			char = Env.GetLocalCharacter() -- reanimated character when active, real one otherwise
		else
			local p = Players:GetPlayerByUserId(uid)
			char = p and p.Character
		end
		if not char or not char.Parent then return nil end
		local part = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
		if part and part:IsA("BasePart") and part.Parent then return part end
	end
	local function remove(uid)
		local e = R.Banners[uid]
		if e then R.Banners[uid] = nil; e.UI:Destroy(true) end
	end

	function R.Process(list)
		local seen = {}
		for _, d in ipairs(list) do
			local uid = type(d) == "table" and tonumber(d.userId)
			if uid and not seen[uid] and (uid == Env.Player.UserId or Players:GetPlayerByUserId(uid)) then
				seen[uid] = true
				local o = sanitize(uid, d)
				local sk = o.style and o.style.key or ""
				local e = R.Banners[uid]
				if not e then
					R.Banners[uid] = {UI = UI.new(o), Sig = sig(o), SKey = sk, Role = o.role, ActKey = o.actKey}
				elseif e.Role ~= o.role or e.ActKey ~= o.actKey then -- rank / moderation rights changed (username just resolved / whitelist updated): rebuild
					R.DisarmKick()
					e.UI:Destroy(false); R.Banners[uid] = {UI = UI.new(o), Sig = sig(o), SKey = sk, Role = o.role, ActKey = o.actKey}
				else
					if e.Sig ~= sig(o) then e.UI:Update(o); e.Sig = sig(o) end
					if e.SKey ~= sk and not (uid == Env.Player.UserId and os.clock() < (R.StyleHold or 0)) then e.UI:Restyle(o.style); e.SKey = sk end
				end
			end
		end
		for uid in pairs(R.Banners) do if not seen[uid] then remove(uid) end end
	end

function R.Fetch()
local ok, res = pcall(Env.Request, {Url = Env.Backend .. "/banners?room=" .. HS:UrlEncode(Env.Room), Method = "GET"})
if not ok or type(res) ~= "table" then return false end
if res.StatusCode ~= 200 then return false, nil, nil, res.StatusCode end
local ok2, data = pcall(HS.JSONDecode, HS, res.Body)
if not ok2 or type(data) ~= "table" or type(data.banners) ~= "table" then return false end
local parts = {}
for _, d in ipairs(data.banners) do
if type(d) == "table" then
local okS, sj = pcall(HS.JSONEncode, HS, d.style or {})
parts[#parts + 1] = tostring(d.userId) .. "|" .. tostring(d.name) .. "|" .. tostring(d.title) .. "|" .. tostring(d.subtitle) .. "|" .. tostring(d.image) .. "|" .. (okS and sj or "")
end
end
table.sort(parts)
local fp = table.concat(parts, "\n")
local same = fp == R.LastFP
R.LastFP = fp
return true, data.banners, same
end

	function R.Poke() R.Kicked = true end

	function R.ApplyLocalStyle(raw) -- instant preview of YOUR style on your own banner (the backend poll then confirms it for everyone)
		local st = cleanStyle(raw)
		R.StyleHold = os.clock() + 3
		local e = R.Banners[Env.Player.UserId]
		if e then e.UI:Restyle(st); e.SKey = st and st.key or "" end
	end

	function R.SetHidden(v) -- local-only: hides/shows every banner on this client
		R.Hidden = v and true or false
		if not R.Hidden then R.Poke() end
	end

	function R.Teleport(uid) -- stand 4 studs in front of the player, facing them
		if os.clock() - (R.LastTP or 0) < 0.6 then return end
		local p = Players:GetPlayerByUserId(uid)
		local tr = p and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		local me = Env.GetLocalCharacter() -- reanimated character when active
		if not (tr and me and me.Parent) then return end
		R.LastTP = os.clock()
		pcall(function()
			local pos = tr.Position + tr.CFrame.LookVector * 4
			me:PivotTo(CFrame.lookAt(pos, Vector3.new(tr.Position.X, pos.Y, tr.Position.Z)))
			local r = me:FindFirstChild("HumanoidRootPart")
			if r then r.AssemblyLinearVelocity = Vector3.zero end
		end)
		local e = R.Banners[uid]
		if e then e.UI:Update(e.UI.Opts) end -- pulse feedback
	end


	-- owner / co-owner tools: clicking another script user's banner opens Teleport / Blacklist
	local menu
	function R.CloseMenu() if menu then menu:Destroy(); menu = nil end end
	function R.CanBlacklist()
		local r = roleOf(Env.Player.UserId)
		return r and (r.tag == "OWNER" or r.tag == "CO-OWNER") and Env.Blacklist ~= nil
	end
	local function toast(msg, title)
		pcall(function() game:GetService("StarterGui"):SetCore("SendNotification", {Title = title or "Blacklist", Text = msg, Duration = 4}) end)
	end
	function R.CanModerate() return Env.Mod ~= nil and Env.Mod.CanModerate() end -- verified moderators + owner / co-owner
	function R.OnBannerClick(uid, pt)
		local mod, bl = R.CanModerate(), R.CanBlacklist()
		if not (mod or bl) or not R.CanTarget(uid) then return R.Teleport(uid) end -- owner / co-owner banners, verified banners (unless you are the OWNER) and everyone without rights just teleport
		local p = Players:GetPlayerByUserId(uid)
		if not p then return end
		R.CloseMenu()
		local items = {{"Teleport", Color3.fromRGB(60, 110, 200), function() R.Teleport(uid) end}}
		if mod then table.insert(items, {"Users...", Color3.fromRGB(60, 140, 120), function() R.OpenUsers() end}) end
		if mod then -- moderators: relayed to script users (verified players only when the sender is the OWNER; never owner / co-owner)
			for _, a in ipairs({{"Kill", "kill"}, {"Deanimate", "deanimate"}, {"Kick", "kick"}, {"Bring", "bring"}, {"Hallucinate", "hallucinate"}, {"Dizzy", "dizzy"}, {"Silent Hell", "silenthell"}}) do
				table.insert(items, {a[1], Color3.fromRGB(205, 125, 40), function()
					task.spawn(function()
						local ok, err = Env.Mod.Send(uid, a[2])
						toast(ok and (a[1] .. ": " .. p.Name) or ("failed: " .. tostring(err)), "Moderator")
					end)
				end})
			end
		end
		if bl then -- owner / co-owner only
			table.insert(items, {"Blacklist", Color3.fromRGB(200, 60, 60), function()
				Env.Blacklist.Confirm(uid, p.Name, function(ok, err)
					toast(ok and (p.Name .. " blacklisted") or ("failed: " .. tostring(err)))
				end)
			end})
		end
		local H = 8 + #items * 34
		local gui = Instance.new("ScreenGui")
		gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.IgnoreGuiInset = "UhBannerMenu", false, 900, true
		gui.Parent = Env.Player:WaitForChild("PlayerGui")
		menu = gui
		local f = Instance.new("Frame", gui)
		f.Size, f.BackgroundColor3, f.BorderSizePixel = UDim2.fromOffset(150, H), Color3.fromRGB(24, 24, 30), 0
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
		f.Position = UDim2.fromOffset(math.clamp(pt.X, 0, vp.X - 150), math.clamp(pt.Y, 0, vp.Y - H))
		Instance.new("UICorner", f).CornerRadius = UDim.new(0, 8)
		for i, it in ipairs(items) do
			local b = Instance.new("TextButton", f)
			b.Size, b.Position, b.Text = UDim2.fromOffset(134, 28), UDim2.fromOffset(8, 8 + (i - 1) * 34), it[1]
			b.BackgroundColor3, b.TextColor3, b.Font, b.TextSize = it[2], Color3.new(1, 1, 1), Enum.Font.GothamBold, 14
			Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
			b.Activated:Connect(function() R.CloseMenu(); it[3]() end)
		end
	end

	-- active script users: everyone with a live banner you may moderate (not you, not owner / co-owner; verified moderators only for the OWNER). One tap = Bring / Hallucinate / Dizzy / Silent Hell on that user.
	-- Same single permission check as the tap-a-banner menu (R.CanModerate = owner / co-owner / verified); the backend checks the sender again.
	local picker
	function R.CloseUsers() if picker then picker:Destroy(); picker = nil end end
	function R.OpenUsers()
		R.CloseUsers()
		if not R.CanModerate() then return end
		local gui = Instance.new("ScreenGui")
		gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.IgnoreGuiInset = "UhBannerUsers", false, 901, true
		gui.Parent = Env.Player:WaitForChild("PlayerGui")
		picker = gui
		local f = Instance.new("Frame", gui)
		f.Size, f.Position, f.BackgroundColor3, f.BorderSizePixel = UDim2.fromOffset(440, 270), UDim2.new(0.5, -220, 0.5, -135), Color3.fromRGB(24, 24, 30), 0
		Instance.new("UICorner", f).CornerRadius = UDim.new(0, 8)
		local t = Instance.new("TextLabel", f)
		t.Size, t.Position, t.BackgroundTransparency, t.Text = UDim2.new(1, -44, 0, 28), UDim2.fromOffset(10, 4), 1, "Active script users"
		t.TextColor3, t.Font, t.TextSize, t.TextXAlignment = Color3.new(1, 1, 1), Enum.Font.GothamBold, 14, Enum.TextXAlignment.Left
		local x = Instance.new("TextButton", f)
		x.Size, x.Position, x.Text = UDim2.fromOffset(26, 24), UDim2.new(1, -34, 0, 6), "X"
		x.BackgroundColor3, x.TextColor3, x.Font, x.TextSize = Color3.fromRGB(70, 70, 80), Color3.new(1, 1, 1), Enum.Font.GothamBold, 13
		Instance.new("UICorner", x).CornerRadius = UDim.new(0, 6)
		x.Activated:Connect(R.CloseUsers)
		local list = Instance.new("ScrollingFrame", f)
		list.Size, list.Position, list.BackgroundTransparency, list.BorderSizePixel = UDim2.new(1, -16, 1, -44), UDim2.fromOffset(8, 36), 1, 0
		list.ScrollBarThickness, list.AutomaticCanvasSize, list.CanvasSize = 4, Enum.AutomaticSize.Y, UDim2.new()
		Instance.new("UIListLayout", list).Padding = UDim.new(0, 4)
		local n = 0
		for uid in pairs(R.Banners) do
			local p = Players:GetPlayerByUserId(uid)
			if p and R.CanTarget(uid) then
				n += 1
				local row = Instance.new("Frame", list)
				row.Size, row.BackgroundTransparency = UDim2.new(1, -6, 0, 30), 1
				local nm = Instance.new("TextLabel", row)
				nm.Size, nm.BackgroundTransparency, nm.Text = UDim2.new(0, 92, 1, 0), 1, p.DisplayName
				nm.TextColor3, nm.Font, nm.TextSize, nm.TextXAlignment, nm.TextTruncate = Color3.new(1, 1, 1), Enum.Font.GothamMedium, 13, Enum.TextXAlignment.Left, Enum.TextTruncate.AtEnd
				for i, a in ipairs({{"Bring", "bring"}, {"Hallucinate", "hallucinate"}, {"Dizzy", "dizzy"}, {"Silent Hell", "silenthell"}}) do
					local b = Instance.new("TextButton", row)
					b.Size, b.Position, b.Text = UDim2.fromOffset(78, 28), UDim2.fromOffset(92 + (i - 1) * 80, 1), a[1]
					b.BackgroundColor3, b.TextColor3, b.Font, b.TextSize = Color3.fromRGB(60, 110, 200), Color3.new(1, 1, 1), Enum.Font.GothamBold, 11
					Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
					b.Activated:Connect(function()
						local why = R.Block("mod")
						if why then return toast(why, "Moderator") end
						task.spawn(function()
							local ok, err = Env.Mod.Send(uid, a[2])
							toast(ok and (a[1] .. ": " .. p.Name) or ("failed: " .. tostring(err)), "Moderator")
						end)
					end)
				end
			end
		end
		if n == 0 then
			local e = Instance.new("TextLabel", list)
			e.Size, e.BackgroundTransparency, e.Text = UDim2.new(1, 0, 0, 30), 1, "No other script users active"
			e.TextColor3, e.Font, e.TextSize = Color3.fromRGB(170, 170, 180), Enum.Font.Gotham, 13
		end
	end

	-- inline buttons next to a banner (Kill / Deanimate / Kick / Ban). Permissions are re-checked at click time, so a stale button can never do more than the
	-- viewer is allowed to: Kill / Deanimate / Kick go through ModTools.Send (the backend checks the moderator list again), Ban goes through the Yes/No
	-- blacklist dialog (owner / co-owner only; the blacklisted client kicks itself). Kick needs a second tap ("Sure?") so a stray tap can't remove someone.
	function R.Block(key) -- nil when the button can run, else the reason it can't. Nobody needs a key: owner / co-owner and verified moderators are recognised by userId.
		if not Env.Request then return "executor has no request()" end
		if key == "ban" then
			if not Env.Blacklist then return "Blacklist module failed to load" end
		else
			if not Env.Mod then return "ModTools module failed to load" end
		end
	end
	local kickArm -- {uid, expires} while a Kick button is waiting for its confirming tap
	function R.DisarmKick()
		local a = kickArm
		kickArm = nil
		local e = a and R.Banners[a.uid]
		if e then e.UI:SetAction("kick") end
	end
	function R.OnAction(uid, key)
		local p, e = Players:GetPlayerByUserId(uid), R.Banners[uid]
		if not (p and e) then return end
		local allowed
		for _, a in ipairs(actionsFor(uid) or {}) do if a.key == key then allowed = a end end
		if not allowed then return end
		R.CloseMenu()
		local why = R.Block(key)
		if why then return toast(why, "Moderator") end
		if key == "ban" then
			e.UI:PulseAction(key)
			return Env.Blacklist.Confirm(uid, p.Name, function(ok, err)
				toast(ok and (p.Name .. " blacklisted") or ("failed: " .. tostring(err)))
			end)
		end
		if key == "kick" and not (kickArm and kickArm.uid == uid and os.clock() < kickArm.expires) then -- first tap: arm the button, don't send anything yet
			R.DisarmKick()
			local arm = {uid = uid, expires = os.clock() + 2.5}
			kickArm = arm
			e.UI:SetAction("kick", "Sure?", Color3.fromRGB(190, 50, 60))
			task.delay(2.6, function() if kickArm == arm then R.DisarmKick() end end)
			return
		end
		if key == "kick" then R.DisarmKick() end -- second tap within 2.5 s: confirmed
		e.UI:PulseAction(key)
		task.spawn(function()
			local ok, err = Env.Mod.Send(uid, key)
			toast(ok and (allowed.label .. ": " .. p.Name) or ("failed: " .. tostring(err)), "Moderator")
		end)
	end

	function R.Start(localOnly)
		if R.Running then return end
		if not localOnly and not Env.Request then return warn("[UhBanner] executor has no request(); live sync unavailable") end
		R.Running = true
		task.spawn(function() -- whitelist.json: read now, then every 60s so edits on GitHub apply without rejoining
			while R.Running do
				fetchRoles()
				fetchWhitelist()
				local waited = 0
				while R.Running and waited < 60 do task.wait(1); waited += 1 end
			end
		end)
		table.insert(conns, RS.Heartbeat:Connect(function() -- re-anchor: a cached part is revalidated with Name + IsDescendantOf; the full lookup only runs for the local player (reanim start/stop) or a stale / unresolved part (respawn)
			local hidden, me = R.Hidden, Env.Player.UserId
			for uid, e in pairs(R.Banners) do
				local part = e.Part
				if hidden then
					part = nil
				elseif uid == me or not part or part.Name ~= "Head" or not part:IsDescendantOf(workspace) then
					part = targetPart(uid)
				end
				if part ~= e.Part then e.Part = part; e.UI:SetAdornee(part) end
			end
		end))
		table.insert(conns, Players.PlayerRemoving:Connect(function(p) remove(p.UserId) end))
		if Env.UserInputService and Env.GuiService then -- tap/click another player's banner -> teleport in front of them
			table.insert(conns, Env.UserInputService.InputBegan:Connect(function(i, gp)
				local t = i.UserInputType
				if gp or R.Hidden or (t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch) then return end
				R.CloseMenu()
				local pt = Vector2.new(i.Position.X, i.Position.Y) + Env.GuiService:GetGuiInset()
				-- every banner under the tap competes; the NEAREST one is drawn on top and alone gets the tap, so a button / card can never be credited to another player's banner.
				-- The winner's own userId (the R.Banners key) travels with its button key into R.OnAction.
				local bestUid, bestKey, bestZ
				for uid, e in pairs(R.Banners) do
					local kind, key, z = e.UI:HitTest(pt)
					if kind and (not bestZ or z < bestZ) then bestUid, bestKey, bestZ = uid, (kind == "act" and key or nil), z end
				end
				if not bestUid or bestUid == Env.Player.UserId then return end -- nothing hit, or your own (nearer) banner covers the spot
				if bestKey then return R.OnAction(bestUid, bestKey) end
				return R.OnBannerClick(bestUid, pt)
			end))
		end
		if localOnly then return end
task.spawn(function()
local fails, calm = 0, 0
while R.Running do
if R.Hidden and not R.Kicked then
task.wait(0.5) -- banners hidden locally: no polling until re-enabled (SetHidden pokes)
else
R.Kicked = false
local okF, ok, list, same, st = pcall(R.Fetch)
if not okF then ok = false end
local wait
if ok then
fails = 0
pcall(R.Process, list)
calm = same and math.min(calm + 1, 3) or 0
wait = ({2, 3, 4, 6})[calm + 1] -- unchanged answers stretch the poll: 2 / 3 / 4 / 6 s
else
fails += 1
wait = math.min(2 * 2 ^ fails, 30) -- exponential failure backoff
if st == 429 then wait = math.max(wait, 20) end
end
wait += math.random()
local waited = 0
while R.Running and waited < wait and not R.Kicked do task.wait(0.25); waited += 0.25 end
end
end
end)
	end

	function R.Stop()
		R.Running = false
		R.CloseMenu()
		R.CloseUsers()
		for _, c in ipairs(conns) do c:Disconnect() end
		conns = {}
		for uid, e in pairs(R.Banners) do e.UI:Destroy(false); R.Banners[uid] = nil end
	end

	return R
end
