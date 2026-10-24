-- Blacklist.lua | loads blacklist.json from the repo; lets OWNER / CO-OWNER add entries (with a Yes/No warning)
-- Usage (main script, after Env is built):  local BL = loadstring(game:HttpGet(Base .. "Blacklist.lua"))()(Env)
-- Env needs: Player, Players, HttpService, Request, Base, Backend, OwnerKey (owner/co-owner only, from getgenv().UhBannerConfig.OwnerKey)
return function(Env)
	local B = {List = {}}

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

	-- call first thing on startup: returns true when the local player may NOT use the script
	function B.CheckSelf()
		B.Fetch()
		local hit, e = B.Is(Env.Player.UserId)
		if hit then warn("[Blacklist] you are blacklisted from this script" .. (e.reason and (": " .. tostring(e.reason)) or "")) end
		return hit
	end

	function B.Add(userId, username, reason)
		if not Env.Request then return false, "executor has no request()" end
		local ok, res = pcall(Env.Request, {
			Url = Env.Backend .. "/blacklist", Method = "POST",
			Headers = {["Content-Type"] = "application/json"},
			Body = Env.HttpService:JSONEncode({
				key = Env.OwnerKey, userId = userId, username = username,
				reason = reason or "", by = Env.Player.Name, byId = Env.Player.UserId,
			}),
		})
		if not ok then return false, tostring(res) end
		if type(res) ~= "table" or res.StatusCode ~= 200 then return false, "HTTP " .. tostring(type(res) == "table" and res.StatusCode) end
		B.Fetch()
		return true
	end

	-- Yes/No warning dialog. onDone(ok, err) is called after the request finishes (not called on "No").
	function B.Confirm(userId, username, onDone)
		local gui = Instance.new("ScreenGui")
		gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "UhBlacklistConfirm", false, 1000
		gui.Parent = Env.Player:WaitForChild("PlayerGui")
		local f = Instance.new("Frame", gui)
		f.Size, f.Position, f.AnchorPoint = UDim2.fromOffset(300, 150), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5)
		f.BackgroundColor3, f.BorderSizePixel = Color3.fromRGB(24, 24, 30), 0
		Instance.new("UICorner", f).CornerRadius = UDim.new(0, 10)
		local t = Instance.new("TextLabel", f)
		t.Size, t.Position, t.BackgroundTransparency = UDim2.new(1, -20, 0, 80), UDim2.fromOffset(10, 10), 1
		t.TextWrapped, t.TextColor3, t.Font, t.TextSize = true, Color3.new(1, 1, 1), Enum.Font.GothamMedium, 15
		t.Text = ("WARNING\nBlacklist %s (@%s)?\nThey will be blocked from using this script."):format(username, username)
		local function btn(txt, x, col, cb)
			local b = Instance.new("TextButton", f)
			b.Size, b.Position, b.Text = UDim2.fromOffset(130, 36), UDim2.fromOffset(x, 100), txt
			b.BackgroundColor3, b.TextColor3, b.Font, b.TextSize = col, Color3.new(1, 1, 1), Enum.Font.GothamBold, 15
			Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
			b.Activated:Connect(function() gui:Destroy(); cb() end)
		end
		btn("Yes", 15, Color3.fromRGB(200, 60, 60), function()
			task.spawn(function()
				local ok, err = B.Add(userId, username)
				if onDone then onDone(ok, err) end
			end)
		end)
		btn("No", 155, Color3.fromRGB(70, 70, 80), function() end)
	end

	return B
end
