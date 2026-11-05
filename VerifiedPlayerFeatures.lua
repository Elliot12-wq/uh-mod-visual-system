-- VerifiedPlayerFeatures.lua | Bring Users / Hallucinate Users / Dizzy
-- ONE permission gate for all three features: OWNER, CO-OWNER and VERIFIED players have identical access. Roles come from roles.json + whitelist.json through
-- BannerReceiver.RoleOf (nothing hardcoded); anyone else gets no controls and cannot send.
-- Targets: only OTHER script users with a live banner (R.Banners), never owner / co-owner / verified. The target is always notified (toast), no prompt.
-- Env.Fx.SetEnabled(false) turns the effects off for a user entirely.
-- Transport: ModTools relays the request through the backend's /mod (the backend re-checks the sender); the recipient's ModTools hands every queued command to F.Receive.
-- Durations are effect lengths, NOT cooldowns (hallucinate 60 s, dizzy 20 s). Every effect registers a stop function: expiry, re-trigger, respawn and unload all clean up.
-- Env needs: Player, Players, RunService, HttpService, Request, Backend, Room, Token (optional: Sign, ModKey, GetLocalCharacter, IsLowEnd)
return function(Env, R)
	local Players, RS, HS = Env.Players, Env.RunService, Env.HttpService
	local genv = (getgenv and getgenv()) or _G
	local F = {Enabled = genv.UhFxEnabled ~= false}
	local ACT = {bring = true, hallucinate = true, dizzy = true}
	local TIME = {hallucinate = 60, dizzy = 20}
	F.Actions = {{key = "bring", label = "Bring Users"}, {key = "hallucinate", label = "Hallucinate Users"}, {key = "dizzy", label = "Dizzy"}}
	F.Time = TIME

	-- ===== permissions: the single gate =====
	function F.Can(uid) return uid ~= nil and R.RoleOf(uid) ~= nil end -- owner / co-owner / verified
	function F.CanUse() return Env.Request ~= nil and F.Can(Env.Player.UserId) end
	function F.Handles(action) return ACT[action] == true end

	-- ===== sender =====
	function F.Request(target, action)
		if not ACT[action] then return false, "bad action" end
		if not F.CanUse() then return false, "verified players, owner and co-owner only" end
		target = tonumber(target)
		if not target or target == Env.Player.UserId then return false, "bad target" end
		if R.IsWhitelisted(target) then return false, "verified players are immune" end
		if not (R.Banners and R.Banners[target] and Players:GetPlayerByUserId(target)) then return false, "not an active script user" end
		local body = {room = Env.Room, userId = Env.Player.UserId, token = Env.Token, key = Env.ModKey, target = target, action = action}
		if Env.Sign then body = Env.Sign("/mod", body, tostring(target) .. ":" .. action) end
		local ok, res = pcall(Env.Request, {Url = Env.Backend .. "/mod", Method = "POST", Headers = {["Content-Type"] = "application/json"}, Body = HS:JSONEncode(body)})
		if not ok then return false, tostring(res) end
		if type(res) ~= "table" then return false, "no response" end
		if res.StatusCode ~= 200 then
			local okD, d = pcall(HS.JSONDecode, HS, res.Body or "")
			return false, (okD and type(d) == "table" and d.error) or ("HTTP " .. tostring(res.StatusCode))
		end
		return true
	end

	-- ===== helpers =====
	local function toast(msg)
		pcall(function() game:GetService("StarterGui"):SetCore("SendNotification", {Title = "Moderator", Text = msg, Duration = 6}) end)
	end
	local function myChar() return (Env.GetLocalCharacter and Env.GetLocalCharacter()) or Env.Player.Character end

	local fx = {}
	local function stopFx(name)
		local f = fx[name]
		fx[name] = nil
		if f then pcall(f) end
	end
	local function expire(name, stop, secs) -- hard stop even if a frame loop stalls
		task.delay(secs, function() if fx[name] == stop then stopFx(name) end end)
	end

	-- ===== Bring Users =====
	-- fallback when no safe spot exists: a marker over the moderator for 30 s
	local function meet(sp)
		stopFx("meet")
		local head = sp.Character and sp.Character:FindFirstChild("Head")
		local pg = Env.Player:FindFirstChildOfClass("PlayerGui")
		if not (head and pg) then return toast("No safe spot - meet " .. sp.Name) end
		local g = Instance.new("BillboardGui")
		g.Name, g.Adornee, g.AlwaysOnTop, g.Size, g.StudsOffset, g.MaxDistance = "UhMeet", head, true, UDim2.fromOffset(170, 30), Vector3.new(0, 3.5, 0), math.huge
		g.Parent = pg
		local l = Instance.new("TextLabel", g)
		l.Size, l.BackgroundColor3, l.BackgroundTransparency, l.Text = UDim2.fromScale(1, 1), Color3.fromRGB(24, 24, 30), 0.25, "Meet " .. sp.Name
		l.TextColor3, l.Font, l.TextSize = Color3.new(1, 1, 1), Enum.Font.GothamBold, 14
		Instance.new("UICorner", l).CornerRadius = UDim.new(0, 8)
		local function stop() g:Destroy() end
		fx.meet = stop
		expire("meet", stop, 30)
		toast("No safe spot next to " .. sp.Name .. " - meet them (marker shown)")
	end

	local BAD = {"kill", "lava", "death", "damage", "acid", "spike", "hurt", "void", "trap", "laser"}
	local function dangerous(hit)
		local inst = hit.Instance
		if hit.Material == Enum.Material.Water or hit.Material == Enum.Material.CrackedLava or hit.Material == Enum.Material.Magma then return true end
		if inst:FindFirstChild("TouchInterest") then return true end
		local n = (inst.Name .. "." .. (inst.Parent and inst.Parent.Name or "")):lower()
		for _, w in ipairs(BAD) do
			if n:find(w, 1, true) then return true end
		end
		return false
	end

	-- a spot in front of the moderator: clear line of sight (no wall between), flat solid floor at the moderator's level, no hazard under it, room for a character
	local function findSpot(sch, sr, me, lift)
		local rp = RaycastParams.new()
		rp.FilterType, rp.RespectCanCollide = Enum.RaycastFilterType.Exclude, true
		rp.FilterDescendantsInstances = {sch, me}
		local op = OverlapParams.new()
		op.FilterType = Enum.RaycastFilterType.Exclude
		op.FilterDescendantsInstances = {sch, me}
		local base = sr.Position
		local look = Vector3.new(sr.CFrame.LookVector.X, 0, sr.CFrame.LookVector.Z)
		look = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)
		local floorY, voidY = base.Y - lift, workspace.FallenPartsDestroyHeight
		for _, dist in ipairs({5, 4, 7}) do
			for _, ang in ipairs({0, 40, -40, 80, -80}) do
				local at = base + (CFrame.Angles(0, math.rad(ang), 0) * look) * dist
				if not workspace:Raycast(base, at - base, rp) then
					local g = workspace:Raycast(at + Vector3.new(0, 4, 0), Vector3.new(0, -14, 0), rp)
					if g and g.Normal.Y > 0.75 and math.abs(g.Position.Y - floorY) <= 5 and g.Position.Y > voidY + 20 and not dangerous(g) then
						local free = true
						for _, p in ipairs(workspace:GetPartBoundsInBox(CFrame.new(g.Position + Vector3.new(0, 3.3, 0)), Vector3.new(2.6, 5.6, 2.6), op)) do
							if p.CanCollide then free = false break end
						end
						if free then
							local pos = g.Position + Vector3.new(0, lift, 0)
							return CFrame.lookAt(pos, Vector3.new(base.X, pos.Y, base.Z))
						end
					end
				end
			end
		end
	end

	local function bring(sp)
		local sch = sp.Character
		local sr = sch and sch:FindFirstChild("HumanoidRootPart")
		local me = myChar()
		local root = me and me:FindFirstChild("HumanoidRootPart")
		local hum = me and me:FindFirstChildOfClass("Humanoid")
		local cf
		if sr and root and hum and me.Parent then
			local ok, r = pcall(findSpot, sch, sr, me, math.max(hum.HipHeight + root.Size.Y / 2, 3))
			cf = ok and r or nil
		end
		if not cf then return meet(sp) end
		pcall(function()
			if hum.SeatPart then hum.Sit = false end
			me:PivotTo(cf)
			root.AssemblyLinearVelocity = Vector3.zero
		end)
	end

	-- ===== Hallucinate Users =====
	-- a local-only, anchored, non-colliding copy of the sender's character creeps toward YOU for 60 s, then fades and is destroyed. It lives under the camera
	-- (invisible to the game's own workspace scans), nothing is replicated and no real character is touched.
	local function hallucinate(sp)
		stopFx("hallucinate")
		local function alive(ch)
			local h = ch and ch:FindFirstChildOfClass("Humanoid")
			return ch and ch.Parent and h and h.Health > 0
		end
		local src = sp.Character
		if not alive(src) then -- sender gone: copy another active script user instead
			src = nil
			for uid in pairs(R.Banners or {}) do
				local p = uid ~= Env.Player.UserId and Players:GetPlayerByUserId(uid)
				if p and alive(p.Character) then
					src = p.Character
					break
				end
			end
		end
		if not src then return toast("Hallucination unavailable: no character to copy") end
		local g
		local was = src.Archivable
		src.Archivable = true
		pcall(function() g = src:Clone() end)
		src.Archivable = was
		local root = g and g:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) then
			if g then g:Destroy() end
			return
		end
		local parts = {}
		for _, d in ipairs(g:GetDescendants()) do
			if d:IsA("BaseScript") or d:IsA("Sound") or d:IsA("BillboardGui") or d:IsA("ForceField") or d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Humanoid") then
				d:Destroy()
			elseif d:IsA("BasePart") then
				d.Anchored, d.CanCollide, d.CanTouch, d.CanQuery, d.CastShadow = true, false, false, false, false
				parts[#parts + 1] = {d, d.Transparency}
			elseif d:IsA("Decal") then
				parts[#parts + 1] = {d, d.Transparency}
			end
		end
		g.PrimaryPart = root
		local cf, size = g:GetBoundingBox()
		local off = root.Position.Y - (cf.Position.Y - size.Y / 2)
		local hl = Instance.new("Highlight")
		hl.FillColor, hl.OutlineColor, hl.DepthMode = Color3.fromRGB(10, 10, 14), Color3.fromRGB(190, 200, 255), Enum.HighlightDepthMode.Occluded
		hl.FillTransparency, hl.OutlineTransparency = 1, 1
		hl.Parent = g
		local folder = Instance.new("Folder")
		folder.Name = "UhHaunt"
		g.Name = "UhHauntCopy"
		g.Parent = folder
		local T = TIME.hallucinate
		local ang, ph, startD, stopD = math.random() * math.pi * 2, math.random() * 6.28, 55 + math.random() * 20, 8 + math.random() * 5
		local rp = RaycastParams.new()
		rp.FilterType, rp.RespectCanCollide = Enum.RaycastFilterType.Exclude, true
		local okL, low = pcall(function() return Env.IsLowEnd and Env.IsLowEnd() end)
		local interval = (okL and low) and 1 / 15 or 1 / 30 -- light on low-end devices
		local t0, acc, gy, conn = os.clock(), interval, nil, nil
		local function stop()
			if conn then conn:Disconnect() end
			folder:Destroy()
		end
		local function step()
			local t = os.clock() - t0
			if t >= T or not folder.Parent then return stopFx("hallucinate") end
			local me = myChar()
			local tr = me and me:FindFirstChild("HumanoidRootPart")
			if not tr then return end
			local fade = math.min(1, t / 4, (T - t) / 4) -- fade in 4 s, fade out the last 4 s
			local k = math.min(1, t / (T - 8)) -- creep: ~55-75 studs away at the start, 8-13 studs at the end
			local d = stopD + (startD - stopD) * (1 - k)
			local a = ang + 0.12 * math.sin(t * 0.35 + ph)
			local c = tr.Position
			local x, z = c.X + math.cos(a) * d, c.Z + math.sin(a) * d
			rp.FilterDescendantsInstances = {folder, me}
			local hit = workspace:Raycast(Vector3.new(x, c.Y + 8, z), Vector3.new(0, -40, 0), rp)
			local y = hit and (hit.Position.Y + off) or c.Y
			gy = gy and (gy + (y - gy) * 0.2) or y
			g:PivotTo(CFrame.lookAt(Vector3.new(x, gy, z), Vector3.new(c.X, gy, c.Z)) * CFrame.Angles(0, 0, math.rad(3) * math.sin(t * 0.9 + ph)))
			local amt = fade * 0.7 * (0.88 + 0.12 * math.sin(t * 6 + ph))
			for _, pr in ipairs(parts) do
				if pr[1].Parent then pr[1].Transparency = 1 - (1 - pr[2]) * amt end
			end
			hl.FillTransparency, hl.OutlineTransparency = 1 - 0.45 * fade, 1 - 0.35 * fade
		end
		fx.hallucinate = stop
		expire("hallucinate", stop, T)
		step()
		folder.Parent = workspace.CurrentCamera or workspace
		conn = RS.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < interval then return end
			acc = 0
			if not pcall(step) then stopFx("hallucinate") end
		end)
	end

	-- ===== Dizzy =====
	-- camera sway + shake for 20 s, plus a mild walk-speed wobble. The camera offset is applied after the camera update and removed again before the next one, so the real
	-- camera CFrame is never changed permanently; FieldOfView / WalkSpeed are restored on expiry, respawn, re-trigger and unload (only if nobody else changed them meanwhile).
	local function dizzy()
		stopFx("dizzy")
		local cam = workspace.CurrentCamera
		if not cam then return end
		local DT = TIME.dizzy
		local me = myChar()
		local hum = me and me:FindFirstChildOfClass("Humanoid")
		local fov, fovSet, speed, speedSet, applied, conn = cam.FieldOfView, nil, nil, nil, nil, nil
		local t0 = os.clock()
		local function undo()
			if applied then
				if cam.Parent then cam.CFrame = cam.CFrame * applied:Inverse() end
				applied = nil
			end
		end
		local function stop()
			pcall(function() RS:UnbindFromRenderStep("UhFxDizzyPost") end)
			pcall(function() RS:UnbindFromRenderStep("UhFxDizzyPre") end)
			pcall(undo)
			pcall(function() if fovSet and math.abs(cam.FieldOfView - fovSet) < 0.01 then cam.FieldOfView = fov end end)
			pcall(function() if hum and speedSet and math.abs(hum.WalkSpeed - speedSet) < 0.01 then hum.WalkSpeed = speed end end)
			if conn then conn:Disconnect() end
		end
		fx.dizzy = stop
		expire("dizzy", stop, DT)
		conn = Env.Player.CharacterAdded:Connect(function() stopFx("dizzy") end) -- respawn: back to normal at once
		RS:BindToRenderStep("UhFxDizzyPre", Enum.RenderPriority.First.Value, function()
			if not pcall(undo) then stopFx("dizzy") end
		end)
		RS:BindToRenderStep("UhFxDizzyPost", Enum.RenderPriority.Camera.Value + 1, function()
			local ok = pcall(function()
				local t = os.clock() - t0
				if t >= DT or workspace.CurrentCamera ~= cam then return stopFx("dizzy") end
				local e = math.min(1, t / 1.5, (DT - t) / 1.5) -- ease in / out
				local nx, ny = math.noise(t * 8, 0.5, 0), math.noise(t * 8, 7.5, 0)
				local off = CFrame.new(0.1 * math.sin(t * 2.3) + 0.05 * nx, 0.08 * math.sin(t * 3.1 + 1) + 0.05 * ny, 0)
					* CFrame.Angles(math.rad(0.8) * math.sin(t * 2.1), math.rad(0.7) * math.sin(t * 1.4 + 2), math.rad(2.2) * math.sin(t * 1.7))
				off = CFrame.identity:Lerp(off, e)
				cam.CFrame = cam.CFrame * off
				applied = off
				if not fovSet or math.abs(cam.FieldOfView - fovSet) >= 0.01 then fov = cam.FieldOfView end
				fovSet = fov + 1.5 * math.sin(t * 1.3) * e
				cam.FieldOfView = fovSet
				if hum and hum.Parent then
					if not speedSet or math.abs(hum.WalkSpeed - speedSet) >= 0.01 then speed = hum.WalkSpeed end
					speedSet = speed * (1 + 0.08 * math.sin(t * 1.7) * e)
					hum.WalkSpeed = speedSet
				end
			end)
			if not ok then stopFx("dizzy") end
		end)
	end

	-- ===== recipient: entry point (called by ModTools for every queued command) =====
	-- returns true when the command was one of the three effects (handled or rejected here), false for everything else
	function F.Receive(c)
		if type(c) ~= "table" or not ACT[c.action] then return false end
		local by, action = tonumber(c.by), c.action
		if not by or by == Env.Player.UserId or not F.Can(by) then return true end -- sender must be owner / co-owner / verified
		if not F.Enabled or R.IsWhitelisted(Env.Player.UserId) then return true end -- switched off, or an immune role
		local sp = Players:GetPlayerByUserId(by)
		if not sp then return true end -- the sender must actually be in this server
		if action == "bring" then
			toast(sp.Name .. " is bringing you to them")
			bring(sp)
		elseif action == "hallucinate" then
			toast(sp.Name .. " made you hallucinate (" .. TIME.hallucinate .. " s)")
			hallucinate(sp)
		else
			toast(sp.Name .. " made you dizzy (" .. TIME.dizzy .. " s)")
			dizzy()
		end
		return true
	end

	function F.StopEffects()
		local names = {}
		for n in pairs(fx) do names[#names + 1] = n end
		for _, n in ipairs(names) do stopFx(n) end
	end
	function F.SetEnabled(on)
		F.Enabled = on ~= false
		genv.UhFxEnabled = F.Enabled
		if not F.Enabled then F.StopEffects() end
	end
	F.Stop = F.StopEffects

	return F
end
