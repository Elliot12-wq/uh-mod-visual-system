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
		}
		local function pull(n) return loadstring(game:HttpGet(Base .. n .. ".lua"))() end
		local UI = pull("BannerUI")(Env)
		local Sender = pull("BannerSender")(Env)
		local Receiver = pull("BannerReceiver")(Env, UI)
		local api = {Stop = function() if not LocalOnly then Sender.Clear(); Sender.Stop() end; Receiver.Stop(); UI.Cleanup() end}
		function api.Set(title, image, sub)
			if LocalOnly then
				Receiver.Process({{userId = Player.UserId, name = Player.Name, title = title, subtitle = sub or ("@" .. Player.Name), image = image}})
			elseif Sender.Send(title, image, sub) then Receiver.Poke() end
		end
		genv.UhBanner = api
		-- local-only banner switch (pill button + api.SetEnabled); saved in SaveData.BannerOff; never affects what other users see
		local function apply(on) if Receiver.SetHidden then Receiver.SetHidden(not on) end; SaveData.BannerOff = (not on) or nil end
		local setPill = UI.Toggle and UI.Toggle(not SaveData.BannerOff, apply)
		apply(not SaveData.BannerOff)
		function api.SetEnabled(on) apply(on); if setPill then setPill(on) end end
		Receiver.Start(LocalOnly)
		if not LocalOnly then Sender.Start() end
		api.Set(Cfg.Title or SaveData.BannerTitle or Player.DisplayName, Cfg.Image or SaveData.BannerImage or "")
	end)
	if not ok then warn("[UhBanner] " .. tostring(err)) end
end)
