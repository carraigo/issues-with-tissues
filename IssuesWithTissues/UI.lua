-- The main window: a movable frame with tabs along the bottom. Features add a tab with
-- ns.UI.AddTab("Roster", function(parent) ... end); the builder runs the first time the tab
-- is shown. Also the minimap button, the guild-frame button and a copy box for reports.

local _, ns = ...

local UI = ns.RegisterModule("UI", {})
ns.UI = UI

UI.tabs = {}
UI.WIDTH, UI.HEIGHT = 640, 460
UI.TAB_TEMPLATES = { "PanelTabButtonTemplate", "CharacterFrameTabButtonTemplate", "UIPanelButtonTemplate" }

local window

local function SavePosition(f)
	local point, _, relPoint, x, y = f:GetPoint()
	ns.db.window = { point = point, relPoint = relPoint, x = x, y = y }
end

function UI.AddTab(title, build)
	local tab = { title = title, build = build }
	UI.tabs[#UI.tabs + 1] = tab
	if window then UI.BuildTabButton(#UI.tabs); UI.CountTabs() end
	return tab
end

-- Each step is guarded: a template that behaves differently on this client must not stop the
-- other tabs from being drawn (and the error goes in /iwt bug, which a Blizzard file's error
-- would otherwise miss).
local function Try(what, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then ns.ReportError("tab button " .. what .. ": " .. tostring(err)) end
	return ok
end

function UI.BuildTabButton(i)
	local tab = UI.tabs[i]
	-- The tab template's name differs between clients: try each, newest first.
	local b
	for _, template in ipairs(UI.TAB_TEMPLATES) do
		local ok, made = pcall(CreateFrame, "Button", "IwTMainWindowTab" .. i, window, template)
		if ok and made then
			b = made
			break
		end
	end
	if not b then
		ns.ReportError("tab button " .. tab.title .. ": no template worked")
		return
	end
	tab.button = b
	Try(tab.title .. " SetID", b.SetID, b, i)
	Try(tab.title .. " SetText", b.SetText, b, tab.title)
	b:ClearAllPoints()
	local prev = UI.tabs[i - 1] and UI.tabs[i - 1].button
	if prev then
		b:SetPoint("LEFT", prev, "RIGHT", -14, 0)
	else
		b:SetPoint("TOPLEFT", window, "BOTTOMLEFT", 8, 2)
	end
	-- Size from the text instead of PanelTemplates_TabResize, whose arguments vary by client.
	Try(tab.title .. " size", function()
		local fs = b.GetFontString and b:GetFontString()
		local w = fs and fs.GetStringWidth and fs:GetStringWidth() or 0
		b:SetWidth(math.max(80, w + 40))
	end)
	b:SetScript("OnClick", function() UI.SelectTab(i) end)
	b:Show()
end

-- Tell Blizzard's tab code about the buttons once they all exist: it walks every tab up to
-- the count, so counting a tab before its button is made fails ("thisTab" is nil).
function UI.CountTabs()
	window.Tabs = {}
	for i, t in ipairs(UI.tabs) do window.Tabs[i] = t.button end
	window.numTabs = #UI.tabs
	if PanelTemplates_SetNumTabs then Try("count", PanelTemplates_SetNumTabs, window, #UI.tabs) end
end

function UI.SelectTab(i)
	if not window or not UI.tabs[i] then return end
	for j, tab in ipairs(UI.tabs) do
		if tab.panel then tab.panel:SetShown(j == i) end
	end
	local tab = UI.tabs[i]
	if not tab.panel then
		local p = CreateFrame("Frame", nil, window)
		p:SetPoint("TOPLEFT", 12, -30)
		p:SetPoint("BOTTOMRIGHT", -12, 12)
		tab.panel = p
		local ok, err = pcall(tab.build, p)
		if not ok then ns.ReportError("tab " .. tab.title .. ": " .. tostring(err)) end
	end
	tab.panel:Show()
	if tab.OnShow then tab.OnShow(tab.panel) end
	if PanelTemplates_SetTab then Try("select", PanelTemplates_SetTab, window, i) end
	UI.current = i
end

function UI.Create()
	if window then return window end
	local f = CreateFrame("Frame", "IwTMainWindow", UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(UI.WIDTH, UI.HEIGHT)
	local pos = ns.db.window
	if pos and pos.point then
		f:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
	else
		f:SetPoint("CENTER")
	end
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition(self) end)
	f:SetClampedToScreen(true)
	f:SetFrameStrata("HIGH")
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.title:SetPoint("TOP", 0, -5)
	f.title:SetText("Issues with Tissues")
	f:Hide()
	tinsert(UISpecialFrames, "IwTMainWindow") -- Escape closes it
	window = f
	UI.window = f
	for i = 1, #UI.tabs do Try(UI.tabs[i].title, UI.BuildTabButton, i) end
	UI.CountTabs()
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

function UI.Open(title)
	local f = UI.Create()
	f:Show()
	for i, tab in ipairs(UI.tabs) do
		if tab.title == title then return UI.SelectTab(i) end
	end
	UI.SelectTab(UI.current or 1)
end

---------------------------------------------------------------------------
-- Copy box: a scrolling, selectable text for reports.
---------------------------------------------------------------------------
local copy
function UI.ShowCopyBox(title, text)
	if not copy then
		copy = CreateFrame("Frame", "IwTCopyBox", UIParent, "BasicFrameTemplateWithInset")
		copy:SetSize(560, 400)
		copy:SetPoint("CENTER")
		copy:SetFrameStrata("DIALOG")
		copy:SetMovable(true)
		copy:EnableMouse(true)
		copy:RegisterForDrag("LeftButton")
		copy:SetScript("OnDragStart", copy.StartMoving)
		copy:SetScript("OnDragStop", copy.StopMovingOrSizing)
		copy.title = copy:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		copy.title:SetPoint("TOP", 0, -5)
		local scroll = CreateFrame("ScrollFrame", nil, copy, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 12, -30)
		scroll:SetPoint("BOTTOMRIGHT", -30, 12)
		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetAutoFocus(false)
		edit:SetFontObject(ChatFontNormal)
		edit:SetWidth(500)
		edit:SetScript("OnEscapePressed", function() copy:Hide() end)
		scroll:SetScrollChild(edit)
		copy.edit = edit
		tinsert(UISpecialFrames, "IwTCopyBox")
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
	guildButton = CreateFrame("Button", "IwTGuildFrameButton", host, "UIPanelButtonTemplate")
	guildButton:SetSize(70, 22)
	guildButton:SetText("Tissues")
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
