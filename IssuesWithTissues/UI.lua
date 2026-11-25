-- The main window: five tabs along the bottom (Home, Chat, Members, Crafting, Guild life), each holding
-- pages behind a row of sub-tabs, and Settings behind the cog in the title bar. Features add a
-- page with ns.UI.AddPage("Members", "Roster", function(panel) ... end); the builder runs the
-- first time the page is shown. A tab with no pages is not shown. Also the window's sounds,
-- size, combat behaviour and Ctrl+F. The building blocks (buttons, lists, inputs, the copy box)
-- are in Widgets.lua; the minimap and guild-window buttons in Buttons.lua.

local _, ns = ...

local UI = ns.RegisterModule("UI", {})
ns.UI = UI

-- The tabs, in order. UI.tabs is the ones with pages, set when the window is made.
UI.groups = {}
for _, title in ipairs({ "Home", "Chat", "Members", "Crafting", "Quests", "Guild life" }) do
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
	tabtext = { 0.78, 0.74, 0.66 }, -- tabs not selected
	subtext = { 0.72, 0.69, 0.63 }, -- sub-tabs not selected
	stamp = { 0.54, 0.51, 0.44 },   -- chat times
	sys = { 0.66, 0.66, 0.66 },     -- chat online/offline lines
}
-- Themes.lua can swap these for another theme's at load.
local C = UI.COLORS

local window

local function SavePosition(f)
	local point, _, relPoint, x, y = f:GetPoint()
	ns.db.window = { point = point, relPoint = relPoint, x = x, y = y, pages = ns.db.window and ns.db.window.pages }
end

local function Group(title)
	for _, g in ipairs(UI.groups) do if g.title == title then return g end end
end

