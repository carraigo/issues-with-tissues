-- The Settings tab: a toggle per option, the officer rank, and the tools.
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
	}
	local x = 0
	for _, t in ipairs(tools) do
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
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

ns.UI.AddTab("Settings", Build)

ns.RegisterCommand("settings", "open the settings", function() ns.UI.Open("Settings") end)
