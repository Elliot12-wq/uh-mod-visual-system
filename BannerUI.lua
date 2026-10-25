-- BannerUI.lua | animated character banner (BillboardGui) themed from the host UI colours, per-user style, real 3D triangle beside the PFP
return function(Env)
	local TS, RS = Env.TweenService, Env.RunService
	local UI, Active, conn = {}, {}, nil
	local Banner = {}; Banner.__index = Banner
	local HOST = "UhBannerHost"
	local WHITE, BLACK = Color3.new(1, 1, 1), Color3.new(0, 0, 0)

	local function host()
		if UI.Host and UI.Host.Parent then return UI.Host end
		local p
		pcall(function() p = (gethui and gethui()) or game:GetService("CoreGui") end)
		p = p or Env.Player:WaitForChild("PlayerGui")
		pcall(function() for _, v in ipairs(p:GetChildren()) do if v.Name == HOST then v:Destroy() end end end)
		local f = Instance.new("Folder"); f.Name = HOST; f.Parent = p
		UI.Host = f
		return f
	end

	local function accent()
		local ok, a = pcall(Env.GetColor)
		return (ok and typeof(a) == "Color3") and a or Color3.fromRGB(95, 165, 255)
	end
	local function cardBG()
		local ok, b = pcall(Env.GetBG)
		if not ok or typeof(b) ~= "Color3" then b = Color3.fromRGB(14, 14, 20) end
		local h, s, v = b:ToHSV()
		return Color3.fromHSV(h, math.min(s, 0.55), math.min(v, 0.14))
	end
	local function sec(c) local h, s, v = c:ToHSV(); return Color3.fromHSV((h + 0.12) % 1, s, v) end
	local function new(c, p, par)
		local i = Instance.new(c)
		for k, v in pairs(p) do i[k] = v end
		i.Parent = par
		return i
	end
	local function round(par, r) return new("UICorner", {CornerRadius = r}, par) end
	local function fade(a, b, c) return NumberSequence.new({NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(0.5, b), NumberSequenceKeypoint.new(1, c)}) end

	-- ===== per-banner style (custom colours / gradient / border / effects). nil = follow the host UI theme =====
	local DEF = {gr = 90, bw = 2, bs = 2, cr = 14, fx = 63}
	local FXB = {glow = 1, shine = 2, spark = 4, ring = 8, depth = 16, float = 32}
	local LOWHIDE = {shine = true, spark = true, ring = true}
	local function hexc(s)
		if type(s) ~= "string" then return nil end
		local r, g, b = s:match("^#?(%x%x)(%x%x)(%x%x)$")
		if not r then return nil end
		return Color3.fromRGB(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
	end
	local function tohex(c) return string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)) end
	local function parseStyle(s)
		s = type(s) == "table" and s or {}
		local function n(k, lo, hi)
			local v = tonumber(s[k])
			if not v then return DEF[k] end
			return math.clamp(math.floor(v + 0.5), lo, hi)
		end
		return {a = hexc(s.a), a2 = hexc(s.a2), b1 = hexc(s.b1), b2 = hexc(s.b2), gr = n("gr", 0, 360), bw = n("bw", 0, 4), bs = n("bs", 0, 2), cr = n("cr", 4, 24), fx = n("fx", 0, 63)}
	end
	local function bgPair(st)
		local b1, b2 = st.b1, st.b2
		if b1 or b2 then
			b1 = b1 or b2
			b2 = b2 or b1:Lerp(BLACK, 0.45)
			return b1, b2
		end
		local bg = cardBG()
		return bg:Lerp(WHITE, 0.08), bg
	end

	-- white check mark drawn from two bars (no font glyph needed)
	local function checkmark(par, z)
		for _, b in ipairs({{2, 6, 6.5, 10.5, -45}, {2, 10, 11, 8.5, 45}}) do
			new("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(b[1], b[2]), Position = UDim2.fromOffset(b[3], b[4]), Rotation = b[5],
				BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = z}, par)
		end
	end

	-- fallback only (host script without Env.NewTriangle): pseudo-3D rotating triangle from two shaded facets
	local LW, LH = 20, 16
	local function facet(par)
		local c = new("Frame", {BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 5}, par)
		return c, new("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, ZIndex = 5}, c)
	end
	local function makeLogo(par)
		local h = new("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(LW, LH), BackgroundTransparency = 1, ZIndex = 5}, par)
		local L = {}
		L.lc, L.lr = facet(h)
		L.rc, L.rr = facet(h)
		return L
	end
	local function logoStep(L, t, a)
		local s = math.sin(t * 1.6)
		local bx = LW / 2 + LW * 0.28 * s
		local wr, T = LW - bx, LH * 3
		local pl, pr = math.atan2(LH, bx), math.atan2(LH, wr)
		L.lc.Size = UDim2.fromOffset(bx, LH)
		L.lr.Rotation, L.lr.Size = -math.deg(pl), UDim2.fromOffset(math.sqrt(bx * bx + LH * LH) + 6, T)
		L.lr.Position = UDim2.fromOffset(bx / 2 + T / 2 * math.sin(pl), LH / 2 + T / 2 * math.cos(pl))
		L.lr.BackgroundColor3 = a:Lerp(WHITE, 0.3 + 0.25 * s)
		L.rc.Position, L.rc.Size = UDim2.fromOffset(bx, 0), UDim2.fromOffset(wr, LH)
		L.rr.Rotation, L.rr.Size = math.deg(pr), UDim2.fromOffset(math.sqrt(wr * wr + LH * LH) + 6, T)
		L.rr.Position = UDim2.fromOffset(wr / 2 - T / 2 * math.sin(pr), LH / 2 + T / 2 * math.cos(pr))
		L.rr.BackgroundColor3 = a:Lerp(BLACK, math.max(0.05, 0.3 - 0.22 * s))
	end

	-- inline moderation buttons beside the card (Kill / Deanimate / Kick / Ban). The receiver decides WHO gets which buttons (o.acts);
	-- this file only draws them and hit-tests them. Layout: a 2-column grid of pills, two rows = about the height of the card.
	-- Slot i (1-based): column (i-1) % ACOLS, row floor((i-1) / ACOLS). Up to 4 buttons fit beside the card.
	local AW, AH, AG, AX, AY, ACOLS = 68, 28, 6, 10, 1, 2 -- pill width / height, gap, offset from the card's right edge, offset from the card's top, columns

	local function step()
		local now = os.clock()
		local low = Env.IsLowEnd and Env.IsLowEnd() or false
		if low then
			if now - (UI.LastLow or 0) < 0.066 then return end
			UI.LastLow = now
		end
		local a = accent()
		local s2 = sec(a)
		for b in pairs(Active) do b:_step(now, a, s2, low) end
	end

	-- show / hide effect groups according to the style flags (and Low End mode)
	function Banner:_flags()
		local fx, lo = self.St.fx, self.FXOff
		for name, list in pairs(self.G) do
			local on = bit32.band(fx, FXB[name]) ~= 0 and not (lo and LOWHIDE[name])
			for _, f in ipairs(list) do f.Visible = on end
		end
	end

	-- apply the static part of a style (corners, border, gradient angle, effect flags); colours are animated in _step
	function Banner:Restyle(raw)
		local st = parseStyle(raw)
		self.St = st
		self.CardC.CornerRadius = UDim.new(0, st.cr)
		self.GlowC.CornerRadius = UDim.new(0, st.cr + 10)
		self.ShadowC.CornerRadius = UDim.new(0, st.cr)
		self.CardGrad.Rotation = st.gr
		self.Stroke.Thickness = st.bw
		self.Stroke.Enabled = st.bw > 0
		self.StrokeGrad.Rotation = 45
		self.LastBG = 0
		self:_flags()
	end

	function UI.new(o)
		local role = o.role
		local st0 = parseStyle(o.style)
		local a = role and role.color or st0.a or accent()
		local c1, c2 = bgPair(st0)
		local W = (role and role.tag) and 340 or 268
		local self = setmetatable({Opts = o, Seed = math.random() * 10, Alive = true, Spark = {}, G = {glow = {}, shine = {}, spark = {}, ring = {}, depth = {}},
			LastBG = os.clock(), Role = role, RoleColor = role and role.color, W = W, CurA = a, St = st0}, Banner)
		-- inline action buttons: only ever on plain (unverified) banners; verified / owner / co-owner banners never get them
		local acts = (not role and type(o.acts) == "table" and #o.acts > 0) and o.acts or nil
		local extra = acts and 2 * (AX + math.min(#acts, ACOLS) * (AW + AG) + 4) or 0 -- the gui is centred on the card, so reserve the room on both sides
		local gui = new("BillboardGui", {Name = "UhBanner_" .. tostring(o.userId), AlwaysOnTop = true, Size = UDim2.fromOffset(W + 10 + extra, 150),
			StudsOffset = Vector3.new(0, 1.7, 0), MaxDistance = 150, LightInfluence = 0, ResetOnSpawn = false,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Enabled = false}, host())
		local holder = new("Frame", {Name = "Holder", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(W, 78), BackgroundTransparency = 1}, gui)
		local scale = new("UIScale", {Scale = 0}, holder)
		local glow = new("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 32), Size = UDim2.new(1, 14, 0, 76),
			BackgroundColor3 = a, BackgroundTransparency = 0.88, BorderSizePixel = 0, ZIndex = 0}, holder)
		local glowC = round(glow, UDim.new(0, 24))
		local shadow = new("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 37), Size = UDim2.new(1, -6, 0, 64),
			BackgroundColor3 = BLACK, BackgroundTransparency = 0.55, BorderSizePixel = 0, ZIndex = 0}, holder)
		local shadowC = round(shadow, UDim.new(0, 14))
		-- triangular pointer: rotated square, upper half hidden behind the opaque card, lower half is the visible triangle
		local pointer = new("Frame", {Name = "Pointer", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 64),
			Size = UDim2.fromOffset(18, 18), Rotation = 45, BackgroundColor3 = a, BorderSizePixel = 0, ZIndex = 1}, holder)
		round(pointer, UDim.new(0, 3))
		local card = new("Frame", {Name = "Card", Size = UDim2.new(1, 0, 0, 64), BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 2, ClipsDescendants = true}, holder)
		local cardC = round(card, UDim.new(0, 14))
		local cardGrad = new("UIGradient", {Rotation = st0.gr, Color = ColorSequence.new(c1, c2)}, card)
		local stroke = new("UIStroke", {Thickness = 2, Color = WHITE, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, card)
		local strokeGrad = new("UIGradient", {Color = ColorSequence.new(a, a)}, stroke)
		-- depth / lighting: top sheen, bottom shade, 1px top highlight
		local sheen = new("Frame", {Size = UDim2.new(1, 0, 0.55, 0), BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 2}, card)
		new("UIGradient", {Rotation = 90, Transparency = NumberSequence.new(0.9, 1)}, sheen)
		local shade = new("Frame", {AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0.4, 0), BackgroundColor3 = BLACK, BorderSizePixel = 0, ZIndex = 2}, card)
		new("UIGradient", {Rotation = 90, Transparency = NumberSequence.new(1, 0.78)}, shade)
		local hi = new("Frame", {Position = UDim2.fromOffset(12, 1), Size = UDim2.new(1, -24, 0, 1), BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 3}, card)
		new("UIGradient", {Transparency = fade(1, 0.5, 1)}, hi)
		local img = new("ImageLabel", {Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(44, 44), BackgroundColor3 = c2:Lerp(WHITE, 0.12),
			BorderSizePixel = 0, Image = o.image, ScaleType = Enum.ScaleType.Crop, ZIndex = 3}, card)
		round(img, UDim.new(1, 0))
		new("UIStroke", {Thickness = 2, Color = a}, img)
		local ring = new("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(32, 32), Size = UDim2.fromOffset(44, 44),
			BackgroundTransparency = 1, ZIndex = 3}, card)
		round(ring, UDim.new(1, 0))
		local ringStroke = new("UIStroke", {Thickness = 2, Color = a}, ring)
		-- 3D triangle medallion right beside the PFP (real FX.NewTriangle3D viewport; pseudo-3D fallback only if the host has no engine hook)
		local plate = new("Frame", {Position = UDim2.fromOffset(56, 15), Size = UDim2.fromOffset(34, 34), BackgroundColor3 = BLACK, BackgroundTransparency = 0.5, BorderSizePixel = 0, ZIndex = 3}, card)
		round(plate, UDim.new(1, 0))
		local big = role and role.logo
		local plateStroke = new("UIStroke", {Thickness = big and 1.8 or 1.2, Color = a, Transparency = big and 0.15 or 0.45}, plate)
		local slot = new("Frame", {Name = "Tri", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(big and 32 or 28, big and 32 or 28),
			BackgroundTransparency = 1, ZIndex = 4}, plate)
		if Env.NewTriangle then
			local okT, T = pcall(Env.NewTriangle, slot, {ZIndex = 5, Halo = false, Dance = false,
				Tint = function() return self.CurA end, IsVisible = function() return self.Alive and gui.Enabled end})
			if okT and T then self.Tri = T end
		end
		if not self.Tri then self.Logo = makeLogo(slot); logoStep(self.Logo, 0.4, a) end
		local rightPad = (role and role.tag) and 128 or 14
		local title = new("TextLabel", {Position = UDim2.fromOffset(98, 11), Size = UDim2.new(1, -(98 + rightPad), 0, 22), BackgroundTransparency = 1, Text = o.title,
			Font = Enum.Font.GothamBold, TextSize = 17, TextColor3 = WHITE:Lerp(a, 0.12), TextXAlignment = Enum.TextXAlignment.Left,
			TextStrokeTransparency = 0.82, TextStrokeColor3 = BLACK, TextTruncate = Enum.TextTruncate.AtEnd, TextTransparency = 1, ZIndex = 4}, card)
		local sub = new("TextLabel", {Position = UDim2.fromOffset(98, 34), Size = UDim2.new(1, -(98 + 14), 0, 16), BackgroundTransparency = 1, Text = o.subtitle,
			Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = a, TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd, TextTransparency = 1, ZIndex = 4}, card)
		local bar = new("Frame", {Position = UDim2.new(0, 12, 1, -6), Size = UDim2.new(1, -24, 0, 2), BackgroundColor3 = a, BorderSizePixel = 0, ZIndex = 4}, card)
		round(bar, UDim.new(1, 0))
		local barGrad = new("UIGradient", {Transparency = fade(1, 0, 1)}, bar)
		local shine = new("Frame", {Position = UDim2.fromOffset(-70, -10), Size = UDim2.new(0, 46, 1, 20), Rotation = 18, BackgroundColor3 = WHITE,
			BorderSizePixel = 0, ZIndex = 6}, card)
		new("UIGradient", {Transparency = fade(1, 0.82, 1)}, shine)
		if role then -- verified check on the avatar (+ rank chip for owners)
			local vb = new("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(49, 49), Size = UDim2.fromOffset(18, 18),
				BackgroundColor3 = Color3.fromRGB(46, 140, 255), BorderSizePixel = 0, ZIndex = 6}, card)
			round(vb, UDim.new(1, 0))
			new("UIStroke", {Thickness = 2, Color = c2}, vb)
			checkmark(vb, 7)
			if role.tag then
				local chip = new("Frame", {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 10), Size = UDim2.fromOffset(0, 22),
					AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = a, BackgroundTransparency = 0.82, BorderSizePixel = 0, ZIndex = 4}, card)
				round(chip, UDim.new(0, 7))
				new("UIStroke", {Thickness = 1.5, Color = a}, chip)
				new("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 5)}, chip)
				new("UIPadding", {PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8)}, chip)
				new("TextLabel", {Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, Text = role.tag,
					Font = Enum.Font.GothamBlack, TextSize = 12, TextColor3 = a:Lerp(WHITE, 0.35), ZIndex = 5, LayoutOrder = 2}, chip)
			end
		end
		if acts then -- moderator buttons beside the card (clicks are handled by the receiver via Banner:HitAction)
			self.ActBtn = {}
			for i, ac in ipairs(acts) do
				local col, row = (i - 1) % ACOLS, math.floor((i - 1) / ACOLS)
				local pill = new("Frame", {Name = "Act_" .. tostring(ac.key), Position = UDim2.new(1, AX + col * (AW + AG), 0, AY + row * (AH + AG)), Size = UDim2.fromOffset(AW, AH),
					BackgroundColor3 = ac.color, BorderSizePixel = 0, ZIndex = 3}, holder)
				round(pill, UDim.new(0, 9))
				new("UIStroke", {Thickness = 1.5, Color = a}, pill)
				local lbl = new("TextLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = tostring(ac.label), Font = Enum.Font.GothamBold,
					TextSize = 12, TextColor3 = WHITE, ZIndex = 4}, pill)
				self.ActBtn[ac.key] = {Frame = pill, Label = lbl, Color = ac.color, Text = tostring(ac.label), Col = col, Row = row}
			end
		end
		for i = 1, 4 do
			local s = new("Frame", {Size = UDim2.fromOffset(4, 4), BackgroundColor3 = a, BorderSizePixel = 0, ZIndex = 5}, holder)
			round(s, UDim.new(1, 0))
			self.Spark[i] = s
			table.insert(self.G.spark, s)
		end
		table.insert(self.G.glow, glow); table.insert(self.G.shine, shine); table.insert(self.G.ring, ring)
		for _, f in ipairs({shadow, sheen, shade, hi}) do table.insert(self.G.depth, f) end
		self.Gui, self.Holder, self.Scale, self.Glow, self.Pointer, self.Card, self.CardGrad = gui, holder, scale, glow, pointer, card, cardGrad
		self.Stroke, self.StrokeGrad, self.Ring, self.RingStroke, self.Bar, self.BarGrad, self.Shine = stroke, strokeGrad, ring, ringStroke, bar, barGrad, shine
		self.Title, self.Sub, self.Img, self.Plate = title, sub, img, plateStroke
		self.CardC, self.GlowC, self.ShadowC = cardC, glowC, shadowC
		self:Restyle(o.style)
		Active[self] = true
		if not conn then conn = RS.RenderStepped:Connect(step) end
		return self
	end

	function Banner:SetAdornee(part)
		if not self.Alive then return end
		self.Gui.Adornee = part
		self.Gui.Enabled = part ~= nil
		if part and not self.Shown then
			self.Shown = true
			TS:Create(self.Scale, TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()
			TS:Create(self.Title, TweenInfo.new(0.45), {TextTransparency = 0}):Play()
			TS:Create(self.Sub, TweenInfo.new(0.45), {TextTransparency = 0}):Play()
		elseif not part and self.Shown then -- respawn gap: re-pop when the new character appears
			self.Shown = false
			self.Scale.Scale = 0
			self.Title.TextTransparency, self.Sub.TextTransparency = 1, 1
		end
	end

	function Banner:Update(o)
		self.Opts = o
		self.Title.Text, self.Sub.Text, self.Img.Image = o.title, o.subtitle, o.image
		if self.Shown then
			TS:Create(self.Scale, TweenInfo.new(0.12), {Scale = 1.08}):Play()
			task.delay(0.12, function()
				if self.Alive then TS:Create(self.Scale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play() end
			end)
		end
	end

	function Banner:Destroy(animated)
		if not self.Alive then return end
		self.Alive = false
		Active[self] = nil
		if not next(Active) and conn then conn:Disconnect(); conn = nil end
		local gui, tri = self.Gui, self.Tri
		self.Tri = nil
		local function kill()
			if tri then pcall(tri.Destroy, tri) end -- stops the triangle's own render loop
			gui:Destroy()
		end
		if animated and gui.Enabled then
			TS:Create(self.Scale, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Scale = 0}):Play()
			task.delay(0.3, kill)
		else
			kill()
		end
	end

	function Banner:Contains(p) -- p = point in viewport coordinates
		local cam, part = workspace.CurrentCamera, self.Gui.Adornee
		if not (self.Alive and self.Shown and cam and part and self.Gui.Enabled) then return false end
		if (cam.CFrame.Position - part.Position).Magnitude > self.Gui.MaxDistance then return false end
		local v, on = cam:WorldToViewportPoint(part.Position + cam.CFrame.UpVector * self.Gui.StudsOffset.Y)
		if not on then return false end
		local s = self.Scale.Scale
		return math.abs(p.X - v.X) <= self.W / 2 * s and p.Y >= v.Y - 78 * s and p.Y <= v.Y - 14 * s
	end

	function Banner:HitAction(p) -- p = point in viewport coordinates; returns the key of the inline button under p (or nil)
		if not self.ActBtn then return nil end
		local cam, part = workspace.CurrentCamera, self.Gui.Adornee
		if not (self.Alive and self.Shown and cam and part and self.Gui.Enabled) then return nil end
		if (cam.CFrame.Position - part.Position).Magnitude > self.Gui.MaxDistance then return nil end
		local v, on = cam:WorldToViewportPoint(part.Position + cam.CFrame.UpVector * self.Gui.StudsOffset.Y)
		if not on then return nil end
		local s = self.Scale.Scale
		for key, b in pairs(self.ActBtn) do
			-- holder is anchored bottom-centre on the gui centre (v) and is 78 tall: its right edge is v.X + W/2, its top is v.Y - 78
			local x0 = v.X + (self.W / 2 + AX + b.Col * (AW + AG)) * s
			local y0 = v.Y + (AY + b.Row * (AH + AG) - 78) * s
			if p.X >= x0 - 3 and p.X <= x0 + (AW + 3) * s and p.Y >= y0 - 3 and p.Y <= y0 + (AH + 3) * s then return key end
		end
		return nil
	end

	function Banner:SetAction(key, text, color) -- re-label / recolour one inline button (e.g. "Sure?"); no args = back to normal
		local b = self.ActBtn and self.ActBtn[key]
		if not (self.Alive and b) then return end
		b.Label.Text = text or b.Text
		b.Frame.BackgroundColor3 = color or b.Color
	end

	function Banner:PulseAction(key) -- click feedback
		local b = self.ActBtn and self.ActBtn[key]
		if not (self.Alive and b) then return end
		b.Frame.BackgroundTransparency = 0.55
		TS:Create(b.Frame, TweenInfo.new(0.3), {BackgroundTransparency = 0}):Play()
	end

	function Banner:_step(now, a, s2, low)
		if not self.Gui.Enabled then return end
		local st = self.St
		local t = now + self.Seed
		if self.RoleColor then a = self.RoleColor; s2 = st.a2 or sec(a) -- owner / co-owner keep their rank colour
		elseif st.a then a = st.a; s2 = st.a2 or sec(a)
		elseif st.a2 then s2 = st.a2 end
		self.CurA = a
		self.Holder.Position = UDim2.new(0.5, 0, 0.5, (low or bit32.band(st.fx, FXB.float) == 0) and 0 or math.sin(t * 2.2) * 3)
		self.Pointer.BackgroundColor3, self.Sub.TextColor3, self.Bar.BackgroundColor3 = a, a, a
		self.Title.TextColor3 = WHITE:Lerp(a, 0.12)
		self.Glow.BackgroundColor3, self.RingStroke.Color, self.Plate.Color = a, a, a
		self.StrokeGrad.Color = (st.bs == 0) and ColorSequence.new(a, a) or ColorSequence.new({ColorSequenceKeypoint.new(0, a), ColorSequenceKeypoint.new(0.5, s2), ColorSequenceKeypoint.new(1, a)})
		if now - self.LastBG > 2 then
			self.LastBG = now
			local c1, c2 = bgPair(st)
			self.CardGrad.Color = ColorSequence.new(c1, c2)
		end
		if low then
			if not self.FXOff then self.FXOff = true; self:_flags() end
			return
		end
		if self.FXOff then self.FXOff = false; self:_flags() end
		if st.bs == 2 then self.StrokeGrad.Rotation = (now * 90) % 360 end
		if self.Logo then logoStep(self.Logo, t, a) end
		self.Glow.BackgroundTransparency = 0.86 + 0.05 * math.sin(t * 3)
		local e = (t * 0.65) % 1
		self.Ring.Size = UDim2.fromOffset(44 + 16 * e, 44 + 16 * e)
		self.RingStroke.Transparency = 0.2 + 0.8 * e
		self.Shine.Position = UDim2.fromOffset(-70 + ((t * 0.3) % 1) * (self.W + 80), -10)
		self.BarGrad.Offset = Vector2.new(((t * 0.5) % 2) - 1, 0)
		for i, s in ipairs(self.Spark) do
			local p = (t * 0.35 + i / #self.Spark) % 1
			s.Position = UDim2.fromOffset(24 + (i - 1) * ((self.W - 48) / 3) + math.sin(t * 2 + i) * 8, 4 - p * 30)
			s.BackgroundTransparency = 0.15 + 0.85 * p
			s.BackgroundColor3 = (i % 2 == 0) and a or s2
		end
	end

	-- ===== banner style panel (opened from the "Banner Style" pill under the on/off pill) =====
	local PRESETS = {
		{"Aurora", "#5FA5FF", "#9B7BFF", "#1B2340", "#0C0F1C"}, {"Ember", "#FF7A3D", "#FFC14D", "#3A1A12", "#170A08"},
		{"Mint", "#3DFFB0", "#3DC9FF", "#11302B", "#07161A"}, {"Sakura", "#FF7AB8", "#FFB3D9", "#3A1830", "#170A18"},
		{"Gold", "#FFC83D", "#FF9A3D", "#33280F", "#17110A"}, {"Mono", "#E6E6EE", "#8A8A99", "#26262C", "#0E0E12"},
		{"Sunset", "#FF5E7E", "#FFA24D", "#2E1430", "#140A1A"}, {"Void", "#9B6BFF", "#FF4DCF", "#1A0F2E", "#080510"},
	}
	local BSTYLE = {[0] = "Solid", [1] = "Gradient", [2] = "Animated"}
	local EFFECTS = {{"Glow", 1}, {"Shine", 2}, {"Sparks", 4}, {"Ring", 8}, {"Depth", 16}, {"Float", 32}}
	local FIELD = Color3.fromRGB(34, 34, 44)

	local function customizer(root, btn, api) -- api = {get = function() -> style table | nil, set = function(styleTable | nil)}
		local st, refreshers, order = {}, {}, 0
		local function load()
			for k in pairs(st) do st[k] = nil end
			for k, v in pairs(api.get() or {}) do st[k] = v end
			for k, v in pairs(DEF) do if st[k] == nil then st[k] = v end end
		end
		load()
		local function commit() local out = {}; for k, v in pairs(st) do out[k] = v end; api.set(out) end
		local function refreshAll() for _, f in ipairs(refreshers) do f() end end
		local function z(c, p, par) p.ZIndex = 61; return new(c, p, par) end
		local function nextOrder() order += 1; return order end

		local sb = new("TextButton", {AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(118, 26), AutoButtonColor = false, Text = "Banner Style",
			Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = WHITE, BorderSizePixel = 0, ZIndex = 50}, root)
		round(sb, UDim.new(1, 0))
		local sbs = new("UIStroke", {Thickness = 1.5}, sb)
		local panel = new("ScrollingFrame", {AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(238, 340), BorderSizePixel = 0, ScrollBarThickness = 3,
			CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y, Visible = false, ZIndex = 60}, root)
		round(panel, UDim.new(0, 12))
		local pst = new("UIStroke", {Thickness = 1.5}, panel)
		new("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder}, panel)
		new("UIPadding", {PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10)}, panel)

		local function paint()
			local bg = cardBG()
			panel.BackgroundColor3, sb.BackgroundColor3 = bg, bg
			pst.Color, sbs.Color = accent(), accent()
			panel.ScrollBarImageColor3 = accent()
		end
		local function sync()
			local p = btn.Position
			sb.Position = UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset + 36)
			panel.Position = UDim2.new(p.X.Scale, p.X.Offset + 126, p.Y.Scale, p.Y.Offset + 18)
		end
		local function row(h) return z("Frame", {Size = UDim2.new(1, 0, 0, h), BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = nextOrder()}, panel) end
		local function text(par, s, x, w, bold)
			return z("TextLabel", {Position = UDim2.fromOffset(x, 0), Size = UDim2.new(0, w, 1, 0), BackgroundTransparency = 1, Text = s,
				Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham, TextSize = 12, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left}, par)
		end
		local function mkbtn(par, s, props)
			props.Text, props.AutoButtonColor, props.Font, props.TextSize, props.TextColor3, props.BorderSizePixel = s, false, Enum.Font.GothamBold, 12, WHITE, 0
			props.BackgroundColor3 = props.BackgroundColor3 or FIELD
			local b = z("TextButton", props, par)
			round(b, UDim.new(0, 7))
			return b
		end

		-- header
		local hr = row(24)
		text(hr, "Banner Style", 0, 120, true)
		local reset = mkbtn(hr, "Reset", {AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(52, 22)})
		reset.Activated:Connect(function() api.set(nil); load(); refreshAll() end)

		-- theme presets
		local pg = z("Frame", {Size = UDim2.new(1, 0, 0, 58), BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = nextOrder()}, panel)
		new("UIGridLayout", {CellSize = UDim2.new(0.25, -5, 0, 26), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder}, pg)
		for i, p in ipairs(PRESETS) do
			local b = mkbtn(pg, p[1], {BackgroundColor3 = WHITE, LayoutOrder = i, TextSize = 11})
			b.TextStrokeTransparency = 0.45
			new("UIGradient", {Color = ColorSequence.new(hexc(p[2]), hexc(p[3]))}, b)
			b.Activated:Connect(function() st.a, st.a2, st.b1, st.b2 = p[2], p[3], p[4], p[5]; commit(); refreshAll() end)
		end

		-- colours (hex); empty = follow the host UI theme
		local function colorField(title, key, fallback)
			local r = row(26)
			text(r, title, 0, 82)
			local sw = z("Frame", {AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(22, 22), BorderSizePixel = 0}, r)
			round(sw, UDim.new(0, 6))
			new("UIStroke", {Thickness = 1, Color = WHITE, Transparency = 0.7}, sw)
			local tb = z("TextBox", {AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -28, 0.5, 0), Size = UDim2.fromOffset(86, 24), Text = "", PlaceholderText = "theme",
				PlaceholderColor3 = Color3.fromRGB(140, 140, 155), ClearTextOnFocus = false, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = WHITE,
				BackgroundColor3 = FIELD, BorderSizePixel = 0}, r)
			round(tb, UDim.new(0, 6))
			local function refresh()
				local c = hexc(st[key])
				tb.Text = c and tohex(c) or ""
				sw.BackgroundColor3 = c or fallback()
			end
			tb.FocusLost:Connect(function()
				local t = tb.Text:gsub("%s", "")
				if t == "" then st[key] = nil; commit()
				elseif hexc(t) then st[key] = tohex(hexc(t)); commit() end
				refresh()
			end)
			table.insert(refreshers, refresh)
			refresh()
		end
		colorField("Accent", "a", accent)
		colorField("Accent 2", "a2", function() return st.a and sec(hexc(st.a)) or sec(accent()) end)
		colorField("Background", "b1", function() return (bgPair({})) end)
		colorField("Background 2", "b2", function() return select(2, bgPair({})) end)

		-- steppers
		local function stepper(title, key, lo, hi, stp, wrap, suffix)
			local r = row(26)
			text(r, title, 0, 100)
			local val = z("TextLabel", {AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -28, 0.5, 0), Size = UDim2.fromOffset(44, 24), BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = WHITE}, r)
			local function refresh() val.Text = tostring(st[key]) .. (suffix or "") end
			local function bump(d)
				local v = (st[key] or DEF[key]) + d * stp
				if wrap then v = v % (hi + 0) elseif v < lo then v = lo elseif v > hi then v = hi end
				st[key] = v
				commit(); refresh()
			end
			mkbtn(r, "+", {AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(24, 24)}).Activated:Connect(function() bump(1) end)
			mkbtn(r, "-", {AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -76, 0.5, 0), Size = UDim2.fromOffset(24, 24)}).Activated:Connect(function() bump(-1) end)
			table.insert(refreshers, refresh)
			refresh()
		end
		stepper("Gradient angle", "gr", 0, 360, 45, true, "°")
		stepper("Border width", "bw", 0, 4, 1)
		stepper("Corners", "cr", 4, 24, 2)

		-- border mode
		local bm = mkbtn(row(26), "", {Size = UDim2.new(1, 0, 1, 0)})
		bm.Parent.Size = UDim2.new(1, 0, 0, 26)
		bm.Activated:Connect(function() st.bs = (st.bs + 1) % 3; commit(); refreshAll() end)
		table.insert(refreshers, function() bm.Text = "Border: " .. BSTYLE[st.bs] end)

		-- effects
		local eg = z("Frame", {Size = UDim2.new(1, 0, 0, 58), BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = nextOrder()}, panel)
		new("UIGridLayout", {CellSize = UDim2.new(1 / 3, -4, 0, 26), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder}, eg)
		for i, e in ipairs(EFFECTS) do
			local b = mkbtn(eg, e[1], {LayoutOrder = i})
			b.Activated:Connect(function() st.fx = bit32.bxor(st.fx, e[2]); commit(); refreshAll() end)
			table.insert(refreshers, function()
				local on = bit32.band(st.fx, e[2]) ~= 0
				b.BackgroundColor3 = on and accent() or FIELD
				b.TextTransparency = on and 0 or 0.4
			end)
		end

		sb.Activated:Connect(function()
			panel.Visible = not panel.Visible
			if panel.Visible then
				local cam = workspace.CurrentCamera
				panel.Size = UDim2.fromOffset(238, math.clamp((cam and cam.ViewportSize.Y or 600) - 80, 220, 380))
				load(); paint(); sync(); refreshAll()
			end
		end)
		paint(); sync(); refreshAll()
		return sync
	end

	-- local-only on/off pill (draggable): hides every banner on THIS client; your own banner keeps broadcasting to everyone else
	-- styleApi (optional) adds the "Banner Style" pill + panel: {get = function() -> style | nil, set = function(style | nil)}
	function UI.Toggle(enabled, onChange, styleApi)
		if not Env.UserInputService then return function() end end
		local par = host().Parent
		pcall(function() if UI.Ctl then UI.Ctl:Destroy() end end)
		for _, c in ipairs(UI.CtlConns or {}) do c:Disconnect() end
		UI.CtlConns = {}
		local root
		if par:IsA("ScreenGui") then root = new("Folder", {Name = HOST .. "Ctl"}, par)
		else root = new("ScreenGui", {Name = HOST .. "Ctl", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 50, ZIndexBehavior = Enum.ZIndexBehavior.Sibling}, par) end
		UI.Ctl = root
		local btn = new("TextButton", {AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.5, 0), Size = UDim2.fromOffset(118, 30),
			AutoButtonColor = false, Text = "", BorderSizePixel = 0, ZIndex = 50}, root)
		round(btn, UDim.new(1, 0))
		local stroke = new("UIStroke", {Thickness = 1.5}, btn)
		local dot = new("Frame", {AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 11, 0.5, 0), Size = UDim2.fromOffset(10, 10), BorderSizePixel = 0, ZIndex = 51}, btn)
		round(dot, UDim.new(1, 0))
		local lbl = new("TextLabel", {Position = UDim2.fromOffset(28, 0), Size = UDim2.new(1, -34, 1, 0), BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
			TextSize = 12, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 51}, btn)
		local function paint()
			btn.BackgroundColor3 = cardBG()
			stroke.Color = enabled and accent() or Color3.fromRGB(110, 110, 125)
			dot.BackgroundColor3 = stroke.Color
			lbl.Text = enabled and "Banners: ON" or "Banners: OFF"
			lbl.TextTransparency = enabled and 0 or 0.35
		end
		paint()
		local sync = function() end
		if styleApi then
			local ok, s = pcall(customizer, root, btn, styleApi)
			if ok and s then sync = s else warn("[UhBanner] style panel failed: " .. tostring(s)) end
		end
		local UIS, drag, start, orig, moved = Env.UserInputService
		local function press(t) return t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch end
		table.insert(UI.CtlConns, btn.InputBegan:Connect(function(i)
			if press(i.UserInputType) then drag, start, orig, moved = true, i.Position, btn.Position, false end
		end))
		table.insert(UI.CtlConns, UIS.InputChanged:Connect(function(i)
			if not drag or not (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then return end
			local d = i.Position - start
			if d.Magnitude > 6 then moved = true end
			if moved then btn.Position = UDim2.new(orig.X.Scale, orig.X.Offset + d.X, orig.Y.Scale, orig.Y.Offset + d.Y); sync() end
		end))
		table.insert(UI.CtlConns, UIS.InputEnded:Connect(function(i)
			if drag and press(i.UserInputType) then
				drag = false
				if not moved then enabled = not enabled; paint(); onChange(enabled) end
			end
		end))
		return function(v) enabled = v and true or false; paint() end
	end

	function UI.Cleanup()
		pcall(function() if UI.Ctl then UI.Ctl:Destroy(); UI.Ctl = nil end end)
		for _, c in ipairs(UI.CtlConns or {}) do c:Disconnect() end
		UI.CtlConns = {}
		for b in pairs(Active) do b:Destroy(false) end
		if conn then conn:Disconnect(); conn = nil end
		if UI.Host then pcall(function() UI.Host:Destroy() end); UI.Host = nil end
	end

	return UI
end