-- A page under a tab. opts.order sorts pages (lower first; default: in the order added).
-- opts.visible: a function; while it returns false the page's sub-tab is hidden (officer pages).
function UI.AddPage(groupTitle, title, build, opts)
	local g = Group(groupTitle)
	assert(g, "no tab " .. tostring(groupTitle))
	local page = { title = title, build = build, order = (opts and opts.order) or (#g.pages + 1) * 10, group = g,
		visible = opts and opts.visible }
	g.pages[#g.pages + 1] = page
	table.sort(g.pages, function(a, b) return a.order < b.order end)
	return page
end

-- The Settings page, opened by the cog (not a tab).
function UI.SetSettings(build)
	UI.settings = { title = "Settings", build = build }
end

-- A line at the right of a tab's sub-tab row.
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
	b:SetScript("OnClick", function() UI.Sound("tab"); UI.SelectTab(i) end)
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
		UI.LayoutSubTabs(g)
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

-- Can this page be shown now?
function UI.PageVisible(page)
	if not page.visible then return true end
	local ok, yes = pcall(page.visible)
	return ok and yes and true or false
end

-- Show the sub-tabs of visible pages only, side by side.
function UI.LayoutSubTabs(g)
	local prev
	for _, page in ipairs(g.pages) do
		local b = page.subButton
		if b then
			local show = UI.PageVisible(page)
			b:SetShown(show)
			if show then
				b:ClearAllPoints()
				if prev then b:SetPoint("LEFT", prev, "RIGHT", 2, 0) else b:SetPoint("TOPLEFT", 0, 0) end
				prev = b
			end
		end
	end
end

-- Ranks changed (or loaded): hide or show officer pages, and leave one that just went hidden.
function UI.RefreshPages()
	for _, g in ipairs(UI.groups) do
		if g.frame then
			UI.LayoutSubTabs(g)
			local cur = g.current and g.pages[g.current]
			if cur and not UI.PageVisible(cur) and g.frame:IsShown() then UI.SelectPage(g, 1) end
		end
	end
end
ns.Listen("ROSTER_UPDATED", function() UI.RefreshPages() end)

function UI.SelectPage(g, j)
	local page = g.pages[j]
	if not page then return end
	if not UI.PageVisible(page) then j, page = 1, g.pages[1] end
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
	if UI.ThemeTree then UI.ThemeTree(window) end
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
		for k, page in ipairs(g.pages) do if page.title == want and UI.PageVisible(page) then j = k end end
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
	if UI.ThemeTree then UI.ThemeTree(window) end
end

---------------------------------------------------------------------------
-- Feel (0.9.0): sounds, size, combat, keyboard
---------------------------------------------------------------------------
UI.SOUNDS = { open = "IG_CHARACTER_INFO_OPEN", close = "IG_CHARACTER_INFO_CLOSE", tab = "IG_CHARACTER_INFO_TAB" }
UI.SOUND_IDS = { open = 839, close = 840, tab = 841 } -- the same sounds, where SOUNDKIT is missing

function UI.Sound(kind)
	if UI.quiet or not ns.db.settings.windowSounds or not PlaySound then return false end
	local id = (SOUNDKIT and SOUNDKIT[UI.SOUNDS[kind]]) or UI.SOUND_IDS[kind]
	if not id then return false end
	pcall(PlaySound, id)
	UI.lastSound = kind
	return true
end

UI.SCALE_MIN, UI.SCALE_MAX = ns.SETTING.scale.min, ns.SETTING.scale.max
function UI.SetScale(v)
	v = tonumber(v) or 1
	v = math.floor(math.max(UI.SCALE_MIN, math.min(UI.SCALE_MAX, v)) * 20 + 0.5) / 20 -- steps of 5%
	ns.db.settings.scale = v
	if window then window:SetScale(v) end
	return v
end

-- Combat: with the option on, the window steps aside when combat starts and comes back after.
function UI.OnCombat(starting)
	if starting then
		if ns.db.settings.hideInCombat and window and window:IsShown() then
			UI.quiet = true; window:Hide(); UI.quiet = false
			UI.hiddenForCombat = true
		end
	else
		if UI.keyboardPending then UI.EnableKeys() end
		if UI.hiddenForCombat then
			UI.hiddenForCombat = false
			if window and not window:IsShown() then UI.quiet = true; window:Show(); UI.quiet = false end
		end
	end
end
ns.On("PLAYER_REGEN_DISABLED", function() UI.OnCombat(true) end)
ns.On("PLAYER_REGEN_ENABLED", function() UI.OnCombat(false) end)

-- A page with a search box says so (UI.SetSearch(panel, box)): Ctrl+F jumps to it.
function UI.SetSearch(panel, box)
	panel.searchBox = box
	box.searchDelay = ns.TIMERS.search
end

function UI.FocusSearch()
	local g = UI.tabs[UI.current or 0]
	if not (window and window:IsShown() and g and g.frame and g.frame:IsShown()) then return false end
	local page = g.pages[g.current or 1]
	local box = page and page.panel and page.panel.searchBox
	if type(box) ~= "table" then return false end
	box:SetFocus()
	if box.HighlightText then box:HighlightText() end
	return true
end

-- The window hears keys only to spot Ctrl+F. Every key still goes on to the game (propagation
-- is set once, outside combat, where the game allows it, and never changed after).
function UI.EnableKeys()
	if not window or not window.EnableKeyboard or not window.SetPropagateKeyboardInput then return false end
	if InCombatLockdown and InCombatLockdown() then UI.keyboardPending = true; return false end
	UI.keyboardPending = false
	local ok = pcall(window.SetPropagateKeyboardInput, window, true)
	if not ok then return false end
	window:EnableKeyboard(true)
	window:SetScript("OnKeyDown", function(_, key)
		if key == "F" and IsControlKeyDown and IsControlKeyDown() then UI.FocusSearch() end
	end)
	UI.keys = true
	return true
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
	f:HookScript("OnShow", function() UI.Sound("open") end)
	f:HookScript("OnHide", function() UI.Sound("close") end)
	window = f
	UI.window = f
	UI.SetScale(ns.db.settings.scale)
	UI.EnableKeys()
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
	-- The game's own guild window, for what only it can do (invites, promotions, notes).
	local blizz = UI.Button(f, nil, 22, 20)
	blizz:SetPoint("RIGHT", cog, "LEFT", -4, 0)
	local bicon = blizz:CreateTexture(nil, "ARTWORK")
	bicon:SetTexture("Interface\\Icons\\INV_Misc_Note_02")
	bicon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	bicon:SetSize(14, 14)
	bicon:SetPoint("CENTER")
	blizz:SetScript("OnClick", function() UI.OpenGameGuildWindow() end)
	blizz:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Game's guild window")
		GameTooltip:AddLine("Invites, promotions and notes", 1, 1, 1)
		GameTooltip:Show()
	end)
	blizz:SetScript("OnLeave", function() GameTooltip:Hide() end)
	UI.gameGuildButton = blizz
	UI.tabs = {}
	for _, g in ipairs(UI.groups) do
		if #g.pages > 0 then UI.tabs[#UI.tabs + 1] = g end
	end
	for i = 1, #UI.tabs do Try("tab button " .. UI.tabs[i].title, UI.BuildTabButton, i) end
	return f
end

-- Opening (minimap, key, /iwt): the tab chosen in Settings, or the last one used.
UI.OPEN_ON = ns.SETTING.openOn.choices
function UI.Toggle()
	local f = UI.Create()
	if f:IsShown() then
		f:Hide()
		return
	end
	local on = ns.db.settings.openOn
	if on == "Home" or on == "Chat" then return UI.Open(on) end
	f:Show()
	UI.SelectTab(UI.current or 1)
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
