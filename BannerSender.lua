-- BannerSender.lua | publishes the local player's banner to the live-sync backend (+ keep-alive)
return function(Env)
	local S = {Payload = nil, Running = false}
	local function post(path, body)
		if not Env.Request then return false, "executor has no request()" end
		body.room, body.userId, body.token = Env.Room, Env.Player.UserId, Env.Token
		local ok, res = pcall(Env.Request, {Url = Env.Backend .. path, Method = "POST",
			Headers = {["Content-Type"] = "application/json"}, Body = Env.HttpService:JSONEncode(body)})
		if not ok then return false, tostring(res) end
		if type(res) ~= "table" or res.StatusCode ~= 200 then return false, "HTTP " .. tostring(type(res) == "table" and res.StatusCode) end
		return true
	end
	local function copy(t) local c = {}; for k, v in pairs(t) do c[k] = v end; return c end

	function S.Send(title, image, subtitle)
		S.Payload = {name = Env.Player.Name, title = tostring(title or ""), image = tostring(image or ""), subtitle = tostring(subtitle or ("@" .. Env.Player.Name)), style = S.Style}
		local ok, err = post("/banner", copy(S.Payload))
		if not ok then warn("[UhBanner] send failed: " .. tostring(err)) end
		return ok, err
	end
	function S.SetStyle(st) -- banner style table (or nil = host theme); goes out with the next Send / keep-alive
		S.Style = st
		if S.Payload then S.Payload.style = st end
	end
	function S.Start() -- backend TTL is 75s; re-announce every 25s
		if S.Running then return end
		S.Running = true
		task.spawn(function()
			while S.Running do
				for _ = 1, 100 do if not S.Running then return end task.wait(0.25) end
				if S.Payload then post("/banner", copy(S.Payload)) end
			end
		end)
	end
	function S.Stop() S.Running = false end
	function S.Clear() S.Payload = nil; post("/clear", {}) end
	return S
end
