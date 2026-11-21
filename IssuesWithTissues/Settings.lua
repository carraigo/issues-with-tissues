-- The Settings tab: a toggle per option, the theme, the officer rank, and the tools.
-- Later features add their own toggles with ns.Settings.AddToggle(key, label, onChange).

local _, ns = ...

local Settings = ns.RegisterModule("Settings", {})
ns.Settings = Settings

Settings.toggles = {
	{ key = "minimap", label = "Show the minimap button", onChange = function() ns.UI.UpdateMinimapButton() end },
	{ key = "guildButton", label = "Show the button on the guild window", onChange = function() ns.UI.UpdateGuildButton() end },
	{ key = "sounds", label = "Play alert sounds" },
	{ key = "debug", label = "Print addon errors in chat" },
}

function Settings.AddToggle(key, label, onChange)
	Settings.toggles[#Settings.toggles + 1] = { key = key, label = label, onChange = onChange }
end

-- Officers are rankIndex 0..officerMaxRank. Default 1 = Guild Master and Officer.
function Settings.OfficerRankText()
	local names = ns.Roster.RankNames()
	local max = ns.db.settings.officerMaxRank
	local list = {}
	for i = 1, max + 1 do list[#list + 1] = names[i] or ("rank " .. i) end
	return table.concat(list, ", ")
end

local function Build(panel)
	local y = -4
	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 4, y)
	title:SetText("Settings")
	y = y - 30
	for _, t in ipairs(Settings.toggles) do
		local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		cb:SetPoint("TOPLEFT", 0, y)
		local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
		label:SetText(t.label)
		cb:SetChecked(ns.db.settings[t.key] and true or false)
		cb:SetScript("OnClick", function(self)
			ns.db.settings[t.key] = self:GetChecked() and true or false
			if t.onChange then t.onChange(ns.db.settings[t.key]) end
		end)
		y = y - 28
	end

	-- Theme: one button per theme; the change shows after a reload.
	y = y - 8
	local themeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	themeLabel:SetPoint("TOPLEFT", 4, y)
	themeLabel:SetText("Theme")
	y = y - 20
	local themeNote = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	local reload = ns.UI.Button(panel, "Reload now", 100, 22, "primary")
	local buttons = {}
	local function MarkThemes()
		for id, b in pairs(buttons) do ns.UI.SetSelected(b, id == ns.db.settings.theme) end
		local changed = ns.db.settings.theme ~= ns.UI.theme.id
		themeNote:SetText(changed and "Reload to switch to the new theme." or "")
		reload:SetShown(changed)
	end
	local tx = 0
	for _, t in ipairs(ns.UI.THEMES) do
		local b = ns.UI.Button(panel, t.name, 112, 22)
		b:SetPoint("TOPLEFT", tx, y)
		b:SetScript("OnClick", function()
			ns.db.settings.theme = t.id
			MarkThemes()
		end)
		buttons[t.id] = b
		tx = tx + 116
	end
	y = y - 28
	themeNote:SetPoint("TOPLEFT", 4, y - 4)
	reload:SetPoint("TOPLEFT", 260, y)
	reload:SetScript("OnClick", function() if ReloadUI then ReloadUI() end end)
	MarkThemes()
	y = y - 28

	y = y - 10
	local officers = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	officers:SetPoint("TOPLEFT", 4, y)
	officers:SetJustifyH("LEFT")
	panel:SetScript("OnShow", function()
		officers:SetText("Officer ranks (can write shared guild data): " .. Settings.OfficerRankText())
	end)
	officers:SetText("Officer ranks (can write shared guild data): " .. Settings.OfficerRankText())
	y = y - 36

	local tools = {
		{ "Bug report", function() ns.HandleSlash("bug") end },
		{ "Profiler report", function() ns.HandleSlash("perf") end },
		{ "Self-test", function() ns.HandleSlash("selftest") end },
		{ "Diagnostics report", function() ns.HandleSlash("report") end },
	}
	local x = 0
	for _, t in ipairs(tools) do
		local b = ns.UI.Button(panel)
		b:SetSize(130, 24)
		b:SetPoint("TOPLEFT", x, y)
		b:SetText(t[1])
		b:SetScript("OnClick", t[2])
		x = x + 140
	end

	local version = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	version:SetPoint("BOTTOMRIGHT", -4, 4)
	version:SetText("Issues with Tissues " .. ns.VERSION)
end

ns.UI.SetSettings(Build)

ns.RegisterCommand("settings", "open the settings", function() ns.UI.Open("Settings") end)
