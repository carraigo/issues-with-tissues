-- The Home tab (first): a short overview of the guild, this character and its main, and
-- this character's professions with a button that scans their recipe lists.

local _, ns = ...

local General = ns.RegisterModule("GeneralTab", {})
ns.GeneralTab = General

-- Plain facts the page shows, kept apart from the drawing so tests can read them.
function General.Facts()
	local f = {}
	local R = ns.Roster
	f.guild = GetGuildInfo and GetGuildInfo("player") or nil
	f.members, f.online = R.count or 0, R.online or 0

	-- Players (alts counted once) and guildmates seen running the addon this session.
	local people = {}
	for key in pairs(R.members) do people[ns.Alts.MainOf(key)] = true end
	local n = 0
	for _ in pairs(people) do n = n + 1 end
	f.players = n
	local users = { [ns.PlayerName() or ""] = true }
	for who in pairs(ns.Comm.versions) do users[who] = true end
	local u = 0
	for _ in pairs(users) do u = u + 1 end
	f.addonUsers = u

	local away = 0
	for _, m in pairs(R.members) do if not m.online and (m.offlineDays or 0) >= 30 then away = away + 1 end end
	f.away30 = away

	-- This character
	local me = ns.PlayerName()
	local m = R.Get(me)
	f.me = R.DisplayName(me)
	f.rank = m and m.rank
	f.main = ns.Alts.MainOf(me)
	f.isMain = f.main == me
	f.accountMain = ns.Alts.AccountMain()
	f.alts = {}
	for _, alt in ipairs(ns.Alts.AltsOf(f.isMain and me or f.main)) do
		if alt ~= me then f.alts[#f.alts + 1] = R.DisplayName(alt) end
	end
	if not f.isMain then table.insert(f.alts, 1, R.DisplayName(f.main) .. " (main)") end

	-- Professions
	f.profs = {}
	for _, p in ipairs(ns.Professions.ReadSkills()) do
		local count = ns.Professions.SharedCount(p.name)
		f.profs[#f.profs + 1] = {
			name = p.name, rank = p.rank, max = p.max,
			recipes = count, noRecipes = ns.Professions.NO_RECIPES[p.name] or false,
		}
	end
	local crafters, recipes = {}, 0
	for _, r in ipairs(ns.Professions.AllRecipes()) do
		crafters[r.crafter] = true
		recipes = recipes + 1
	end
	local c = 0
	for _ in pairs(crafters) do c = c + 1 end
	f.guildCrafters, f.guildRecipes = c, recipes
	f.kills = ns.Kills.Totals()
	-- Honorable kills are of the other faction.
	local faction = UnitFactionGroup and UnitFactionGroup("player")
	f.enemyFaction = faction == "Alliance" and "Horde" or faction == "Horde" and "Alliance" or "Enemy player"
	return f
end

function General.ScanLabel()
	local s = ns.Professions.scan
	if s then return "Scanning (" .. s.done .. "/" .. s.total .. " done)" end
	return "Scan my recipes"
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------
local texts = {}
local mainButton, scanButton, scanHint
local HINT = "Press, then open your professions (your profession book key) and click each profession tab on the right of that window. The addon reads each tab as it appears. Skill levels are shared automatically."

local function Section(panel, x, y, title)
	local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(title)
	return fs
end

local function Body(panel, x, y, width)
	local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetWidth(width)
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("TOP")
	return fs
end

function General.Refresh()
	if not General.panel or not General.panel:IsShown() then return end
	local f = General.Facts()
	texts.guildTitle:SetText(f.guild or "No guild")
	texts.guild:SetText(table.concat({
		string.format("%d characters, %d players (alts counted once)", f.members, f.players),
		string.format("|cff40ff40%d online now|r", f.online),
		string.format("%d away 30 days or more", f.away30),
		string.format("%d using Issues with Tissues this session", f.addonUsers),
		string.format("|cffff9050Enemy Kills: %s|r", ns.Kills.Format(f.kills.mobs)),
		string.format("|cffff9050%s Kills: %s|r", f.enemyFaction, ns.Kills.Format(f.kills.hk)),
		string.format("|cff999999(added up from %d characters using the addon)|r", f.kills.chars),
	}, "\n"))

	local lines = { f.me .. (f.rank and ("  |cff999999" .. f.rank .. "|r") or "") }
	if f.isMain and f.accountMain == ns.PlayerName() then
		lines[#lines + 1] = "|cff7fd4ffThis is your main.|r"
	elseif f.isMain then
		lines[#lines + 1] = "Not linked to a main."
	else
		lines[#lines + 1] = "Alt of " .. ns.Roster.DisplayName(f.main)
	end
	if #f.alts > 0 then lines[#lines + 1] = "|cff999999Also: " .. table.concat(f.alts, ", ") .. "|r" end
	texts.me:SetText(table.concat(lines, "\n"))
	if f.accountMain == ns.PlayerName() then
		mainButton:SetText("Main (set)")
		mainButton:Disable()
	else
		mainButton:SetText("Set as my main")
		mainButton:Enable()
	end

	local pl = {}
	for _, p in ipairs(f.profs) do
		local recipes
		if p.noRecipes then recipes = "|cff999999no recipes|r"
		elseif p.recipes then recipes = "|cff40ff40" .. p.recipes .. " recipes shared|r"
		else recipes = "|cffff8040not scanned|r" end
		pl[#pl + 1] = string.format("%s %d/%d  %s", p.name, p.rank, p.max, recipes)
	end
	if #pl == 0 then pl[1] = "No professions on this character." end
	texts.profs:SetText(table.concat(pl, "\n"))
	scanButton:SetText(General.ScanLabel())
	local s = ns.Professions.scan
	if s and #s.left > 0 then
		scanHint:SetText("|cffffd100Now click each profession tab on the right of the profession window. Still to do: "
			.. table.concat(s.left, ", ") .. "|r")
	else
		scanHint:SetText(HINT)
	end
end

local function Build(panel)
	General.panel = panel
	-- Three cards, as in the layout mock-up.
	ns.UI.Card(panel, 0, 0, 300, 146)
	ns.UI.Card(panel, 308, 0, 308, 146)
	ns.UI.Card(panel, 0, -156, 616, 170)

	texts.guildTitle = Section(panel, 12, -10, "Issues with Tissues")
	texts.guild = Body(panel, 12, -30, 280)

	Section(panel, 320, -10, "This character")
	texts.me = Body(panel, 320, -30, 284)
	mainButton = ns.UI.Button(panel)
	mainButton:SetSize(140, 24)
	mainButton:SetPoint("TOPLEFT", 320, -108)
	mainButton:SetScript("OnClick", function() ns.Alts.SetMain(); General.Refresh() end)

	Section(panel, 12, -166, "Your professions")
	texts.profs = Body(panel, 12, -186, 390)
	scanButton = ns.UI.Button(panel, nil, nil, nil, "primary")
	scanButton:SetSize(180, 26)
	scanButton:SetPoint("TOPLEFT", 420, -166)
	scanButton:SetScript("OnClick", function() ns.Professions.Scan(); General.Refresh() end)
	scanHint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	scanHint:SetPoint("TOPLEFT", 420, -200)
	scanHint:SetWidth(184)
	scanHint:SetJustifyH("LEFT")
	scanHint:SetText(HINT)

	panel:SetScript("OnShow", General.Refresh)
	General.Refresh()
end

ns.UI.AddPage("Home", "Home", Build)

ns.Listen("ROSTER_UPDATED", function() General.Refresh() end)
ns.Listen("SYNC_CHANGED", function() General.Refresh() end)
ns.Listen("SCAN_CHANGED", function() General.Refresh() end)
ns.Listen("VERSION_SEEN", function() General.Refresh() end)
