-- The Settings tab, built from the declared settings (ns.SETTINGS in Core.lua): tick boxes in two
-- columns, then each drop-down, slider and row of choices in the order declared, the officer
-- ranks and the tools. A feature reacts to its setting with Settings.OnChange(key, fn).

local _, ns = ...

local Settings = ns.RegisterModule("Settings", {})
ns.Settings = Settings

local listeners = {}
function Settings.OnChange(key, fn)
	listeners[key] = listeners[key] or {}
	table.insert(listeners[key], fn)
end

-- Change a setting the way the page does: checked against its declaration, saved, then the
-- feature told. Returns the value kept (nil when the key or value isn't allowed).
function Settings.Set(key, value)
	local def = ns.SETTING[key]
	if not def then return nil end
	if def.kind == "toggle" then
		value = value and true or false
	elseif def.kind == "range" then
		value = tonumber(value)
		if not value then return nil end
		value = math.max(def.min, math.min(def.max, value))
		value = math.floor(value / def.step + 0.5) * def.step
		value = math.floor(value * 1000 + 0.5) / 1000
	elseif def.kind == "choice" or def.kind == "dropdown" then
		local choices = type(def.choices) == "function" and def.choices() or def.choices
		local ok = false
		for _, c in ipairs(choices) do if c.id == value then ok = true end end
		if not ok then return nil end
	end
	ns.db.settings[key] = value
	for _, fn in ipairs(listeners[key] or {}) do fn(value) end
	return value
end

Settings.OnChange("minimap", function() ns.UI.UpdateMinimapButton() end)
Settings.OnChange("guildButton", function() ns.UI.UpdateGuildButton() end)
Settings.OnChange("scale", function(v) ns.UI.SetScale(v) end)

-- Officers are rankIndex 0..officerMaxRank. Default 1 = Guild Master and Officer.
function Settings.OfficerRankText()
	local names = ns.Roster.RankNames()
	local max = ns.db.settings.officerMaxRank
	local list = {}
	for i = 1, max + 1 do list[#list + 1] = names[i] or ("rank " .. i) end
	return table.concat(list, ", ")
end

---------------------------------------------------------------------------
-- One builder per kind: (panel, def, y) -> the height used.
---------------------------------------------------------------------------
Settings.checks = {}
local Kinds = {}

function Kinds.dropdown(panel, def, y)
	local label = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("TOPLEFT", 4, y)
	label:SetText(def.label)
	y = y - 20
	local note = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	local reload = ns.UI.Button(panel, "Reload now", 100, 22, "primary")
	-- The chosen value on a button; clicking it lists them all beneath.
	local pick = ns.UI.Button(panel, "", 200, 22)
	pick:SetPoint("TOPLEFT", 0, y)
	local choices = def.choices()
	local list = CreateFrame("Frame", nil, panel)
	list:SetFrameStrata("DIALOG")
	list:EnableMouse(true)
	ns.UI.Skin(list, ns.UI.COLORS.bg, ns.UI.COLORS.edge)
	list:SetPoint("TOPLEFT", pick, "BOTTOMLEFT", 0, -2)
	list:SetSize(200, 6 + #choices * 24)
	list:Hide()
	local buttons = {}
	local active = def.key == "theme" and ns.UI.theme.id or ns.db.settings[def.key] -- what's in use now
	local function Mark()
		local id = ns.db.settings[def.key]
		local name = id
		for cid, b in pairs(buttons) do ns.UI.SetSelected(b, cid == id) end
		for _, c in ipairs(choices) do if c.id == id then name = c.name end end
		pick:SetText(tostring(name) .. "  v")
		local changed = def.reload and id ~= active
		note:SetText(changed and "Reload to switch." or "")
		reload:SetShown(changed and true or false)
	end
	for i, c in ipairs(choices) do
		local b = ns.UI.Button(list, c.name, 192, 22)
		b:SetPoint("TOPLEFT", 4, -3 - (i - 1) * 24)
		b:SetScript("OnClick", function()
			Settings.Set(def.key, c.id)
			list:Hide()
			Mark()
		end)
		buttons[c.id] = b
	end
	pick:SetScript("OnClick", function() list:SetShown(not list:IsShown()) end)
	panel:HookScript("OnHide", function() list:Hide() end)
	note:SetPoint("LEFT", pick, "RIGHT", 12, 0)
	reload:SetPoint("LEFT", pick, "RIGHT", 230, 0)
	reload:SetScript("OnClick", function() if ReloadUI then ReloadUI() end end)
	Mark()
	if def.key == "theme" then Settings.themeButtons, Settings.themePick, Settings.themeList = buttons, pick, list end
	return 48
end

-- A slider in percent, applied when it is let go (the window doesn't resize under the mouse).
function Kinds.range(panel, def, y)
	local label = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("TOPLEFT", 4, y)
	label:SetText(def.label)
	local slider = CreateFrame("Slider", nil, panel)
	slider:SetPoint("LEFT", label, "RIGHT", 16, 0)
	slider:SetSize(220, 16)
	slider:SetOrientation("HORIZONTAL")
	slider:SetMinMaxValues(def.min * 100, def.max * 100)
	slider:SetValueStep(def.step * 100)
	if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
	local track = ns.UI.Fill(slider:CreateTexture(nil, "BACKGROUND"), ns.UI.COLORS.dim)
	track:SetPoint("LEFT"); track:SetPoint("RIGHT"); track:SetHeight(4)
	local thumb = ns.UI.Fill(slider:CreateTexture(nil, "OVERLAY"), ns.UI.COLORS.edge)
	thumb:SetSize(10, 16)
	slider:SetThumbTexture(thumb)
	local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("LEFT", slider, "RIGHT", 10, 0)
	local reset = ns.UI.Button(panel, math.floor(def.default * 100 + 0.5) .. "%", 50, 20)
	reset:SetPoint("LEFT", text, "RIGHT", 10, 0)
	local function Pct(v) return math.floor(v * 100 + 0.5) .. "%" end
	local function Apply(v)
		local kept = Settings.Set(def.key, v / 100)
		if kept then text:SetText(Pct(kept)) end
	end
	slider:SetScript("OnValueChanged", function(_, v)
		text:SetText(Pct(math.floor(v / (def.step * 100) + 0.5) * def.step))
		if not slider.dragging then Apply(v) end
	end)
	slider:SetScript("OnMouseDown", function() slider.dragging = true end)
	slider:SetScript("OnMouseUp", function() slider.dragging = false; Apply(slider:GetValue()) end)
	reset:SetScript("OnClick", function() slider:SetValue(def.default * 100); Apply(def.default * 100) end)
	slider:SetValue((ns.db.settings[def.key] or def.default) * 100)
	text:SetText(Pct(ns.db.settings[def.key] or def.default))
	if def.key == "scale" then Settings.scaleSlider = slider end
	return 30
end

function Kinds.choice(panel, def, y)
	local label = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("TOPLEFT", 4, y - 4)
	label:SetText(def.label)
	local buttons = {}
	local function Mark()
		for id, b in pairs(buttons) do ns.UI.SetSelected(b, id == ns.db.settings[def.key]) end
	end
	local x = 150
	for _, c in ipairs(def.choices) do
		local b = ns.UI.Button(panel, c.name, 90, 22)
		b:SetPoint("TOPLEFT", x, y)
		b:SetScript("OnClick", function() Settings.Set(def.key, c.id); Mark() end)
		buttons[c.id] = b
		x = x + 94
	end
	Mark()
	if def.key == "openOn" then Settings.openButtons = buttons end
	return 30
end

local function Build(panel)
	local y = -4
	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 4, y)
	title:SetText("Settings")
	y = y - 30
	-- Tick boxes in two columns.
	local toggles = {}
	for _, def in ipairs(ns.SETTINGS) do if def.kind == "toggle" then toggles[#toggles + 1] = def end end
	local half = math.ceil(#toggles / 2)
	for i, def in ipairs(toggles) do
		local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		local col, row = i > half and 1 or 0, (i - 1) % half
		cb:SetPoint("TOPLEFT", col * 308, y - row * 28)
		local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
		label:SetText(def.label)
		cb:SetChecked(ns.db.settings[def.key] and true or false)
		cb:SetScript("OnClick", function(self) Settings.Set(def.key, self:GetChecked()) end)
		Settings.checks[def.key] = cb
	end
	y = y - half * 28 - 8

	-- The rest, in the order declared.
	for _, def in ipairs(ns.SETTINGS) do
		if Kinds[def.kind] then y = y - Kinds[def.kind](panel, def, y) end
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
		{ "Self-test", function() ns.HandleSlash("selftest") end },
		{ "Diagnostics report", function() ns.HandleSlash("report") end },
		{ "Sync now", function() ns.HandleSlash("sync") end },
	}
	local x = 0
	for _, t in ipairs(tools) do
		local b = ns.UI.Button(panel)
		b:SetSize(116, 24)
		b:SetPoint("TOPLEFT", x, y)
		b:SetText(t[1])
		b:SetScript("OnClick", t[2])
		x = x + 122
	end

	local version = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	version:SetPoint("BOTTOMRIGHT", -4, 4)
	version:SetText("Issues with Tissues " .. ns.VERSION)
end

ns.UI.SetSettings(Build)

ns.RegisterCommand("sync", "ask the guild for any shared data you're missing", function()
	local ok, why = ns.Sync.AskNow()
	ns.Print(ok and "Asking the guild for shared data. Home shows how it's going." or ("Not now: " .. why .. "."))
end)
ns.RegisterCommand("settings", "open the settings", function() ns.UI.Open("Settings") end)
ns.RegisterCommand("scale", "window size in percent: /iwt scale 90 (70 to 130)", function(rest)
	local v = tonumber((rest or ""):match("%d+"))
	if not v then return ns.Print("Window size: %d%%. Type /iwt scale 70 to 130.", math.floor((ns.db.settings.scale or 1) * 100 + 0.5)) end
	ns.Print("Window size: %d%%.", math.floor(ns.UI.SetScale(v / 100) * 100 + 0.5))
	if Settings.scaleSlider then Settings.scaleSlider:SetValue(ns.db.settings.scale * 100) end
end)
