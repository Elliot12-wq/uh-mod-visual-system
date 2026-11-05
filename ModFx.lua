-- ModFx.lua | consent-based visual actions between SCRIPT USERS: Bring Users (meeting invitation), Hallucinate Users, Dizzy.
-- Sender: owner / co-owner / verified player (gate = ModTools.CanFx, same role detection as the other moderation actions, re-checked by the backend's /fx).
-- Flow follows AltFling: request -> recipient gets an Accept / Decline card -> accepted effect starts on the recipient's client only (visual only, hard duration, cancellable).
-- Nothing ever moves, controls or touches another player: Bring is a waypoint (the recipient walks), Hallucinate = local anchored copies, Dizzy = camera sway.
-- Optional: getgenv().UhBannerConfig.BringHook = function({userId, name}) return true end -- an authorised server-side teleport in an experience we control; without it Bring is the waypoint invitation.
-- Env needs: Player, Players, RunService, HttpService, Request, Backend, Room, Token, Mod (ModTools: CanFx / FxRequest / FxActions), GetColor, GetLocalCharacter, Notify(msg) optional
return function(Env, R)
	local HS, Players, RS, Me = Env.HttpService, Env.Players, Env.RunService, Env.Player
	local UIS, Lighting, SG = game:GetService("UserInputService"), game:GetService("Lighting"), game:GetService("StarterGui")
	local F = {Running = false, Pending = {}, Out = {}}
	local ORDER = {"bring", "hallucinate", "dizzy"}
	local LABEL = {bring = "Bring Users", hallucinate = "Hallucinate Users", dizzy = "Dizzy"}
	local SHORT = {bring = "Bring", hallucinate = "Hallucinate", dizzy = "Dizzy"}
	local DUR = {bring = 120, hallucinate = 60, dizzy = 20}
	local ASK = {
		bring = "invite you to meet them. You get a waypoint to their location and walk there yourself - nothing moves you.",
		hallucinate = "show you a 60 s hallucination: harmless visual copies slowly approaching you. Visual only, cancel any time.",
		dizzy = "make your screen sway for 20 s. Visual only, your controls are untouched, cancel any time.",
	}
	local HINT = {
		bring = "Sends a meeting invitation. They accept, get a waypoint to you and walk there themselves.",
		hallucinate = "[x] = whose avatar appears (none picked = up to 4 others). Send = who sees it.",
		dizzy = "Sends a 20 s screen-sway request. Visual only, they can cancel any time.",
	}
	local conns, active, P, UI = {}, {}, {Cards = {}}, {Sel = {}}
	local FAR, NEAR = 60, 9 -- hallucination: spawn ring radius / closest approach (studs)
	local STARTERS = {}

	local function new(c, p, par) local i = Instance.new(c); for k, v in pairs(p) do i[k] = v end; i.Parent = par; return i end
	local function round(par, r) return new("UICorner", {CornerRadius = UDim.new(0, r or 6)}, par) end
	local function accent()
		local ok, c = pcall(Env.GetColor)
		return (ok and typeof(c) == "Color3") and c or Color3.fromRGB(95, 165, 255)
	end
	local function stroke(par) return new("UIStroke", {Color = accent(), Thickness = 1.5}, par) end
	local function esc(s) return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
	local function setVis(o, v) if o then pcall(function() o.Visible = v end) end end
	local function setText(o, t) if o then pcall(function() o.Text = t end) end end
	local function notify(t)
		if Env.Notify then return pcall(Env.Notify, tostring(t)) end
		pcall(function() SG:SetCore("SendNotification", {Title = "Effects", Text = tostring(t), Duration = 5}) end)
	end

	-- ===== backend (AltFling conventions: identity = the banner token) =====
	local function call(method, path, body)
		if not Env.Request then return false, "executor has no request()" end
		local req = {Url = Env.Backend .. path, Method = method}
		if body then
			body.room, body.userId, body.token = Env.Room, Me.UserId, Env.Token
			req.Headers, req.Body = {["Content-Type"] = "application/json"}, HS:JSONEncode(body)
		end
		local ok, res = pcall(Env.Request, req)
		if not ok then return false, tostring(res) end
		if type(res) ~= "table" then return false, "no response" end
		local okD, data = pcall(HS.JSONDecode, HS, res.Body or "")
		if res.StatusCode ~= 200 then
			return false, (okD and type(data) == "table" and data.error) or ("HTTP " .. tostring(res.StatusCode)), res.StatusCode
		end
		return true, (okD and type(data) == "table") and data or {}
	end
	local function post(op, target, extra)
		local body = extra or {}
		body.op, body.target = op, tostring(target)
		for _ = 1, 3 do
			local ok, r, code = call("POST", "/fx", body)
			if ok or code ~= 429 then return ok, r end
			task.wait(0.6)
		end
		return false, "slow down"
	end

	-- ===== ui helpers =====
	local function host()
		if F.Gui and F.Gui.Parent then return F.Gui end
		local parent
		pcall(function() parent = (gethui and gethui()) or game:GetService("CoreGui") end)
		parent = parent or Me:WaitForChild("PlayerGui")
		pcall(function() for _, v in ipairs(parent:GetChildren()) do if v.Name == "UhFxHost" then v:Destroy() end end end)
		F.Gui = new("ScreenGui", {Name = "UhFxHost", ResetOnSpawn = false, DisplayOrder = 940, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling}, parent)
		return F.Gui
	end
	local function button(par, text, size, pos, cb)
		local b = new("TextButton", {Text = text, Size = size, Position = pos, BackgroundColor3 = Color3.fromRGB(24, 26, 34), TextColor3 = Color3.new(1, 1, 1),
			Font = Enum.Font.Code, TextSize = 12, BorderSizePixel = 0}, par)
		round(b, 5)
		b.Activated:Connect(cb)
		return b
	end
	local function drag(frame, handle)
		local dragging, start, origin
		conns[#conns + 1] = handle.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
				dragging, start, origin = true, i.Position, frame.Position
			end
		end)
		conns[#conns + 1] = UIS.InputChanged:Connect(function(i)
			if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
				local d = i.Position - start
				frame.Position = UDim2.new(origin.X.Scale, origin.X.Offset + d.X, origin.Y.Scale, origin.Y.Offset + d.Y)
			end
		end)
		conns[#conns + 1] = UIS.InputEnded:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
		end)
	end
	local function panel(g, name, size, pos, anchor, title)
		local f = new("Frame", {Name = name, Size = size, Position = pos, AnchorPoint = anchor or Vector2.zero, BackgroundColor3 = Color3.fromRGB(8, 9, 12),
			BorderSizePixel = 0, Visible = false, Active = true}, g)
		round(f, 8); stroke(f)
		local head = new("Frame", {Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = Color3.fromRGB(16, 18, 24), BorderSizePixel = 0, Active = true}, f)
		round(head, 8)
		local lab = new("TextLabel", {BackgroundTransparency = 1, Size = UDim2.new(1, -40, 1, 0), Position = UDim2.fromOffset(8, 0), Text = title, Font = Enum.Font.Code,
			TextSize = 12, TextColor3 = accent(), TextXAlignment = Enum.TextXAlignment.Left}, head)
		drag(f, head)
		return f, head, lab
	end
	local function list(par, pos, size)
		local s = new("ScrollingFrame", {Position = pos, Size = size, BackgroundColor3 = Color3.fromRGB(12, 13, 18), BorderSizePixel = 0, ScrollBarThickness = 3,
			CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y}, par)
		round(s, 5)
		new("UIListLayout", {Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder}, s)
		return s
	end

	-- ===== running effects bar (one row per active effect, each with its own Cancel) =====
	local function hud()
		if UI.Hud and UI.Hud.Parent then return UI.Hud end
		UI.Hud = new("Frame", {Name = "Effects", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -80), Size = UDim2.fromOffset(300, 0),
			AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1}, host())
		new("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center}, UI.Hud)
		return UI.Hud
	end
	local function addRow(key, e)
		local row = new("Frame", {Size = UDim2.fromOffset(300, 30), BackgroundColor3 = Color3.fromRGB(8, 9, 12), BorderSizePixel = 0}, hud())
		round(row, 8); stroke(row)
		e.Label = new("TextLabel", {BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -86, 1, 0), Font = Enum.Font.Code, TextSize = 12,
			TextColor3 = Color3.fromRGB(220, 224, 235), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = ""}, row)
		button(row, "Cancel", UDim2.fromOffset(64, 22), UDim2.new(1, -70, 0, 4), function() F.End(key, "cancelled") end)
		e.Row = row
	end

	-- why: expired (backend expires it itself) | cancelled | respawn | arrived | left | failed | stopped (module stop, quiet)
	function F.End(key, why, quiet)
		local e = active[key]
		if not e then return end
		active[key] = nil
		pcall(e.Cleanup)
		if e.Row then pcall(function() e.Row:Destroy() end) end
		if why ~= "expired" and why ~= "left" and not quiet then task.spawn(post, "cancel", e.From, {action = key, why = why}) end
	end

	local function begin(s) -- s = payload the BACKEND returned for the request this client just accepted
		if type(s) ~= "table" then return end
		local key = s.action
		if not (LABEL[key] and STARTERS[key]) or active[key] then return end
		local e = {Key = key, From = tonumber(s.from), Name = tostring(s.name or "?"), EndAt = os.clock() + math.min(tonumber(s.dur) or DUR[key], DUR[key])}
		active[key] = e
		addRow(key, e)
		local ok, cleanup = pcall(STARTERS[key], e, s)
		if not ok or type(cleanup) ~= "function" then
			warn("[ModFx] " .. key .. " failed: " .. tostring(cleanup))
			F.End(key, "failed")
			notify(LABEL[key] .. " could not start")
			return
		end
		e.Cleanup = cleanup
		if active[key] ~= e then pcall(cleanup) end -- the effect ended while it was starting
	end

	-- ===== Bring Users: meeting-location invitation (waypoint), or the experience's own authorised teleport via BringHook =====
	STARTERS.bring = function(e)
		local cfg = (getgenv and getgenv().UhBannerConfig) or {}
		if type(cfg.BringHook) == "function" then
			local ok, done = pcall(cfg.BringHook, {userId = e.From, name = e.Name})
			if ok and done == true then
				notify("Bring accepted - " .. e.Name .. " (handled by this experience's own teleport)")
				task.delay(1, function() F.End("bring", "arrived") end)
				return function() end
			end
		end
		local gui = new("BillboardGui", {Name = "UhFxWaypoint", Size = UDim2.fromOffset(200, 46), StudsOffset = Vector3.new(0, 5, 0), AlwaysOnTop = true, ResetOnSpawn = false}, host())
		local lab = new("TextLabel", {BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Font = Enum.Font.Code, TextSize = 14, TextColor3 = Color3.new(1, 1, 1),
			TextStrokeTransparency = 0.4, TextWrapped = true, Text = ""}, gui)
		e.Update = function()
			local sp = Players:GetPlayerByUserId(e.From)
			if not sp then return F.End("bring", "left") end
			local sr = sp.Character and sp.Character:FindFirstChild("HumanoidRootPart")
			local mc = Env.GetLocalCharacter()
			local mr = mc and mc:FindFirstChild("HumanoidRootPart")
			gui.Adornee = sr
			if not sr then lab.Text = "Meet " .. e.Name .. " (location unavailable)"; return end
			local d = mr and (mr.Position - sr.Position).Magnitude
			lab.Text = d and ("Meet " .. e.Name .. "\n" .. math.floor(d) .. " studs") or ("Meet " .. e.Name)
			if d and d <= 10 then F.End("bring", "arrived") end
		end
		e.Update()
		return function() pcall(function() gui:Destroy() end) end
	end

	-- ===== Dizzy: mild camera shake + sway, never touches controls / character; camera restored on end / cancel / respawn =====
	STARTERS.dizzy = function(e)
		local name = "UhFxDizzy"
		local cam0 = workspace.CurrentCamera
		local fov0 = cam0 and cam0.FieldOfView or 70
		local blur = new("BlurEffect", {Name = "UhFxBlur", Size = 0}, Lighting)
		local t0, last = os.clock(), CFrame.new()
		RS:BindToRenderStep(name, Enum.RenderPriority.Camera.Value + 1, function()
			local cam = workspace.CurrentCamera
			if not cam then return end
			local t = os.clock() - t0
			local k = math.clamp(math.min(t / 1.5, (e.EndAt - os.clock()) / 1.5), 0, 1) -- ease in / out
			local rx = math.rad(1.1) * math.sin(t * 1.1 + 2) + math.rad(0.25) * math.noise(t * 7, 0.31)
			local ry = math.rad(1.6) * math.sin(t * 0.9 + 1) + math.rad(0.25) * math.noise(t * 7, 5.17)
			local rz = math.rad(2.2) * math.sin(t * 1.3)
			local jx, jy = 0.04 * math.noise(t * 9, 2.43), 0.04 * math.noise(t * 9, 7.91)
			local off = CFrame.new(jx * k, jy * k, 0) * CFrame.Angles(rx * k, ry * k, rz * k)
			if cam.CameraType == Enum.CameraType.Scriptable then cam.CFrame = cam.CFrame * last:Inverse() end -- the default camera rebuilds its CFrame every frame; a scripted one would accumulate
			cam.CFrame = cam.CFrame * off
			last = off
			cam.FieldOfView = fov0 + 3 * math.sin(t * 0.8) * k
			blur.Size = 2.5 * k * (0.5 + 0.5 * math.sin(t * 1.7))
		end)
		return function()
			pcall(function() RS:UnbindFromRenderStep(name) end)
			pcall(function() blur:Destroy() end)
			local cam = workspace.CurrentCamera
			if cam then
				if cam.CameraType == Enum.CameraType.Scriptable then pcall(function() cam.CFrame = cam.CFrame * last:Inverse() end) end
				cam.FieldOfView = fov0
			end
		end
	end

	-- ===== Hallucinate Users: local, anchored, non-colliding copies that slowly close in =====
	local function buildCopy(uid) -- yields; returns {Model, Hip, Parts, HL} or nil. Never edits the real player / character.
		local model
		local p = Players:GetPlayerByUserId(uid)
		local src = p and p.Character
		if src and src.Archivable then
			local ok, c = pcall(function() return src:Clone() end)
			if ok and c then model = c end
		end
		if not model then
			local okD, desc = pcall(Players.GetHumanoidDescriptionFromUserId, Players, uid)
			if okD and desc then
				local okM, m = pcall(Players.CreateHumanoidModelFromDescription, Players, desc, Enum.HumanoidRigType.R15)
				if okM and m then model = m end
			end
		end
		if not model then return nil end
		local hum = model:FindFirstChildOfClass("Humanoid")
		local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
		if not (root and root:IsA("BasePart")) then model:Destroy(); return nil end
		local hip = math.max(3, (hum and hum.HipHeight or 2) + root.Size.Y / 2)
		model.PrimaryPart = root
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("LuaSourceContainer") or d:IsA("Humanoid") or d:IsA("BackpackItem") or d:IsA("Sound") or d:IsA("BillboardGui") or d:IsA("SurfaceGui") or d:IsA("ParticleEmitter")
				or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") or d:IsA("Light") or d:IsA("ForceField") or d:IsA("Highlight") then
				d:Destroy()
			end
		end
		local parts = {}
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored, d.CanCollide, d.CanTouch, d.CanQuery, d.CastShadow, d.Massless = true, false, false, false, false, true
				local isRoot = d == root
				if not isRoot then d.Color = d.Color:Lerp(Color3.new(0, 0, 0), 0.5) end
				parts[#parts + 1] = {d, isRoot and 1 or math.max(d.Transparency, 0.2)}
				d.Transparency = 1 -- faded in by the effect
			end
		end
		local hl = new("Highlight", {FillColor = Color3.new(0, 0, 0), FillTransparency = 0.7, OutlineColor = Color3.fromRGB(190, 30, 30), OutlineTransparency = 1,
			DepthMode = Enum.HighlightDepthMode.Occluded}, model)
		return {Model = model, Hip = hip, Parts = parts, HL = hl}
	end

	STARTERS.hallucinate = function(e, s)
		local folder = new("Folder", {Name = "UhFxHallucination"}, workspace)
		local grade = new("ColorCorrectionEffect", {Name = "UhFxGrade"}, Lighting)
		local function bar(top) return new("Frame", {Size = UDim2.new(1, 0, 0.07, 0), Position = UDim2.fromScale(0, top and 0 or 0.93), BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 0}, host()) end
		local b1, b2 = bar(true), bar(false) -- cinematic letterbox
		local clones, alive, t0, lastA, lastF = {}, true, os.clock(), -1, -10
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		local function setAlpha(a)
			if math.abs(a - lastA) < 0.01 then return end
			lastA = a
			for _, c in ipairs(clones) do for _, pr in ipairs(c.Parts) do pr[1].Transparency = 1 - (1 - pr[2]) * a end end
		end
		local hb = RS.Heartbeat:Connect(function(dt)
			local t = os.clock() - t0
			local a = math.clamp(math.min(t / 4, (e.EndAt - os.clock()) / 3), 0, 1)
			grade.Saturation, grade.Contrast, grade.Brightness = -0.45 * a, 0.12 * a, -0.05 * a
			grade.TintColor = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(215, 205, 235), a)
			b1.BackgroundTransparency = 1 - 0.85 * a
			b2.BackgroundTransparency = b1.BackgroundTransparency
			setAlpha(a)
			local mc = Env.GetLocalCharacter()
			local mr = mc and mc:FindFirstChild("HumanoidRootPart")
			if not mr then return end
			if t - lastF > 1 then
				lastF = t
				local f = {folder}
				for _, pl in ipairs(Players:GetPlayers()) do if pl.Character then f[#f + 1] = pl.Character end end
				if mc then f[#f + 1] = mc end
				rp.FilterDescendantsInstances = f
			end
			local cam = workspace.CurrentCamera
			for i, c in ipairs(clones) do
				local to = Vector3.new(mr.Position.X - c.X, 0, mr.Position.Z - c.Z)
				local dist, stop = to.Magnitude, NEAR + (i - 1) * 1.6
				if dist > stop then
					local mult = 1.5 -- closes in faster while you are not looking, slower in view, and freezes now and then
					if cam then
						local rel = Vector3.new(c.X, mr.Position.Y, c.Z) - cam.CFrame.Position
						if rel.Magnitude > 0 and rel.Unit:Dot(cam.CFrame.LookVector) > 0.5 then mult = 0.45 end
					end
					if math.sin(t * 0.6 + c.Phase) > 0.75 then mult = 0 end
					local step = math.min(1.6 * mult * dt, dist - stop)
					c.X += to.X / dist * step
					c.Z += to.Z / dist * step
				end
				local hit = workspace:Raycast(Vector3.new(c.X, mr.Position.Y + 8, c.Z), Vector3.new(0, -60, 0), rp)
				local ty = hit and (hit.Position.Y + c.Hip) or mr.Position.Y
				c.Y += (ty - c.Y) * math.min(1, dt * 6)
				local y = c.Y + math.sin(t * 1.2 + c.Phase) * 0.06
				c.Model:PivotTo(CFrame.lookAt(Vector3.new(c.X, y, c.Z), Vector3.new(mr.Position.X, y, mr.Position.Z)))
				c.HL.OutlineTransparency = math.min(1, 0.5 + 0.3 * math.sin(t * 2.1 + c.Phase) + (1 - a))
			end
		end)
		task.defer(function() -- avatar lookups can yield, so the copies are built off-thread (after e.Cleanup is registered)
			local av = type(s.avatars) == "table" and s.avatars or {}
			for i, v in ipairs(av) do
				if not alive or i > 4 then break end
				local uid = tonumber(type(v) == "table" and v.userId)
				if uid and uid ~= Me.UserId then
					local c = buildCopy(uid)
					local mc = Env.GetLocalCharacter()
					local mr = mc and mc:FindFirstChild("HumanoidRootPart")
					if c and alive and mr then
						local ang, r = (i / #av) * math.pi * 2 + math.random() * 0.8, FAR + math.random(-6, 8)
						c.Phase, c.X, c.Z, c.Y = math.random() * 10, mr.Position.X + math.cos(ang) * r, mr.Position.Z + math.sin(ang) * r, mr.Position.Y
						c.Model.Parent = folder
						clones[#clones + 1] = c
						lastA = -1
					elseif c then
						c.Model:Destroy()
					end
				end
			end
			if alive and #clones == 0 then notify("Hallucination: nothing to show"); F.End("hallucinate", "failed") end
		end)
		return function()
			alive = false
			hb:Disconnect()
			for _, x in ipairs({folder, grade, b1, b2}) do pcall(function() x:Destroy() end) end
		end
	end

	-- ===== recipient cards (Accept / Decline) =====
	local function buildPrompt(r)
		if not (P.List and P.List.Parent) then
			P.List = new("Frame", {Name = "Prompts", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 170), Size = UDim2.fromOffset(320, 0),
				AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1}, host())
			new("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder}, P.List)
		end
		local role = R.RoleOf(r.from)
		local tag = role and (" [" .. (role.tag or "VERIFIED") .. "]") or ""
		local card = new("Frame", {Size = UDim2.fromOffset(320, 128), BackgroundColor3 = Color3.fromRGB(8, 9, 12), BorderSizePixel = 0, LayoutOrder = r.ts or 0}, P.List)
		round(card, 8); stroke(card)
		new("TextLabel", {BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 82), RichText = true, TextWrapped = true, Font = Enum.Font.Code,
			TextSize = 12, TextColor3 = Color3.fromRGB(220, 224, 235), TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
			Text = ("<b>%s</b>%s wants to %s"):format(esc(r.name), esc(tag), ASK[r.action])}, card)
		button(card, "Accept", UDim2.new(0.5, -14, 0, 26), UDim2.new(0, 10, 1, -34), function() F.Respond(r.from, true) end)
		button(card, "Decline", UDim2.new(0.5, -14, 0, 26), UDim2.new(0.5, 4, 1, -34), function() F.Respond(r.from, false) end)
		P.Cards[r.from] = card
	end

	function F.Respond(from, accept)
		local card = P.Cards[from]
		if card then card:Destroy(); P.Cards[from] = nil end
		local ok, res = post("respond", from, {accept = accept and true or false})
		if not ok then notify("Could not answer the request: " .. tostring(res)); F.Poll(); return false, res end
		if accept and type(res) == "table" then begin(res.start) end
		F.Poll()
		return true
	end

	-- ===== picker (the sender's list of eligible, active script users) =====
	local function outTo(uid) for _, o in ipairs(F.Out) do if o.to == uid then return o end end end

	local function renderPicker(force)
		local f = UI.Picker
		if not (f and f.Parent and f.Visible) then return end
		local act = UI.Action
		local targets = R.FxTargets and R.FxTargets() or {}
		table.sort(targets, function(a, b)
			local pa, pb = a.userId == UI.Pre, b.userId == UI.Pre
			if pa ~= pb then return pa end
			return a.name:lower() < b.name:lower()
		end)
		local ids = {}
		for _, t in ipairs(targets) do ids[#ids + 1] = t.userId .. (outTo(t.userId) and "*" or "") .. (UI.Sel[t.userId] and "+" or "") end
		local sig = act .. "|" .. tostring(UI.Pre) .. "|" .. table.concat(ids, ",")
		if sig == UI.Sig and not force then return end
		UI.Sig = sig
		setText(UI.Title, "EFFECTS - " .. LABEL[act]:upper())
		setText(UI.Hint, HINT[act])
		for k, b in pairs(UI.Tabs) do pcall(function() b.BackgroundColor3 = (k == act) and accent() or Color3.fromRGB(24, 26, 34) end) end
		for _, c in ipairs(UI.List:GetChildren()) do if not c:IsA("UIListLayout") then c:Destroy() end end
		if #targets == 0 then
			new("TextLabel", {BackgroundTransparency = 1, Size = UDim2.new(1, -4, 0, 28), Text = "No eligible script users in this server.", Font = Enum.Font.Code,
				TextSize = 11, TextColor3 = Color3.fromRGB(138, 147, 166), TextWrapped = true}, UI.List)
		end
		local hallu = act == "hallucinate"
		for i, t in ipairs(targets) do
			local row = new("Frame", {Size = UDim2.new(1, -4, 0, 28), BackgroundColor3 = Color3.fromRGB(16, 18, 24), BorderSizePixel = 0, LayoutOrder = i}, UI.List)
			round(row, 5)
			new("TextLabel", {BackgroundTransparency = 1, Size = UDim2.new(1, hallu and -104 or -72, 1, 0), Position = UDim2.fromOffset(8, 0), Font = Enum.Font.Code, TextSize = 11,
				TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
				Text = t.name .. (t.userId == UI.Pre and "  <" or "")}, row)
			if hallu then
				button(row, UI.Sel[t.userId] and "[x]" or "[ ]", UDim2.fromOffset(28, 20), UDim2.new(1, -96, 0, 4), function()
					UI.Sel[t.userId] = not UI.Sel[t.userId] or nil
					renderPicker(true)
				end)
			end
			local pending = outTo(t.userId)
			button(row, pending and "Cancel" or "Send", UDim2.fromOffset(58, 20), UDim2.new(1, -62, 0, 4), function()
				if pending then
					task.spawn(function() local ok, e2 = post("withdraw", t.userId); notify(ok and "Request withdrawn" or ("Could not withdraw: " .. tostring(e2))); F.Poll() end)
				else
					F.Send(t.userId, t.name)
				end
			end)
		end
	end

	function F.Send(uid, name)
		if os.clock() - (F.LastSend or 0) < 0.8 then return end
		F.LastSend = os.clock()
		local act = UI.Action
		if outTo(uid) then return notify("Already waiting for " .. name .. " to answer") end
		local av
		if act == "hallucinate" then
			av = {}
			for id in pairs(UI.Sel) do if id ~= uid and #av < 4 then av[#av + 1] = tostring(id) end end
			if #av == 0 then
				for _, t in ipairs(R.FxTargets and R.FxTargets() or {}) do if t.userId ~= uid and #av < 4 then av[#av + 1] = tostring(t.userId) end end
			end
			if #av == 0 then av[1] = tostring(Me.UserId) end
		end
		task.spawn(function()
			local ok, err = Env.Mod.FxRequest(uid, act, av)
			notify(ok and (LABEL[act] .. " request sent to " .. name .. " - waiting for them to accept") or (LABEL[act] .. " not sent: " .. tostring(err)))
			if ok then F.Poll() end
		end)
	end

	local function buildPicker()
		if UI.Picker and UI.Picker.Parent then return end
		local f, head, title = panel(host(), "Picker", UDim2.fromOffset(300, 300), UDim2.new(0.5, 0, 0.5, 0), Vector2.new(0.5, 0.5), "EFFECTS")
		UI.Picker, UI.Title = f, title
		button(head, "X", UDim2.fromOffset(22, 18), UDim2.new(1, -26, 0, 4), function() f.Visible = false end)
		UI.Tabs = {}
		for i, k in ipairs(ORDER) do
			UI.Tabs[k] = button(f, SHORT[k], UDim2.new(1 / 3, -8, 0, 22), UDim2.new((i - 1) / 3, 5, 0, 30), function() UI.Action = k; renderPicker(true) end)
		end
		UI.Hint = new("TextLabel", {BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 56), Size = UDim2.new(1, -16, 0, 30), Font = Enum.Font.Code, TextSize = 10,
			TextColor3 = Color3.fromRGB(138, 147, 166), TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = ""}, f)
		UI.List = list(f, UDim2.fromOffset(8, 90), UDim2.new(1, -16, 1, -98))
	end

	function F.OpenPicker(action, pre)
		if not (Env.Mod and Env.Mod.CanFx and Env.Mod.CanFx()) then return notify("Effects: verified players, owner and co-owner only") end
		if not F.Running then return notify("Effects need the live-sync backend (not connected)") end
		buildPicker()
		UI.Action = LABEL[action] and action or UI.Action or "bring"
		UI.Pre = pre
		UI.Picker.Visible = true
		renderPicker(true)
		task.spawn(F.Poll)
	end

	local function buildPill()
		if UI.Pill and UI.Pill.Parent then return end
		UI.Pill = button(host(), "FX", UDim2.fromOffset(40, 24), UDim2.new(0, 8, 0, 56), function()
			if UI.Picker and UI.Picker.Visible then UI.Picker.Visible = false else F.OpenPicker(UI.Action or "bring") end
		end)
		UI.Pill.Visible = false
	end

	-- ===== polling =====
	local function handle(ev)
		local what, who = LABEL[ev.action] or "effect", tostring(ev.name or "?")
		if ev.type == "accepted" then notify(who .. " accepted " .. what)
		elseif ev.type == "declined" then notify(who .. " declined " .. what)
		elseif ev.type == "expired" then notify("Your " .. what .. " request to " .. who .. " expired")
		elseif ev.type == "cancelled" then notify(ev.why == "arrived" and (who .. " reached the meeting point") or (who .. " ended " .. what)) end
	end

	function F.Render()
		local want = {}
		for _, r in ipairs(F.Pending) do
			if ASK[r.action] and R.RoleOf(r.from) then -- the backend already authorised the sender; this client also needs to recognise them as owner / co-owner / verified
				want[r.from] = true
				if not P.Cards[r.from] then
					buildPrompt(r)
					notify(r.name .. " wants to use " .. LABEL[r.action] .. " on you - Accept or Decline")
				end
			end
		end
		for id, card in pairs(P.Cards) do if not want[id] then card:Destroy(); P.Cards[id] = nil end end
		renderPicker()
	end

	function F.Poll()
		local ok, d = call("GET", "/fx?room=" .. HS:UrlEncode(Env.Room) .. "&userId=" .. Me.UserId .. "&token=" .. HS:UrlEncode(Env.Token))
		if not ok then return false, d end
		F.Pending, F.Out = d.pending or {}, d.out or {}
		for _, ev in ipairs(d.events or {}) do pcall(handle, ev) end
		F.Render()
		return true
	end

	function F.Tick()
		local now = os.clock()
		for key, e in pairs(active) do
			if now >= e.EndAt then
				F.End(key, "expired")
			else
				setText(e.Label, ("%s (%s)  %ds"):format(LABEL[key], e.Name, math.ceil(e.EndAt - now)))
				if e.Update then pcall(e.Update) end
			end
		end
		setVis(UI.Pill, F.Running and Env.Mod ~= nil and Env.Mod.CanFx ~= nil and Env.Mod.CanFx() == true)
	end

	function F.Start()
		if F.Running or not Env.Request then return end
		F.Running = true
		buildPill()
		conns[#conns + 1] = Me.CharacterAdded:Connect(function() F.End("dizzy", "respawn") end) -- camera is restored when you respawn
		task.spawn(function()
			local fails = 0
			while F.Running do
				local ok, res = pcall(F.Poll)
				if ok and res then fails = 0 else fails += 1 end
				local busy = #F.Pending > 0 or #F.Out > 0 or next(active) ~= nil
				task.wait(math.min((busy and 1.5 or 4) + fails * 1.5, 12))
			end
		end)
		task.spawn(function() while F.Running do task.wait(0.25); pcall(F.Tick) end end)
	end

	function F.Stop()
		F.Running = false
		for key in pairs(active) do F.End(key, "stopped", true) end
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		table.clear(conns)
		if F.Gui then pcall(function() F.Gui:Destroy() end); F.Gui = nil end
		P, UI = {Cards = {}}, {Sel = {}}
		F.Pending, F.Out = {}, {}
	end

	return F
end
