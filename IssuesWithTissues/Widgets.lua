-- The building blocks every page uses: the flat look (Fill, Skin, Card), buttons, sub-tabs,
-- windows, scrolling lists, input boxes with name suggestions, a copy box for reports, and
-- small formatting helpers. Colours come from UI.COLORS (UI.lua), which a theme may change.

local _, ns = ...

local UI = ns.UI
local C = UI.COLORS

function UI.Fill(tex, c)
	if tex.SetColorTexture then
		tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
	else
		tex:SetTexture("Interface\\Buttons\\WHITE8x8")
		tex:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
	end
	return tex
end

-- A flat background and a 1px edge (edge false: none) on any frame.
local SIDES = { { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }
local skins = setmetatable({}, { __mode = "k" })
function UI.Skin(f, bg, edge)
	local s = skins[f]
	if not s then
		s = { edges = {} }
		skins[f] = s
		s.bg = f:CreateTexture(nil, "BACKGROUND")
		s.bg:SetAllPoints()
		for i, pts in ipairs(SIDES) do
			local t = f:CreateTexture(nil, "BORDER")
			t:SetPoint(pts[1])
			t:SetPoint(pts[2])
			if i <= 2 then t:SetHeight(1) else t:SetWidth(1) end
			s.edges[i] = t
		end
	end
	if bg then UI.Fill(s.bg, bg); s.bg:Show() else s.bg:Hide() end
	for _, t in ipairs(s.edges) do
		if edge then UI.Fill(t, edge); t:Show() else t:Hide() end
	end
	return s
end

-- A card: a slightly lighter box to group things on a page. Drawn with the page's own
-- background textures, so the page's text stays on top (a child frame would cover it).
function UI.Card(parent, x, y, w, h)
	local bg = UI.Fill(parent:CreateTexture(nil, "BACKGROUND"), C.card)
	bg:SetPoint("TOPLEFT", x, y)
	bg:SetSize(w, h)
	for i, pts in ipairs(SIDES) do
		local t = UI.Fill(parent:CreateTexture(nil, "BORDER"), C.dim)
		t:SetPoint(pts[1], bg, pts[1])
		t:SetPoint(pts[2], bg, pts[2])
		if i <= 2 then t:SetHeight(1) else t:SetWidth(1) end
	end
	return bg
end

-- A flat button. style: nil (plain), "primary" (the main action on a page), "close".
function UI.Button(parent, text, width, height, style)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(width or 100, height or 22)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("CENTER")
	b:SetFontString(fs)
	-- No font objects per state: they would reset the text colour on hover. Greyed out by hand.
	local disable, enable = b.Disable, b.Enable
	function b:Disable()
		disable(self)
		if self.label.SetTextColor then self.label:SetTextColor(0.5, 0.5, 0.5) end
	end
	function b:Enable()
		enable(self)
		UI.SetSelected(self, self.selected)
	end
	function b:SetEnabled(on) if on then self:Enable() else self:Disable() end end
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	UI.Fill(hl, C.hover)
	b.label = fs
	b.style = style or "plain"
	fs.noTheme = b.style == "primary" -- its own text colour, set for the button's fill
	UI.SetSelected(b, false)
	if text then b:SetText(text) end
	return b
end

-- Selected: lighter, with a gold edge and gold text (filters, tabs).
function UI.SetSelected(b, on)
	b.selected = on and true or false
	if b.style == "tab" then
		-- Tabs share the window's gold edge, so they read as part of the frame.
		UI.Skin(b, on and C.selected or C.button, C.edge)
	elseif on then
		UI.Skin(b, C.selected, C.edge)
	elseif b.style == "primary" then
		UI.Skin(b, C.primary, C.edge)
	elseif b.style == "close" then
		UI.Skin(b, C.close, C.dim)
	else
		UI.Skin(b, C.button, C.dim)
	end
	local fs = b.label
	if fs and fs.SetTextColor then
		local c = on and C.gold or C.text
		if b.style == "primary" and not on then c = C.primarytext or C.gold end
		if b.style == "tab" and not on then c = C.tabtext end
		fs:SetTextColor(c[1], c[2], c[3])
	end
end

-- A sub-tab: text with a gold line under it when selected.
function UI.SubTab(parent, text)
	local b = CreateFrame("Button", nil, parent)
	b:SetHeight(24)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("CENTER", 0, 1)
	fs:SetText(text)
	b:SetWidth(math.max(70, (fs.GetStringWidth and fs:GetStringWidth() or 0) + 28))
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	UI.Fill(hl, C.hover)
	b.line = UI.Fill(b:CreateTexture(nil, "ARTWORK"), C.gold)
	b.line:SetPoint("BOTTOMLEFT", 6, 0)
	b.line:SetPoint("BOTTOMRIGHT", -6, 0)
	b.line:SetHeight(2)
	function b:SetSelectedTab(on)
		self.line:SetShown(on)
		local c = on and C.gold or C.subtext
		if fs.SetTextColor then fs:SetTextColor(c[1], c[2], c[3]) end
	end
	b:SetSelectedTab(false)
	return b
end

-- A movable window with a title bar, close button and the flat look.
function UI.Window(name, width, height, title, strata)
	local f = CreateFrame("Frame", name, UIParent)
	f:SetSize(width, height)
	f:SetPoint("CENTER")
	f:SetFrameStrata(strata or "HIGH")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	UI.Skin(f, C.bg, C.edge)
	local bar = UI.Fill(f:CreateTexture(nil, "BORDER"), C.bar)
	bar:SetPoint("TOPLEFT", 1, -1)
	bar:SetPoint("TOPRIGHT", -1, -1)
	bar:SetHeight(30)
	local under = UI.Fill(f:CreateTexture(nil, "BORDER"), C.dim)
	under:SetPoint("TOPLEFT", 1, -31)
	under:SetPoint("TOPRIGHT", -1, -31)
	under:SetHeight(1)
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("TOP", 0, -10)
	f.title:SetText(title or "")
	f.close = UI.Button(f, "x", 22, 20, "close")
	f.close:SetPoint("TOPRIGHT", -6, -6)
	f.close:SetScript("OnClick", function() f:Hide() end)
	f:Hide()
	if name then tinsert(UISpecialFrames, name) end -- Escape closes it
	return f
end


-- A list row: a faint stripe on every other row and a soft glow under the mouse.
function UI.StyleRow(line, i)
	if i % 2 == 0 then
		local st = UI.Fill(line:CreateTexture(nil, "BACKGROUND"), C.stripe)
		st:SetAllPoints()
	end
	local hl = UI.Fill(line:CreateTexture(nil, "HIGHLIGHT"), C.hover)
	hl:SetAllPoints()
end

---------------------------------------------------------------------------
-- A scrolling list with column titles, shared by the boards.
--   local list = UI.CreateList(panel, { top = -60, rows = 15, columns = { {key, label, width}, ... },
--       onClick = fn(row, button), onEnter = fn(line, row) })
--   list:SetRows(rows, function(row, key) return text, r, g, b end)
---------------------------------------------------------------------------
function UI.CreateList(panel, opts)
	local list = { rows = {}, offset = 0, lines = {}, titles = {} }
	local ROW_H = opts.rowHeight or 18
	local x = 4
	for c, col in ipairs(opts.columns) do
		local t = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		t:SetPoint("TOPLEFT", x, opts.top)
		t:SetText(col.label)
		list.titles[c] = t
		x = x + col.width
	end
	local rule = UI.Fill(panel:CreateTexture(nil, "BORDER"), C.dim)
	rule:SetPoint("TOPLEFT", 0, opts.top - 15)
	rule:SetPoint("TOPRIGHT", 0, opts.top - 15)
	rule:SetHeight(1)
	for i = 1, opts.rows do
		local line = CreateFrame("Button", nil, panel)
		line:SetSize(606, ROW_H)
		UI.StyleRow(line, i)
		line:SetPoint("TOPLEFT", 4, opts.top - 18 - (i - 1) * ROW_H)
		line.cells = {}
		local cx = 0
		for c, col in ipairs(opts.columns) do
			local fs = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			fs:SetPoint("LEFT", cx, 0)
			fs:SetWidth(col.width - 4)
			fs:SetJustifyH("LEFT")
			fs:SetWordWrap(false)
			line.cells[c] = fs
			cx = cx + col.width
		end
		line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		line:SetScript("OnClick", function(self, button)
			if self.row and opts.onClick then opts.onClick(self.row, button) end
		end)
		line:SetScript("OnEnter", function(self)
			if not self.row or not opts.onEnter then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			opts.onEnter(self, self.row)
			GameTooltip:Show()
		end)
		line:SetScript("OnLeave", function() GameTooltip:Hide() end)
		line:Hide()
		list.lines[i] = line
	end
	-- Shown in place of the rows when there are none (list:SetEmpty("Nobody's ...")).
	local empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	empty:SetPoint("TOPLEFT", 12, opts.top - 30)
	empty:SetWidth(580)
	empty:SetJustifyH("LEFT")
	list.emptyText = empty
	function list:SetEmpty(text) self.empty = text end
	panel:EnableMouseWheel(true)
	panel:SetScript("OnMouseWheel", function(_, delta)
		list.offset = math.max(0, list.offset - delta * 3)
		list:Draw()
	end)
	function list:SetRows(rows, cell)
		self.rows, self.cell = rows, cell
		self:Draw()
	end
	function list:Draw()
		self.emptyText:SetText(#self.rows == 0 and self.empty or "")
		local maxOffset = math.max(0, #self.rows - opts.rows)
		if self.offset > maxOffset then self.offset = maxOffset end
		for i, line in ipairs(self.lines) do
			local row = self.rows[i + self.offset]
			line.row = row
			if row then
				for c, col in ipairs(opts.columns) do
					local text, r, g, b = self.cell(row, col.key)
					line.cells[c]:SetText(text or "")
					line.cells[c]:SetTextColor(r or 1, g or 1, b or 1)
				end
				line:Show()
			else
				line:Hide()
			end
		end
	end
	return list
end

-- A one-line text box with a grey hint while empty.
function UI.CreateInput(panel, width, hint)
	local box = CreateFrame("EditBox", nil, panel)
	box:SetSize(width, 22)
	box:SetAutoFocus(false)
	box:SetMaxLetters(80)
	box:SetFontObject(_G.GameFontHighlightSmall or "GameFontHighlightSmall")
	box:SetTextInsets(7, 7, 0, 0)
	UI.Skin(box, C.input, C.dim)
	local h = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	h:SetPoint("LEFT", 7, 0)
	h:SetText(hint or "")
	box.hint = h
	local function Update()
		local focus = box:HasFocus()
		if not focus and GetTime then box.focusLostAt = GetTime() end
		h:SetShown((box:GetText() or "") == "" and not focus)
		UI.Skin(box, C.input, focus and C.edge or C.dim)
	end
	box:SetScript("OnEditFocusGained", Update)
	box:SetScript("OnEditFocusLost", Update)
	box:SetScript("OnTextChanged", function(self, user)
		Update()
		if self.onChange then self.onChange(self:GetText() or "", user) end
	end)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
		if self.onEnter then self.onEnter(self:GetText() or "") end
	end)
	return box
end

-- Guildmates whose name matches what was typed, like the mailbox's To box: names (first name,
-- surname or full name) that start with it come first, then names that merely contain it;
-- online before offline, then alphabetical. Returns roster keys.
function UI.NameMatches(text, max)
	text = tostring(text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then return {} end
	local hits = {}
	for key, m in pairs(ns.Roster.members) do
		local name = ns.Roster.DisplayName(key)
		local low = name:lower()
		local score
		if low:sub(1, #text) == text then score = 0
		else
			for word in low:gmatch("%S+") do
				if word:sub(1, #text) == text then score = 1 break end
			end
			if not score and low:find(text, 1, true) then score = 2 end
		end
		if score then hits[#hits + 1] = { key = key, name = name, score = score, online = m.online and 0 or 1 } end
	end
	table.sort(hits, function(a, b)
		if a.score ~= b.score then return a.score < b.score end
		if a.online ~= b.online then return a.online < b.online end
		return a.name < b.name
	end)
	local out = {}
	for i = 1, math.min(#hits, max or 8) do out[i] = hits[i].key end
	return out
end

-- A dropdown of matching guildmates under an input box (see UI.NameMatches). Click a name, or
-- use the arrow keys and Tab / Enter, to fill the box with the full name.
local SUGGEST_ROWS = 8
function UI.AttachNameSuggest(box)
	local drop = CreateFrame("Frame", nil, box)
	drop:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -2)
	drop:SetSize((box:GetWidth() or 140) + 60, 10)
	drop:SetFrameStrata("DIALOG")
	UI.Skin(drop, C.bg, C.edge)
	drop:Hide()
	local state = { keys = {}, sel = 1 }
	box.suggest = state
	local rows = {}

	local function Paint()
		for i, b in ipairs(rows) do
			local key = state.keys[i]
			if key then
				local m = ns.Roster.members[key] or {}
				b.label:SetText(ns.Roster.DisplayName(key) .. (m.online and "" or " |cff808080(offline)|r"))
				b.label:SetTextColor(UI.ClassColor(m.classFile))
				b.sel:SetShown(i == state.sel)
				b:Show()
			else
				b:Hide()
			end
		end
		drop:SetHeight(#state.keys * 18 + 6)
		drop:SetShown(#state.keys > 0)
	end

	function state.Pick(i)
		local key = state.keys[i or state.sel]
		if not key then return false end
		state.keys = {}
		box.picking = true
		box:SetText(ns.Roster.DisplayName(key))
		box.picking = nil
		Paint()
		if box.onPick then box.onPick(key) end
		return true
	end
	function state.Update(text)
		local keys = UI.NameMatches(text, SUGGEST_ROWS)
		-- Nothing to suggest once the box holds exactly one guildmate's full name.
		if #keys == 1 and ns.Roster.DisplayName(keys[1]):lower() == tostring(text):lower() then keys = {} end
		state.keys, state.sel = keys, 1
		Paint()
	end
	function state.Move(delta)
		if #state.keys == 0 then return end
		state.sel = (state.sel - 1 + delta) % #state.keys + 1
		Paint()
	end
	function state.Hide() state.keys = {}; Paint() end

	for i = 1, SUGGEST_ROWS do
		local b = CreateFrame("Button", nil, drop)
		b:SetPoint("TOPLEFT", 3, -3 - (i - 1) * 18)
		b:SetPoint("RIGHT", drop, "RIGHT", -3, 0)
		b:SetHeight(18)
		b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.label:SetPoint("LEFT", 5, 0)
		b.sel = UI.Fill(b:CreateTexture(nil, "BACKGROUND"), C.hover)
		b.sel:SetAllPoints()
		local hl = UI.Fill(b:CreateTexture(nil, "HIGHLIGHT"), C.hover)
		hl:SetAllPoints()
		b:SetScript("OnClick", function() state.Pick(i) end)
		rows[i] = b
	end

	local onChange = box.onChange
	box.onChange = function(text, user)
		if onChange then onChange(text, user) end
		if not box.picking and box:HasFocus() then state.Update(text) end
	end
	if box.SetAltArrowKeyMode then box:SetAltArrowKeyMode(false) end
	box:SetScript("OnArrowPressed", function(_, key)
		if key == "DOWN" then state.Move(1) elseif key == "UP" then state.Move(-1) end
	end)
	box:SetScript("OnTabPressed", function() state.Pick() end)
	local onEnter = box.onEnter
	box.onEnter = function(text)
		if state.Pick() then return end
		if onEnter then onEnter(text) end
	end
	-- Leaving the box closes the list, a moment later so a click on a name still lands.
	box:HookScript("OnEditFocusLost", function() ns.After(0.2, function() if not box:HasFocus() then state.Hide() end end) end)
	box:HookScript("OnEscapePressed", function() state.Hide() end)
	return state
end

-- Open a whisper to a guildmate ("First Surname").
function UI.Whisper(key)
	local target = ns.Roster.DisplayName(key)
	if not target or target == "" then return end
	if ChatFrame_SendTell then
		ChatFrame_SendTell(target)
	elseif ChatFrame_OpenChat then
		ChatFrame_OpenChat("/w " .. target .. " ")
	end
	return target
end

-- Invite a guildmate to your group.
function UI.Invite(key)
	local target = ns.Roster.DisplayName(key)
	if not target or target == "" then return end
	local fn = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
	if fn then pcall(fn, target) end
	return target
end

function UI.ClassColor(token)
	local c = RAID_CLASS_COLORS and token and RAID_CLASS_COLORS[token]
	if c then return c.r, c.g, c.b end
	return 1, 1, 1
end

-- 1234567 -> "1,234,567"
function UI.Number(n)
	local s = tostring(math.floor(n or 0))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- Copper -> "12g 34s" (or "34s 5c" under a gold).
function UI.Money(copper)
	copper = math.floor(copper or 0)
	local g, s, c = math.floor(copper / 10000), math.floor(copper % 10000 / 100), copper % 100
	if g > 0 then return UI.Number(g) .. "g" .. (s > 0 and (" " .. s .. "s") or "") end
	if s > 0 then return s .. "s" .. (c > 0 and (" " .. c .. "c") or "") end
	return c .. "c"
end

-- "5m", "2h"
function UI.Ago(seconds)
	seconds = math.max(0, seconds or 0)
	if seconds < 60 then return "now" end
	if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
	return math.floor(seconds / 3600) .. "h"
end

---------------------------------------------------------------------------
-- Copy box: a scrolling, selectable text for reports.
---------------------------------------------------------------------------
local copy
function UI.ShowCopyBox(title, text)
	if not copy then
		copy = UI.Window("IwTCopyBox", 560, 400, "", "DIALOG")
		local scroll = CreateFrame("ScrollFrame", nil, copy, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 12, -42)
		scroll:SetPoint("BOTTOMRIGHT", -30, 12)
		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetAutoFocus(false)
		edit:SetFontObject(ChatFontNormal)
		edit:SetWidth(500)
		edit:SetScript("OnEscapePressed", function() copy:Hide() end)
		scroll:SetScrollChild(edit)
		copy.edit = edit
	end
	copy.title:SetText(title)
	copy.edit:SetText(text or "")
	copy:Show()
	copy.edit:SetFocus()
	copy.edit:HighlightText()
end
