-- BannerReceiver.lua | polls the backend, sanitises banner data, one banner per player, follows respawns
return function(Env, UI)
	local Players, RS, HS = Env.Players, Env.RunService, Env.HttpService
	local R = {Banners = {}, Running = false, Kicked = false}
	local conns, thumbs = {}, {}

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
		return {userId = uid, title = title ~= "" and title or name, subtitle = clean(d.subtitle, 40), image = img}
	end
	local function sig(o) return o.title .. "|" .. o.subtitle .. "|" .. o.image end

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
					R.Banners[uid] = {UI = UI.new(o), Sig = sig(o)}
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

	function R.Start(localOnly)
		if R.Running then return end
		if not localOnly and not Env.Request then return warn("[UhBanner] executor has no request(); live sync unavailable") end
		R.Running = true
		table.insert(conns, RS.Heartbeat:Connect(function() -- re-anchor every frame: handles respawns / reanim start+stop
			for uid, e in pairs(R.Banners) do
				local part = targetPart(uid)
				if part ~= e.Part then e.Part = part; e.UI:SetAdornee(part) end
			end
		end))
		table.insert(conns, Players.PlayerRemoving:Connect(function(p) remove(p.UserId) end))
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
