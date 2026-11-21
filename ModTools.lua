-- ModTools.lua | moderator actions (kill / deanimate / kick / bring / hallucinate / dizzy) relayed to OTHER SCRIPT USERS.
-- Who may send: verified moderators (whitelist.json) + owner / co-owner, recognised by userId from roles.json on GitHub (no key).
-- Who can be hit: only players running this script, never owner / co-owner; verified players only by the OWNER (roles.json "owner", R.CanTarget). The target is always notified.
-- bring / hallucinate / dizzy: implemented in VerifiedPlayerFeatures.lua (Env.Fx): recipient is notified, no prompt, no cooldown, the temporary effects (hallucinate 60 s, dizzy 20 s) clean themselves up.
-- Env needs: Player, Players, RunService, HttpService, Request, Backend, Room, Token, ModActions {Kill, Deanimate, Kick(msg)}, Fx (VerifiedPlayerFeatures.lua)
return function(Env, R)
	local HS, Players, RS = Env.HttpService, Env.Players, Env.RunService
	local M = {Running = false}
	local ACTIONS = {kill = true, deanimate = true, kick = true}
	local FXA = {bring = true, hallucinate = true, dizzy = true, silenthell = true} -- handled by Env.Fx (VerifiedPlayerFeatures.lua)

	function M.CanModerate()
		return Env.Request ~= nil and R.RoleOf(Env.Player.UserId) ~= nil -- owner / co-owner / verified players: no key (the backend recognises their userId)
	end

	function M.Send(target, action)
		if FXA[action] then
			if not Env.Fx then return false, "VerifiedPlayerFeatures module failed to load" end
			return Env.Fx.Request(target, action)
		end
		if not ACTIONS[action] then return false, "bad action" end
		if not M.CanModerate() then return false, "moderators only" end
		if not R.CanTarget(target) then return false, R.IsWhitelisted(target) and "verified players are immune" or "bad target" end
		local ok, res = pcall(Env.Request, {Url = Env.Backend .. "/mod", Method = "POST", Headers = {["Content-Type"] = "application/json"},
			Body = HS:JSONEncode(Env.Sign("/mod", {room = Env.Room, userId = Env.Player.UserId, token = Env.Token, target = target, action = action}, tostring(target) .. ":" .. action))})
		if not ok then return false, tostring(res) end
		if type(res) ~= "table" or res.StatusCode ~= 200 then return false, "HTTP " .. tostring(type(res) == "table" and res.StatusCode) end
		return true
	end

	local function toast(msg)
		pcall(function() game:GetService("StarterGui"):SetCore("SendNotification", {Title = "Moderator", Text = msg, Duration = 6}) end)
	end

	local function handle(c)
		if Env.Fx and Env.Fx.Receive(c) then return end -- bring / hallucinate / dizzy
		if type(c) ~= "table" or not ACTIONS[c.action] then return end
		local by = tonumber(c.by)
		if not R.CanBeModeratedBy(by) then return end -- sender must be a verified moderator / owner / co-owner; verified recipients accept ONLY an OWNER in this server, owner / co-owner recipients nobody
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
local fails, idle = 0, 0
while M.Running do
local ok, res = pcall(Env.Request, {Url = Env.Backend .. "/commands?room=" .. HS:UrlEncode(Env.Room) .. "&userId=" .. Env.Player.UserId .. "&token=" .. HS:UrlEncode(Env.Token), Method = "GET"})
local wait
if ok and type(res) == "table" and res.StatusCode == 200 then
fails = 0
local got = false
local ok2, data = pcall(HS.JSONDecode, HS, res.Body)
if ok2 and type(data) == "table" and type(data.commands) == "table" then
for _, c in ipairs(data.commands) do got = true; pcall(handle, c) end
end
idle = got and 0 or math.min(idle + 1, 3)
wait = 2 + idle -- 2s right after a command, stretching to 5s while nothing arrives
else
fails += 1
wait = math.min(2 * 2 ^ fails, 30)
if ok and type(res) == "table" and res.StatusCode == 429 then wait = math.max(wait, 20) end
end
task.wait(wait + math.random())
end
		end)
	end

	function M.Stop() M.Running = false; if Env.Fx then Env.Fx.StopEffects() end end

	return M
end
