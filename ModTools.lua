-- ModTools.lua | moderator actions (kill / deanimate / kick) relayed to OTHER SCRIPT USERS who misuse the script.
-- Who may send: verified moderators + owner / co-owner (their userId must hold a key in the backend's MOD_KEYS).
-- Who can be hit: only players running this script, and never verified players / owner / co-owner. The target is always notified.
-- Env needs: Player, Players, HttpService, Request, Backend, Room, Token, ModKey (getgenv().UhBannerConfig.ModKey), ModActions {Kill, Deanimate, Kick(msg)}
return function(Env, R)
	local HS, Players = Env.HttpService, Env.Players
	local M = {Running = false}
	local ACTIONS = {kill = true, deanimate = true, kick = true}

	function M.CanModerate()
		return Env.Request ~= nil and Env.ModKey ~= nil and Env.ModKey ~= "" and R.RoleOf(Env.Player.UserId) ~= nil
	end

	-- key box in the main UI: a whitelisted account redeems a one-time key; the first user to use a key locks it to their account.
	-- returns ok, message, definitelyBad (true when the backend rejected the key itself)
	function M.Redeem(key)
		key = (tostring(key or ""):gsub("%s", ""))
		if key == "" then return false, "enter your key first" end
		if not R.IsWhitelisted(Env.Player.UserId) then return false, "this account is not on the verified whitelist" end
		if not Env.Request then return false, "executor has no request()" end
		local ok, res = pcall(Env.Request, {Url = Env.Backend .. "/verify", Method = "POST", Headers = {["Content-Type"] = "application/json"},
			Body = HS:JSONEncode({userId = Env.Player.UserId, key = key})})
		if not ok or type(res) ~= "table" then return false, "backend unreachable" end
		if res.StatusCode == 403 then return false, "invalid key, or it was already used by someone else", true end
		if res.StatusCode ~= 200 then return false, "HTTP " .. tostring(res.StatusCode) end
		Env.ModKey = key
		R.SetVerified(Env.Player.UserId) -- badge right away; the next banner poll confirms it for everyone
		R.Poke()
		return true
	end

	function M.Send(target, action)
		if not ACTIONS[action] then return false, "bad action" end
		if not M.CanModerate() then return false, "moderators only" end
		if R.IsWhitelisted(target) then return false, "verified players are immune" end
		local ok, res = pcall(Env.Request, {Url = Env.Backend .. "/mod", Method = "POST", Headers = {["Content-Type"] = "application/json"},
			Body = HS:JSONEncode({room = Env.Room, userId = Env.Player.UserId, key = Env.ModKey, target = target, action = action})})
		if not ok then return false, tostring(res) end
		if type(res) ~= "table" or res.StatusCode ~= 200 then return false, "HTTP " .. tostring(type(res) == "table" and res.StatusCode) end
		return true
	end

	local function toast(msg)
		pcall(function() game:GetService("StarterGui"):SetCore("SendNotification", {Title = "Moderator", Text = msg, Duration = 6}) end)
	end

	local function handle(c)
		if type(c) ~= "table" or not ACTIONS[c.action] then return end
		local by = tonumber(c.by)
		if not by or by == Env.Player.UserId or not R.RoleOf(by) then return end -- sender must be a verified moderator / owner / co-owner
		if R.IsWhitelisted(Env.Player.UserId) then return end -- whitelisted / verified players, owner and co-owner are immune
		local p = Players:GetPlayerByUserId(by)
		local name = p and p.Name or "a moderator"
		local A = Env.ModActions or {}
		if c.action == "kick" then
			toast("Kicked by moderator " .. name)
			if A.Kick then A.Kick("Kicked by moderator " .. name .. " (script misuse)") end
		elseif c.action == "kill" then
			toast(name .. " used Kill on you (script misuse)")
			if A.Kill then A.Kill() end
		else
			toast(name .. " used Deanimate on you (script misuse)")
			if A.Deanimate then A.Deanimate() end
		end
	end

	function M.Start()
		if M.Running or not Env.Request then return end
		M.Running = true
		task.spawn(function()
			local fails = 0
			while M.Running do
				local ok, res = pcall(Env.Request, {Url = Env.Backend .. "/commands?room=" .. HS:UrlEncode(Env.Room) .. "&userId=" .. Env.Player.UserId .. "&token=" .. HS:UrlEncode(Env.Token), Method = "GET"})
				if ok and type(res) == "table" and res.StatusCode == 200 then
					fails = 0
					local ok2, data = pcall(HS.JSONDecode, HS, res.Body)
					if ok2 and type(data) == "table" and type(data.commands) == "table" then
						for _, c in ipairs(data.commands) do pcall(handle, c) end
					end
				else fails += 1 end
				task.wait(math.min(2 + fails * 2, 12))
			end
		end)
	end

	function M.Stop() M.Running = false end

	return M
end
