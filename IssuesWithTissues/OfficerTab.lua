-- Members > Officers (officers and the Guild Master only): a clean-up list of players away 30
-- days or more, ready to demote or remove, and who runs which version of the addon.
-- Versions are heard at login (Comm HELLO) and remembered on this PC (db.versionsSeen), so
-- nothing extra is sent.

local _, ns = ...

local Off = ns.RegisterModule("OfficerTab", {})
ns.OfficerTab = Off

Off.AWAY_DAYS = 30
Off.KEEP_VERSIONS = 60 * 86400 -- forget a version heard over 60 days ago

function Off.Visible()
	local me = ns.Roster.me
	return me ~= nil and ns.Roster.IsOfficer(me)
end

-- Players away AWAY_DAYS or more (alts grouped under their main), longest away first.
function Off.AwayRows()
	return ns.RosterTab.Rows({ filter = "away30", groupAlts = true, sort = "where", desc = true, search = "" })
end

local function Seen()
	ns.db.versionsSeen = ns.db.versionsSeen or {}
	return ns.db.versionsSeen
end

function Off.Remember(who, version)
	if type(who) ~= "string" or who == "" or type(version) ~= "string" or version == "" then return end
	Seen()[ns.FullName(who)] = { v = version, at = ns.Now() }
end
ns.Listen("VERSION_SEEN", function(who, version) Off.Remember(who, version) end)

-- The newest release version anyone has (ours included); pre-releases only count against
-- other pre-releases, as in the update notice.
function Off.Newest()
	local W = ns.Welcome
	local best = ns.VERSION
	for _, s in pairs(Seen()) do
		local _, _, _, pre = W.ParseVersion(s.v)
		if not pre and W.Newer(s.v, best) then best = s.v end
	end
	return best
end

-- { name, version, at, online, old } per guildmate heard from (still in the guild), oldest
-- version first; and how many members have never been heard from.
function Off.VersionRows()
	local seen, now, newest = Seen(), ns.Now(), Off.Newest()
	Off.Remember(ns.PlayerName(), ns.VERSION)
	local rows, heard = {}, {}
	for who, s in pairs(seen) do
		local m = ns.Roster.Get(who)
		if now - (s.at or 0) > Off.KEEP_VERSIONS then
			seen[who] = nil
		elseif m then
			heard[who] = true
			rows[#rows + 1] = { full = who, name = ns.Roster.DisplayName(who), version = s.v, at = s.at,
				online = m.online, classFile = m.classFile, old = ns.Welcome.Newer(newest, s.v) }
		end
	end
	table.sort(rows, function(a, b)
		if a.old ~= b.old then return a.old end
		if a.version ~= b.version then return ns.Welcome.Newer(b.version, a.version) end
		return a.name < b.name
	end)
	local never = 0
	for full in pairs(ns.Roster.members) do
		if not heard[full] and not heard[ns.Alts.MainOf(full)] then never = never + 1 end
	end
	return rows, never, newest
end

local function Ago(t) return ns.UI.Ago(t) end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------
local awayList, versionList, awayTitle, versionTitle

function Off.Refresh()
	if not Off.panel or not Off.panel:IsShown() then return end
	local away = Off.AwayRows()
	awayTitle:SetText(string.format("Away %d days or more: %d  |cff999999(right-click to demote or remove)|r", Off.AWAY_DAYS, #away))
	awayList:SetRows(away, function(row, key)
		if key == "name" then return row.name, ns.UI.ClassColor(row.classFile) end
		if key == "rank" then return row.mainRank or row.rank end
		if key == "level" then return tostring(row.level) end
		if key == "where" then return row.where end
		if key == "alts" then return #row.alts > 0 and table.concat(row.alts, ", ") or "" end
	end)
	local rows, never, newest = Off.VersionRows()
	local old = 0
	for _, r in ipairs(rows) do if r.old then old = old + 1 end end
	versionTitle:SetText(string.format("Addon versions (newest %s): %d up to date, %d older, %d members not seen using it",
		newest, #rows - old, old, never))
	versionList:SetRows(rows, function(row, key)
		if key == "name" then return row.name, ns.UI.ClassColor(row.classFile) end
		if key == "version" then
			if row.old then return row.version .. "  (older)", 1, 0.55, 0.3 end
			return row.version, 0.4, 0.85, 0.4
		end
		if key == "seen" then return row.online and "online now" or Ago(row.at) end
	end)
end

local function Build(panel)
	Off.panel = panel
	local top = CreateFrame("Frame", nil, panel)
	top:SetPoint("TOPLEFT", 0, 0)
	top:SetPoint("TOPRIGHT", 0, 0)
	top:SetHeight(220)
	awayTitle = top:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	awayTitle:SetPoint("TOPLEFT", 4, -2)
	awayList = ns.UI.CreateList(top, {
		top = -22, rows = 10,
		columns = {
			{ key = "name", label = "Name", width = 150 },
			{ key = "rank", label = "Rank", width = 100 },
			{ key = "level", label = "Lvl", width = 40 },
			{ key = "where", label = "Last seen", width = 100 },
			{ key = "alts", label = "Alts", width = 216 },
		},
		onClick = function(row, button)
			if button == "RightButton" then ns.RosterTab.ShowMenu(row, nil, panel) end
		end,
		onEnter = function(_, row)
			GameTooltip:AddLine(row.name)
			for _, l in ipairs(ns.RosterTab.Notes(row.full)) do GameTooltip:AddLine(l[1], l[2], l[3], l[4], true) end
			GameTooltip:AddLine("Right-click to demote or remove", 0.7, 0.7, 0.7)
		end,
	})
	awayList:SetEmpty("Nobody has been away that long.")

	local bottom = CreateFrame("Frame", nil, panel)
	bottom:SetPoint("TOPLEFT", 0, -228)
	bottom:SetPoint("BOTTOMRIGHT", 0, 0)
	versionTitle = bottom:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	versionTitle:SetPoint("TOPLEFT", 4, -2)
	versionList = ns.UI.CreateList(bottom, {
		top = -22, rows = 8,
		columns = {
			{ key = "name", label = "Name", width = 200 },
			{ key = "version", label = "Version", width = 200 },
			{ key = "seen", label = "Last heard", width = 206 },
		},
		onClick = function(row, button)
			if button == "LeftButton" and row.old then ns.UI.Whisper(row.full) end
		end,
		onEnter = function(_, row)
			GameTooltip:AddLine(row.name .. ": " .. row.version)
			GameTooltip:AddLine("Heard " .. ns.UI.Ago(row.at) .. " (" .. date("%d %b %Y, %H:%M", row.at) .. ")", 0.7, 0.7, 0.7)
			if row.old then GameTooltip:AddLine("Click to whisper them about updating", 0.7, 0.7, 0.7) end
		end,
	})
	versionList:SetEmpty("No guildmates heard from yet. Versions arrive as people log in.")
	panel:SetScript("OnShow", Off.Refresh)
	Off.Refresh()
end

ns.UI.AddPage("Members", "Officers", Build, { order = 20, visible = Off.Visible })

local Soon = ns.Coalesce(function() Off.Refresh() end)
ns.Listen("ROSTER_UPDATED", Soon)
ns.Listen("VERSION_SEEN", Soon)
ns.Listen("SYNC_CHANGED", function(set) if set == "alts" then Soon() end end)
