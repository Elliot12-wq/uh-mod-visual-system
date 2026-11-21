-- VerifiedPlayerFeatures.lua | Bring Users / Hallucinate Users / Dizzy / Silent Hell (10 s, recipient-side, ends with the existing Kill)
-- ONE permission gate for all three features: OWNER, CO-OWNER and VERIFIED players have identical access. Roles come from roles.json + whitelist.json through
-- BannerReceiver.RoleOf (nothing hardcoded); anyone else gets no controls and cannot send.
-- Targets: only OTHER script users with a live banner (R.Banners), never owner / co-owner; verified players only when the sender is the OWNER (R.CanTarget). The target is always notified (toast), no prompt.
-- Env.Fx.SetEnabled(false) turns the effects off for a user entirely.
-- Transport: ModTools relays the request through the backend's /mod (the backend re-checks the sender); the recipient's ModTools hands every queued command to F.Receive.
-- Durations are effect lengths, NOT cooldowns (hallucinate 60 s, dizzy 20 s). Every effect registers a stop function: expiry, re-trigger, respawn and unload all clean up.
-- Env needs: Player, Players, RunService, HttpService, Request, Backend, Room, Token (optional: Sign, ModKey, GetLocalCharacter, IsLowEnd)
return function(Env, R)
	local Players, RS, HS = Env.Players, Env.RunService, Env.HttpService
	local genv = (getgenv and getgenv()) or _G
	local F = {Enabled = genv.UhFxEnabled ~= false}
	local ACT = {bring = true, hallucinate = true, dizzy = true, silenthell = true}
	local TIME = {hallucinate = 60, dizzy = 20, silenthell = 10}
	local DEFT = {hallucinate = 60, dizzy = 20, silenthell = 10} -- default effect lengths (TIME may be overridden per command by F.Run)
	F.Actions = {{key = "bring", label = "Bring Users"}, {key = "hallucinate", label = "Hallucinate Users"}, {key = "dizzy", label = "Dizzy"}, {key = "silenthell", label = "Silent Hell"}}
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
		if not R.CanTarget(target) then return false, "verified players are immune" end
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
	-- THIS client teleports to stand 4 studs in front of the moderator, facing them (same move as the banner "Teleport", reversed). A clear spot (no wall between, solid
	-- flat floor at the moderator's level, no hazard under it) is preferred; when none is found the spot straight in front of the moderator is used anyway, so it always happens.
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

	local function flatLook(sr)
		local v = Vector3.new(sr.CFrame.LookVector.X, 0, sr.CFrame.LookVector.Z)
		return v.Magnitude > 0.01 and v.Unit or Vector3.new(0, 0, -1)
	end

	local function findSpot(sch, sr, me, lift)
		local rp = RaycastParams.new()
		rp.FilterType, rp.RespectCanCollide = Enum.RaycastFilterType.Exclude, true
		rp.FilterDescendantsInstances = {sch, me}
		local op = OverlapParams.new()
		op.FilterType = Enum.RaycastFilterType.Exclude
		op.FilterDescendantsInstances = {sch, me}
		local base, look = sr.Position, flatLook(sr)
		local floorY, voidY = base.Y - lift, workspace.FallenPartsDestroyHeight
		for _, dist in ipairs({4, 5, 7}) do
			for _, ang in ipairs({0, 40, -40, 80, -80}) do
				local at = base + (CFrame.Angles(0, math.rad(ang), 0) * look) * dist
				if not workspace:Raycast(base, at - base, rp) then
					local g = workspace:Raycast(at + Vector3.new(0, 4, 0), Vector3.new(0, -14, 0), rp)
					if g and g.Normal.Y > 0.75 and math.abs(g.Position.Y - floorY) <= 5 and g.Position.Y > voidY + 20 and not dangerous(g) then
						local free = true
						for _, p in ipairs(workspace:GetPartBoundsInBox(CFrame.new(g.Position + Vector3.new(0, 3.3, 0)), Vector3.new(2.6, 5.6, 2.6), op)) do
							if p.CanCollide then
								free = false
								break
							end
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
		local sch, sr
		if Env.ActiveBody then
			local sh
			sch, sh, sr = Env.ActiveBody(sp) -- the moderator's visible reanimated body, never their reset real character
			sr = sr or sh
		else
			sch = sp.Character
			sr = sch and sch:FindFirstChild("HumanoidRootPart")
		end
		local me = myChar()
		if not (sr and me and me.Parent) then return toast("Bring failed: " .. sp.Name .. " is not loaded for you") end
		local root = me:FindFirstChild("HumanoidRootPart")
		local hum = me:FindFirstChildOfClass("Humanoid")
		local cf
		pcall(function()
			local lift = math.max(((hum and hum.HipHeight) or 2) + ((root and root.Size.Y) or 2) / 2, 3)
			cf = findSpot(sch, sr, me, lift)
		end)
		if not cf then -- no clear spot: straight in front of the moderator, stopping short of a wall
			local look, dist = flatLook(sr), 4
			pcall(function()
				local rp = RaycastParams.new()
				rp.FilterType, rp.RespectCanCollide = Enum.RaycastFilterType.Exclude, true
				rp.FilterDescendantsInstances = {sch, me}
				local h = workspace:Raycast(sr.Position, look * 4, rp)
				if h then dist = math.max(1, h.Distance - 1.5) end
			end)
			local pos = sr.Position + look * dist
			cf = CFrame.lookAt(pos, Vector3.new(sr.Position.X, pos.Y, sr.Position.Z))
		end
		pcall(function()
			if hum and hum.SeatPart then hum.Sit = false end
			me:PivotTo(cf)
			if root then root.AssemblyLinearVelocity = Vector3.zero end
		end)
	end

	-- ===== Hallucinate Users =====
	-- a local-only copy of YOUR OWN avatar appears in the distance and creeps toward you for 60 s: a tiny step or two, a stop, then a few more, always facing you.
	-- Root anchored, every part non-colliding / untouchable / unqueryable, no Humanoid (games can't mistake it for a player), parked under the camera; destroyed when
	-- the 60 s are up. Nothing is replicated and your real character is never touched.
	local RIG = {R15 = {walk = "rbxassetid://507777826", idle = "rbxassetid://507766388"}, R6 = {walk = "rbxassetid://180426354", idle = "rbxassetid://180435571"}}
	local function animId(g, folderName, animName, default) -- the avatar's own animation pack (from its Animate script), default Roblox animations otherwise
		local a = g:FindFirstChild("Animate")
		a = a and a:FindFirstChild(folderName)
		a = a and a:FindFirstChild(animName)
		return (a and a:IsA("Animation") and a.AnimationId ~= "") and a.AnimationId or default
	end

	local function hallucinate()
		stopFx("hallucinate")
		local function usable(c) return c and c.Parent and c:FindFirstChild("HumanoidRootPart") and c:FindFirstChildOfClass("Humanoid") end
		local ch = myChar()
		if not usable(ch) then ch = Env.Player.Character end
		if not usable(ch) then return toast("Hallucination unavailable: no character to copy") end
		local g
		local was = ch.Archivable
		ch.Archivable = true
		pcall(function() g = ch:Clone() end)
		ch.Archivable = was
		local root = g and g:FindFirstChild("HumanoidRootPart")
		local hum = g and g:FindFirstChildOfClass("Humanoid")
		if not (root and root:IsA("BasePart") and hum) then
			if g then g:Destroy() end
			return
		end
		local rig = hum.RigType == Enum.HumanoidRigType.R15 and "R15" or "R6"
		local walkId, idleId = animId(g, "walk", "WalkAnim", RIG[rig].walk), animId(g, "idle", "Animation1", RIG[rig].idle)
		local lift = math.max(hum.HipHeight + root.Size.Y / 2, 3)
		local parts = {}
		for _, d in ipairs(g:GetDescendants()) do
			pcall(function()
				if d:IsA("BaseScript") or d:IsA("Sound") or d:IsA("BillboardGui") or d:IsA("ForceField") or d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Humanoid") then
					d:Destroy()
				elseif d:IsA("BasePart") then
					d.CanCollide, d.CanTouch, d.CanQuery, d.CastShadow, d.Massless = false, false, false, false, true
					d.Anchored = d == root -- only the root is anchored: the limbs follow it through their joints and can still animate
					parts[#parts + 1] = {d, d.Transparency}
					d.Transparency = 1
				elseif d:IsA("Decal") then
					parts[#parts + 1] = {d, d.Transparency}
					d.Transparency = 1
				end
			end)
		end
		local ac = Instance.new("AnimationController")
		ac.Parent = g
		local an = Instance.new("Animator")
		an.Parent = ac
		g.PrimaryPart = root
		g.Name = "UhHauntCopy"
		local folder = Instance.new("Folder")
		folder.Name = "UhHaunt"
		g.Parent = folder

		local T = TIME.hallucinate
		local STEP_SPEED, STOP_D, SPAWN_D = 1.6, 5, 42 -- studs/s while stepping, stops this far from you, starts this far away
		local okL, low = pcall(function() return Env.IsLowEnd and Env.IsLowEnd() end)
		local interval = (okL and low) and 1 / 15 or 1 / 30 -- light on low-end devices
		local rp = RaycastParams.new()
		rp.FilterType, rp.RespectCanCollide = Enum.RaycastFilterType.Exclude, true
		local t0 = os.clock()
		local last, acc, gy, pos, lastFade = t0, interval, nil, nil, nil
		local walk, idle, conn
		local walking, phaseEnd = false, 1.5 + math.random()
		local function setWalk(on)
			walking = on
			if on then
				if idle then idle:Stop(0.25) end
				if walk then walk:Play(0.25, 1, 0.35) end -- slow, small steps
			else
				if walk then walk:Stop(0.25) end
				if idle then idle:Play(0.25) end
			end
		end
		local function stop()
			if conn then conn:Disconnect() end
			pcall(function()
				if walk then walk:Stop(0) end
				if idle then idle:Stop(0) end
			end)
			folder:Destroy()
		end
		fx.hallucinate = stop
		expire("hallucinate", stop, T) -- hard stop at exactly 60 s even if the frame loop stalls

		local function step()
			local now = os.clock()
			local t, dt = now - t0, math.min(now - last, 0.25)
			last = now
			if t >= T or not folder.Parent then return stopFx("hallucinate") end
			local me = myChar()
			local tr = me and me:FindFirstChild("HumanoidRootPart")
			if not tr then return end
			local c = tr.Position
			if not pos or Vector3.new(pos.X - c.X, 0, pos.Z - c.Z).Magnitude > 70 then -- first frame, or you ran far off: appear ahead of you again
				local cam = workspace.CurrentCamera
				local lv = cam and cam.CFrame.LookVector or Vector3.new(0, 0, -1)
				lv = Vector3.new(lv.X, 0, lv.Z)
				lv = lv.Magnitude > 0.01 and lv.Unit or Vector3.new(0, 0, -1)
				local d = (CFrame.Angles(0, math.rad(math.random(-25, 25)), 0) * lv) * SPAWN_D
				pos = Vector3.new(c.X + d.X, c.Y, c.Z + d.Z)
			end
			local to = Vector3.new(c.X - pos.X, 0, c.Z - pos.Z)
			local dist = to.Magnitude
			if dist <= STOP_D then -- arrived: stands and watches
				if walking then setWalk(false) end
			elseif t >= phaseEnd then -- step / stop / step ...
				if walking then
					setWalk(false)
					phaseEnd = t + 0.9 + math.random() * 0.9
				else
					setWalk(true)
					phaseEnd = t + 0.8 + math.random() * 0.4
				end
			end
			if walking and dist > STOP_D then pos += to.Unit * (STEP_SPEED * dt) end
			rp.FilterDescendantsInstances = {folder, me, Env.Player.Character}
			local hit = workspace:Raycast(Vector3.new(pos.X, c.Y + 8, pos.Z), Vector3.new(0, -40, 0), rp)
			local y = hit and (hit.Position.Y + lift) or c.Y
			gy = gy and (gy + (y - gy) * 0.25) or y
			local at, here = Vector3.new(c.X, gy, c.Z), Vector3.new(pos.X, gy, pos.Z)
			g:PivotTo(dist > 0.05 and CFrame.lookAt(here, at) or CFrame.new(here))
			local fade = math.min(1, t / 3, (T - t) / 3) -- fade in 3 s, fade out the last 3 s
			if fade ~= lastFade then
				lastFade = fade
				local amt = fade * 0.9
				for _, pr in ipairs(parts) do
					if pr[1].Parent then pr[1].Transparency = 1 - (1 - pr[2]) * amt end
				end
			end
		end

		folder.Parent = workspace.CurrentCamera or workspace
		local function load(id, prio)
			local a = Instance.new("Animation")
			a.AnimationId = id
			local ok, tr = pcall(function() return an:LoadAnimation(a) end)
			if ok and tr then
				tr.Looped, tr.Priority = true, prio
				return tr
			end
		end
		walk, idle = load(walkId, Enum.AnimationPriority.Movement), load(idleId, Enum.AnimationPriority.Idle)
		if idle then idle:Play(0) end
		step()
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

	-- ===== Silent Hell =====
	-- 10 s sequence that runs ONLY on this client: smooth dark-red colour grade (a ColorCorrectionEffect under the camera - Lighting is never touched), the bundled "Who Will Know (24 Bigslow)" track
	-- (Env.SilentHellSong() = Util.Intro15Song, played from 0:00 at low volume), ten black silhouettes creeping in from different directions while movement is frozen (Humanoid values of the real AND the
	-- reanimated character + the PlayerModule controls; nothing is anchored, destroyed or disconnected), then the existing Env.ModActions.Kill exactly once.
	-- ONE stop function cleans up every exit (completion, re-trigger, respawn, FX disabled, unload, lost character); only normal completion kills.
	local function silenthell()
		stopFx("silenthell")
		if not F.Enabled then return end
		local cam = workspace.CurrentCamera
		local me0 = myChar()
		local root0 = me0 and me0:FindFirstChild("HumanoidRootPart")
		if not (cam and root0) then return toast("Silent Hell unavailable: no character") end
		local TS, SND = Env.TweenService or game:GetService("TweenService"), game:GetService("SoundService")
		local T = TIME.silenthell
		local OUTRO, STEPS, VOL = 0.8, 7, 0.14 -- figures finish converging when the last 0.8 s (final impact) start
		local TC = T - OUTRO
		local okL, low = pcall(function() return Env.IsLowEnd and Env.IsLowEnd() end)
		local interval = (okL and low) and 1 / 20 or 0
		local hum0 = me0:FindFirstChildOfClass("Humanoid")
		local lift = math.max(((hum0 and hum0.HipHeight) or 2) + root0.Size.Y / 2, 3)
		local c0 = root0.Position
		local folder = Instance.new("Folder")
		folder.Name = "UhSilentHell"
		local figs = {}
		for i = 1, 10 do -- six anchored, non-colliding black parts each (no Humanoid, no scripts, nothing replicated)
			local s = (lift / 3) * (0.9 + math.random() * 0.25)
			local m, ps = Instance.new("Model"), {}
			m.Name = "F" .. i
			local function part(name, size, off, ball)
				local p = Instance.new("Part")
				p.Name, p.Size, p.Color, p.Material = name, size * s, Color3.new(0, 0, 0), Enum.Material.SmoothPlastic
				p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery, p.CastShadow, p.Massless = true, false, false, false, false, true
				p.TopSurface, p.BottomSurface, p.Transparency = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth, 1
				if ball then p.Shape = Enum.PartType.Ball end
				p.CFrame = CFrame.new(off * s)
				p.Parent = m
				ps[#ps + 1] = p
				return p
			end
			m.PrimaryPart = part("Torso", Vector3.new(2, 2, 1), Vector3.zero)
			part("Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 1.6, 0), true)
			part("LArm", Vector3.new(1, 2, 1), Vector3.new(-1.5, 0, 0))
			part("RArm", Vector3.new(1, 2, 1), Vector3.new(1.5, 0, 0))
			part("LLeg", Vector3.new(1, 2, 1), Vector3.new(-0.5, -2, 0))
			part("RLeg", Vector3.new(1, 2, 1), Vector3.new(0.5, -2, 0))
			m.Parent = folder
			figs[i] = {m = m, p = ps, s = s, a = (i - 1) / 10 * math.pi * 2 + (math.random() - 0.5) * 0.4, r0 = 20 + math.random() * 9, r1 = 3 + (i % 2) * 1.2,
				d = math.random() * 1.2, ph = math.random() * 6.28, lean = (math.random() - 0.5) * 0.3, fade = -1, gy = c0.Y - lift, gyT = c0.Y - lift}
		end

		local t0 = os.clock()
		local dead, outro, lost, lastMe, n = false, false, nil, nil, 0
		local tw, frozen, snd, ctl, ctlOff, conn, cconn = {}, {}, nil, nil, false, nil, nil
		local rp = RaycastParams.new()
		rp.FilterType, rp.RespectCanCollide = Enum.RaycastFilterType.Exclude, true
		local cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "UhSilentHellTint"

		local function tween(o, secs, props)
			pcall(function()
				local x = TS:Create(o, TweenInfo.new(secs, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), props)
				tw[#tw + 1] = x
				x:Play()
			end)
		end
		local function hold(h) -- freeze one Humanoid; a value somebody else sets meanwhile becomes the one restored
			local r = frozen[h]
			if not r then
				r = {ws = h.WalkSpeed, jp = h.JumpPower, jh = h.JumpHeight, up = h.UseJumpPower}
				frozen[h] = r
			end
			if h.WalkSpeed ~= 0 then r.ws = h.WalkSpeed; h.WalkSpeed = 0 end
			if h.JumpPower ~= 0 then r.jp = h.JumpPower; h.JumpPower = 0 end
			if h.JumpHeight ~= 0 then r.jh = h.JumpHeight; h.JumpHeight = 0 end
		end
		local function stop() -- the ONE cleanup
			dead = true
			if conn then conn:Disconnect(); conn = nil end
			if cconn then cconn:Disconnect(); cconn = nil end
			for _, x in ipairs(tw) do pcall(function() x:Cancel() end) end
			table.clear(tw)
			if snd then pcall(function() snd:Stop(); snd:Destroy() end); snd = nil end
			pcall(function() cc:Destroy() end)
			pcall(function() folder:Destroy() end)
			for h, r in pairs(frozen) do
				pcall(function()
					if h.Parent then
						h.WalkSpeed, h.JumpPower, h.JumpHeight = r.ws, r.jp, r.jh
						h.UseJumpPower = r.up
					end
				end)
			end
			table.clear(frozen)
			if ctl and ctlOff then pcall(function() ctl:Enable(true) end); ctlOff = false end
		end
		fx.silenthell = stop
		local function complete() -- normal end only: clean up, then the existing Kill (Player.Character + Reanimate.Character), once
			if fx.silenthell ~= stop then return end
			stopFx("silenthell")
			local A = Env.ModActions
			if A and A.Kill then pcall(A.Kill) end
		end

		local function step()
			local t = os.clock() - t0
			if t >= T then return complete() end
			local cur = workspace.CurrentCamera
			if cur and cur ~= cam then cam = cur; cc.Parent = cam; folder.Parent = cam end
			local me = myChar()
			local tr = me and me:FindFirstChild("HumanoidRootPart")
			if not tr then
				lost = lost or t
				if t - lost > 1.5 then stopFx("silenthell") end -- character / reanimation model gone: clean up, no Kill
				return
			end
			lost = nil
			for _, ch in ipairs({Env.Player.Character or false, me}) do -- real character AND the active reanimated one
				local h = ch and ch:FindFirstChildOfClass("Humanoid")
				if h then hold(h) end
			end
			if me ~= lastMe then
				lastMe = me
				rp.FilterDescendantsInstances = {folder, me, Env.Player.Character}
			end
			if not outro and t >= TC then -- final impact: the grade goes black-red, the song fades out
				outro = true
				tween(cc, OUTRO, {Brightness = -0.6, Contrast = 0.55, TintColor = Color3.fromRGB(190, 20, 20)})
				if snd then tween(snd, OUTRO, {Volume = 0}) end
			end
			n += 1
			local c = tr.Position
			local gy0 = c.Y - lift
			for i, f in ipairs(figs) do
				local u = math.clamp((t - f.d) / (TC - f.d), 0, 1)
				local x = u * STEPS -- creep: STEPS short lunges with a pause after each, finishing exactly at u = 1
				local k = math.floor(x)
				local fr = math.clamp((x - k) / 0.6, 0, 1)
				local g = (k + fr * fr * (3 - 2 * fr)) / STEPS
				local r = f.r1 + (f.r0 - f.r1) * (1 - g)
				local a = f.a + 0.35 * u
				local px, pz = c.X + math.cos(a) * r, c.Z + math.sin(a) * r
				if n % 6 == i % 6 then
					local hit = workspace:Raycast(Vector3.new(px, c.Y + 6, pz), Vector3.new(0, -40, 0), rp)
					f.gyT = hit and hit.Position.Y or gy0
				end
				f.gy = f.gy + (f.gyT - f.gy) * 0.3
				local pos = Vector3.new(px, f.gy + 3 * f.s + 0.06 * f.s * math.sin(t * 2 + f.ph), pz)
				f.m:PivotTo(CFrame.lookAt(pos, Vector3.new(c.X, pos.Y, c.Z)) * CFrame.Angles(f.lean, 0, math.rad(3) * math.sin(t * 1.6 + f.ph)))
				local fade = math.clamp((t - f.d) / 1.6, 0, 1)
				if fade ~= f.fade then
					f.fade = fade
					for _, p in ipairs(f.p) do p.Transparency = 1 - fade end
				end
			end
		end

		cc.Parent = cam
		tween(cc, 1.4, {TintColor = Color3.fromRGB(255, 80, 70), Saturation = -0.25, Contrast = 0.25, Brightness = -0.1}) -- smooth fade into the red atmosphere
		pcall(function() -- no walking / jumping input (the Humanoid values are held every step as well)
			local ps = Env.Player:FindFirstChild("PlayerScripts")
			local pm = ps and ps:FindFirstChild("PlayerModule")
			local c = pm and require(pm):GetControls()
			if c and c.controlsEnabled ~= false then c:Disable(); ctl, ctlOff = c, true end
		end)
		cconn = Env.Player.CharacterAdded:Connect(function() stopFx("silenthell") end) -- respawn: back to normal at once, no Kill
		task.delay(T, complete) -- hard stop even if the frame loop stalls
		if not pcall(step) then return stopFx("silenthell") end
		folder.Parent = cam
		task.spawn(function() -- the supplied track from the existing bundled asset (written to the asset folder once), local to this client
			local S = Env.SilentHellSong and Env.SilentHellSong()
			if not S then return end
			local okE, ready = pcall(S.Ensure, 60)
			if dead or not (okE and ready) or os.clock() - t0 > T - 1.5 then return end
			local okA, id = pcall(getcustomasset, S.Path)
			if dead or not okA or type(id) ~= "string" or id == "" then return end
			local sn = Instance.new("Sound")
			sn.Name, sn.SoundId, sn.Volume, sn.Looped, sn.TimePosition = "UhSilentHellSong", id, 0, false, 0
			sn.Parent = SND
			snd = sn
			sn:Play()
			tween(sn, 1.5, {Volume = VOL})
		end)
		local acc = interval
		conn = RS.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < interval then return end
			acc = 0
			if not pcall(step) then stopFx("silenthell") end
		end)
	end

	-- ===== recipient: entry point (called by ModTools for every queued command) =====
	-- returns true when the command was one of the three effects (handled or rejected here), false for everything else
	function F.Receive(c)
		if type(c) ~= "table" or not ACT[c.action] then return false end
		local by, action = tonumber(c.by), c.action
		if not by or by == Env.Player.UserId or not F.Can(by) then return true end -- sender must be owner / co-owner / verified
		if not F.Enabled or not R.CanBeModeratedBy(by) then return true end -- switched off, or an immune recipient (verified recipients accept only an OWNER in this server)
		local sp = Players:GetPlayerByUserId(by)
		if not sp then return true end -- the sender must actually be in this server
		if action == "bring" then
			toast(sp.Name .. " is bringing you to them")
			bring(sp)
		elseif action == "hallucinate" then
			toast(sp.Name .. " made you hallucinate (" .. TIME.hallucinate .. " s)")
			hallucinate()
		elseif action == "silenthell" then
			toast(sp.Name .. " sent you to Silent Hell (" .. TIME.silenthell .. " s)")
			silenthell()
		else
			toast(sp.Name .. " made you dizzy (" .. TIME.dizzy .. " s)")
			dizzy()
		end
		return true
	end

	-- ===== backend-authorised entry point (Live Player Log command channel) =====
	-- The Worker already verified the moderator's role and addressed THIS script session. `secs` = optional effect length (clamped 5..120 s; Silent Hell is fixed at 10 s). Returns ok, reason.
	function F.Run(action, who, secs)
		if action ~= "hallucinate" and action ~= "dizzy" and action ~= "silenthell" then return false, "unsupported" end
		if action == "silenthell" then
			if not F.Enabled then return false, "effects disabled by the recipient" end
			toast(tostring(who) .. " sent you to Silent Hell (" .. TIME.silenthell .. " s)")
			silenthell()
			return true
		end
		local dt = tonumber(secs)
		TIME[action] = dt and math.clamp(math.floor(dt), 5, 120) or DEFT[action]
		toast(tostring(who) .. " made you " .. (action == "dizzy" and "dizzy" or "hallucinate") .. " (" .. TIME[action] .. " s)")
		if action == "hallucinate" then hallucinate() else dizzy() end
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
