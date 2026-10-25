-- [BANNER v1] INSERT AFTER the end of `Reanimate.DestroyCharacter = function() ... end` (original line 263326).
-- Modules load from GitHub. No backend URL set -> LOCAL-ONLY (just you). Backend URL set -> live sync with other users.
task.spawn(function()
	local genv = (getgenv and getgenv()) or _G
	local Cfg = genv.UhBannerConfig or {}
	local Base = Cfg.Base or "https://raw.githubusercontent.com/Elliot12-wq/uh-mod-visual-system/main/"
	local Backend = tostring(Cfg.Backend or "https://banner-system.elliptmal.workers.dev"):gsub("/+$", "")
	local LocalOnly = Backend:find("YOUR%-SUBDOMAIN") ~= nil
	if LocalOnly then warn("[UhBanner] no backend set: LOCAL-ONLY mode (only you see your banner). Deploy worker.js (wrangler deploy) and set getgenv().UhBannerConfig = {Backend = '<worker url>'} for live sync.") end
	if genv.UhBanner and genv.UhBanner.Stop then pcall(genv.UhBanner.Stop) end -- no duplicates on re-execute
	local ok, err = pcall(function()
		local function FXcall(n) local f = Util.FX and Util.FX[n]; if f then return f() end end
		local Env = {
			Player = Player, Players = Players, RunService = RunService, HttpService = HttpService,
			TweenService = cloneref(game:GetService("TweenService")), Request = request or http_request or (syn and syn.request), Backend = Backend, UserInputService = UserInputService, GuiService = GuiService,
			Room = tostring(game.PlaceId) .. "-" .. tostring(game.JobId), Token = HttpService:GenerateGUID(false),
			GetColor = function() return FXcall("GetColor") end, GetBG = function() return FXcall("GetBG") end,
			IsLowEnd = function() return FXcall("IsLowEnd") == true end,
			GetLocalCharacter = function() return Reanimate.Character or Player.Character end,
			NewTriangle = function(parent, o) -- the real 3D triangle engine (Util.FX.NewTriangle3D); o.Tint() recolours it per banner
				local FX = Util.FX
				if not (FX and FX.NewTriangle3D) then return nil end
				local T = FX.NewTriangle3D(parent, o)
				local tint, stepf = o and o.Tint, T and T.Step
				if tint and stepf then
					T.Step = function(self, dt, sd)
						local c, orig = tint(), FX.TriColor
						if typeof(c) == "Color3" then FX.TriColor = function() return c end end
						local ok, err = pcall(stepf, self, dt, sd)
						FX.TriColor = orig
						if not ok then error(err, 0) end
					end
				end
				return T
			end,
		}
		local function pull(n) return loadstring(game:HttpGet(Base .. n .. ".lua"))() end
		local UI = pull("BannerUI")(Env)
		local Sender = pull("BannerSender")(Env)
		local Receiver = pull("BannerReceiver")(Env, UI)
		local api = {Stop = function() if not LocalOnly then Sender.Clear(); Sender.Stop() end; Receiver.Stop(); UI.Cleanup() end}
		local cur, styleTok = {}, 0
		function api.Set(title, image, sub)
			cur = {title, image, sub}
			if LocalOnly then
				Receiver.Process({{userId = Player.UserId, name = Player.Name, title = title, subtitle = sub or ("@" .. Player.Name), image = image, style = SaveData.BannerStyle}})
			elseif Sender.Send(title, image, sub) then Receiver.Poke() end
		end
		function api.SetStyle(st) -- banner customization: applies to your own banner at once, then broadcasts (debounced) so every client sees it
			SaveData.BannerStyle = st
			if Receiver.ApplyLocalStyle then Receiver.ApplyLocalStyle(st) end
			if Sender.SetStyle then Sender.SetStyle(st) end
			styleTok += 1
			local my = styleTok
			task.delay(0.4, function() if my == styleTok and cur[1] ~= nil then api.Set(cur[1], cur[2], cur[3]) end end)
		end
		genv.UhBanner = api
		-- local-only banner switch (pill button + api.SetEnabled); saved in SaveData.BannerOff; never affects what other users see
		local function apply(on) if Receiver.SetHidden then Receiver.SetHidden(not on) end; SaveData.BannerOff = (not on) or nil end
		local styleApi = {get = function() return SaveData.BannerStyle end, set = function(st) api.SetStyle(st) end}
		local setPill = UI.Toggle and UI.Toggle(not SaveData.BannerOff, apply, styleApi)
		apply(not SaveData.BannerOff)
		function api.SetEnabled(on) apply(on); if setPill then setPill(on) end end
		if Sender.SetStyle then Sender.SetStyle(SaveData.BannerStyle) end
		if Sender.SetStyle then Sender.SetStyle(SaveData.BannerStyle) end
		Receiver.Start(LocalOnly)
		if not LocalOnly then Sender.Start() end
		api.Set(Cfg.Title or SaveData.BannerTitle or Player.DisplayName, Cfg.Image or SaveData.BannerImage or "")
	end)
	if not ok then warn("[UhBanner] " .. tostring(err)) end
end)
