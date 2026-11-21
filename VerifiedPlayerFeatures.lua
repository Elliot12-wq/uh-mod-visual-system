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
	local ACT = {bring = true, hallucinate = true, dizzy = true, silenthell = true, dropbomb = true, domain = true, cooked = true}
	local BOMB_LIFE = 10.0 -- Drop Bomb: explosion lifetime in seconds, counted from the detonation (the fall is not part of it)
	local TIME = {hallucinate = 60, dizzy = 20, silenthell = 10, dropbomb = BOMB_LIFE, domain = 30, cooked = 10}
	local DEFT = {hallucinate = 60, dizzy = 20, silenthell = 10, dropbomb = BOMB_LIFE, domain = 30, cooked = 10} -- default effect lengths (TIME may be overridden per command by F.Run; Domain is fixed at 30 s)
	F.Actions = {{key = "bring", label = "Bring Users"}, {key = "hallucinate", label = "Hallucinate Users"}, {key = "dizzy", label = "Dizzy"}, {key = "silenthell", label = "Silent Hell"}, {key = "dropbomb", label = "Drop Bomb"}, {key = "domain", label = "Domain", desc = "Activates Gojo's Unlimited Void domain around the selected player for 30 seconds"}, {key = "cooked", label = "Cooked", desc = "Calls a 5-operator SWAT squad that aims and fires at the selected player for 10 seconds"}}
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

	-- ===== Domain (Gojo's Unlimited Void) =====
	-- 30 s Domain Expansion that runs ONLY on this client (nothing here is replicated to other players). The recipient cannot move for the whole 30 s: the lock starts the moment the command arrives,
	-- before any visual exists, and covers the real character AND the active (reanimated) one - Humanoid walk / jump values + the PlayerModule controls, re-applied every step (nothing is anchored, destroyed or
	-- disconnected; no teleport, no damage, no Kill / Deanimate). Only the values THIS effect changed are restored. Visuals: expansion (darken, blue-white flash, shock discs, shell + void floor expand) ->
	-- Unlimited Void (starfield, tilted rotating rings, orbiting fragments, energy arcs, light rays from the void core, drifting particles; camera-local grade / bloom / blur, Lighting is never touched) ->
	-- collapse (everything contracts and fades over the last 3 s). Everything lives in the ONE container "UhDomainExpansion" (+ the camera post effects). ONE stop function cleans up every exit
	-- (30 s expiry, re-trigger, respawn, FX disabled, unload, lost character).
	local function domain()
		stopFx("domain")
		if not F.Enabled then return end
		local cam = workspace.CurrentCamera
		local me0 = myChar()
		local function rootOf(ch) return ch and (ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart or ch:FindFirstChildWhichIsA("BasePart")) or nil end
		local root0 = rootOf(me0)
		if not (cam and root0) then return toast("Domain unavailable: no character") end
		local TS = Env.TweenService or game:GetService("TweenService")
		local T, INTRO, OUTRO = TIME.domain, 3.0, 3.0 -- expansion runs 0.6 -> 3.6 s, collapse over the last OUTRO seconds
		local TC = T - OUTRO
		local okL, lowE = pcall(function() return Env.IsLowEnd and Env.IsLowEnd() end)
		local low = (okL and lowE) and true or false
		local interval = low and 1 / 20 or 0
		local R = low and 140 or 170 -- domain radius (studs)
		local ctr = root0.Position + Vector3.new(0, 2, 0)
		local rnd = Random.new()
		local C_VOID, C_NAVY, C_INDIGO = Color3.fromRGB(4, 6, 22), Color3.fromRGB(10, 14, 52), Color3.fromRGB(34, 22, 104)
		local C_BLUE, C_VIOLET, C_WHITE = Color3.fromRGB(80, 130, 255), Color3.fromRGB(130, 96, 255), Color3.fromRGB(226, 240, 255)

		local t0 = os.clock()
		local lost, ph, lastE = nil, 0, -1
		local tw, frozen, snd, ctl, ctlOff, conn, cconn = {}, {}, nil, nil, false, nil, nil
		local folder = Instance.new("Folder")
		folder.Name = "UhDomainExpansion"
		local cc, bl, bu, dof = Instance.new("ColorCorrectionEffect"), Instance.new("BloomEffect"), Instance.new("BlurEffect"), nil
		cc.Name, bl.Name, bu.Name = "UhDomainGrade", "UhDomainBloom", "UhDomainBlur"
		bl.Intensity, bl.Size, bl.Threshold, bu.Size = 0, 24, 0.9, 0
		if not low then
			dof = Instance.new("DepthOfFieldEffect")
			dof.Name, dof.FarIntensity, dof.NearIntensity, dof.FocusDistance, dof.InFocusRadius = "UhDomainDepth", 0, 0, 30, 70
		end
		local lt, emit, anc -- void-core light / particle emitter / beam anchor (created in build)
		local st, rigs, bms = {}, {}, {} -- static pieces / rotating rings (+ their fragments) / beams, all revealed by e
		local sp, sc, ap, ac = {}, {}, {}, {} -- reusable arrays for BulkMoveTo (no per-frame Instance creation)

		local function ease(u) return u * u * (3 - 2 * u) end
		local function tween(o, secs, props, style, dir)
			pcall(function()
				local x = TS:Create(o, TweenInfo.new(secs, style or Enum.EasingStyle.Sine, dir or Enum.EasingDirection.InOut), props)
				tw[#tw + 1] = x
				x:Play()
			end)
		end

		-- ----- movement lock (real character + active reanimated character + PlayerModule controls) -----
		local function hold(h) -- freeze one Humanoid; records only what THIS effect changes, a value somebody else sets meanwhile becomes the one restored
			local r = frozen[h]
			if not r then r = {up = h.UseJumpPower}; frozen[h] = r end
			if h.WalkSpeed ~= 0 then r.ws = h.WalkSpeed; h.WalkSpeed = 0 end
			if h.JumpPower ~= 0 then r.jp = h.JumpPower; h.JumpPower = 0 end
			if h.JumpHeight ~= 0 then r.jh = h.JumpHeight; h.JumpHeight = 0 end
		end
		local function lockCtl() -- walking / jumping input; re-disabled every step in case another effect re-enabled the controls
			pcall(function()
				if not ctl then
					local ps = Env.Player:FindFirstChild("PlayerScripts")
					local pm = ps and ps:FindFirstChild("PlayerModule")
					ctl = pm and require(pm):GetControls() or nil
				end
				if ctl and ctl.controlsEnabled ~= false then ctl:Disable(); ctlOff = true end
			end)
		end
		local function lockMove() -- returns the active character (myChar())
			local me = myChar()
			for _, ch in ipairs({Env.Player.Character or false, me or false}) do
				local h = ch and ch:FindFirstChildOfClass("Humanoid")
				if h then hold(h) end
			end
			lockCtl()
			return me
		end

		local function stop() -- the ONE cleanup
			if conn then conn:Disconnect(); conn = nil end
			if cconn then cconn:Disconnect(); cconn = nil end
			for _, x in ipairs(tw) do pcall(function() x:Cancel() end) end
			table.clear(tw)
			if snd then pcall(function() snd:Stop() end); snd = nil end
			pcall(function() cc:Destroy() end)
			pcall(function() bl:Destroy() end)
			pcall(function() bu:Destroy() end)
			if dof then pcall(function() dof:Destroy() end) end
			pcall(function() folder:Destroy() end)
			for h, r in pairs(frozen) do
				pcall(function()
					if h.Parent then
						if r.ws then h.WalkSpeed = r.ws end
						if r.jp then h.JumpPower = r.jp end
						if r.jh then h.JumpHeight = r.jh end
						if r.jp or r.jh then h.UseJumpPower = r.up end -- last: writing JumpPower / JumpHeight can flip it
					end
				end)
			end
			table.clear(frozen)
			if ctl and ctlOff then pcall(function() ctl:Enable(true) end); ctlOff = false end
		end
		fx.domain = stop
		expire("domain", stop, T) -- hard stop at exactly 30 s even if the frame loop stalls
		pcall(lockMove) -- movement is locked NOW, before any visual is built
		cconn = Env.Player.CharacterAdded:Connect(function() stopFx("domain") end) -- respawn: back to normal at once

		-- ----- visuals -----
		local function mk(name, shape, size, color, mat, tr, cf) -- anchored, non-colliding, non-queryable cosmetic part inside the container
			local p = Instance.new("Part")
			p.Shape = shape
			p.Name, p.Size, p.Color, p.Material, p.Transparency = name, size, color, mat, tr
			p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery, p.CastShadow, p.Massless = true, false, false, false, false, true
			p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
			p.CFrame = cf or CFrame.new(ctr)
			p.Parent = folder
			return p
		end
		local function reveal(e) -- e = 0 (hidden, contracted) .. 1 (fully expanded); only runs while e changes (expansion / collapse)
			local s = 0.08 + 0.92 * e
			for i, it in ipairs(st) do
				local p = it.p
				sp[i] = p
				sc[i] = CFrame.new(ctr + it.off * s) * it.rot
				if it.size then p.Size = it.size * s end
				p.Transparency = 1 - (1 - it.tr) * e
			end
			workspace:BulkMoveTo(sp, sc, Enum.BulkMoveMode.FireCFrameChanged)
			for _, rg in ipairs(rigs) do
				rg.p.Size = Vector3.new(0.3, 2 * rg.r * s, 2 * rg.r * s)
				rg.p.Transparency = 1 - 0.1 * e
				for _, fr in ipairs(rg.fr) do fr.p.Transparency = 1 - (1 - fr.tr) * e end
			end
			for _, bm in ipairs(bms) do bm.b.Width0, bm.b.Width1 = bm.w * e, bm.w * e end
		end
		local function animate(t, e) -- the rotating pieces: ring discs (the beam dashes ride on them), orbiting fragments, the sweeping beam anchor
			local s = 0.08 + 0.92 * e
			local k = 0
			for _, rg in ipairs(rigs) do
				local cf = CFrame.new(ctr) * rg.tilt * CFrame.Angles(t * rg.spd, 0, 0)
				k += 1; ap[k] = rg.p; ac[k] = cf
				for _, fr in ipairs(rg.fr) do
					k += 1; ap[k] = fr.p
					ac[k] = cf * CFrame.new(0, math.cos(fr.a) * rg.r * s, math.sin(fr.a) * rg.r * s) * CFrame.Angles(t * fr.x, t * fr.y, t * fr.z)
				end
			end
			workspace:BulkMoveTo(ap, ac, Enum.BulkMoveMode.FireCFrameChanged)
			if anc then anc.CFrame = CFrame.new(ctr) * CFrame.Angles(0, t * 0.05, 0) end
		end
		local function build()
			folder.Parent = cam
			cc.Parent, bl.Parent, bu.Parent = cam, cam, cam
			if dof then dof.Parent = cam end
			local function add(p, off, rot, size, tr) st[#st + 1] = {p = p, off = off, rot = rot, size = size, tr = tr} end
			-- dome shell: inward-facing tiles on a Fibonacci sphere (closed blocks, so their inner faces are what you see from inside)
			local NP = low and 20 or 36
			local gold = math.pi * (3 - math.sqrt(5))
			local side = math.sqrt(4 * math.pi / NP) * R * 1.3
			local tiles = {C_VOID, C_NAVY, C_INDIGO}
			for i = 1, NP do
				local y = 1 - (i - 0.5) / NP * 2
				local rr = math.sqrt(1 - y * y)
				local dir = Vector3.new(math.cos(gold * i) * rr, y, math.sin(gold * i) * rr)
				local p = mk("Shell", Enum.PartType.Block, Vector3.new(side, side, 1), tiles[1 + (i % 3)], Enum.Material.SmoothPlastic, 1)
				add(p, dir * R, CFrame.lookAt(Vector3.zero, -dir) * CFrame.Angles(0, 0, rnd:NextNumber(0, math.pi)), Vector3.new(side, side, 1), 0.08)
			end
			-- distant stars at different depths (parallax gives the sense of infinite space)
			for i = 1, (low and 26 or 64) do
				local rad = R * rnd:NextNumber(0.3, 0.92)
				local z = rnd:NextNumber(0.5, 1.2) * rad / 45
				local p = mk("Star", Enum.PartType.Ball, Vector3.new(z, z, z), (i % 3 == 0) and C_BLUE or C_WHITE, Enum.Material.Neon, 1)
				add(p, rnd:NextUnitVector() * rad, CFrame.new(), nil, 0.05)
			end
			-- void floor over the real ground + a glowing circle under the target
			local rp = RaycastParams.new()
			rp.FilterType, rp.RespectCanCollide = Enum.RaycastFilterType.Exclude, true
			rp.FilterDescendantsInstances = {folder, me0, Env.Player.Character or folder}
			local hit = workspace:Raycast(root0.Position, Vector3.new(0, -80, 0), rp)
			local oy = (hit and hit.Position.Y or (root0.Position.Y - 3)) - ctr.Y
			local flat = CFrame.Angles(0, 0, math.pi / 2)
			local ground = mk("VoidFloor", Enum.PartType.Cylinder, Vector3.new(1, 2 * R, 2 * R), C_VOID, Enum.Material.SmoothPlastic, 1)
			ground.Reflectance = 0.12
			add(ground, Vector3.new(0, oy - 0.4, 0), flat, Vector3.new(1, 2 * R, 2 * R), 0)
			add(mk("Rune", Enum.PartType.Cylinder, Vector3.new(1, 26, 26), C_BLUE, Enum.Material.Neon, 1), Vector3.new(0, oy - 0.3, 0), flat, Vector3.new(1, 26, 26), 0.55)
			-- luminous blue-white void core high above the target, with layered halos and a light
			local coreOff = Vector3.new(0, 78, 0)
			local core = mk("VoidCore", Enum.PartType.Ball, Vector3.new(22, 22, 22), C_WHITE, Enum.Material.Neon, 1)
			add(core, coreOff, CFrame.new(), Vector3.new(22, 22, 22), 0)
			add(mk("VoidHalo1", Enum.PartType.Ball, Vector3.new(42, 42, 42), C_BLUE, Enum.Material.Neon, 1), coreOff, CFrame.new(), Vector3.new(42, 42, 42), 0.8)
			add(mk("VoidHalo2", Enum.PartType.Ball, Vector3.new(70, 70, 70), C_VIOLET, Enum.Material.Neon, 1), coreOff, CFrame.new(), Vector3.new(70, 70, 70), 0.93)
			lt = Instance.new("PointLight")
			lt.Color, lt.Range, lt.Brightness, lt.Shadows = C_BLUE, 60, 0, false
			lt.Parent = core
			-- beams: attachments live on parts of the container, so nothing here costs a per-frame update
			local function att(p, pos) local a = Instance.new("Attachment"); a.Position = pos; a.Parent = p; return a end
			local function beam(a0, a1, w, color, curve)
				local b = Instance.new("Beam")
				b.Attachment0, b.Attachment1 = a0, a1
				b.Color = ColorSequence.new(color)
				b.LightEmission, b.LightInfluence, b.FaceCamera = 1, 0, true
				b.Width0, b.Width1 = 0, 0
				if curve then
					b.Segments, b.CurveSize0, b.CurveSize1 = 20, curve, -curve
					b.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.2, 0.15), NumberSequenceKeypoint.new(0.8, 0.15), NumberSequenceKeypoint.new(1, 1)})
				else
					b.Segments, b.Transparency = 1, NumberSequence.new(0.1)
				end
				b.Parent = a0.Parent
				bms[#bms + 1] = {b = b, w = w}
			end
			-- concentric rings at different angles / speeds: a faint disc + dashed beam rim, with fragments orbiting on each ring
			local RAD, SPD = {0.3, 0.46, 0.64, 0.86}, {0.55, -0.38, 0.26, -0.17}
			local K, NF = low and 8 or 14, low and 2 or 4
			for i = 1, (low and 3 or 4) do
				local r = R * RAD[i]
				local disc = mk("Ring" .. i, Enum.PartType.Cylinder, Vector3.new(0.3, 2 * r, 2 * r), (i % 2 == 0) and C_VIOLET or C_BLUE, Enum.Material.Neon, 1)
				local rg = {p = disc, r = r, spd = SPD[i], fr = {}, tilt = CFrame.Angles(rnd:NextNumber(-0.9, 0.9) + (i % 2) * 0.6, rnd:NextNumber(0, 6.28), rnd:NextNumber(-0.7, 0.7))}
				for j = 0, K - 1 do
					local a0 = j / K * math.pi * 2
					local a1 = a0 + math.pi * 2 / K * 0.58
					beam(att(disc, Vector3.new(0, math.cos(a0) * r, math.sin(a0) * r)), att(disc, Vector3.new(0, math.cos(a1) * r, math.sin(a1) * r)), 1 + i * 0.3, (j % 2 == 0) and C_WHITE or C_BLUE)
				end
				for j = 1, NF do
					local sz = rnd:NextNumber(4, 11)
					local blk = (j % 2 == 0)
					local p = mk("Fragment", blk and Enum.PartType.Block or Enum.PartType.Cylinder, blk and Vector3.new(sz, sz * 2.4, sz * 0.5) or Vector3.new(sz * 0.4, sz * 1.6, sz * 1.6),
						blk and C_INDIGO or C_BLUE, blk and Enum.Material.ForceField or Enum.Material.Neon, 1)
					rg.fr[j] = {p = p, a = (j - 1) / NF * math.pi * 2 + rnd:NextNumber(-0.3, 0.3), x = rnd:NextNumber(-0.7, 0.7), y = rnd:NextNumber(-0.7, 0.7), z = rnd:NextNumber(-0.7, 0.7), tr = blk and 0.2 or 0.3}
				end
				rigs[i] = rg
			end
			-- layered energy arcs + thin light rays from the core (the anchor sweeps slowly)
			anc = mk("Anchor", Enum.PartType.Ball, Vector3.new(1, 1, 1), C_WHITE, Enum.Material.Neon, 1)
			for i = 1, (low and 3 or 8) do
				local r0, r1 = R * rnd:NextNumber(0.4, 0.88), R * rnd:NextNumber(0.4, 0.88)
				beam(att(anc, rnd:NextUnitVector() * r0), att(anc, rnd:NextUnitVector() * r1), rnd:NextNumber(0.8, 1.7), (i % 2 == 0) and C_WHITE or C_VIOLET, rnd:NextNumber(30, 80) * ((i % 2 == 0) and 1 or -1))
			end
			for _ = 1, (low and 4 or 10) do
				local d = rnd:NextUnitVector()
				beam(att(core, Vector3.zero), att(anc, Vector3.new(d.X, -math.abs(d.Y), d.Z) * R * 0.9), 0.4, C_WHITE)
			end
			-- drifting glowing particles through the whole volume (built-in sparkle texture, no external asset)
			local vol = mk("Volume", Enum.PartType.Block, Vector3.new(R * 1.5, R * 0.8, R * 1.5), C_WHITE, Enum.Material.Neon, 1)
			emit = Instance.new("ParticleEmitter")
			emit.Name, emit.Enabled, emit.Rate, emit.Shape = "UhDomainMotes", false, low and 12 or 28, Enum.ParticleEmitterShape.Box
			emit.Lifetime, emit.Speed, emit.SpreadAngle = NumberRange.new(6, 10), NumberRange.new(1, 5), Vector2.new(180, 180)
			emit.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.2, 2.2), NumberSequenceKeypoint.new(1, 0)})
			emit.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.2, 0.15), NumberSequenceKeypoint.new(0.8, 0.3), NumberSequenceKeypoint.new(1, 1)})
			emit.Color = ColorSequence.new(C_WHITE, C_BLUE)
			emit.LightEmission, emit.LightInfluence, emit.Drag, emit.Acceleration = 1, 0, 0.6, Vector3.new(0, 1.5, 0)
			emit.Parent = vol
			reveal(0)
		end

		-- ----- cinematic phases -----
		local function shock() -- three expanding energy discs (the "circular boundary" rushing outward)
			for i = 1, 3 do
				local tilt = (i == 1) and 0 or ((i == 2) and 0.9 or -0.9)
				local sw = mk("Shock" .. i, Enum.PartType.Cylinder, Vector3.new(0.4, 4, 4), (i == 2) and C_BLUE or C_WHITE, Enum.Material.Neon, 0.15, CFrame.new(ctr) * CFrame.Angles(tilt, 0, 0) * CFrame.Angles(0, 0, math.pi / 2))
				tween(sw, 1.7, {Size = Vector3.new(0.4, 2.3 * R, 2.3 * R), Transparency = 1}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				task.delay(1.9, function() pcall(function() sw:Destroy() end) end)
			end
		end
		local function boom() -- the engine's built-in explosion sample, slowed down (rbxasset://, no external asset)
			local s = Instance.new("Sound")
			s.Name, s.SoundId, s.Volume, s.PlaybackSpeed = "UhDomainBoom", "rbxasset://sounds/impact_explosion_03.mp3", 0.7, 0.55
			s.Parent = folder
			snd = s
			s:Play()
		end
		local function flash()
			tween(cc, 0.12, {Brightness = 0.85, Contrast = -0.15, Saturation = -0.9, TintColor = C_WHITE}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			tween(bl, 0.12, {Intensity = 3.2, Size = 60}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			tween(bu, 0.12, {Size = 20}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			if emit then emit:Emit(low and 30 or 80) end
			shock()
			boom()
		end
		local function voidGrade() -- settle into the deep indigo / blue-white Unlimited Void look
			tween(cc, 1.6, {Brightness = -0.2, Contrast = 0.3, Saturation = -0.35, TintColor = Color3.fromRGB(150, 170, 255)})
			tween(bl, 1.6, {Intensity = 1.1, Size = 30, Threshold = 0.85})
			tween(bu, 1.6, {Size = 0})
			if dof then tween(dof, 2, {FarIntensity = 0.3}) end
			if lt then tween(lt, 2, {Brightness = 3}) end
			if emit then emit.Enabled = true end
		end
		local function collapse() -- everything fades back to the original look, finishing exactly at T
			tween(cc, OUTRO, {Brightness = 0, Contrast = 0, Saturation = 0, TintColor = Color3.new(1, 1, 1)})
			tween(bl, OUTRO, {Intensity = 0})
			if dof then tween(dof, OUTRO, {FarIntensity = 0}) end
			if lt then tween(lt, OUTRO, {Brightness = 0}) end
			if emit then emit.Enabled = false end
		end

		local function step()
			local t = os.clock() - t0
			if t >= T then return stopFx("domain") end
			local cur = workspace.CurrentCamera
			if cur and cur ~= cam then
				cam = cur
				folder.Parent, cc.Parent, bl.Parent, bu.Parent = cam, cam, cam, cam
				if dof then dof.Parent = cam end
			end
			local tr = rootOf(lockMove()) -- the movement lock is re-applied EVERY step (new Humanoid after a reanimation swap, controls re-enabled by someone else, ...)
			if not tr then
				lost = lost or t
				if t - lost > 1.5 then stopFx("domain") end -- character / reanimation model gone: clean up
				return
			end
			lost = nil
			if ph < 1 and t >= 0.55 then ph = 1; flash() end
			if ph < 2 and t >= 0.75 then ph = 2; voidGrade() end
			if ph < 3 and t >= TC then ph = 3; collapse() end
			local e = math.min(ease(math.clamp((t - 0.6) / INTRO, 0, 1)), ease(math.clamp(1 - (t - TC) / OUTRO, 0, 1)))
			if e ~= lastE then lastE = e; reveal(e) end
			if e > 0 then animate(t, e) end
		end

		if not pcall(build) then return stopFx("domain") end
		tween(cc, 0.55, {Brightness = -0.5, Contrast = 0.15, Saturation = -0.45, TintColor = Color3.fromRGB(130, 140, 210)}) -- phase 1: the scene darkens
		local acc = interval
		conn = RS.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < interval then return end
			acc = 0
			if not pcall(step) then stopFx("domain") end
		end)
	end

	-- ===== Drop Bomb =====
	-- A locally built bomb (Parts / emitters only, nothing replicated) falls from 35 studs above THIS client's active character (myChar()), tracks it while spinning and detonates the moment its nose reaches the
	-- character (character position + ground raycast, no Touched). At that instant the layered explosion starts and the existing Env.ModActions.Kill runs exactly once. The explosion lives in its own Workspace
	-- folder for EXACTLY BOMB_LIFE = 10.0 s counted from detonation (the fall is NOT part of it) and survives the respawn the Kill causes. ONE stop function cleans up every exit (10 s expiry, re-trigger,
	-- respawn BEFORE impact, FX disabled, unload, lost character); only an impact kills. Sound = the engine's built-in explosion sample (rbxasset://, no external asset ids; silent if the client lacks it).
	local function dropbomb()
		stopFx("dropbomb")
		if not F.Enabled then return end
		local cam = workspace.CurrentCamera
		local me0 = myChar()
		local root0 = me0 and me0:FindFirstChild("HumanoidRootPart")
		if not (cam and root0) then return toast("Drop Bomb unavailable: no character") end
		local TS = Env.TweenService or game:GetService("TweenService")
		local ES, ED, C = Enum.EasingStyle, Enum.EasingDirection, Color3.fromRGB
		local okL, low = pcall(function() return Env.IsLowEnd and Env.IsLowEnd() end)
		low = okL and low == true
		local Q, interval = low and 0.5 or 1, low and 1 / 30 or 0 -- low-end: half the particles, 30 Hz fall loop
		local FALL_H, FALL_MAX, NOSE, SHAKE = 35, 4, 4.1, 0.7 -- start height, fall safety limit (s), centre-to-nose distance of the bomb, camera shake length (s)
		local folder = Instance.new("Folder")
		folder.Name = "UhDropBomb"
		local tw, conn, cconn, snd, bomb = {}, nil, nil, nil, nil
		local dead, detonated, shaking, applied, shakeT0 = false, false, false, nil, 0
		local lastMe, lost, gy, n = me0, nil, nil, 0
		local rp = RaycastParams.new()
		rp.FilterType, rp.RespectCanCollide = Enum.RaycastFilterType.Exclude, true
		rp.FilterDescendantsInstances = {folder, me0, Env.Player.Character}

		local function tween(o, secs, props, style, dir, delay, rep, rev)
			pcall(function()
				local x = TS:Create(o, TweenInfo.new(secs, style or ES.Quad, dir or ED.Out, rep or 0, rev or false, delay or 0), props)
				tw[#tw + 1] = x
				x:Play()
			end)
		end
		local function ns(...)
			local a, k = {...}, {}
			for i = 1, #a, 2 do k[#k + 1] = NumberSequenceKeypoint.new(a[i], a[i + 1]) end
			return NumberSequence.new(k)
		end
		local function cs(...)
			local a, k = {...}, {}
			for i = 1, #a, 2 do k[#k + 1] = ColorSequenceKeypoint.new(a[i], a[i + 1]) end
			return ColorSequence.new(k)
		end
		local function mk(parent, name, shape, size, cf, color, mat, tr) -- anchored, non-colliding, non-queryable cosmetic part
			local p = Instance.new("Part")
			p.Shape = shape
			p.Name, p.Size, p.Color, p.Material, p.Transparency = name, size, color, mat, tr or 0
			p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery, p.CastShadow, p.Massless = true, false, false, false, false, true
			p.TopSurface, p.BottomSurface, p.CFrame = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth, cf
			p.Parent = parent
			return p
		end
		local function groundAt(p) -- ground height below a point (nil when nothing is hit)
			local hit = workspace:Raycast(p + Vector3.new(0, 4, 0), Vector3.new(0, -500, 0), rp)
			return hit and hit.Position.Y
		end

		-- camera shake: offset applied after the camera update and removed before the next one (same pattern as Dizzy); ends by itself after SHAKE seconds, the camera is never changed permanently
		local function undo()
			if applied then
				if cam.Parent then cam.CFrame = cam.CFrame * applied:Inverse() end
				applied = nil
			end
		end
		local function unshake()
			if shaking then
				shaking = false
				pcall(function() RS:UnbindFromRenderStep("UhFxDropBombPost") end)
				pcall(function() RS:UnbindFromRenderStep("UhFxDropBombPre") end)
			end
			pcall(undo)
		end
		local function shake()
			if shaking then return end
			shaking, shakeT0 = true, os.clock()
			RS:BindToRenderStep("UhFxDropBombPre", Enum.RenderPriority.First.Value, function()
				if not pcall(undo) then unshake() end
			end)
			RS:BindToRenderStep("UhFxDropBombPost", Enum.RenderPriority.Camera.Value + 1, function()
				local t = os.clock() - shakeT0
				if t >= SHAKE or workspace.CurrentCamera ~= cam then return unshake() end
				local k = (1 - t / SHAKE) ^ 2 -- decays to exactly 0
				local off = CFrame.new(math.noise(t * 31, 1.5, 0) * 1.4 * k, math.noise(t * 29, 8.5, 0) * 1.4 * k, 0) * CFrame.Angles(0, 0, math.rad(2) * math.noise(t * 23, 4.5, 0) * k)
				cam.CFrame = cam.CFrame * off
				applied = off
			end)
		end

		-- the ONE cleanup
		local function stop()
			if dead then return end
			dead = true
			if conn then conn:Disconnect(); conn = nil end
			if cconn then cconn:Disconnect(); cconn = nil end
			pcall(unshake)
			for _, x in ipairs(tw) do pcall(function() x:Cancel() end) end
			table.clear(tw)
			if snd then pcall(function() snd:Stop(); snd:Destroy() end); snd = nil end
			pcall(function() folder:Destroy() end) -- bomb, parts, rings, emitters, lights: everything lives under this folder
		end
		fx.dropbomb = stop

		-- the bomb: dark metal body + domed nose, banded and riveted, brass fuse assembly with a pulsing glowing indicator, four swept stabilising fins, suspension lugs (nose points down, -Y)
		local function buildBomb()
			local m = Instance.new("Model")
			m.Name = "UhBomb"
			local DARK, STEEL, BRASS, RED = C(32, 34, 40), C(112, 118, 128), C(184, 142, 58), C(196, 38, 30)
			local METAL, PLATE = Enum.Material.Metal, Enum.Material.DiamondPlate
			local BLOCK, BALL, CYL = Enum.PartType.Block, Enum.PartType.Ball, Enum.PartType.Cylinder
			local UP = CFrame.Angles(0, 0, math.pi / 2) -- a Cylinder part's axis is X: this stands it upright
			local function cyl(name, h, d, y, color, mat) return mk(m, name, CYL, Vector3.new(h, d, d), CFrame.new(0, y, 0) * UP, color, mat) end
			local function ball(name, d, y, color, mat) return mk(m, name, BALL, Vector3.new(d, d, d), CFrame.new(0, y, 0), color, mat) end
			cyl("Body", 4.8, 2.8, 0, DARK, METAL)
			ball("Nose", 2.8, -2.4, DARK, METAL)
			ball("NoseTip", 0.8, -3.75, STEEL, METAL)
			cyl("NoseBand", 0.35, 2.95, -1.9, STEEL, PLATE)
			cyl("LowerBand", 0.35, 2.95, -0.95, STEEL, PLATE)
			cyl("Stripe", 0.6, 2.88, 0.1, RED, METAL)
			cyl("UpperBand", 0.35, 2.95, 1.25, STEEL, PLATE)
			cyl("TailCap", 0.8, 2.3, 2.8, DARK, METAL)
			cyl("Collar", 0.5, 1.5, 3.45, BRASS, METAL)
			cyl("Stem", 1.0, 0.55, 4.2, DARK, METAL)
			local ind = ball("Indicator", 0.95, 4.85, C(255, 72, 24), Enum.Material.Neon)
			for k = 0, 3 do -- stepped fins, swept back towards the tail
				local R = CFrame.Angles(0, k * math.pi / 2, 0)
				mk(m, "FinA" .. k, BLOCK, Vector3.new(0.22, 2.4, 1.5), R * CFrame.new(0, 2.1, 1.75), STEEL, METAL)
				mk(m, "FinB" .. k, BLOCK, Vector3.new(0.22, 1.8, 0.8), R * CFrame.new(0, 2.8, 2.9), RED, METAL)
			end
			for _, a in ipairs({45, 225}) do -- suspension lugs
				mk(m, "Lug", BLOCK, Vector3.new(0.35, 0.7, 0.6), CFrame.Angles(0, math.rad(a), 0) * CFrame.new(0, 0.1, 1.6), STEEL, METAL)
			end
			for k = 0, 7 do -- rivets on the lower band
				mk(m, "Rivet", BALL, Vector3.new(0.24, 0.24, 0.24), CFrame.Angles(0, k * math.pi / 4 + math.pi / 8, 0) * CFrame.new(0, -0.95, 1.48), STEEL, METAL)
			end
			local lamp = Instance.new("PointLight")
			lamp.Color, lamp.Brightness, lamp.Range = C(255, 70, 30), 2.5, 14
			lamp.Parent = ind
			tween(ind, 0.16, {Color = C(255, 205, 90)}, ES.Sine, ED.InOut, 0, -1, true) -- pulsing indicator (cancelled by stop)
			tween(lamp, 0.16, {Brightness = 0.6}, ES.Sine, ED.InOut, 0, -1, true)
			local sp = Instance.new("ParticleEmitter") -- sputtering fuse sparks, left behind as a trail while the bomb falls
			sp.Rate, sp.Lifetime, sp.Speed, sp.SpreadAngle, sp.EmissionDirection = 45 * Q, NumberRange.new(0.25, 0.5), NumberRange.new(6, 13), Vector2.new(35, 35), Enum.NormalId.Top
			sp.Size, sp.LightEmission, sp.Acceleration, sp.Color = ns(0, 0.4, 1, 0), 1, Vector3.new(0, -12, 0), cs(0, C(255, 230, 140), 1, C(255, 110, 30))
			sp.Parent = ind
			m.WorldPivot = CFrame.new()
			return m
		end

		-- the explosion at c (centre, = character root) with the ground at height g; every animation is a Tween or a tapering emitter, all of them ending inside BOMB_LIFE
		local function boom(c, g)
			local BLOCK, BALL = Enum.PartType.Block, Enum.PartType.Ball
			local NEON, SMOOTH = Enum.Material.Neon, Enum.Material.SmoothPlastic
			local SMOKE = "rbxasset://textures/particles/smoke_main.dds" -- engine built-in particle texture (same one the legacy Smoke object uses)
			local core = mk(folder, "Core", BLOCK, Vector3.one, CFrame.new(c), Color3.new(1, 1, 1), SMOOTH, 1)
			local base = mk(folder, "Base", BLOCK, Vector3.new(12, 0.2, 12), CFrame.new(c.X, g + 0.1, c.Z), Color3.new(1, 1, 1), SMOOTH, 1)
			local function ball(name, d, color, tr) return mk(folder, name, BALL, Vector3.one * d, CFrame.new(c), color, NEON, tr) end
			local function lamp(color, range, bright)
				local l = Instance.new("PointLight")
				l.Color, l.Range, l.Brightness, l.Shadows = color, range, bright, false
				l.Parent = core
				return l
			end
			-- lights: a hard white flash that is gone in 0.5 s, plus a fire glow that dims over the whole 10 s
			tween(lamp(C(255, 235, 190), 80, 35), 0.5, {Brightness = 0}, ES.Quad, ED.Out)
			tween(lamp(C(255, 130, 40), 48, 6), BOMB_LIFE, {Brightness = 0, Range = 18}, ES.Sine, ED.In)
			-- central flash, bright inner fireball, dark red outer blast, lingering rising fireball that cools and fades
			tween(ball("Flash", 4, C(255, 248, 220), 0), 0.3, {Size = Vector3.one * 46, Transparency = 1})
			local inner = ball("FireCore", 6, C(255, 226, 110), 0.05)
			tween(inner, 0.55, {Size = Vector3.one * 30}, ES.Quart, ED.Out)
			tween(inner, 1.7, {Transparency = 1}, ES.Sine, ED.In)
			local shell = ball("BlastShell", 8, C(205, 42, 22), 0.3)
			tween(shell, 0.85, {Size = Vector3.one * 46}, ES.Quart, ED.Out)
			tween(shell, 3.4, {Transparency = 1}, ES.Quad, ED.In)
			local heat = ball("Fireball", 10, C(255, 150, 40), 0.1)
			tween(heat, 7, {Size = Vector3.one * 26}, ES.Exponential, ED.Out)
			tween(heat, 8, {CFrame = CFrame.new(c + Vector3.new(0, 10, 0))}, ES.Sine, ED.Out)
			tween(heat, 8, {Color = C(120, 24, 10)}, ES.Linear, ED.Out)
			tween(heat, 8.6, {Transparency = 1}, ES.Quad, ED.In)
			-- shock rings: three on the ground (energy ring + two outer ones) and two vertical ones around the fireball
			local function ring(host, cf, color, R, secs, delay, h, inner)
				local a = Instance.new("CylinderHandleAdornment")
				a.Adornee, a.CFrame, a.Color3, a.Height, a.Transparency = host, cf, color, h, 0.05
				a.Radius = 2
				a.InnerRadius = 1.2
				a.AlwaysOnTop, a.ZIndex = false, 1
				a.Parent = folder
				tween(a, secs, {Radius = R, InnerRadius = R * inner}, ES.Quart, ED.Out, delay)
				tween(a, secs, {Transparency = 1}, ES.Quad, ED.In, delay)
			end
			local flat = CFrame.Angles(math.pi / 2, 0, 0) -- the adornment's axis is Z: this lays the ring on the ground
			ring(base, flat, C(255, 160, 50), 48, 1.6, 0, 0.5, 0.86)
			ring(base, flat, C(255, 244, 200), 34, 1.1, 0.08, 0.4, 0.9)
			ring(base, flat, C(210, 48, 28), 64, 2.3, 0.18, 0.6, 0.9)
			ring(core, CFrame.new(), C(255, 190, 90), 38, 1.2, 0.04, 0.35, 0.9)
			ring(core, CFrame.Angles(0, math.rad(70), math.rad(20)), C(255, 120, 40), 30, 1.0, 0.1, 0.35, 0.9)
			-- particles: (parent, properties, sustained rate, burst count, seconds over which the rate tapers to 0; the taper plus the longest lifetime never exceed BOMB_LIFE)
			local function em(parent, p, rate, burst, taper)
				local e = Instance.new("ParticleEmitter")
				e.Rate = rate * Q
				for k, v in pairs(p) do e[k] = v end
				e.Parent = parent
				if burst > 0 then e:Emit(math.max(1, math.floor(burst * Q))) end
				if taper then tween(e, taper, {Rate = 0}, ES.Linear, ED.Out) end
			end
			local TOP = Enum.NormalId.Top
			em(core, { -- outward sparks
				Color = cs(0, C(255, 240, 170), 1, C(255, 110, 30)), Size = ns(0, 0.9, 1, 0), Transparency = ns(0, 0, 0.8, 0.2, 1, 1), LightEmission = 1,
				Lifetime = NumberRange.new(1, 2.2), Speed = NumberRange.new(45, 115), SpreadAngle = Vector2.new(180, 180), Acceleration = Vector3.new(0, -55, 0), Drag = 0.3, Rotation = NumberRange.new(0, 360),
			}, 0, 90)
			em(core, { -- glowing embers that rise and drift
				Color = cs(0, C(255, 175, 60), 1, C(200, 40, 10)), Size = ns(0, 0.5, 0.6, 0.32, 1, 0), Transparency = ns(0, 0.1, 0.7, 0.25, 1, 1), LightEmission = 0.9,
				Lifetime = NumberRange.new(4, 6), Speed = NumberRange.new(5, 22), SpreadAngle = Vector2.new(75, 75), EmissionDirection = TOP, Acceleration = Vector3.new(0, 7, 0), Drag = 1.5,
				Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-60, 60),
			}, 26, 40, 4)
			em(core, { -- subtle glow motes
				Color = cs(0, C(255, 190, 90), 1, C(255, 100, 30)), Size = ns(0, 1.6, 1, 0), Transparency = ns(0, 0.4, 1, 1), LightEmission = 1,
				Lifetime = NumberRange.new(2.5, 3.5), Speed = NumberRange.new(1, 5), SpreadAngle = Vector2.new(180, 180), Acceleration = Vector3.new(0, 2, 0), Drag = 1,
			}, 12, 10, 6.5)
			em(base, { -- dense low smoke rolling out of the ground
				Texture = SMOKE, Color = cs(0, C(255, 160, 80), 0.15, C(84, 74, 68), 1, C(34, 34, 38)), Size = ns(0, 7, 0.35, 22, 1, 34), Transparency = ns(0, 0.6, 0.12, 0.25, 0.65, 0.45, 1, 1),
				LightEmission = 0.1, LightInfluence = 0.6, Lifetime = NumberRange.new(5, 6.5), Speed = NumberRange.new(8, 22), SpreadAngle = Vector2.new(75, 75), EmissionDirection = TOP,
				Acceleration = Vector3.new(0, 2, 0), Drag = 1.8, Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-25, 25),
			}, 34, 42, 3.5)
			em(core, { -- rising smoke column
				Texture = SMOKE, Color = cs(0, C(255, 140, 60), 0.2, C(72, 66, 64), 1, C(30, 30, 32)), Size = ns(0, 9, 0.4, 26, 1, 40), Transparency = ns(0, 0.5, 0.15, 0.3, 0.7, 0.5, 1, 1),
				LightEmission = 0.1, LightInfluence = 0.6, Lifetime = NumberRange.new(5.5, 6.5), Speed = NumberRange.new(14, 32), SpreadAngle = Vector2.new(18, 18), EmissionDirection = TOP,
				Acceleration = Vector3.new(0, 4, 0), Drag = 1.4, Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-20, 20),
			}, 26, 26, 3.4)
			em(base, { -- cosmetic debris
				Texture = SMOKE, Color = cs(0, C(70, 56, 44), 1, C(40, 34, 30)), Size = ns(0, 0.55, 1, 0.3), Transparency = ns(0, 0.2, 0.8, 0.2, 1, 1), LightEmission = 0, LightInfluence = 1,
				Lifetime = NumberRange.new(1.6, 3), Speed = NumberRange.new(25, 65), SpreadAngle = Vector2.new(55, 55), EmissionDirection = TOP, Acceleration = Vector3.new(0, -70, 0),
				Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-300, 300),
			}, 0, 36)
			local s = Instance.new("Sound") -- positional, synchronised with the detonation
			s.Name, s.SoundId, s.Volume, s.RollOffMaxDistance = "UhDropBombBoom", "rbxasset://sounds/impact_explosion_03.mp3", 1.4, 400
			s.Parent = core
			snd = s
			s:Play()
			shake()
		end

		-- impact: stop the fall loop, drop the bomb, start the 10 s explosion clock, then the existing Kill exactly once
		local function detonate(c)
			if detonated or dead then return end
			detonated = true
			if conn then conn:Disconnect(); conn = nil end -- no frame loop during the explosion: tweens, emitters and the hard expiry do all the work
			if cconn then cconn:Disconnect(); cconn = nil end -- the respawn the Kill causes must not touch the remaining visuals
			pcall(function() bomb:Destroy() end)
			bomb = nil
			expire("dropbomb", stop, BOMB_LIFE) -- the 10.0 s start HERE (impact), not when the bomb spawned; hard stop even if nothing else runs
			local okG, g = pcall(groundAt, c)
			pcall(boom, c, (okG and g) or (c.Y - 3))
			local A = Env.ModActions
			if A and A.Kill then pcall(A.Kill) end -- the existing Kill (Player.Character + Reanimate.Character), once
		end

		-- fall: gravity-accelerated descent, spin, XZ glued to the character; impact = nose at head height (inequality test, so a hitch can never skip it), ground reached, or the safety limit
		local c0 = root0.Position
		local bx, by, bz, vy, spin = c0.X, c0.Y + FALL_H, c0.Z, 16, 0
		local t0 = os.clock()
		local function fall(dt)
			local t = os.clock() - t0
			local me = myChar()
			local tr = me and me:FindFirstChild("HumanoidRootPart")
			if not tr then
				lost = lost or t
				if t - lost > 1.5 then stopFx("dropbomb") end -- character / reanimation model gone before impact: clean up, no Kill
				return
			end
			lost = nil
			if me ~= lastMe then
				lastMe = me
				rp.FilterDescendantsInstances = {folder, me, Env.Player.Character}
			end
			local c = tr.Position
			n += 1
			if not gy or n % 3 == 0 then gy = groundAt(c) or (c.Y - 3) end
			vy = math.min(vy + 150 * dt, 120)
			by -= vy * dt
			spin += 9 * dt
			local k = 1 - math.exp(-14 * dt)
			bx, bz = bx + (c.X - bx) * k, bz + (c.Z - bz) * k
			bomb:PivotTo(CFrame.new(bx, by, bz) * CFrame.Angles(0.06 * math.sin(t * 7), spin, 0.06 * math.cos(t * 6)))
			local tip = by - NOSE
			if tip <= c.Y + 2.5 or tip <= gy + 0.3 or t >= FALL_MAX then detonate(c) end
		end

		local okB, b = pcall(buildBomb)
		if not okB then
			toast("Drop Bomb failed to build")
			return stopFx("dropbomb")
		end
		bomb = b
		bomb:PivotTo(CFrame.new(bx, by, bz))
		bomb.Parent = folder
		folder.Parent = workspace
		cconn = Env.Player.CharacterAdded:Connect(function() stopFx("dropbomb") end) -- respawn BEFORE impact: back to normal at once, no Kill (disconnected at impact)
		local acc = interval
		conn = RS.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < interval then return end
			local d = math.min(acc, 0.1)
			acc = 0
			if not pcall(fall, d) and not detonated then stopFx("dropbomb") end
		end)
	end

	-- ===== Cooked =====
	-- Recipient-side only (nothing is replicated). Five SWAT operators ring THIS player, track and fire for TIME.cooked s. One Heartbeat loop drives all five, ONE container "UhCooked", ONE stop function
	-- (expiry, respawn, character lost / dead, FX disabled, unload). A re-trigger while active is ignored (no duplicate squad). One ray per shot: a confirmed hit = exactly COOKED_DMG HP once, a miss = 0.
	local COOKED_DMG = 3
	local function cooked()
		if fx.cooked or not F.Enabled then return end
		for _, v in ipairs(workspace:GetChildren()) do
			if v.Name == "UhCooked" then pcall(function() v:Destroy() end) end
		end
		local me0 = myChar()
		local root0 = me0 and (me0:FindFirstChild("HumanoidRootPart") or me0.PrimaryPart)
		if not root0 then return toast("Cooked unavailable: no character") end
		local okL, lowE = pcall(function() return Env.IsLowEnd and Env.IsLowEnd() end)
		local low = okL and lowE == true
		local C3, V3, CF, ANG, MT = Color3.fromRGB, Vector3.new, CFrame.new, CFrame.Angles, Enum.Material
		local rnd, T, RAD = Random.new(), TIME.cooked, low and 14 or 16
		local folder = Instance.new("Folder")
		folder.Name = "UhCooked"
		local ops, pool, reg = {}, {}, {}
		local conn, cconn, anchor, lost
		local shot, pi, burst = 0, 0, 0
		local t0 = os.clock()
		local nextShot = t0 + 0.9
		local gp, bp = RaycastParams.new(), RaycastParams.new()
		gp.FilterType, gp.RespectCanCollide, gp.FilterDescendantsInstances = Enum.RaycastFilterType.Exclude, true, {folder, me0, Env.Player.Character}
		bp.FilterType, bp.FilterDescendantsInstances = Enum.RaycastFilterType.Exclude, {folder}

		local function stop()
			if conn then conn:Disconnect(); conn = nil end
			if cconn then cconn:Disconnect(); cconn = nil end
			pcall(function() folder:Destroy() end)
			table.clear(ops); table.clear(pool); table.clear(reg)
		end
		fx.cooked = stop
		expire("cooked", stop, T + 1)

		local UNI, VEST, BLK, GLV = C3(38, 44, 52), C3(24, 27, 30), C3(14, 14, 16), C3(12, 12, 12)
		local METAL, POLY, HELM = C3(30, 30, 33), C3(40, 42, 44), C3(30, 34, 28)

		local function part(par, base, name, size, cf, col, mat, shape)
			local p = Instance.new("Part")
			p.Name, p.Size, p.Color, p.Material = name, size, col, mat or MT.SmoothPlastic
			p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery, p.Massless, p.CastShadow = false, false, false, false, true, false
			if shape then p.Shape = shape end
			local w = Instance.new("Weld")
			w.Part0, w.Part1, w.C0, w.Parent = base, p, cf, p
			p.Parent = par
			return p
		end
		local function em(par, dir, props)
			local e = Instance.new("ParticleEmitter")
			e.Rate, e.Enabled, e.EmissionDirection = 0, false, dir
			for k, v in pairs(props) do e[k] = v end
			e.Parent = par
			return e
		end

		local function buildOp()
			local m = Instance.new("Model")
			m.Name = "SwatOperator"
			local root = Instance.new("Part")
			root.Name, root.Size, root.Transparency = "HumanoidRootPart", V3(2, 2, 1), 1
			root.Anchored, root.CanCollide, root.CanTouch, root.CanQuery, root.CastShadow = true, false, false, false, false
			root.Parent = m
			m.PrimaryPart = root
			local function P(...) return part(m, root, ...) end
			-- legs, boots, knee pads, holster
			for s = -1, 1, 2 do
				P("Leg", V3(0.95, 2, 1), CF(s * 0.5, -2, 0), UNI)
				P("Boot", V3(1, 0.6, 1.3), CF(s * 0.5, -2.8, -0.15), BLK, MT.Slate)
				P("KneePad", V3(0.9, 0.55, 0.25), CF(s * 0.5, -1.55, -0.55), VEST)
				P("ShoulderPad", V3(0.75, 0.35, 1.1), CF(s * 1.3, 1.0, 0), VEST)
				P("EarPro", V3(0.25, 0.55, 0.5), CF(s * 0.75, 1.8, 0.05), BLK)
			end
			P("Holster", V3(0.35, 0.9, 0.5), CF(1.1, -1.45, -0.1), BLK)
			-- uniform, plate carrier, pouches, belt, radio
			P("Torso", V3(2, 2, 1), CF(), UNI)
			P("Vest", V3(2.3, 1.75, 1.3), CF(0, 0.12, 0), VEST)
			P("PlateF", V3(1.5, 1.25, 0.14), CF(0, 0.22, -0.72), BLK, MT.Metal)
			local pb = P("PlateB", V3(1.5, 1.25, 0.14), CF(0, 0.22, 0.72), BLK, MT.Metal)
			local sg = Instance.new("SurfaceGui")
			sg.Face = Enum.NormalId.Back
			local tl = Instance.new("TextLabel")
			tl.Size, tl.BackgroundTransparency, tl.Text, tl.TextColor3, tl.Font, tl.TextScaled = UDim2.fromScale(1, 1), 1, "SWAT", C3(235, 235, 235), Enum.Font.GothamBlack, true
			tl.Parent = sg
			sg.Parent = pb
			for i = -1, 1 do P("MagPouch", V3(0.4, 0.55, 0.26), CF(i * 0.5, -0.45, -0.86), C3(34, 36, 30)) end
			P("Belt", V3(2.2, 0.32, 1.15), CF(0, -0.98, 0), BLK)
			P("Radio", V3(0.32, 0.6, 0.24), CF(0.85, 0.65, -0.82), BLK)
			P("Antenna", V3(0.07, 0.6, 0.07), CF(0.85, 1.2, -0.82), BLK)
			P("Collar", V3(1.1, 0.35, 0.9), CF(0, 1.1, 0), VEST)
			-- balaclava, ballistic visor, helmet, NVG mount
			P("Head", V3(1.2, 1.2, 1.2), CF(0, 1.75, 0), BLK)
			P("Visor", V3(1.05, 0.38, 0.08), CF(0, 1.82, -0.64), C3(16, 40, 52), MT.Glass)
			P("Helmet", V3(1.55, 1.55, 1.55), CF(0, 2.3, 0.08), HELM, MT.SmoothPlastic, Enum.PartType.Ball)
			P("HelmetBrim", V3(1.3, 0.14, 0.35), CF(0, 2.28, -0.72), HELM)
			P("NVGMount", V3(0.4, 0.3, 0.3), CF(0, 2.55, -0.7), BLK)
			-- aim group (arms + rifle) hangs off ONE weld that is pitched / recoiled each frame
			local aim = Instance.new("Part")
			aim.Name, aim.Size, aim.Transparency = "Aim", V3(0.2, 0.2, 0.2), 1
			aim.Anchored, aim.CanCollide, aim.CanTouch, aim.CanQuery, aim.Massless, aim.CastShadow = false, false, false, false, true, false
			local aimW = Instance.new("Weld")
			aimW.Part0, aimW.Part1, aimW.C0, aimW.Parent = root, aim, CF(0, 1, 0), aim
			aim.Parent = m
			local function A(...) return part(m, aim, ...) end
			local S, RO, K = 0.75, CF(0.38, -0.1, -1.75), ANG(0, math.rad(90), 0)
			local function Rf(name, size, x, y, z, col, mat, rot, shape)
				return A(name, size * S, RO * CF(x * S, y * S, z * S) * (rot or CF()), col, mat or MT.Metal, shape)
			end
			local up = Rf("Upper", V3(0.3, 0.3, 1.1), 0, 0.3, -0.05, METAL)
			Rf("Lower", V3(0.28, 0.34, 1.0), 0, 0, 0, METAL)
			Rf("ChargingHandle", V3(0.16, 0.08, 0.2), 0, 0.5, 0.5, BLK)
			Rf("Handguard", V3(0.36, 0.36, 1.25), 0, 0.2, -1.1, POLY, MT.SmoothPlastic)
			Rf("RailTop", V3(0.12, 0.06, 2.4), 0, 0.5, -0.45, BLK)
			Rf("Barrel", V3(0.9, 0.13, 0.13), 0, 0.2, -2.1, BLK, MT.Metal, K, Enum.PartType.Cylinder)
			Rf("FlashHider", V3(0.35, 0.2, 0.2), 0, 0.2, -2.65, BLK, MT.Metal, K, Enum.PartType.Cylinder)
			Rf("Optic", V3(0.26, 0.28, 0.45), 0, 0.68, -0.2, BLK)
			Rf("Lens", V3(0.2, 0.2, 0.03), 0, 0.7, -0.44, C3(150, 30, 30), MT.Glass)
			Rf("FrontSight", V3(0.06, 0.3, 0.06), 0, 0.68, -1.5, BLK)
			Rf("RearSight", V3(0.08, 0.2, 0.1), 0, 0.6, 0.6, BLK)
			Rf("Magazine", V3(0.2, 0.8, 0.3), 0, -0.55, -0.2, C3(22, 22, 24), MT.Metal, ANG(math.rad(-8), 0, 0))
			Rf("MagBase", V3(0.22, 0.08, 0.32), 0, -0.97, -0.13, BLK, MT.Metal, ANG(math.rad(-8), 0, 0))
			Rf("PistolGrip", V3(0.2, 0.55, 0.26), 0, -0.4, 0.38, BLK, MT.SmoothPlastic, ANG(math.rad(20), 0, 0))
			Rf("TriggerGuard", V3(0.05, 0.12, 0.3), 0, -0.22, 0.12, METAL)
			Rf("BufferTube", V3(0.2, 0.2, 0.8), 0, 0.12, 0.95, METAL)
			Rf("Stock", V3(0.24, 0.5, 0.7), 0, 0, 1.45, POLY, MT.SmoothPlastic)
			Rf("CheekRest", V3(0.22, 0.14, 0.5), 0, 0.3, 1.4, BLK)
			Rf("ButtPad", V3(0.26, 0.54, 0.1), 0, 0, 1.85, BLK)
			Rf("Foregrip", V3(0.18, 0.55, 0.18), 0, -0.3, -1.25, BLK, MT.SmoothPlastic, ANG(math.rad(10), 0, 0))
			Rf("WeaponLight", V3(0.16, 0.16, 0.45), 0.26, 0.2, -1.5, BLK)
			Rf("LightLens", V3(0.12, 0.12, 0.03), 0.26, 0.2, -1.74, C3(255, 245, 210), MT.Neon)
			Rf("Laser", V3(0.12, 0.12, 0.24), -0.24, 0.2, -1.5, BLK)
			Rf("LaserDot", V3(0.05, 0.05, 0.03), -0.24, 0.2, -1.63, C3(255, 20, 20), MT.Neon)
			local muz = Rf("Muzzle", V3(0.1, 0.1, 0.1), 0, 0.2, -2.95, METAL)
			muz.Transparency = 1
			local fl = Rf("Flash", V3(0.5, 0.5, 0.5), 0, 0.2, -3.1, C3(255, 200, 90), MT.Neon, nil, Enum.PartType.Ball)
			fl.Transparency = 1
			-- arms (sleeves, elbow pads, gloves) reaching the grip and the foregrip
			local function limb(a, b, t) return A("Arm", V3(t, t, (b - a).Magnitude), CFrame.lookAt((a + b) / 2, b), UNI, MT.Fabric) end
			local rs, re, hr = V3(1.25, -0.1, 0.1), V3(1.0, -0.95, -0.55), V3(0.38, -0.4, -1.47)
			local ls, le, hl = V3(-1.25, -0.1, 0.1), V3(-0.55, -0.95, -1.3), V3(0.38, -0.38, -2.65)
			limb(rs, re, 0.85); limb(re, hr, 0.75); limb(ls, le, 0.85); limb(le, hl, 0.75)
			A("ElbowPad", V3(0.6, 0.6, 0.6), CF(re), VEST); A("ElbowPad", V3(0.6, 0.6, 0.6), CF(le), VEST)
			A("Glove", V3(0.45, 0.45, 0.45), CF(hr), GLV); A("Glove", V3(0.45, 0.45, 0.45), CF(hl), GLV)
			-- effects: flash + brief muzzle light, smoke, ejected brass
			local o = {m = m, root = root, aimW = aimW, muz = muz, fl = fl, k = 0, pt = 0, flT = 0}
			o.ef = em(muz, Enum.NormalId.Front, {Texture = "rbxasset://textures/particles/sparkles_main.dds", Color = ColorSequence.new(C3(255, 225, 130), C3(255, 120, 30)), Size = NumberSequence.new(1.4, 0), LightEmission = 1, Lifetime = NumberRange.new(0.05, 0.09), Speed = NumberRange.new(0, 3)})
			o.es = em(muz, Enum.NormalId.Front, {Texture = "rbxasset://textures/particles/smoke_main.dds", Color = ColorSequence.new(C3(170, 170, 170)), Size = NumberSequence.new(0.4, 1.4), Transparency = NumberSequence.new(0.6, 1), Lifetime = NumberRange.new(0.4, 0.7), Speed = NumberRange.new(2, 5), Drag = 2, SpreadAngle = Vector2.new(20, 20)})
			o.esh = em(up, Enum.NormalId.Right, {Color = ColorSequence.new(C3(210, 165, 60)), Size = NumberSequence.new(0.14), Lifetime = NumberRange.new(0.6, 0.9), Speed = NumberRange.new(9, 14), Acceleration = V3(0, -50, 0), SpreadAngle = Vector2.new(18, 18), Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-400, 400)})
			if not low then
				local lt = Instance.new("PointLight")
				lt.Color, lt.Brightness, lt.Range, lt.Enabled = C3(255, 170, 70), 3, 14, false
				lt.Parent = muz
				o.lt = lt
			end
			return o
		end

		local function place(c)
			anchor = c
			for _, o in ipairs(ops) do
				local x, z = c.X + math.cos(o.a) * RAD, c.Z + math.sin(o.a) * RAD
				local g = workspace:Raycast(V3(x, c.Y + 4, z), V3(0, -50, 0), gp)
				o.pos = V3(x, (g and g.Position.Y or c.Y - 3) + 3.1, z)
			end
		end
		local function pose(o, tp, dt)
			o.root.CFrame = CFrame.lookAt(o.pos, V3(tp.X, o.pos.Y, tp.Z))
			local d = tp - (o.pos + V3(0, 1, 0))
			local want = math.clamp(math.atan2(d.Y, math.sqrt(d.X * d.X + d.Z * d.Z)), -0.9, 0.9)
			o.pt += (want - o.pt) * math.min(1, dt * 12)
			o.k = math.max(0, o.k - dt * 9)
			o.aimW.C0 = CF(0, 1, 0) * ANG(o.pt + o.k * 0.07, 0, 0) * CF(0, 0, o.k * 0.16)
		end
		local function fire(o, t, tp, hum, me, rc)
			local mp = o.muz.Position
			local aimAt = tp + V3(rnd:NextNumber(-0.7, 0.7), rnd:NextNumber(-0.9, 0.9), rnd:NextNumber(-0.7, 0.7))
			if rnd:NextNumber() < 0.45 then -- deliberate miss: the round passes the target
				aimAt += V3(rnd:NextNumber(-1, 1), rnd:NextNumber(-0.4, 1), rnd:NextNumber(-1, 1)).Unit * rnd:NextNumber(3, 6)
			end
			local dir = (aimAt - mp).Unit
			local res = workspace:Raycast(mp, dir * 300, bp)
			local ep = res and res.Position or (mp + dir * 300)
			shot += 1
			if res and hum and COOKED_DMG > 0 and hum.Health > 0 and not reg[shot] and (res.Instance:IsDescendantOf(me) or (rc and res.Instance:IsDescendantOf(rc))) then
				reg[shot] = true; reg[shot - 30] = nil -- one ray = at most one registered hit
				hum:TakeDamage(COOKED_DMG)
			end
			pi = pi % #pool + 1
			local tr, len = pool[pi], (ep - mp).Magnitude
			tr.p.Size = V3(0.08, 0.08, len)
			tr.p.CFrame = CFrame.lookAt(mp, ep) * CF(0, 0, -len / 2)
			tr.p.Transparency, tr.t0 = 0.1, t
			o.k, o.flT = 1, t + 0.05
			o.fl.Transparency = 0
			if o.lt then o.lt.Enabled = true end
			o.ef:Emit(1); o.esh:Emit(1)
			if shot % 2 == 0 then o.es:Emit(1) end
		end
		local function step(dt)
			local t = os.clock()
			local me, rc = myChar(), Env.Player.Character
			local tr = me and (me:FindFirstChild("HumanoidRootPart") or me.PrimaryPart)
			if not (tr and tr.Parent) then
				lost = lost or t
				if t - lost > 1.5 then stopFx("cooked") end -- target / character gone
				return
			end
			lost = nil
			local hum = rc and rc:FindFirstChildOfClass("Humanoid")
			if t - t0 >= T or (hum and hum.Health <= 0) then return stopFx("cooked") end
			local tp = tr.Position + V3(0, 0.6, 0)
			if V3(tp.X - anchor.X, 0, tp.Z - anchor.Z).Magnitude > RAD * 2.2 then place(tr.Position) end
			local go = t >= nextShot -- ONE synchronized clock: 4-round bursts, all five operators together
			if go then
				burst += 1
				nextShot = t + (burst >= 4 and 0.6 or 0.11)
				if burst >= 4 then burst = 0 end
			end
			for _, o in ipairs(ops) do
				pose(o, tp, dt)
				if go then fire(o, t, tp, hum, me, rc) end
				if o.flT > 0 and t >= o.flT then
					o.flT = 0
					o.fl.Transparency = 1
					if o.lt then o.lt.Enabled = false end
				end
			end
			for _, p in ipairs(pool) do
				if p.t0 >= 0 then
					local k = (t - p.t0) / 0.07
					if k >= 1 then p.t0, p.p.Transparency = -1, 1 else p.p.Transparency = 0.1 + 0.9 * k end
				end
			end
		end

		local okB = pcall(function()
			local a0 = rnd:NextNumber(0, math.pi * 2)
			for i = 1, 5 do
				local o = buildOp()
				o.a = a0 + (i - 1) * math.pi * 2 / 5
				o.m.Parent = folder
				ops[i] = o
			end
			for i = 1, low and 8 or 14 do
				local p = Instance.new("Part")
				p.Name, p.Material, p.Color, p.Transparency, p.Size = "Tracer", MT.Neon, C3(255, 214, 120), 1, V3(0.08, 0.08, 1)
				p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery, p.CastShadow = true, false, false, false, false
				p.Parent = folder
				pool[i] = {p = p, t0 = -1}
			end
			place(root0.Position)
			local tp0 = root0.Position + V3(0, 0.6, 0)
			for _, o in ipairs(ops) do pose(o, tp0, 1) end
			folder.Parent = workspace
		end)
		if not okB then
			toast("Cooked failed to build")
			return stopFx("cooked")
		end
		cconn = Env.Player.CharacterAdded:Connect(function() stopFx("cooked") end) -- respawn: squad gone at once
		local interval, acc = low and 1 / 30 or 0, 0
		conn = RS.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < interval then return end
			local d = math.min(acc, 0.1)
			acc = 0
			if not pcall(step, d) then stopFx("cooked") end
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
		elseif action == "dropbomb" then
			toast(sp.Name .. " dropped a bomb on you (explosion " .. BOMB_LIFE .. " s)")
			dropbomb()
		elseif action == "silenthell" then
			toast(sp.Name .. " sent you to Silent Hell (" .. TIME.silenthell .. " s)")
			silenthell()
		elseif action == "domain" then
			toast(sp.Name .. " activated Domain Expansion: Unlimited Void on you (" .. TIME.domain .. " s)")
			domain()
		elseif action == "cooked" then
			toast(sp.Name .. " called a SWAT squad on you (" .. TIME.cooked .. " s)")
			cooked()
		else
			toast(sp.Name .. " made you dizzy (" .. TIME.dizzy .. " s)")
			dizzy()
		end
		return true
	end

	-- ===== backend-authorised entry point (Live Player Log command channel) =====
	-- The Worker already verified the moderator's role and addressed THIS script session. `secs` = optional effect length (clamped 5..120 s; Silent Hell is fixed at 10 s). Returns ok, reason.
	function F.Run(action, who, secs)
		if action ~= "hallucinate" and action ~= "dizzy" and action ~= "silenthell" and action ~= "dropbomb" then return false, "unsupported" end
		if action == "silenthell" then
			if not F.Enabled then return false, "effects disabled by the recipient" end
			toast(tostring(who) .. " sent you to Silent Hell (" .. TIME.silenthell .. " s)")
			silenthell()
			return true
		end
		if action == "dropbomb" then
			if not F.Enabled then return false, "effects disabled by the recipient" end
			toast(tostring(who) .. " dropped a bomb on you (explosion " .. BOMB_LIFE .. " s)")
			dropbomb()
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
