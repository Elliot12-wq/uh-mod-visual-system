-- BannerUI.lua | animated character banner (BillboardGui) themed from the host UI colours
return function(Env)
	local TS, RS = Env.TweenService, Env.RunService
	local UI, Active, conn = {}, {}, nil
	local Banner = {}; Banner.__index = Banner
	local HOST = "UhBannerHost"
	local WHITE = Color3.new(1, 1, 1)

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
	local BLACK = Color3.new(0, 0, 0)
	local LW, LH = 20, 16
	-- white check mark drawn from two bars (no font glyph needed)
	local function checkmark(par, z)
		for _, b in ipairs({{2, 6, 6.5, 10.5, -45}, {2, 10, 11, 8.5, 45}}) do
			new("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(b[1], b[2]), Position = UDim2.fromOffset(b[3], b[4]), Rotation = b[5],
				BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = z}, par)
		end
	end
	-- pseudo-3D rotating triangle: two shaded facets sharing an apex that slides sideways
	local function facet(par)
		local c = new("Frame", {BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 4}, par)
		return c, new("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, ZIndex = 4}, c)
	end
	local function makeLogo(par)
		local h = new("Frame", {Size = UDim2.fromOffset(LW, LH), BackgroundTransparency = 1, ZIndex = 4, LayoutOrder = 1}, par)
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

	function UI.new(o)
		local role = o.role
		local a = role and role.color or accent()
		local bg = cardBG()
		local W = (role and role.tag) and 316 or 250
		local self = setmetatable({Opts = o, Seed = math.random() * 10, Alive = true, FX = {}, Spark = {}, LastBG = os.clock(), Role = role, RoleColor = role and role.color, W = W}, Banner)
		local gui = new("BillboardGui", {Name = "UhBanner_" .. tostring(o.userId), AlwaysOnTop = true, Size = UDim2.fromOffset(W + 10, 150),
			StudsOffset = Vector3.new(0, 1.7, 0), MaxDistance = 150, LightInfluence = 0, ResetOnSpawn = false,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Enabled = false}, host())
		local holder = new("Frame", {Name = "Holder", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(W, 78), BackgroundTransparency = 1}, gui)
		local scale = new("UIScale", {Scale = 0}, holder)
		local glow = new("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 32), Size = UDim2.new(1, 14, 0, 76),
			BackgroundColor3 = a, BackgroundTransparency = 0.88, BorderSizePixel = 0, ZIndex = 0}, holder)
		round(glow, UDim.new(0, 24))
		-- triangular pointer: rotated square, upper half hidden behind the opaque card, lower half is the visible triangle
		local pointer = new("Frame", {Name = "Pointer", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 64),
			Size = UDim2.fromOffset(18, 18), Rotation = 45, BackgroundColor3 = a, BorderSizePixel = 0, ZIndex = 1}, holder)
		round(pointer, UDim.new(0, 3))
		local card = new("Frame", {Name = "Card", Size = UDim2.new(1, 0, 0, 64), BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 2, ClipsDescendants = true}, holder)
		round(card, UDim.new(0, 14))
		local cardGrad = new("UIGradient", {Rotation = 90, Color = ColorSequence.new(bg:Lerp(WHITE, 0.08), bg)}, card)
		local stroke = new("UIStroke", {Thickness = 2, Color = WHITE, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, card)
		local strokeGrad = new("UIGradient", {Color = ColorSequence.new(a, a)}, stroke)
		local img = new("ImageLabel", {Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(44, 44), BackgroundColor3 = bg:Lerp(WHITE, 0.12),
			BorderSizePixel = 0, Image = o.image, ScaleType = Enum.ScaleType.Crop, ZIndex = 3}, card)
		round(img, UDim.new(1, 0))
		new("UIStroke", {Thickness = 2, Color = a}, img)
		local ring = new("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(32, 32), Size = UDim2.fromOffset(44, 44),
			BackgroundTransparency = 1, ZIndex = 3}, card)
		round(ring, UDim.new(1, 0))
		local ringStroke = new("UIStroke", {Thickness = 2, Color = a}, ring)
		local title = new("TextLabel", {Position = UDim2.fromOffset(66, 11), Size = UDim2.new(1, (role and role.tag) and -178 or -78, 0, 22), BackgroundTransparency = 1, Text = o.title,
			Font = Enum.Font.GothamBold, TextSize = 17, TextColor3 = WHITE:Lerp(a, 0.12), TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd, TextTransparency = 1, ZIndex = 3}, card)
		local sub = new("TextLabel", {Position = UDim2.fromOffset(66, 34), Size = UDim2.new(1, -78, 0, 16), BackgroundTransparency = 1, Text = o.subtitle,
			Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = a, TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd, TextTransparency = 1, ZIndex = 3}, card)
		local bar = new("Frame", {Position = UDim2.new(0, 12, 1, -6), Size = UDim2.new(1, -24, 0, 2), BackgroundColor3 = a, BorderSizePixel = 0, ZIndex = 3}, card)
		local barGrad = new("UIGradient", {Transparency = fade(1, 0, 1)}, bar)
		local shine = new("Frame", {Position = UDim2.fromOffset(-70, -10), Size = UDim2.new(0, 46, 1, 20), Rotation = 18, BackgroundColor3 = WHITE,
			BorderSizePixel = 0, ZIndex = 4}, card)
		new("UIGradient", {Transparency = fade(1, 0.82, 1)}, shine)
		if role then -- verified check on the avatar (+ rank chip for owners)
			local vb = new("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(49, 49), Size = UDim2.fromOffset(18, 18),
				BackgroundColor3 = Color3.fromRGB(46, 140, 255), BorderSizePixel = 0, ZIndex = 6}, card)
			round(vb, UDim.new(1, 0))
			new("UIStroke", {Thickness = 2, Color = bg}, vb)
			checkmark(vb, 7)
			if role.tag then
				local chip = new("Frame", {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 10), Size = UDim2.fromOffset(0, 22),
					AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = a, BackgroundTransparency = 0.82, BorderSizePixel = 0, ZIndex = 3}, card)
				round(chip, UDim.new(0, 7))
				new("UIStroke", {Thickness = 1.5, Color = a}, chip)
				new("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 5)}, chip)
				new("UIPadding", {PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 8)}, chip)
				if role.logo then self.Logo = makeLogo(chip); logoStep(self.Logo, 0.4, a) end
				new("TextLabel", {Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, Text = role.tag,
					Font = Enum.Font.GothamBlack, TextSize = 12, TextColor3 = a:Lerp(WHITE, 0.35), ZIndex = 4, LayoutOrder = 2}, chip)
			end
		end
		for i = 1, 4 do
			local s = new("Frame", {Size = UDim2.fromOffset(4, 4), BackgroundColor3 = a, BorderSizePixel = 0, ZIndex = 5}, holder)
			round(s, UDim.new(1, 0))
			self.Spark[i] = s
			table.insert(self.FX, s)
		end
		table.insert(self.FX, ring); table.insert(self.FX, shine)
		self.Gui, self.Holder, self.Scale, self.Glow, self.Pointer, self.Card, self.CardGrad = gui, holder, scale, glow, pointer, card, cardGrad
		self.Stroke, self.StrokeGrad, self.Ring, self.RingStroke, self.Bar, self.BarGrad, self.Shine = stroke, strokeGrad, ring, ringStroke, bar, barGrad, shine
		self.Title, self.Sub, self.Img = title, sub, img
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
		local gui = self.Gui
		if animated and gui.Enabled then
			TS:Create(self.Scale, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Scale = 0}):Play()
			task.delay(0.3, function() gui:Destroy() end)
		else
			gui:Destroy()
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

	function Banner:_step(now, a, s2, low)
		if not self.Gui.Enabled then return end
		local t = now + self.Seed
		if self.RoleColor then a = self.RoleColor; s2 = sec(a) end
		self.Holder.Position = UDim2.new(0.5, 0, 0.5, low and 0 or math.sin(t * 2.2) * 3)
		self.Pointer.BackgroundColor3, self.Sub.TextColor3, self.Bar.BackgroundColor3 = a, a, a
		self.Glow.BackgroundColor3, self.RingStroke.Color = a, a
		self.StrokeGrad.Color = ColorSequence.new({ColorSequenceKeypoint.new(0, a), ColorSequenceKeypoint.new(0.5, s2), ColorSequenceKeypoint.new(1, a)})
		if now - self.LastBG > 2 then
			self.LastBG = now
			local bg = cardBG()
			self.CardGrad.Color = ColorSequence.new(bg:Lerp(WHITE, 0.08), bg)
		end
		if low then
			if not self.FXOff then self.FXOff = true; for _, f in ipairs(self.FX) do f.Visible = false end end
			return
		end
		if self.FXOff then self.FXOff = false; for _, f in ipairs(self.FX) do f.Visible = true end end
		self.StrokeGrad.Rotation = (now * 90) % 360
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

	-- local-only on/off pill (draggable): hides every banner on THIS client; your own banner keeps broadcasting to everyone else
	function UI.Toggle(enabled, onChange)
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
		local UIS, drag, start, orig, moved = Env.UserInputService
		local function press(t) return t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch end
		table.insert(UI.CtlConns, btn.InputBegan:Connect(function(i)
			if press(i.UserInputType) then drag, start, orig, moved = true, i.Position, btn.Position, false end
		end))
		table.insert(UI.CtlConns, UIS.InputChanged:Connect(function(i)
			if not drag or not (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then return end
			local d = i.Position - start
			if d.Magnitude > 6 then moved = true end
			if moved then btn.Position = UDim2.new(orig.X.Scale, orig.X.Offset + d.X, orig.Y.Scale, orig.Y.Offset + d.Y) end
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
