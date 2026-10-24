-- BannerReceiver.lua | polls the backend, sanitises banner data, one banner per player, follows respawns
return function(Env, UI)
	local Players, RS, HS = Env.Players, Env.RunService, Env.HttpService
	local R = {Banners = {}, Running = false, Kicked = false}
	local conns, thumbs = {}, {}

	-- Verified users, matched by userId (resolved once from the username; until then the REAL in-game name is used, never the sent payload).
	-- tag = rank chip text, logo = rotating 3D triangle, color = accent override. An entry of {} = plain verified (check badge only).
	local VERIFIED = {
		kingbaconnon19 = {tag = "OWNER", logo = true, color = Color3.fromRGB(255, 190, 50)},
		hellii129 = {tag = "CO-OWNER", color = Color3.fromRGB(170, 120, 255)},
	}
	local roleIds, resolved = {}, {}
	for name, r in pairs(VERIFIED) do
		task.spawn(function()
			local ok, id = pcall(Players.GetUserIdFromNameAsync, Players, name)
			if ok and id then roleIds[id] = r; resolved[name] = true end
		end)
	end
	local function roleOf(uid)
		if roleIds[uid] then return roleIds[uid] end
		local p = Players:GetPlayerByUserId(uid)
		local n = p and p.Name:lower()
		if n and VERIFIED[n] and not resolved[n] then return VERIFIED[n] end
	end

	local function clean(s, n) return (tostring(s or ""):gsub("%c", "")):sub(1, n) end
	local function headshot(uid)
		if thumbs[uid] == nil then
			local ok, url = pcall(Players.GetUserThumbnailAsync, Players, uid, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
			thumbs[uid] = ok and url or ""
		end
		return thumbs[uid]
	end
	local function sanitize(uid, d)
		local img = tostring(d.image or "")
		if img:match("^%d+$") then img = "rbxassetid://" .. img elseif not img:match("^rbxassetid://%d+$") then img = "" end
		if img == "" then img = headshot(uid) end
		local name = clean(d.name, 40)
		local title = clean(d.title, 40)
		return {userId = uid, title = title ~= "" and title or name, subtitle = clean(d.subtitle, 40), image = img, role = roleOf(uid)}
	end
	local function sig(o) return o.title .. "|" .. o.subtitle .. "|" .. o.image .. "|" .. (o.role and (o.role.tag or "v") or "") end

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
				local e = R.Banners[uid]
				if not e then
					R.Banners[uid] = {UI = UI.new(o), Sig = sig(o), Role = o.role}
				elseif e.Role ~= o.role then -- rank changed (username just resolved): rebuild
					e.UI:Destroy(false); R.Banners[uid] = {UI = UI.new(o), Sig = sig(o), Role = o.role}
				elseif e.Sig ~= sig(o) then
					e.UI:Update(o); e.Sig = sig(o)
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
				local pt = Vector2.new(i.Position.X, i.Position.Y) + Env.GuiService:GetGuiInset()
				for uid, e in pairs(R.Banners) do
					if uid ~= Env.Player.UserId and e.UI:Contains(pt) then return R.Teleport(uid) end
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
		for _, c in ipairs(conns) do c:Disconnect() end
		conns = {}
		for uid, e in pairs(R.Banners) do e.UI:Destroy(false); R.Banners[uid] = nil end
	end

	return R
end
