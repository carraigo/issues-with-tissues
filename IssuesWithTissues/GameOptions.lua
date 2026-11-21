-- A page in the game's own Options (Esc, Options, AddOns), as players expect from an addon. It
-- points to the addon's Settings, which live in the addon's window with everything else.
-- Uses the Settings API where the client has it, and the older Interface Options otherwise.

local _, ns = ...

local GameOptions = ns.RegisterModule("GameOptions", {})
ns.GameOptions = GameOptions

local function CloseGameMenus()
	for _, name in ipairs({ "SettingsPanel", "InterfaceOptionsFrame", "GameMenuFrame" }) do
		local f = _G[name]
		if f and f.IsShown and f:IsShown() and HideUIPanel then pcall(HideUIPanel, f) end
	end
end

function GameOptions.Build()
	local panel = CreateFrame("Frame")
	panel.name = "Issues with Tissues"
	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Issues with Tissues")
	local version = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	version:SetPoint("LEFT", title, "RIGHT", 8, -1)
	version:SetText(ns.VERSION)
	local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
	text:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	text:SetJustifyH("LEFT")
	text:SetText("The guild's roster, chat, crafters, layer hopping, polls and donations in one window. "
		.. "Its settings, themes included, are in the window behind the cog.")
	local function Button(label, x, fn)
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetSize(170, 24)
		b:SetPoint("TOPLEFT", text, "BOTTOMLEFT", x, -16)
		b:SetText(label)
		b:SetScript("OnClick", function() CloseGameMenus(); fn() end)
		return b
	end
	Button("Open settings", 0, function() ns.UI.Open("Settings") end)
	Button("Open the window", 180, function() ns.UI.Open("Home") end)
	Button("What's new", 360, function() ns.Welcome.ShowWhatsNew(nil) end)
	GameOptions.panel = panel
	return panel
end

function GameOptions.Register()
	local panel = GameOptions.Build()
	if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
		local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
		Settings.RegisterAddOnCategory(category)
		GameOptions.category = category
		GameOptions.how = "Settings"
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
		GameOptions.how = "InterfaceOptions"
	else
		GameOptions.how = "none"
	end
	ns.Log("options: game Options page via %s", GameOptions.how)
end

function GameOptions:OnLogin()
	local ok, err = pcall(GameOptions.Register)
	if not ok then ns.Log("options: couldn't add the game Options page: %s", tostring(err)) end
end
