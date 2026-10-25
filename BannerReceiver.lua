-- BannerReceiver.lua | polls the backend, sanitises banner data, one banner per player, follows respawns
return function(Env, UI)
	local Players, RS, HS = Env.Players, Env.RunService, Env.HttpService
	local R = {Banners = {}, Running = false, Kicked = false}
	local conns, thumbs = {}, {}

	-- Verified users, matched by userId (resolved once from the username; until then the REAL in-game name is used, never the sent payload).
	-- tag = rank chip text, logo = rotating 3D triangle, color = accent override. An entry of {} = plain verified (check badge only).
	local VERIFIED = {
		kingbaconnon19 = {tag = "OWNER", logo = true, color = Color3.fromRGB(255, 190, 50)},
		helloman1_23 = {tag = "CO-OWNER", color = Color3.fromRGB(170, 120, 255)},
		-- moderator whitelist (plain "Verified" banner, check badge only; they can kick / kill / deanimate misusing script users).
		-- A whitelisted account only becomes Verified after it redeems a one-time key in the main UI ("VERIFIED KEY"). One per line, lower-case username:
		-- exampleusername = {},
	}
	local roleIds, resolved = {}, {}
	for name, r in pairs(VERIFIED) do
		task.spawn(function()
			local ok, id = pcall(Players.GetUserIdFromNameAsync, Players, name)
			if ok and id then roleIds[id] = r; resolved[name] = true end
		end)
	end
	local confirmed = {} -- userIds the backend says have redeemed a verified key (set from each /banners poll)
	local function rawRole(uid) -- whitelisted by username (protected from kill / kick / blacklist), key or not
		if roleIds[uid] then return roleIds[uid] end
		local p = Players:GetPlayerByUserId(uid)
		local n = p and p.Name:lower()
		if n and VERIFIED[n] and not resolved[n] then return VERIFIED[n] end
	end
	local function roleOf(uid) -- OWNER / CO-OWNER always; plain "Verified" moderators only once their key is redeemed
		local r = rawRole(uid)
		if r and not r.tag and not confirmed[uid] then return nil end
		return r
	end
	function R.IsWhitelisted(uid) return rawRole(uid) ~= nil end
	function R.SetVerified(uid) confirmed[uid] = true end

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
	local function actionsFor(uid) -- the buttons THIS viewer may use on that player's banner; nothing on yourself, and nothing on verified / owner / co-owner (they are immune)
		if uid == Env.Player.UserId or rawRole(uid) then return nil end
		local mod = R.CanModerate and R.CanModerate()
		local bl = R.CanBlacklist and R.CanBlacklist()
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
				confirmed[uid] = d.verified == true
				local o = sanitize(uid, d)
				local sk = o.style and o.style.key or ""
				local e = R.Banners[uid]
				if not e then
					R.Banners[uid] = {UI = UI.new(o), Sig = sig(o), SKey = sk, Role = o.role, ActKey = o.actKey}
				elseif e.Role ~= o.role or e.ActKey ~= o.actKey then -- rank / moderation rights changed (username just resolved, key redeemed): rebuild
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
		if not ok or type(res) ~= "table" or res.StatusCode ~= 200 then return false end
		local ok2, data = pcall(HS.JSONDecode, HS, res.Body)
		if not ok2 or type(data) ~= "table" or type(data.banners) ~= "table" then return false end
		return true, data.banners
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
		return r and (r.tag == "OWNER" or r.tag == "CO-OWNER") and Env.Blacklist ~= nil and Env.OwnerKey ~= nil and Env.OwnerKey ~= ""
	end
	local function toast(msg, title)
		pcall(function() game:GetService("StarterGui"):SetCore("SendNotification", {Title = title or "Blacklist", Text = msg, Duration = 4}) end)
	end
	function R.CanModerate() return Env.Mod ~= nil and Env.Mod.CanModerate() end -- verified moderators + owner / co-owner
	function R.OnBannerClick(uid, pt)
		local mod, bl = R.CanModerate(), R.CanBlacklist()
		if not (mod or bl) or rawRole(uid) then return R.Teleport(uid) end -- whitelisted / verified / owner banners (and everyone without rights) just teleport
		local p = Players:GetPlayerByUserId(uid)
		if not p then return end
		R.CloseMenu()
		local items = {{"Teleport", Color3.fromRGB(60, 110, 200), function() R.Teleport(uid) end}}
		if mod then -- moderators: kick / kill / deanimate only (relayed to script users, never to verified players)
			for _, a in ipairs({{"Kill", "kill"}, {"Deanimate", "deanimate"}, {"Kick", "kick"}}) do
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

	-- inline buttons next to a banner (Kill / Deanimate / Kick / Ban). Permissions are re-checked at click time, so a stale button can never do more than the
	-- viewer is allowed to: Kill / Deanimate / Kick go through ModTools.Send (the backend checks the moderator key again), Ban goes through the Yes/No
	-- blacklist dialog (owner / co-owner only; the blacklisted client kicks itself). Kick needs a second tap ("Sure?") so a stray tap can't remove someone.
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
		if os.clock() - (R.LastAct or 0) < 1.6 then return toast("slow down a little", "Moderator") end -- the backend allows one command per ~1.5 s per moderator (an armed Kick stays armed)
		if key == "kick" then R.DisarmKick() end -- second tap within 2.5 s: confirmed
		R.LastAct = os.clock()
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
		table.insert(conns, RS.Heartbeat:Connect(function() -- re-anchor every frame: handles respawns / reanim start+stop
			for uid, e in pairs(R.Banners) do
				local part = not R.Hidden and targetPart(uid) or nil
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
				for uid, e in pairs(R.Banners) do
					if uid ~= Env.Player.UserId then
						local key = e.ActKey ~= "" and e.UI:HitAction(pt) -- inline moderation buttons beside the banner
						if key then return R.OnAction(uid, key) end
						if e.UI:Contains(pt) then return R.OnBannerClick(uid, pt) end
					end
				end
			end))
		end
		if localOnly then return end
		task.spawn(function()
			local fails = 0
			while R.Running do
				local ok, list = R.Fetch()
				if ok then fails = 0; pcall(R.Process, list) else fails += 1 end
				local wait, waited = math.min(2 + fails * 2, 12), 0
				while R.Running and waited < wait and not R.Kicked do task.wait(0.25); waited += 0.25 end
				R.Kicked = false
			end
		end)
	end

	function R.Stop()
		R.Running = false
		R.CloseMenu()
		for _, c in ipairs(conns) do c:Disconnect() end
		conns = {}
		for uid, e in pairs(R.Banners) do e.UI:Destroy(false); R.Banners[uid] = nil end
	end

	return R
end
