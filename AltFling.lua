-- AltFling.lua | Alt-Fling remake: Served User requests + consent, Alt-Flinger console, relationship viewer
-- Backend: POST /alt and GET /alt on the existing live-sync backend (server.js). Identity = the banner token (Env.Token), same check as /commands.
-- Roles: the REQUESTER is the Alt Flinger (flings with its own current fling method); the TARGET is the Served User (clicks targets, gets the results back).
-- Env needs: Player, Players, HttpService, Request, Backend, Room, Token, GetColor, Notify(msg), MethodId(), MethodName(), RunFling(player) -> ok, reason,
--            GetServedUI() -> {Input, Request, View, Status} (main-tab controls), Expose(api)
return function(Env)
	local HS, Players, Me = Env.HttpService, Env.Players, Env.Player
	local UIS = game:GetService("UserInputService")
	local A = {Running = false, Rels = {}, Pending = {}, Out = {}, Log = {}}
	local conns, C, V, P = {}, {}, {}, {Cards = {}}
	local dirty = {log = true, view = true}
	local WINDOW, MOVED, SPEED = 5, 60, 300 -- observation window (s), studs moved / studs per second that count as evidence of a fling
	local COL = {CONFIRMED = "#46f08c", UNCONFIRMED = "#ffbe3c", FAILED = "#ff5a5a", PENDING = "#8a93a6", INFO = "#7aa2ff"}

	local function new(c, p, par) local i = Instance.new(c); for k, v in pairs(p) do i[k] = v end; i.Parent = par; return i end
	local function round(par, r) return new("UICorner", {CornerRadius = UDim.new(0, r or 6)}, par) end
	local function accent()
		local ok, c = pcall(Env.GetColor)
		return (ok and typeof(c) == "Color3") and c or Color3.fromRGB(95, 165, 255)
	end
	local function stroke(par) return new("UIStroke", {Color = accent(), Thickness = 1.5}, par) end
	local function esc(s) return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
	local function stamp() return os.date("%H:%M:%S") end
	local function notify(t) pcall(Env.Notify, t) end
	local function setVis(o, v) if o then pcall(function() o.Visible = v end) end end
	local function setText(o, t) if o then pcall(function() o.Text = t end) end end
	local function methodName() local ok, n = pcall(Env.MethodName); return ok and tostring(n) or "unknown" end

	-- ===== backend =====
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
			local ok, r, code = call("POST", "/alt", body)
			if ok or code ~= 429 then return ok, r end
			task.wait(0.5)
		end
		return false, "slow down"
	end

	-- ===== state helpers =====
	local function asFlinger() local t = {}; for _, r in ipairs(A.Rels) do if r.flinger == Me.UserId then t[#t + 1] = r end end; return t end
	local function asServed() local t = {}; for _, r in ipairs(A.Rels) do if r.served == Me.UserId then t[#t + 1] = r end end; return t end
	local function names(list, key) local t = {}; for _, r in ipairs(list) do t[#t + 1] = r[key] end; return table.concat(t, ", ") end
	local function find(name)
		local low, best = name:lower(), nil
		for _, p in ipairs(Players:GetPlayers()) do
			if p.Name:lower() == low then return p end
			if not best and (p.DisplayName:lower() == low or p.Name:lower():sub(1, #low) == low) then best = p end
		end
		return best
	end
	local function findExact(name)
		local low = tostring(name):lower()
		for _, p in ipairs(Players:GetPlayers()) do if p.Name:lower() == low then return p end end
	end

	-- ===== log =====
	local function addLog(e)
		e.time = e.time or stamp()
		A.Log[#A.Log + 1] = e
		if #A.Log > 80 then table.remove(A.Log, 1) end
		dirty.log = true
		return e
	end
	local function lineOf(e)
		if e.text then return ('<font color="#8a93a6">[%s]</font> <font color="%s">*</font> %s'):format(e.time, COL.INFO, esc(e.text)) end
		return ('<font color="#8a93a6">[%s]</font> %s <font color="#8a93a6">|</font> %s <font color="#8a93a6">|</font> <font color="%s"><b>%s</b></font>%s'):format(
			e.time, esc(e.victim), esc(e.method), COL[e.status] or COL.PENDING, e.status, e.detail and (" " .. esc(e.detail)) or "")
	end

	-- ===== ui =====
	local function host()
		if A.Gui and A.Gui.Parent then return A.Gui end
		local parent
		pcall(function() parent = (gethui and gethui()) or game:GetService("CoreGui") end)
		parent = parent or Me:WaitForChild("PlayerGui")
		pcall(function() for _, v in ipairs(parent:GetChildren()) do if v.Name == "UhAltFlingHost" then v:Destroy() end end end)
		A.Gui = new("ScreenGui", {Name = "UhAltFlingHost", ResetOnSpawn = false, DisplayOrder = 950, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling}, parent)
		return A.Gui
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
		new("TextLabel", {BackgroundTransparency = 1, Size = UDim2.new(1, -40, 1, 0), Position = UDim2.fromOffset(8, 0), Text = title, Font = Enum.Font.Code,
			TextSize = 12, TextColor3 = accent(), TextXAlignment = Enum.TextXAlignment.Left}, head)
		drag(f, head)
		return f, head
	end
	local function list(par, pos, size)
		local s = new("ScrollingFrame", {Position = pos, Size = size, BackgroundColor3 = Color3.fromRGB(12, 13, 18), BorderSizePixel = 0, ScrollBarThickness = 3,
			CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y}, par)
		round(s, 5)
		new("UIListLayout", {Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder}, s)
		return s
	end

	local function buildConsole()
		if C.Frame and C.Frame.Parent then return end
		C.Frame = panel(host(), "Console", UDim2.fromOffset(320, 250), UDim2.new(0, 14, 0.5, -125), nil, "ALT-FLINGER CONSOLE")
		C.Info = new("TextLabel", {BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 30), Size = UDim2.new(1, -16, 0, 46), RichText = true, Font = Enum.Font.Code,
			TextSize = 12, TextColor3 = Color3.fromRGB(220, 224, 235), TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = ""}, C.Frame)
		C.Scroll = list(C.Frame, UDim2.fromOffset(8, 80), UDim2.new(1, -16, 1, -116))
		button(C.Frame, "Users", UDim2.fromOffset(96, 24), UDim2.new(0, 8, 1, -30), function() A.ToggleViewer() end)
		button(C.Frame, "Clear log", UDim2.fromOffset(96, 24), UDim2.new(0, 112, 1, -30), function() table.clear(A.Log); dirty.log = true; A.Render() end)
		button(C.Frame, "Stop", UDim2.fromOffset(96, 24), UDim2.new(0, 216, 1, -30), function()
			for _, r in ipairs(asFlinger()) do
				local ok, e = post("end", r.served)
				if not ok then notify("Could not end " .. r.sname .. ": " .. tostring(e)) end
			end
			A.Poll()
		end)
	end
	local function buildViewer()
		if V.Frame and V.Frame.Parent then return end
		local _, head
		V.Frame, head = panel(host(), "Viewer", UDim2.fromOffset(300, 200), UDim2.new(0.5, 0, 0.5, 0), Vector2.new(0.5, 0.5), "ALT FLINGER FOR")
		button(head, "X", UDim2.fromOffset(22, 18), UDim2.new(1, -26, 0, 4), function() V.Frame.Visible = false end)
		V.List = list(V.Frame, UDim2.fromOffset(8, 32), UDim2.new(1, -16, 1, -40))
	end
	local function buildPrompt(r)
		if not (P.List and P.List.Parent) then
			P.List = new("Frame", {Name = "Prompts", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 64), Size = UDim2.fromOffset(320, 0),
				AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1}, host())
			new("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder}, P.List)
		end
		local card = new("Frame", {Size = UDim2.fromOffset(320, 88), BackgroundColor3 = Color3.fromRGB(8, 9, 12), BorderSizePixel = 0, LayoutOrder = r.ts or 0}, P.List)
		round(card, 8); stroke(card)
		new("TextLabel", {BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 44), RichText = true, TextWrapped = true, Font = Enum.Font.Code,
			TextSize = 12, TextColor3 = Color3.fromRGB(220, 224, 235), TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
			Text = ("<b>%s</b> wants you as their Served User.\nThey would be your Alt Flinger."):format(esc(r.name))}, card)
		button(card, "Accept", UDim2.new(0.5, -14, 0, 26), UDim2.new(0, 10, 1, -34), function() A.Respond(r.from, true) end)
		button(card, "Decline", UDim2.new(0.5, -14, 0, 26), UDim2.new(0.5, 4, 1, -34), function() A.Respond(r.from, false) end)
		P.Cards[r.from] = card
	end

	local function updateInfo()
		if not (C.Frame and C.Frame.Visible) then return end
		C.Info.Text = ('<font color="#8a93a6">status </font><font color="#46f08c"><b>ACTIVE</b></font>\n<font color="#8a93a6">method </font>%s\n<font color="#8a93a6">served </font>%s'):format(
			esc(methodName()), esc(names(asFlinger(), "sname")))
	end
	local function renderLog()
		if not dirty.log or not (C.Scroll and C.Scroll.Parent) then return end
		dirty.log = false
		for _, c in ipairs(C.Scroll:GetChildren()) do if c:IsA("TextLabel") then c:Destroy() end end
		for i, e in ipairs(A.Log) do
			new("TextLabel", {BackgroundTransparency = 1, Size = UDim2.new(1, -4, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, RichText = true,
				Font = Enum.Font.Code, TextSize = 11, TextColor3 = Color3.fromRGB(220, 224, 235), TextXAlignment = Enum.TextXAlignment.Left, Text = lineOf(e), LayoutOrder = i}, C.Scroll)
		end
		task.defer(function() if C.Scroll and C.Scroll.Parent then C.Scroll.CanvasPosition = Vector2.new(0, 1e6) end end)
	end
	local function renderViewer()
		if not dirty.view or not (V.Frame and V.Frame.Parent and V.Frame.Visible) then return end
		dirty.view = false
		for _, c in ipairs(V.List:GetChildren()) do if not c:IsA("UIListLayout") then c:Destroy() end end
		local f = asFlinger()
		if #f == 0 then
			new("TextLabel", {BackgroundTransparency = 1, Size = UDim2.new(1, -4, 0, 28), Text = "You are not an active Alt Flinger for anyone.", Font = Enum.Font.Code,
				TextSize = 11, TextColor3 = Color3.fromRGB(138, 147, 166), TextWrapped = true}, V.List)
		end
		for i, r in ipairs(f) do
			local row = new("Frame", {Size = UDim2.new(1, -4, 0, 28), BackgroundColor3 = Color3.fromRGB(16, 18, 24), BorderSizePixel = 0, LayoutOrder = i}, V.List)
			round(row, 5)
			new("TextLabel", {BackgroundTransparency = 1, Size = UDim2.new(1, -70, 1, 0), Position = UDim2.fromOffset(8, 0), Font = Enum.Font.Code, TextSize = 11,
				TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
				Text = r.sname .. "  (since " .. os.date("%H:%M:%S", math.floor((r.ts or 0) / 1000)) .. ")"}, row)
			button(row, "End", UDim2.fromOffset(52, 20), UDim2.new(1, -58, 0, 4), function()
				local ok, e = post("end", r.served)
				if not ok then notify("Could not end: " .. tostring(e)) end
				A.Poll()
			end)
		end
	end
	local function syncMain()
		local ui = Env.GetServedUI and Env.GetServedUI()
		if not ui then return end
		local f, s, txt = asFlinger(), asServed(), nil
		if #f > 0 then txt = "Served User: ACTIVE for " .. names(f, "sname") .. " (console open)"
		elseif #s > 0 then txt = "Served User: " .. names(s, "fname") .. " is your Alt Flinger"
		elseif #A.Out > 0 then txt = "Served User: waiting for " .. A.Out[1].name .. " to answer"
		else txt = "Served User: none" end
		setText(ui.Status, txt)
		setVis(ui.Input, #f == 0)
		setVis(ui.Request, #f == 0)
	end
	function A.Render()
		if #asFlinger() > 0 then
			buildConsole()
			C.Frame.Visible = true
		elseif C.Frame then
			C.Frame.Visible = false
		end
		updateInfo(); renderLog(); renderViewer(); syncMain()
		local want = {}
		for _, r in ipairs(A.Pending) do
			want[r.from] = true
			if not P.Cards[r.from] then
				buildPrompt(r)
				notify(r.name .. " wants you as their Served User - Accept or Decline")
			end
		end
		for id, card in pairs(P.Cards) do if not want[id] then card:Destroy(); P.Cards[id] = nil end end
	end

	function A.ToggleViewer()
		if not A.Running then notify("Alt-Fling needs the live-sync backend (not connected)"); return end
		buildViewer()
		V.Frame.Visible = not V.Frame.Visible
		dirty.view = true
		A.Render()
		if V.Frame.Visible then task.spawn(A.Poll) end
	end

	-- ===== flinging (Alt Flinger side) =====
	local function rootOf(p) local c = p.Character; return c and (c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart), c end
	local function observe(target) -- only reports CONFIRMED on evidence this client actually saw; everything else is UNCONFIRMED
		local r0, c0 = rootOf(target)
		if not r0 then return "UNCONFIRMED", "target had no character to observe" end
		local p0, t0 = r0.Position, os.clock()
		while os.clock() - t0 < WINDOW do
			task.wait(0.1)
			if not target.Parent then return "UNCONFIRMED", "target left the server before a result could be observed" end
			local r, c = rootOf(target)
			if not r or c ~= c0 then return "UNCONFIRMED", "target respawned or died (cause not established)" end
			local moved, speed = (r.Position - p0).Magnitude, r.AssemblyLinearVelocity.Magnitude
			if moved >= MOVED then return "CONFIRMED", ("observed locally: moved %d studs"):format(math.floor(moved)) end
			if speed >= SPEED then return "CONFIRMED", ("observed locally: %d studs/s"):format(math.floor(speed)) end
		end
		return "UNCONFIRMED", ("no displacement observed in %ds"):format(WINDOW)
	end
	local function report(ev, e)
		local ok, err = post("result", ev.served, {cid = ev.cid, victim = ev.victim, method = e.method, result = e.status:lower(), detail = e.detail or ""})
		if not ok then
			e.detail = (e.detail or "") .. " (report to Served User failed: " .. tostring(err) .. ")"
			dirty.log = true
			A.Render()
		end
	end
	function A.Execute(ev)
		local e = addLog({victim = ev.victim, method = methodName(), status = "PENDING", detail = "command from " .. tostring(ev.sname)})
		A.Render()
		local function finish(status, detail)
			e.status, e.detail = status, detail
			dirty.log = true
			A.Render()
			report(ev, e)
		end
		local ok = false
		for _, r in ipairs(asFlinger()) do if r.served == ev.served then ok = true end end
		if not ok then return finish("FAILED", "no active relationship on the backend") end
		local target = findExact(ev.victim)
		if not target then return finish("FAILED", "target is not in this server") end
		if target == Me then return finish("FAILED", "target is this account") end
		if target.UserId == ev.served then return finish("FAILED", "target is the Served User") end
		local okM, mid = pcall(Env.MethodId)
		if okM and mid == 8 then return finish("FAILED", "current method is Alt-fling, which never flings (pick a real fling method)") end
		local okR, r1, r2 = pcall(Env.RunFling, target)
		if not okR then return finish("FAILED", tostring(r1):sub(1, 80)) end
		if r1 == false then return finish("FAILED", tostring(r2 or "fling engine rejected the target (dead / already flinging / invalid)")) end
		local status, detail = observe(target)
		if status == "UNCONFIRMED" and r1 == nil then detail = detail .. "; engine returned no result" end
		finish(status, detail)
	end

	-- ===== served side =====
	function A.SendFling(target)
		local r = asServed()[1]
		if not r then return false end
		if typeof(target) ~= "Instance" or not target:IsA("Player") then return false end
		if os.clock() - (A.LastFling or 0) < 0.5 then return false end
		A.LastFling = os.clock()
		local ok, err = post("fling", r.flinger, {victim = target.Name, cid = tostring(math.random(100000, 999999))})
		if not ok then notify("Alt-Fling NOT sent: " .. tostring(err)); return false end
		notify("Fling command sent to " .. r.fname .. " for " .. target.Name .. " (result pending)")
		return true
	end

	-- ===== requests / consent =====
	function A.Request(name)
		if not A.Running then
			local m = "Alt-Fling needs the live-sync backend (not connected)"
			notify(m)
			return false, m
		end
		name = (tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""))
		local function fail(m) notify(m); return false, m end
		if name == "" then return fail("Type a username first") end
		local pl = find(name)
		if not pl then return fail("No player matching '" .. name .. "' in this server") end
		if pl == Me then return fail("You can't request yourself") end
		local ok, err = post("request", pl.UserId)
		if not ok then
			if err == "target is not running the script" then err = pl.Name .. " is not running this script" end
			return fail("Request not sent: " .. tostring(err))
		end
		notify("Request sent to " .. pl.Name .. " - waiting for them to answer")
		A.Poll()
		return true
	end
	function A.Respond(from, accept)
		local ok, err = post("respond", from, {accept = accept and true or false})
		local card = P.Cards[from]
		if card then card:Destroy(); P.Cards[from] = nil end
		if not ok then notify("Could not answer the request: " .. tostring(err)) end
		A.Poll()
		return ok, err
	end

	-- ===== polling =====
	local function handle(ev, ended)
		local t, me = ev.type, Me.UserId
		if t == "accepted" then
			if ev.flinger == me then
				addLog({text = ev.sname .. " accepted - you are now their Alt Flinger"})
				notify(ev.sname .. " accepted. You are now their Alt Flinger.")
			elseif ev.served == me then
				notify("You accepted " .. ev.fname .. ". They are now your Alt Flinger.")
			end
		elseif t == "declined" then
			addLog({text = ev.name .. " declined your Served User request"})
			notify(ev.name .. " declined your Served User request.")
		elseif t == "ended" then
			ended[ev.flinger .. ">" .. ev.served] = true
			if ev.flinger == me then addLog({text = "relationship with " .. ev.sname .. " ended"}) end
			notify("Alt-Fling relationship ended by " .. tostring(ev.name))
		elseif t == "fling" then
			task.spawn(A.Execute, ev)
		elseif t == "result" then
			notify(("%s: %s %s [%s]%s"):format(ev.fname, ev.victim, tostring(ev.result):upper(), ev.method, (ev.detail ~= "" and (" - " .. ev.detail) or "")))
		end
	end
	local function apply(d)
		local old = {}
		for _, r in ipairs(A.Rels) do old[r.flinger .. ">" .. r.served] = r end
		A.Rels, A.Pending, A.Out = d.rels or {}, d.pending or {}, d.out or {}
		local sig = {}
		for _, r in ipairs(A.Rels) do sig[#sig + 1] = r.flinger .. ">" .. r.served end
		sig = table.concat(sig, ",")
		if sig ~= A.Sig then A.Sig = sig; dirty.view = true end
		local ended = {}
		for _, ev in ipairs(d.events or {}) do
			local ok, err = pcall(handle, ev, ended)
			if not ok then warn("[AltFling] event failed: " .. tostring(err)) end
		end
		for _, r in ipairs(A.Rels) do old[r.flinger .. ">" .. r.served] = nil end
		for k, r in pairs(old) do
			if not ended[k] then -- gone from the backend without an ended event (other player left / backend restarted)
				if r.flinger == Me.UserId then addLog({text = "relationship with " .. r.sname .. " is no longer active on the backend"}) end
				notify("Alt-Fling relationship is no longer active on the backend")
			end
		end
		A.Render()
	end
	function A.Poll()
		local ok, d = call("GET", "/alt?room=" .. HS:UrlEncode(Env.Room) .. "&userId=" .. Me.UserId .. "&token=" .. HS:UrlEncode(Env.Token))
		if not ok then return false, d end
		apply(d)
		return true
	end
	function A.Start()
		if A.Running or not Env.Request then return end
		A.Running = true
		task.spawn(function()
			local fails = 0
			while A.Running do
				local ok, res = pcall(A.Poll)
				if ok and res then fails = 0 else fails += 1 end
				local busy = #A.Rels > 0 or #A.Pending > 0 or #A.Out > 0 -- poll slowly while idle (saves backend requests)
				task.wait(math.min((busy and 1.5 or 4) + fails * 1.5, 12))
			end
		end)
		task.spawn(function() while A.Running do task.wait(0.5); pcall(updateInfo) end end)
	end
	function A.Stop()
		A.Running = false
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		table.clear(conns)
		if A.Gui then pcall(function() A.Gui:Destroy() end); A.Gui = nil end
		C, V, P = {}, {}, {Cards = {}}
		A.Rels, A.Pending, A.Out = {}, {}, {}
		pcall(syncMain)
		pcall(Env.Expose, nil)
	end

	Env.Expose({
		Request = A.Request, SendFling = A.SendFling, ToggleViewer = A.ToggleViewer, Poll = A.Poll, Stop = A.Stop,
		HasFlinger = function() return #asServed() > 0 end,
	})
	return A
end
