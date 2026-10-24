-- Blacklist.lua | loads blacklist.json from the repo; lets OWNER / CO-OWNER add + remove entries (Yes/No warning each time)
-- Usage (main script, after Env is built):  local BL = loadstring(game:HttpGet(Base .. "Blacklist.lua"))()(Env)
-- Env needs: Player, Players, HttpService, Request, Base, Backend, OwnerKey (owner/co-owner only, from getgenv().UhBannerConfig.OwnerKey)
-- A blacklisted client kicks itself: "BLACKLISTED by the owner / co-owner" (checked at startup + every few seconds by B.Watch)
return function(Env)
	local B = {List = {}}
	local ROLE_BY_NAME = {kingbaconnon19 = "owner", hellii129 = "co-owner"}

	function B.Fetch()
		local ok, body = pcall(function() return game:HttpGet(Env.Base .. "blacklist.json?t=" .. os.time()) end)
		if not ok then return false end
		local ok2, data = pcall(Env.HttpService.JSONDecode, Env.HttpService, body)
		if not ok2 or type(data) ~= "table" or type(data.entries) ~= "table" then return false end
		B.List = data.entries
		return true
	end

	function B.Is(userId)
		for _, e in ipairs(B.List) do
			if tonumber(e.userId) == userId then return true, e end
		end
		return false
	end

	function B.KickText(e)
		local who = e and e.by and ROLE_BY_NAME[tostring(e.by):lower()] or "owner/co-owner"
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
			while B.Watching do
				for _ = 1, 32 do if not B.Watching then return end task.wait(0.25) end
				if B.Fetch() then B.Enforce() end
			end
		end)
	end

	local function post(path, extra)
		if not Env.Request then return false, "executor has no request()" end
		if not Env.OwnerKey or Env.OwnerKey == "" then return false, "owner / co-owner only" end
		local body = {key = Env.OwnerKey, by = Env.Player.Name, byId = Env.Player.UserId}
		for k, v in pairs(extra) do body[k] = v end
		local ok, res = pcall(Env.Request, {
			Url = Env.Backend .. path, Method = "POST",
			Headers = {["Content-Type"] = "application/json"},
			Body = Env.HttpService:JSONEncode(body),
		})
		if not ok then return false, tostring(res) end
		if type(res) ~= "table" or res.StatusCode ~= 200 then return false, "HTTP " .. tostring(type(res) == "table" and res.StatusCode) end
		B.Fetch()
		return true
	end

	function B.Add(userId, username, reason)
		return post("/blacklist", {userId = userId, username = username, reason = reason or ""})
	end

	function B.Remove(userId) -- unblacklist (mistakes)
		return post("/unblacklist", {userId = userId})
	end

	local function toast(msg)
		pcall(function() game:GetService("StarterGui"):SetCore("SendNotification", {Title = "Blacklist", Text = msg, Duration = 4}) end)
	end

	-- Yes/No warning dialog. cb runs only on "Yes".
	local function dialog(text, cb)
		local gui = Instance.new("ScreenGui")
		gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "UhBlacklistConfirm", false, 1000
		gui.Parent = Env.Player:WaitForChild("PlayerGui")
		local f = Instance.new("Frame", gui)
		f.Size, f.Position, f.AnchorPoint = UDim2.fromOffset(300, 150), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5)
		f.BackgroundColor3, f.BorderSizePixel = Color3.fromRGB(24, 24, 30), 0
		Instance.new("UICorner", f).CornerRadius = UDim.new(0, 10)
		local t = Instance.new("TextLabel", f)
		t.Size, t.Position, t.BackgroundTransparency = UDim2.new(1, -20, 0, 84), UDim2.fromOffset(10, 8), 1
		t.TextWrapped, t.TextColor3, t.Font, t.TextSize = true, Color3.new(1, 1, 1), Enum.Font.GothamMedium, 14
		t.Text = text
		local function btn(txt, x, col, fn)
			local b = Instance.new("TextButton", f)
			b.Size, b.Position, b.Text = UDim2.fromOffset(130, 36), UDim2.fromOffset(x, 100), txt
			b.BackgroundColor3, b.TextColor3, b.Font, b.TextSize = col, Color3.new(1, 1, 1), Enum.Font.GothamBold, 15
			Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
			b.Activated:Connect(function() gui:Destroy(); fn() end)
		end
		btn("Yes", 15, Color3.fromRGB(200, 60, 60), cb)
		btn("No", 155, Color3.fromRGB(70, 70, 80), function() end)
	end

	-- onDone(ok, err) is called after the request finishes (not called on "No").
	function B.Confirm(userId, username, onDone)
		dialog(("WARNING\nBlacklist %s (@%s)?\nThey will be blocked from using this script and kicked from the game."):format(username, username), function()
			task.spawn(function()
				local ok, err = B.Add(userId, username)
				if onDone then onDone(ok, err) end
			end)
		end)
	end

	function B.ConfirmRemove(userId, username, onDone)
		dialog(("Unblacklist %s (@%s)?\nThey will be able to use this script again."):format(username, username), function()
			task.spawn(function()
				local ok, err = B.Remove(userId)
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
			f.Size, f.Position, f.AnchorPoint = UDim2.fromOffset(320, 300), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5)
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
				l.Size, l.Position, l.BackgroundTransparency, l.Text = UDim2.new(1, -118, 1, 0), UDim2.fromOffset(10, 0), 1, name
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
		b.AnchorPoint, b.Position, b.Size, b.Text = Vector2.new(0, 0.5), UDim2.new(0, 8, 0.5, 38), UDim2.fromOffset(118, 30), "Blacklist"
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
