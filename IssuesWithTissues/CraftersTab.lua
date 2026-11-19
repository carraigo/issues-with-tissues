-- The Crafters tab: who in the guild can make something. Type part of an item's name to see
-- every guildmate who knows the recipe (online first); with the box empty it lists crafters by
-- profession and skill. Data comes from the shared "recipes" and "profs" sets (Professions.lua).

local _, ns = ...

local Crafters = ns.RegisterModule("CraftersTab", {})
ns.CraftersTab = Crafters

Crafters.state = { search = "", onlineOnly = false }

local function Online(who)
	local m = ns.Roster.Get(who)
	return m and m.online or false
end

local function Skill(who, profession)
	for _, p in ipairs(ns.Professions.Of(who)) do
		if p.name == profession then return p.rank, p.max end
	end
end

-- Search results: one row per recipe and crafter.
function Crafters.Search(text, onlineOnly)
	local rows = {}
	for _, r in ipairs(ns.Professions.WhoCanMake(text)) do
		local online = Online(r.crafter)
		if online or not onlineOnly then
			rows[#rows + 1] = {
				who = r.crafter, item = r.item, name = r.name, profession = r.profession,
				rank = Skill(r.crafter, r.profession), online = online,
			}
		end
	end
	table.sort(rows, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		if a.online ~= b.online then return a.online end
		return (a.rank or 0) > (b.rank or 0)
	end)
	return rows
end

-- No search: every crafter by profession, highest skill first.
function Crafters.ByProfession(onlineOnly)
	local counts = {}
	for _, r in ipairs(ns.Professions.AllRecipes()) do
		local k = r.crafter .. "#" .. r.profession
		counts[k] = (counts[k] or 0) + 1
	end
	local rows = {}
	for who in ns.Sync.Each("profs") do
		local online = Online(who)
		if ns.Roster.IsMember(who) and (online or not onlineOnly) then
			for _, p in ipairs(ns.Professions.Of(who)) do
				if not ns.Professions.NO_RECIPES[p.name] or p.name == "Mining" then
					rows[#rows + 1] = {
						who = who, profession = p.name, rank = p.rank, max = p.max, online = online,
						recipes = counts[who .. "#" .. p.name],
					}
				end
			end
		end
	end
	table.sort(rows, function(a, b)
		if a.profession ~= b.profession then return a.profession < b.profession end
		if a.rank ~= b.rank then return a.rank > b.rank end
		return a.who < b.who
	end)
	return rows
end

---------------------------------------------------------------------------
-- The tab
---------------------------------------------------------------------------
local list, status

local COLUMNS = {
	{ key = "c1", label = "", width = 200 },
	{ key = "who", label = "Crafter", width = 160 },
	{ key = "c3", label = "", width = 130 },
	{ key = "c4", label = "", width = 110 },
}

local GREY = 0.6

function Crafters.Refresh()
	if not Crafters.panel or not Crafters.panel:IsShown() then return end
	local s = Crafters.state
	local searching = s.search ~= ""
	local rows = searching and Crafters.Search(s.search, s.onlineOnly) or Crafters.ByProfession(s.onlineOnly)
	local titles = searching and { "Item", "Crafter", "Profession", "Skill" } or { "Profession", "Crafter", "Skill", "Recipes shared" }
	for i, t in ipairs(titles) do list.titles[i]:SetText(t) end
	list:SetRows(rows, function(r, key)
		local shade = r.online and 1 or GREY
		if key == "who" then
			local m = ns.Roster.Get(r.who)
			local cr, cg, cb = ns.UI.ClassColor(m and m.classFile)
			if not r.online then cr, cg, cb = cr * GREY, cg * GREY, cb * GREY end
			return ns.Roster.DisplayName(r.who) .. (r.online and "" or " |cff808080(offline)|r"), cr, cg, cb
		end
		if searching then
			if key == "c1" then return r.name, shade, shade, shade end
			if key == "c3" then return r.profession, shade, shade, shade end
			if key == "c4" then return r.rank and tostring(r.rank) or "", shade, shade, shade end
		else
			if key == "c1" then return r.profession, shade, shade, shade end
			if key == "c3" then return string.format("%d/%d", r.rank, r.max), shade, shade, shade end
			if key == "c4" then return r.recipes and tostring(r.recipes) or "not scanned", shade, shade, shade end
		end
	end)
	local online = 0
	for _, r in ipairs(rows) do if r.online then online = online + 1 end end
	if searching then
		status:SetText(#rows == 0 and ("Nobody has shared a recipe matching \"" .. s.search .. "\".")
			or string.format("%d matches, %d with the crafter online. Right-click to whisper.", #rows, online))
	else
		status:SetText("Type part of an item name to search. Recipes come from guildmates' Scan my recipes. Right-click to whisper.")
	end
end

local function Build(panel)
	Crafters.panel = panel
	local box = ns.UI.CreateInput(panel, 300, "Search: e.g. linen, bracer, potion")
	box:SetPoint("TOPLEFT", 8, 0)
	box.onChange = function(text)
		Crafters.state.search = text:match("^%s*(.-)%s*$")
		list.offset = 0
		Crafters.Refresh()
	end
	local online = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	online:SetPoint("LEFT", box, "RIGHT", 12, 0)
	local ol = online:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ol:SetPoint("LEFT", online, "RIGHT", 0, 0)
	ol:SetText("Online only")
	online:SetScript("OnClick", function(self)
		Crafters.state.onlineOnly = self:GetChecked() and true or false
		Crafters.Refresh()
	end)

	list = ns.UI.CreateList(panel, {
		top = -30, rows = 16, columns = COLUMNS,
		onClick = function(r, button) if button == "RightButton" then ns.UI.Whisper(r.who) end end,
		onEnter = function(line, r)
			if r.item and r.item > 0 and GameTooltip.SetItemByID then
				if pcall(GameTooltip.SetItemByID, GameTooltip, r.item) then
					GameTooltip:AddLine(" ")
				end
			end
			GameTooltip:AddLine(ns.Roster.DisplayName(r.who) .. (r.online and " (online)" or " (offline)"), 1, 0.82, 0)
			for _, p in ipairs(ns.Professions.Of(r.who)) do
				GameTooltip:AddLine(string.format("%s %d/%d", p.name, p.rank, p.max), 0.6, 0.9, 1)
			end
			GameTooltip:AddLine("Right-click to whisper", 0.5, 0.5, 0.5)
		end,
	})
	status = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	status:SetPoint("BOTTOMLEFT", 4, 2)
	status:SetWidth(600)
	status:SetJustifyH("LEFT")
	panel:SetScript("OnShow", Crafters.Refresh)
	Crafters.Refresh()
end

ns.UI.AddTabBeforeSettings("Crafters", Build)
ns.Listen("SYNC_CHANGED", function(set) if set == "recipes" or set == "profs" then Crafters.Refresh() end end)
ns.Listen("ROSTER_UPDATED", function() Crafters.Refresh() end)
