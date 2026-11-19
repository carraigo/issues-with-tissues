-- The main window: four tabs along the bottom (Home, Members, Play, Guild life), each holding
-- pages behind a row of sub-tabs, and Settings behind the cog in the title bar. Features add a
-- page with ns.UI.AddPage("Members", "Roster", function(panel) ... end); the builder runs the
-- first time the page is shown. A tab with no pages is not shown. Also the minimap button, the
-- guild-frame button and a copy box for reports.

local _, ns = ...

local UI = ns.RegisterModule("UI", {})
ns.UI = UI

-- The tabs, in order. UI.tabs is the ones with pages, set when the window is made.
UI.groups = {}
for _, title in ipairs({ "Home", "Members", "Play", "Guild life" }) do
	UI.groups[#UI.groups + 1] = { title = title, pages = {} }
end
UI.tabs = {}
UI.settings = nil -- { title = "Settings", build, panel }
UI.WIDTH, UI.HEIGHT = 640, 492

-- The look: flat dark panels with a thin gold edge, as in the layout mock-up. Everything is
-- drawn with plain colour textures, so it doesn't depend on Blizzard templates that differ
-- between clients.
UI.COLORS = {
	bg = { 0.07, 0.06, 0.045, 0.97 },
	bar = { 0.115, 0.095, 0.07, 1 },
	card = { 0.14, 0.12, 0.09, 0.9 },
	edge = { 0.54, 0.43, 0.23, 1 },
	dim = { 0.29, 0.24, 0.15, 1 },
	button = { 0.165, 0.137, 0.10, 1 },
	primary = { 0.43, 0.11, 0.07, 1 },
	close = { 0.35, 0.11, 0.08, 1 },
	selected = { 0.23, 0.18, 0.10, 1 },
	hover = { 1, 0.85, 0.45, 0.10 },
	stripe = { 1, 1, 1, 0.025 },
	input = { 0.045, 0.04, 0.03, 1 },
	gold = { 0.96, 0.82, 0.48 },
	text = { 0.92, 0.90, 0.85 },
}
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
		local c = (on or b.style == "primary") and C.gold or C.text
		if b.style == "tab" and not on then c = { 0.78, 0.74, 0.66 } end
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
		local c = on and C.gold or { 0.72, 0.69, 0.63 }
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

local window

local function SavePosition(f)
	local point, _, relPoint, x, y = f:GetPoint()
	ns.db.window = { point = point, relPoint = relPoint, x = x, y = y, pages = ns.db.window and ns.db.window.pages }
end

local function Group(title)
	for _, g in ipairs(UI.groups) do if g.title == title then return g end end
end

-- A page under a tab. opts.order sorts pages (lower first; default: in the order added).
function UI.AddPage(groupTitle, title, build, opts)
	local g = Group(groupTitle)
	assert(g, "no tab " .. tostring(groupTitle))
	local page = { title = title, build = build, order = (opts and opts.order) or (#g.pages + 1) * 10, group = g }
	g.pages[#g.pages + 1] = page
	table.sort(g.pages, function(a, b) return a.order < b.order end)
	return page
end

-- The Settings page, opened by the cog (not a tab).
function UI.SetSettings(build)
	UI.settings = { title = "Settings", build = build }
end

-- A line at the right of a tab's sub-tab row (Play: your layer).
function UI.SetInfo(groupTitle, fn)
	local g = Group(groupTitle)
	if g then g.info = fn end
	UI.RefreshInfo()
end

function UI.RefreshInfo()
	for _, g in ipairs(UI.groups) do
		if g.infoText then g.infoText:SetText(g.info and g.info() or "") end
	end
end

local function Try(what, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then ns.ReportError(what .. ": " .. tostring(err)) end
	return ok
end

-- The tabs hang below the window, like the mock-up.
function UI.BuildTabButton(i)
	local tab = UI.tabs[i]
	local b = UI.Button(window, tab.title, 96, 28, "tab")
	b.label:SetFontObject(_G.GameFontHighlight or "GameFontHighlight")
	UI.SetSelected(b, false)
	local w = b.label.GetStringWidth and b.label:GetStringWidth() or 0
	b:SetWidth(math.max(90, (w or 0) + 36))
	local prev = UI.tabs[i - 1] and UI.tabs[i - 1].button
	if prev then
		b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
	else
		b:SetPoint("TOPLEFT", window, "BOTTOMLEFT", 12, 1)
	end
	b:SetScript("OnClick", function() UI.SelectTab(i) end)
	tab.button = b
	b:Show()
end

local function MarkTabs(current)
	for i, t in ipairs(UI.tabs) do
		if t.button then UI.SetSelected(t.button, i == current) end
	end
	if UI.cog then UI.SetSelected(UI.cog, current == 0) end
end

local function BuildPanel(item, parent, top)
	local p = CreateFrame("Frame", nil, parent)
	p:SetPoint("TOPLEFT", 0, top or 0)
	p:SetPoint("BOTTOMRIGHT", 0, 0)
	item.panel = p
	local ok, err = pcall(item.build, p)
	if not ok then ns.ReportError("page " .. item.title .. ": " .. tostring(err)) end
	return p
end

local function HideAll()
	for _, g in ipairs(UI.groups) do if g.frame then g.frame:Hide() end end
	if UI.settings and UI.settings.panel then UI.settings.panel:Hide() end
end

-- The frame for a tab: its sub-tab row (when it has more than one page) and its pages.
local function GroupFrame(g)
	if g.frame then return g.frame end
	local f = CreateFrame("Frame", nil, window)
	f:SetPoint("TOPLEFT", 12, -42)
	f:SetPoint("BOTTOMRIGHT", -12, 12)
	g.frame = f
	g.top = 0
	if #g.pages > 1 then
		local prev
		for j, page in ipairs(g.pages) do
			local b = UI.SubTab(f, page.title)
			if prev then b:SetPoint("LEFT", prev, "RIGHT", 2, 0) else b:SetPoint("TOPLEFT", 0, 0) end
			b:SetScript("OnClick", function() UI.SelectPage(g, j) end)
			page.subButton = b
			prev = b
		end
		local line = UI.Fill(f:CreateTexture(nil, "BORDER"), C.dim)
		line:SetPoint("TOPLEFT", 0, -24)
		line:SetPoint("TOPRIGHT", 0, -24)
		line:SetHeight(1)
		g.top = -34
	end
	g.infoText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	g.infoText:SetPoint("TOPRIGHT", -4, -6)
	return f
end

function UI.SelectPage(g, j)
	local page = g.pages[j]
	if not page then return end
	for k, other in ipairs(g.pages) do
		if other.panel then other.panel:SetShown(k == j) end
		if other.subButton then other.subButton:SetSelectedTab(k == j) end
	end
	if not page.panel then BuildPanel(page, g.frame, g.top) end
	page.panel:Show()
	g.current = j
	ns.db.window.pages = ns.db.window.pages or {}
	ns.db.window.pages[g.title] = page.title
	UI.RefreshInfo()
end

-- Show tab i of UI.tabs, on the page it was last left on.
function UI.SelectTab(i)
	if not window or not UI.tabs[i] then return end
	local g = UI.tabs[i]
	HideAll()
	GroupFrame(g):Show()
	local want = ns.db.window.pages and ns.db.window.pages[g.title]
	local j = g.current or 1
	if not g.current and want then
		for k, page in ipairs(g.pages) do if page.title == want then j = k end end
	end
	UI.SelectPage(g, j)
	MarkTabs(i)
	UI.current = i
end

function UI.ShowSettings()
	if not window or not UI.settings then return end
	HideAll()
	local s = UI.settings
	if not s.panel then
		local holder = CreateFrame("Frame", nil, window)
		holder:SetPoint("TOPLEFT", 12, -42)
		holder:SetPoint("BOTTOMRIGHT", -12, 12)
		BuildPanel(s, holder, 0)
		s.holder = holder
	end
	s.holder:Show()
	s.panel:Show()
	MarkTabs(0)
end

function UI.Create()
	if window then return window end
	local f = UI.Window("IwTMainWindow", UI.WIDTH, UI.HEIGHT, "Issues with Tissues")
	f:ClearAllPoints()
	local pos = ns.db.window
	if pos and pos.point then
		f:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
	else
		f:SetPoint("CENTER")
	end
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition(self) end)
	window = f
	UI.window = f
	-- The cog: Settings.
	local cog = UI.Button(f, nil, 22, 20)
	cog:SetPoint("RIGHT", f.close, "LEFT", -4, 0)
	local icon = cog:CreateTexture(nil, "ARTWORK")
	icon:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetSize(14, 14)
	icon:SetPoint("CENTER")
	cog:SetScript("OnClick", function() UI.ShowSettings() end)
	cog:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Settings")
		GameTooltip:Show()
	end)
	cog:SetScript("OnLeave", function() GameTooltip:Hide() end)
	UI.cog = cog
	UI.tabs = {}
	for _, g in ipairs(UI.groups) do
		if #g.pages > 0 then UI.tabs[#UI.tabs + 1] = g end
	end
	for i = 1, #UI.tabs do Try("tab button " .. UI.tabs[i].title, UI.BuildTabButton, i) end
	return f
end

function UI.Toggle()
	local f = UI.Create()
	if f:IsShown() then
		f:Hide()
	else
		f:Show()
		UI.SelectTab(UI.current or 1)
	end
end

-- Open the window on a tab ("Members"), a page ("Roster") or "Settings".
function UI.Open(title)
	local f = UI.Create()
	f:Show()
	if title == "Settings" then return UI.ShowSettings() end
	for i, g in ipairs(UI.tabs) do
		if g.title == title then return UI.SelectTab(i) end
		for j, page in ipairs(g.pages) do
			if page.title == title then
				UI.SelectTab(i)
				return UI.SelectPage(g, j)
			end
		end
	end
	UI.SelectTab(UI.current or 1)
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

---------------------------------------------------------------------------
-- Minimap button (no library: a round button that can be dragged around the edge).
---------------------------------------------------------------------------
local mini
local function PlaceMini()
	local angle = math.rad(ns.db.minimapAngle or 220)
	mini:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

function UI.CreateMinimapButton()
	if mini or not Minimap then return end
	mini = CreateFrame("Button", "IwTMinimapButton", Minimap)
	mini:SetSize(31, 31)
	mini:SetFrameStrata("MEDIUM")
	mini:SetFrameLevel(8)
	mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local icon = mini:CreateTexture(nil, "BACKGROUND")
	icon:SetTexture("Interface\\Icons\\INV_Misc_Bandage_15")
	icon:SetSize(20, 20)
	icon:SetPoint("CENTER", 0, 1)
	local border = mini:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	mini:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	mini:RegisterForDrag("LeftButton")
	mini:SetScript("OnClick", function(_, button)
		if button == "RightButton" then UI.Open("Settings") else UI.Toggle() end
	end)
	mini:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			ns.db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
			PlaceMini()
		end)
	end)
	mini:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	mini:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Issues with Tissues")
		GameTooltip:AddLine("Left-click: open", 1, 1, 1)
		GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
		GameTooltip:Show()
	end)
	mini:SetScript("OnLeave", function() GameTooltip:Hide() end)
	PlaceMini()
end

function UI.UpdateMinimapButton()
	if ns.db.settings.minimap then
		UI.CreateMinimapButton()
		if mini then mini:Show() end
	elseif mini then
		mini:Hide()
	end
end

---------------------------------------------------------------------------
-- Guild-frame button: whichever guild window this client has (GuildFrame or
-- CommunitiesFrame), loaded on demand by the game.
---------------------------------------------------------------------------
local guildButton
function UI.AttachGuildButton()
	if guildButton then return end
	local host = _G.CommunitiesFrame or _G.GuildFrame
	if not host then return end
	guildButton = UI.Button(host, "Tissues", 70, 22)
	guildButton:SetPoint("TOPRIGHT", host, "TOPRIGHT", -30, -28)
	guildButton:SetScript("OnClick", function() UI.Toggle() end)
	UI.UpdateGuildButton()
end

function UI.UpdateGuildButton()
	if guildButton then guildButton:SetShown(ns.db.settings.guildButton) end
end

ns.On("ADDON_LOADED", function(_, name)
	if name == "Blizzard_Communities" or name == "Blizzard_GuildUI" then UI.AttachGuildButton() end
end)

function UI:OnLogin()
	UI.UpdateMinimapButton()
	UI.AttachGuildButton()
end
