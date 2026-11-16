-- Blacklist.lua | loads the blacklist from the backend (GET /blacklist, falls back to blacklist.json in the repo); lets OWNER / CO-OWNER add + remove entries (Yes/No warning each time)
-- Usage (main script, after Env is built):  local BL = loadstring(game:HttpGet(Base .. "Blacklist.lua"))()(Env)
-- Env needs: Player, Players, HttpService, Request, Base, Backend (owner / co-owner recognised by userId from roles.json on GitHub, no key)
-- A blacklisted client kicks itself: "BLACKLISTED by the owner / co-owner" (checked at startup + every few seconds by B.Watch)
return function(Env)
	local B = {List = {}, Official = "uh-mod-visual-system"}
	local function roleOfEntry(e) -- which rank blacklisted them: looked up in roles.json (Env.Roles), nothing hardcoded
		local RL = Env.Roles
		if not (RL and e) then return nil end
		return RL.ById[math.floor(tonumber(e.byId) or 0)] or (e.by and RL.ByName[tostring(e.by):lower()]) or nil
	end

	function B.Fetch()
		if B.Fresh and os.clock() - B.Fresh < 15 then return true end -- keep the list the backend just returned
		local data
		for _, url in ipairs({Env.Backend .. "/blacklist?t=" .. os.time(), Env.Base .. "blacklist.json?t=" .. os.time()}) do -- backend first (no GitHub token involved), repo file as fallback
			local ok, body = pcall(function() return game:HttpGet(url) end)
			if ok and type(body) == "string" then
				local ok2, d = pcall(Env.HttpService.JSONDecode, Env.HttpService, body)
				if ok2 and type(d) == "table" and type(d.entries) == "table" then data = d; break end
			end
		end
		if not data then return false end
		B.List = data.entries; B.Fresh = os.clock()
		return true
	end

	function B.Is(userId)
		for _, e in ipairs(B.List) do
			if tonumber(e.userId) == userId then return true, e end
		end
		return false
	end

	function B.KickText(e)
		local who = roleOfEntry(e) or "owner/co-owner"
		return "BLACKLISTED by the " .. who
	end

	function B.Enforce() -- kicks the local player when listed
		local hit, e = B.Is(Env.Player.UserId)
		if hit then pcall(function() Env.Player:Kick(B.KickText(e)) end) end
		return hit
	end

	-- call first thing on startup: returns true when the local player may NOT use the script
	function B.CheckSelf()
		B.Fetch()
		local hit, e = B.Is(Env.Player.UserId)
		if hit then warn("[Blacklist] you are blacklisted from this script" .. (e.reason and (": " .. tostring(e.reason)) or "")); B.Enforce() end
		return hit
	end

	function B.Watch() -- live enforcement: blacklisted while already running -> kicked
		if B.Watching then return end
		B.Watching = true
		task.spawn(function()
			local rounds = 0
			while B.Watching do
				for _ = 1, 80 do if not B.Watching then return end task.wait(0.25) end
				if B.Fetch() then B.Enforce() end
				rounds += 1
				if rounds % 15 == 0 and Env.Guard and Env.Guard.Recheck then pcall(Env.Guard.Recheck) end -- device ban / backend handshake re-check about every 5 min (a failed request never bans anyone)
			end
		end)
	end

	local function post(path, extra)
		if not Env.Request then return false, "executor has no request()" end
		if not (Env.IsOwner and Env.IsOwner()) then return false, "owner / co-owner only" end
		local body = {room = Env.Room, by = Env.Player.Name, byId = Env.Player.UserId}
		for k, v in pairs(extra) do body[k] = v end
		if body.banDevice or path:sub(1, 8) == "/device/" then -- permanent device bans also need the owner secret set on the backend (read from UhBannerConfig.OwnerKey, never stored in this script)
			local okC, c = pcall(function() return (getgenv and getgenv().UhBannerConfig or {}).OwnerKey end)
			if okC and type(c) == "string" and c ~= "" then body.key = c end
		end
		if Env.Sign then Env.Sign(path, body, tostring(extra.userId)) end
		local ok, res = pcall(Env.Request, {
			Url = Env.Backend .. path, Method = "POST",
			Headers = {["Content-Type"] = "application/json"},
			Body = Env.HttpService:JSONEncode(body),
		})
		if not ok then return false, tostring(res) end
		local okJ, data = pcall(Env.HttpService.JSONDecode, Env.HttpService, type(res) == "table" and res.Body or "")
		if not okJ or type(data) ~= "table" then data = nil end
		if type(res) ~= "table" or res.StatusCode ~= 200 then return false, "HTTP " .. tostring(type(res) == "table" and res.StatusCode) .. ((data and data.error) and (": " .. tostring(data.error)) or "") end
		if data and type(data.entries) == "table" then B.List = data.entries; B.Fresh = os.clock() else B.Fetch() end -- the backend returns the new list: use it
		return true, nil, data
	end

	function B.Add(userId, username, reason, banDevice) -- banDevice: also ban the account's device(s) permanently (owner secret required on the backend)
		return post("/blacklist", {userId = userId, username = username, reason = reason or "", banDevice = banDevice == true or nil})
	end

	function B.Remove(userId) -- unblacklist (mistakes); a device ban is NOT lifted by this, it needs B.DeviceUnban
		return post("/unblacklist", {userId = userId})
	end

	function B.DeviceUnban(userId) -- explicit, owner-authorised removal of the permanent device ban(s) recorded for an account
		return post("/device/unban", {userId = userId})
	end

	local function toast(msg)
		pcall(function() game:GetService("StarterGui"):SetCore("SendNotification", {Title = "Blacklist", Text = msg, Duration = 4}) end)
	end

	-- Yes/No warning dialog. cb runs only on "Yes".
	local function dialog(text, cb, cb2, label2)
		local gui = Instance.new("ScreenGui")
		gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "UhBlacklistConfirm", false, 1000
		gui.Parent = Env.Player:WaitForChild("PlayerGui")
		local f = Instance.new("Frame", gui)
		f.Size, f.Position, f.AnchorPoint = UDim2.fromOffset(300, cb2 and 180 or 150), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5)
		f.BackgroundColor3, f.BorderSizePixel = Color3.fromRGB(24, 24, 30), 0
		Instance.new("UICorner", f).CornerRadius = UDim.new(0, 10)
		local t = Instance.new("TextLabel", f)
		t.Size, t.Position, t.BackgroundTransparency = UDim2.new(1, -20, 0, cb2 and 114 or 84), UDim2.fromOffset(10, 8), 1
		t.TextWrapped, t.TextColor3, t.Font, t.TextSize = true, Color3.new(1, 1, 1), Enum.Font.GothamMedium, 14
		t.Text = text
		local function btn(txt, x, w, col, fn)
			local b = Instance.new("TextButton", f)
			b.Size, b.Position, b.Text = UDim2.fromOffset(w, 36), UDim2.fromOffset(x, cb2 and 130 or 100), txt
			b.BackgroundColor3, b.TextColor3, b.Font, b.TextSize = col, Color3.new(1, 1, 1), Enum.Font.GothamBold, (w < 120) and 13 or 15
			Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
			b.Activated:Connect(function() gui:Destroy(); fn() end)
		end
		if cb2 then
			btn("Yes", 10, 84, Color3.fromRGB(200, 60, 60), cb)
			btn(label2 or "Yes + Device", 100, 110, Color3.fromRGB(150, 40, 40), cb2)
			btn("No", 216, 74, Color3.fromRGB(70, 70, 80), function() end)
		else
			btn("Yes", 15, 130, Color3.fromRGB(200, 60, 60), cb)
			btn("No", 155, 130, Color3.fromRGB(70, 70, 80), function() end)
		end
	end

	-- onDone(ok, err) is called after the request finishes (not called on "No").
	function B.Confirm(userId, username, onDone)
		local function go(withDevice)
			task.spawn(function()
				local ok, err, data = B.Add(userId, username, nil, withDevice)
				if onDone then onDone(ok, err) end
				if ok and withDevice then
					local d = data and data.device
					local st = d and d.status
					toast(st == "banned" and "Device ban applied" or st == "pending" and "No device on record yet: it is banned the next time this account launches the script" or st == "protected" and "Device ban skipped: that device is shared with an owner / moderator account" or ("Device ban not applied" .. ((d and d.error) and (": " .. tostring(d.error)) or "")))
				end
			end)
		end
		dialog(("WARNING\nBlacklist %s (@%s)?\nThey will be blocked from using this script and kicked from the game.\n\"Yes + Device\" also bans their device permanently."):format(username, username), function() go(false) end, function() go(true) end)
	end

	function B.ConfirmRemove(userId, username, onDone)
		dialog(("Unblacklist %s (@%s)?\nThey will be able to use this script again."):format(username, username), function()
			task.spawn(function()
				local ok, err = B.Remove(userId)
				if onDone then onDone(ok, err) end
			end)
		end)
	end

	function B.ConfirmDeviceRemove(userId, username, onDone)
		dialog(("Remove the permanent device ban recorded for %s (@%s)?\nThe account blacklist stays as it is."):format(username, username), function()
			task.spawn(function()
				local ok, err = B.DeviceUnban(userId)
				if onDone then onDone(ok, err) end
			end)
		end)
	end

	-- list of blacklisted players with an Unblacklist button each (owner / co-owner)
	function B.ClosePanel() if B.Panel then B.Panel:Destroy(); B.Panel = nil end end
	function B.OpenPanel()
		B.ClosePanel()
		task.spawn(function()
			B.Fetch()
			local gui = Instance.new("ScreenGui")
			gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "UhBlacklistPanel", false, 999
			gui.Parent = Env.Player:WaitForChild("PlayerGui")
			B.Panel = gui
			local f = Instance.new("Frame", gui)
			f.Size, f.Position, f.AnchorPoint = UDim2.fromOffset(380, 300), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5)
			f.BackgroundColor3, f.BorderSizePixel = Color3.fromRGB(24, 24, 30), 0
			Instance.new("UICorner", f).CornerRadius = UDim.new(0, 10)
			local t = Instance.new("TextLabel", f)
			t.Size, t.Position, t.BackgroundTransparency = UDim2.new(1, -60, 0, 30), UDim2.fromOffset(12, 6), 1
			t.Text, t.TextColor3, t.Font, t.TextSize, t.TextXAlignment = ("Blacklist (%d)"):format(#B.List), Color3.new(1, 1, 1), Enum.Font.GothamBold, 16, Enum.TextXAlignment.Left
			local x = Instance.new("TextButton", f)
			x.Size, x.Position, x.Text = UDim2.fromOffset(30, 26), UDim2.new(1, -40, 0, 8), "X"
			x.BackgroundColor3, x.TextColor3, x.Font, x.TextSize = Color3.fromRGB(70, 70, 80), Color3.new(1, 1, 1), Enum.Font.GothamBold, 14
			Instance.new("UICorner", x).CornerRadius = UDim.new(0, 6)
			x.Activated:Connect(B.ClosePanel)
			local sc = Instance.new("ScrollingFrame", f)
			sc.Size, sc.Position, sc.BackgroundTransparency, sc.BorderSizePixel = UDim2.new(1, -20, 1, -50), UDim2.fromOffset(10, 40), 1, 0
			sc.ScrollBarThickness, sc.CanvasSize, sc.AutomaticCanvasSize = 4, UDim2.new(), Enum.AutomaticSize.Y
			local lay = Instance.new("UIListLayout", sc)
			lay.Padding, lay.SortOrder = UDim.new(0, 6), Enum.SortOrder.LayoutOrder
			if #B.List == 0 then
				local e = Instance.new("TextLabel", sc)
				e.Size, e.BackgroundTransparency, e.Text, e.TextColor3, e.Font, e.TextSize = UDim2.new(1, 0, 0, 30), 1, "Nobody is blacklisted", Color3.fromRGB(170, 170, 180), Enum.Font.Gotham, 14
			end
			for i, e in ipairs(B.List) do
				local uid, name = tonumber(e.userId), tostring(e.username or e.userId)
				local row = Instance.new("Frame", sc)
				row.Size, row.BackgroundColor3, row.BorderSizePixel, row.LayoutOrder = UDim2.new(1, -6, 0, 38), Color3.fromRGB(34, 34, 42), 0, i
				Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
				local l = Instance.new("TextLabel", row)
				l.Size, l.Position, l.BackgroundTransparency, l.Text = UDim2.new(1, -200, 1, 0), UDim2.fromOffset(10, 0), 1, name
				l.TextColor3, l.Font, l.TextSize, l.TextXAlignment, l.TextTruncate = Color3.new(1, 1, 1), Enum.Font.GothamMedium, 13, Enum.TextXAlignment.Left, Enum.TextTruncate.AtEnd
				local u = Instance.new("TextButton", row)
				u.Size, u.Position, u.Text = UDim2.fromOffset(100, 26), UDim2.new(1, -106, 0.5, -13), "Unblacklist"
				u.BackgroundColor3, u.TextColor3, u.Font, u.TextSize = Color3.fromRGB(60, 140, 90), Color3.new(1, 1, 1), Enum.Font.GothamBold, 12
				Instance.new("UICorner", u).CornerRadius = UDim.new(0, 6)
				u.Activated:Connect(function()
					if not uid then return end
					B.ConfirmRemove(uid, name, function(ok, err)
						toast(ok and (name .. " unblacklisted") or ("failed: " .. tostring(err)))
						if ok and B.Panel then B.OpenPanel() end
					end)
				end)
				local dv = Instance.new("TextButton", row)
				dv.Size, dv.Position, dv.Text = UDim2.fromOffset(88, 26), UDim2.new(1, -198, 0.5, -13), "Unban device"
				dv.BackgroundColor3, dv.TextColor3, dv.Font, dv.TextSize = Color3.fromRGB(150, 110, 40), Color3.new(1, 1, 1), Enum.Font.GothamBold, 11
				Instance.new("UICorner", dv).CornerRadius = UDim.new(0, 6)
				dv.Activated:Connect(function()
					if not uid then return end
					B.ConfirmDeviceRemove(uid, name, function(ok, err) toast(ok and "Device ban removed" or ("failed: " .. tostring(err))) end)
				end)
			end
		end)
	end

	-- small "Blacklist" button (owner / co-owner) that opens the panel
	function B.ShowPill()
		if B.PillGui then return end
		local gui = Instance.new("ScreenGui")
		gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.IgnoreGuiInset = "UhBlacklistCtl", false, 50, true
		gui.Parent = Env.Player:WaitForChild("PlayerGui")
		B.PillGui = gui
		local b = Instance.new("TextButton", gui)
		b.AnchorPoint, b.Position, b.Size, b.Text = Vector2.new(0, 0.5), UDim2.new(0, 8, 0.5, 38), UDim2.fromOffset(118, 30), "Blacklist (unban)"
		b.BackgroundColor3, b.TextColor3, b.Font, b.TextSize, b.BorderSizePixel = Color3.fromRGB(24, 24, 30), Color3.new(1, 1, 1), Enum.Font.GothamBold, 12, 0
		Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0)
		local s = Instance.new("UIStroke", b)
		s.Thickness, s.Color = 1.5, Color3.fromRGB(200, 60, 60)
		b.Activated:Connect(B.OpenPanel)
	end

	function B.Stop()
		B.Watching = false
		B.ClosePanel()
		if B.PillGui then B.PillGui:Destroy(); B.PillGui = nil end
	end

	return B
end
