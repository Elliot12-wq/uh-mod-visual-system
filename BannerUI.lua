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
		local a = accent()
		local bg = cardBG()
		local self = setmetatable({Opts = o, Seed = math.random() * 10, Alive = true, FX = {}, Spark = {}, LastBG = os.clock()}, Banner)
		local gui = new("BillboardGui", {Name = "UhBanner_" .. tostring(o.userId), AlwaysOnTop = true, Size = UDim2.fromOffset(260, 150),
			StudsOffset = Vector3.new(0, 1.7, 0), MaxDistance = 150, LightInfluence = 0, ResetOnSpawn = false,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Enabled = false}, host())
		local holder = new("Frame", {Name = "Holder", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(250, 78), BackgroundTransparency = 1}, gui)
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
		local title = new("TextLabel", {Position = UDim2.fromOffset(66, 11), Size = UDim2.new(1, -78, 0, 22), BackgroundTransparency = 1, Text = o.title,
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

	function Banner:_step(now, a, s2, low)
		if not self.Gui.Enabled then return end
		local t = now + self.Seed
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
		self.Glow.BackgroundTransparency = 0.86 + 0.05 * math.sin(t * 3)
		local e = (t * 0.65) % 1
		self.Ring.Size = UDim2.fromOffset(44 + 16 * e, 44 + 16 * e)
		self.RingStroke.Transparency = 0.2 + 0.8 * e
		self.Shine.Position = UDim2.fromOffset(-70 + ((t * 0.3) % 1) * 330, -10)
		self.BarGrad.Offset = Vector2.new(((t * 0.5) % 2) - 1, 0)
		for i, s in ipairs(self.Spark) do
			local p = (t * 0.35 + i / #self.Spark) % 1
			s.Position = UDim2.fromOffset(24 + (i - 1) * 62 + math.sin(t * 2 + i) * 8, 4 - p * 30)
			s.BackgroundTransparency = 0.15 + 0.85 * p
			s.BackgroundColor3 = (i % 2 == 0) and a or s2
		end
	end

	function UI.Cleanup()
		for b in pairs(Active) do b:Destroy(false) end
		if conn then conn:Disconnect(); conn = nil end
		if UI.Host then pcall(function() UI.Host:Destroy() end); UI.Host = nil end
	end

	return UI
end
