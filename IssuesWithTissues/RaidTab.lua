-- Members > Raid: who is attuned and keyed, and who is saved to which raid, from the guild's
-- shared character sheets (Sheet.lua). Only characters running the addon are listed.
-- Shown to officers and the Guild Master only.

local _, ns = ...

local Raid = ns.RegisterModule("RaidTab", {})
ns.RaidTab = Raid

local GREEN, GREY = "|cff66dd66", "|cff555555"

-- "MC Ony BWL Naxx" with the ones they have in green.
function Raid.Marks(has, raids)
	local out = {}
	for _, a in ipairs(ns.Sheet.ATTUNEMENTS) do
		if (a.raid and true or false) == raids then
			out[#out + 1] = (has[a.code] and GREEN or GREY) .. a.short .. "|r"
		end
	end
	return table.concat(out, " ")
end

-- A raid's short name for the Saved column: the attunement's short name when it matches.
local SHORT = { ["Molten Core"] = "MC", ["Onyxia's Lair"] = "Ony", ["Blackwing Lair"] = "BWL", ["Naxxramas"] = "Naxx",
	["Zul'Gurub"] = "ZG", ["Ruins of Ahn'Qiraj"] = "AQ20", ["Ahn'Qiraj Temple"] = "AQ40", ["Temple of Ahn'Qiraj"] = "AQ40" }
function Raid.Saved(locks)
	local out = {}
	for _, l in ipairs(locks) do
		local name = SHORT[l.name] or l.name
		out[#out + 1] = l.total > 0 and string.format("%s %d/%d", name, l.done, l.total) or name
	end
	return table.concat(out, ", ")
end

-- "3d 4h", "5h 20m", "12m"
function Raid.Until(t, now)
	local s = math.max(0, t - (now or ns.Now()))
	local d, h, m = math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60)
	if d > 0 then return string.format("%dd %dh", d, h) end
	if h > 0 then return string.format("%dh %dm", h, m) end
	return m .. "m"
end

local function Count(row, raids)
	local n = 0
	for _, a in ipairs(ns.Sheet.ATTUNEMENTS) do
		if (a.raid and true or false) == raids and row.has[a.code] then n = n + 1 end
	end
	return n
end

Raid.FILTERS = {
	{ key = "all", label = "All" },
	{ key = "online", label = "Online", test = function(r) return r.online end },
	{ key = "max", label = "Level 60", test = function(r) return r.level >= 60 end },
	{ key = "free", label = "Not saved", test = function(r) return #r.locks == 0 end },
}

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------
local list, summary

-- "Attuned: MC 12, Ony 8, BWL 5, Naxx 0. Saved: MC 9, Ony 4." for the rows shown.
function Raid.Summary(rows)
	local has, saved = ns.Sheet.Counts(rows)
	local a = {}
	for _, at in ipairs(ns.Sheet.ATTUNEMENTS) do
		if at.raid then a[#a + 1] = at.short .. " " .. (has[at.code] or 0) end
	end
	local s = {}
	for name, n in pairs(saved) do s[#s + 1] = (SHORT[name] or name) .. " " .. n end
	table.sort(s)
	return "Attuned: " .. table.concat(a, ", ") .. (#s > 0 and ("   Saved: " .. table.concat(s, ", ")) or "")
end

function Raid.Refresh()
	if not Raid.panel or not Raid.panel:IsShown() then return end
	list:SetRows(ns.Sheet.Rows(), function(row, key)
		local shade = row.online and 1 or 0.6
		if key == "name" then return row.name, ns.UI.ClassColor(row.classFile) end
		if key == "level" then return tostring(row.level), shade, shade, shade end
		if key == "raids" then return Raid.Marks(row.has, true) end
		if key == "keys" then return Raid.Marks(row.has, false) end
		if key == "saved" then
			if #row.locks == 0 then return "free", 0.4, 0.85, 0.4 end
			return Raid.Saved(row.locks), 1, 0.7, 0.3
		end
	end)
end

local function Tooltip(_, row)
	GameTooltip:AddLine(row.name, ns.UI.ClassColor(row.classFile))
	for _, a in ipairs(ns.Sheet.ATTUNEMENTS) do
		if row.has[a.code] then GameTooltip:AddLine(a.name, 0.4, 0.85, 0.4)
		else GameTooltip:AddLine(a.name .. ": not yet", 0.5, 0.5, 0.5) end
	end
	local now = ns.Now()
	for _, l in ipairs(row.locks) do
		GameTooltip:AddLine(string.format("Saved to %s%s, resets in %s (%s)", l.name,
			l.total > 0 and string.format(" (%d/%d bosses)", l.done, l.total) or "",
			Raid.Until(l.resetAt, now), date("%a %H:%M", l.resetAt)), 1, 0.7, 0.3, true)
	end
	if #row.locks == 0 then GameTooltip:AddLine("Not saved to any raid", 0.4, 0.85, 0.4) end
	GameTooltip:AddLine("Right-click to whisper or invite", 0.5, 0.5, 0.5)
end

local function Build(panel)
	Raid.panel = panel
	list = ns.UI.CreateList(panel, {
		top = -50, rows = 15, filters = Raid.FILTERS, save = "raid",
		state = { sort = "raids", desc = true },
		columns = {
			{ key = "name", label = "Name", width = 140, sort = true },
			{ key = "level", label = "Lvl", width = 36, sort = true, desc = true },
			{ key = "raids", label = "Raids", width = 140, sort = function(r) return Count(r, true) end, desc = true },
			{ key = "keys", label = "Keys", width = 160, sort = function(r) return Count(r, false) end, desc = true },
			{ key = "saved", label = "Saved to", width = 130, sort = function(r) return #r.locks end },
		},
		search = { width = 136, hint = "Search names", text = function(r) return r.name end,
			onEnter = function(first) ns.UI.Whisper(first.full) end },
		count = function(shown, all)
			summary:SetText(Raid.Summary(shown))
			return string.format("%d shown of %d sharing their sheet. Hover a name for details.", #shown, #all)
		end,
		onClick = function(row, button) if button == "RightButton" then ns.RosterTab.ShowMenu(row, nil, panel) end end,
		onEnter = Tooltip,
	})
	list:SetEmpty("Nobody has shared a character sheet yet. Sheets arrive as guildmates log in with this version.")
	summary = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	summary:SetPoint("TOPLEFT", 4, -28)
	summary:SetWidth(600)
	summary:SetJustifyH("LEFT")
	Raid.list = list
	panel:SetScript("OnShow", function() ns.Sheet.AskRaidInfo(); Raid.Refresh() end)
	Raid.Refresh()
end

-- Officers and the Guild Master only for now (everyone still shares their sheet).
function Raid.Visible() return ns.OfficerTab.Visible() end
ns.UI.AddPage("Members", "Raid", Build, { order = 15, visible = Raid.Visible })

local Soon = ns.Coalesce(function() Raid.Refresh() end)
ns.Listen("ROSTER_UPDATED", Soon)
ns.Listen("SYNC_CHANGED", function(set) if set == "sheet" then Soon() end end)
