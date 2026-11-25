-- The Roster tab: the guild roster with level, class, honorable kills and professions (rank and
-- last online are in the tooltip, and still drive the filters). Filters: everyone, online now, away 7 / 14 / 30+ days. Click a column title to
-- sort. "Group alts" shows each player once, under their main, with their alts' names.

local _, ns = ...

local Tab = ns.RegisterModule("RosterTab", {})
ns.RosterTab = Tab

Tab.FILTERS = {
	{ key = "all", label = "All" },
	{ key = "online", label = "Online" },
	{ key = "away7", label = "Away 7d+", days = 7 },
	{ key = "away14", label = "Away 14d+", days = 14 },
	{ key = "away30", label = "Away 30d+", days = 30 },
}
Tab.COLUMNS = {
	{ key = "name", label = "Name", width = 200 },
	{ key = "level", label = "Lvl", width = 36 },
	{ key = "class", label = "Class", width = 80 },
	{ key = "hk", label = "Honourable kills", width = 110 },
	{ key = "rankIndex", label = "Rank", width = 90 },
	{ key = "where", label = "Last seen", width = 90 },
}
Tab.state = { filter = "all", sort = "rankIndex", desc = false, groupAlts = true, offset = 0, search = "" }

-- Display name: the roster's own spelling ("Clane Stocious"), without the realm.
local function Short(key)
	return ns.Roster.DisplayName(key)
end

local function Where(m)
	if m.online then return m.zone or "" end
	local d = m.offlineDays or 0
	if d == 0 then return "today" end
	return d == 1 and "1 day ago" or (d .. " days ago")
end

-- The rows to show, filtered, grouped and sorted. Each row: the roster entry plus name,
-- alts (when grouped), where.
function Tab.Rows(state)
	state = state or Tab.state
	local filter
	for _, f in ipairs(Tab.FILTERS) do if f.key == state.filter then filter = f end end
	filter = filter or Tab.FILTERS[1]

	-- Group: one entry per main. A main not in the guild (alt in guild, main elsewhere) is
	-- represented by the alt itself.
	local groups = {}
	for full in pairs(ns.Roster.members) do
		local key = full
		if state.groupAlts then
			local main = ns.Alts.MainOf(full)
			if ns.Roster.members[main] then key = main end
		end
		local g = groups[key]
		if not g then
			g = { members = {} }
			groups[key] = g
		end
		g.members[#g.members + 1] = full
	end

	local rows = {}
	for key, g in pairs(groups) do
		local m = ns.Roster.members[key]
		-- The group counts as online if any of its characters is, and as away for the
		-- shortest time any of them has been away.
		local online, days, zone, onlineChar = false, math.huge, nil, nil
		local alts = {}
		for _, full in ipairs(g.members) do
			local c = ns.Roster.members[full]
			if c.online then
				online = true
				-- The character actually logged on (the main when it is).
				if not onlineChar or full == key then onlineChar, zone = full, c.zone end
			end
			days = math.min(days, c.offlineDays or 0)
			if full ~= key then alts[#alts + 1] = Short(full) end
		end
		table.sort(alts)
		local keep
		if filter.key == "online" then keep = online
		elseif filter.days then keep = not online and days >= filter.days
		else keep = true end
		-- Search: any of the group's characters by name (first name, surname or both).
		local search = (state.search or ""):lower()
		if keep and search ~= "" then
			local hit = false
			for _, full in ipairs(g.members) do
				if Short(full):lower():find(search, 1, true) then hit = true break end
			end
			keep = hit
		end
		if keep then
			-- Online on an alt: show that character (its level and class), with the main beside it.
			local shown = onlineChar or key
			local c = ns.Roster.members[shown]
			local row = {
				full = key, name = Short(shown), level = c.level or 0, class = c.class or "", classFile = c.classFile,
				rank = c.rank or "", rankIndex = m.rankIndex or 99, online = online,
				mainRank = (shown ~= key) and m.rank or nil,
				offlineDays = online and 0 or days, zone = zone or m.zone, alts = alts,
				tell = shown, mainName = (shown ~= key) and Short(key) or nil,
			}
			-- The other alts: never the character the row already shows.
			row.otherAlts = {}
			for _, full in ipairs(g.members) do
				if full ~= key and full ~= shown then row.otherAlts[#row.otherAlts + 1] = Short(full) end
			end
			table.sort(row.otherAlts)
			row.where = Where(row)
			-- Honorable kills of the character shown; -1 (shown as "-") until it shares them.
			local k = ns.Kills.Of(shown)
			row.hk = k and k.hk or -1
			rows[#rows + 1] = row
		end
	end

	local key, desc = state.sort or "rankIndex", state.desc
	table.sort(rows, function(a, b)
		local x, y = a[key], b[key]
		if key == "where" then x, y = a.online and -1 or a.offlineDays, b.online and -1 or b.offlineDays end
		if x ~= y then
			if desc then return x > y end
			return x < y
		end
		return a.name < b.name
	end)
	return rows
end

---------------------------------------------------------------------------
-- The page (the shared list builder; Tab.Rows does the filtering, grouping and sorting)
---------------------------------------------------------------------------
local ROWS = 17
local list

local function ClassColor(token) return ns.UI.ClassColor(token) end -- the theme's, when it has its own

local function Cell(row, key)
	if key == "name" then
		local text
		if row.mainName then
			text = row.name .. " |cff999999(" .. row.mainName .. ")|r"
		else
			text = row.name .. (#row.alts > 0 and (" |cff999999+" .. #row.alts .. "|r") or "")
		end
		return text, ClassColor(row.classFile)
	end
	local shade = row.online and 1 or 0.6
	local text
	if key == "rankIndex" then text = row.rank
	elseif key == "hk" then text = row.hk >= 0 and ns.Kills.Format(row.hk) or "|cff666666-|r"
	else text = tostring(row[key] or "") end
	return text, shade, shade, shade
end

-- rebuild: the data changed. Scrolling only repaints the rows already built; filters, sorting
-- and opening the page rebuild them too.
function Tab.Refresh(rebuild)
	if not Tab.panel or not Tab.panel:IsShown() or not list then return end
	if rebuild == false then list:Draw() else list:Refresh() end
end

-- Enter in the search: whisper the first match.
function Tab.PickFirst()
	if (Tab.state.search or "") == "" then return nil end
	local first = Tab.Rows()[1]
	if not first then return nil end
	return Tab.Whisper(first.tell or first.full)
end

-- The guild notes for a character's tooltip: { text, r, g, b }. The officer note only for
-- officers (the game gives it only to ranks allowed to see it anyway).
function Tab.Notes(who)
	local m = ns.Roster.Get(who)
	local out = {}
	if not m then return out end
	if m.note and m.note ~= "" then out[#out + 1] = { "Note: " .. m.note, 1, 0.82, 0 } end
	local me = ns.Roster.me
	if m.officerNote and m.officerNote ~= "" and me and ns.Roster.IsOfficer(me) then
		out[#out + 1] = { "Officer note: " .. m.officerNote, 1, 0.5, 0.25 }
	end
	return out
end

-- Open a whisper to a guildmate. Forever's server finds a character by "First Surname"
-- (the roster's spelling, without the realm); the first name alone reaches nobody.
function Tab.Whisper(key)
	local target = ns.Roster.DisplayName(key)
	if not target or target == "" then return end
	if ChatFrame_SendTell then
		ChatFrame_SendTell(target)
	elseif ChatFrame_OpenChat then
		ChatFrame_OpenChat("/w " .. target .. " ")
	end
	return target
end

local function Tooltip(_, r)
	GameTooltip:AddLine(r.name, ClassColor(r.classFile))
	if r.mainName then GameTooltip:AddLine("Alt of " .. r.mainName .. " (" .. (r.mainRank or "") .. ")", 0.7, 0.7, 0.7) end
	GameTooltip:AddLine(string.format("Level %d %s, %s", r.level, r.class, r.rank), 1, 1, 1)
	GameTooltip:AddLine(r.online and ("Online: " .. (r.zone or "")) or ("Last online: " .. r.where), 1, 1, 1)
	GameTooltip:AddLine(r.hk >= 0 and ("Honourable kills: " .. ns.Kills.Format(r.hk)) or "Honourable kills: not shared (no addon)", 1, 0.56, 0.31)
	if #r.otherAlts > 0 then
		GameTooltip:AddLine((r.mainName and "Other alts: " or "Alts: ") .. table.concat(r.otherAlts, ", "), 0.7, 0.7, 0.7, true)
	end
	for _, p in ipairs(ns.Professions.Of(r.tell or r.full)) do
		GameTooltip:AddLine(string.format("%s %d/%d", p.name, p.rank, p.max), 0.6, 0.9, 1)
	end
	for _, n in ipairs(Tab.Notes(r.tell or r.full)) do GameTooltip:AddLine(n[1], n[2], n[3], n[4], true) end
	GameTooltip:AddLine("Right-click to whisper, invite" .. (Tab.CanManage() and ", promote or demote" or ""), 0.5, 0.5, 0.5)
end

local function Build(panel)
	Tab.panel = panel
	local columns = {}
	for i, col in ipairs(Tab.COLUMNS) do
		columns[i] = { key = col.key, label = col.label, width = col.width, sort = true,
			desc = col.key == "level" or col.key == "hk" }
	end
	local filters = {}
	for i, f in ipairs(Tab.FILTERS) do filters[i] = { key = f.key, label = f.label } end
	list = ns.UI.CreateList(panel, {
		top = -32, rows = ROWS, columns = columns, filters = filters,
		state = Tab.state, save = "roster",
		-- Search by name (Ctrl+F); Enter whispers the first match.
		search = { width = 136, hint = "Search names", onEnter = function(first) return Tab.Whisper(first.tell or first.full) end },
		source = function(state) return Tab.Rows(state) end,
		cell = Cell,
		count = function(rows)
			local online = 0
			for _, r in ipairs(rows) do if r.online then online = online + 1 end end
			return string.format("%d shown, %d online. Guild: %d members, %d online.",
				#rows, online, ns.Roster.count, ns.Roster.online)
		end,
		onClick = function(row, button, line) if button == "RightButton" then Tab.ShowMenu(row, line) end end,
		onEnter = Tooltip,
	})
	Tab.list, Tab.searchBox = list, list.searchBox
	local group = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	group:SetPoint("TOPLEFT", list.toolbarX, 1)
	local gl = group:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	gl:SetPoint("LEFT", group, "RIGHT", 0, 0)
	gl:SetText("Group alts")
	group:SetChecked(Tab.state.groupAlts)
	group:SetScript("OnClick", function(self) Tab.state.groupAlts = self:GetChecked() and true or false; Tab.Refresh() end)
	panel:SetScript("OnShow", function() ns.Roster.Request(); Tab.Refresh() end)
	panel:HookScript("OnHide", Tab.HideMenu)
	Tab.Refresh()
end

---------------------------------------------------------------------------
-- Right-click menu: whisper, invite, and for officers promote and demote.
---------------------------------------------------------------------------

-- Officers and the Guild Master only, and only when the game lets this rank change ranks.
function Tab.CanManage()
	local me = ns.Roster.me
	return me ~= nil and ns.Roster.IsOfficer(me) and ns.Roster.Get(me) ~= nil
end

local function GameAllows(fn)
	if type(fn) ~= "function" then return true end -- not in this client: the server decides
	local ok, yes = pcall(fn)
	return not ok or yes and true or false
end

-- What this player may do to a character: can promote, can demote. The game's own rules: never
-- to your own rank or above, never someone at or above your rank, never below the lowest rank.
function Tab.RankActions(target)
	if not Tab.CanManage() then return false, false end
	local me = ns.Roster.Get(ns.Roster.me)
	local them = ns.Roster.Get(target)
	if not them or ns.FullName(target) == ns.Roster.me or them.rankIndex == nil or me.rankIndex == nil then
		return false, false
	end
	local lowest = (GuildControlGetNumRanks and GuildControlGetNumRanks() or 10) - 1
	local promote = them.rankIndex - 1 > me.rankIndex
		and GameAllows(CanGuildPromote or (C_GuildInfo and C_GuildInfo.CanGuildPromote))
	local demote = them.rankIndex > me.rankIndex and them.rankIndex < lowest
		and GameAllows(CanGuildDemote or (C_GuildInfo and C_GuildInfo.CanGuildDemote))
	return promote, demote
end

local function RankName(index)
	return GuildControlGetRankName and GuildControlGetRankName(index + 1) or ("rank " .. (index + 1))
end

-- Forever forbids addons from calling GuildPromote and GuildDemote (ADDON_ACTION_FORBIDDEN), and
-- the game's own command typed into chat by an addon is blocked too (the chat box carries the
-- addon's taint: "the game blocked Promote()", 1.4.0). What works is the game's command run from
-- a secure macro button that the player clicks, as from their own macro. So the menu's Promote,
-- Demote and Remove are such buttons: the first click arms it ("Click again to ..."), the second
-- runs "/gpromote Sara Exe". The server finds the character by "First Surname", as for whispers.
-- In combat secure buttons can't be set up, so the menu says what to type instead.
function Tab.RankCommand(target, up)
	local promote, demote = Tab.RankActions(target)
	if (up and not promote) or (not up and not demote) then return nil end
	return (up and "/gpromote " or "/gdemote ") .. ns.Roster.DisplayName(target)
end

-- Kept for /iwt and older callers: says what to type, as nothing else can do it.
function Tab.ChangeRank(target, up)
	local command = Tab.RankCommand(target, up)
	if not command then return false end
	ns.Print("Type %s to %s %s, or use Promote/Demote on the roster's right-click menu.", command,
		up and "promote" or "demote", ns.Roster.DisplayName(target))
	return command
end

-- Removing someone: officers, only for a rank below their own, the same way as rank changes.
function Tab.CanRemove(target)
	if not Tab.CanManage() then return false end
	local me = ns.Roster.Get(ns.Roster.me)
	local them = ns.Roster.Get(target)
	if not them or ns.FullName(target) == ns.Roster.me or them.rankIndex == nil or me.rankIndex == nil then return false end
	return them.rankIndex > me.rankIndex and GameAllows(CanGuildRemove or (C_GuildInfo and C_GuildInfo.CanGuildRemove))
end

function Tab.RemoveCommand(target)
	if not Tab.CanRemove(target) then return nil end
	return "/gremove " .. ns.Roster.DisplayName(target)
end

function Tab.Remove(target)
	local command = Tab.RemoveCommand(target)
	if not command then return false end
	ns.Print("Type %s to remove %s from the guild.", command, ns.Roster.DisplayName(target))
	return command
end

local menu

-- A secure macro button laid over a menu button, for the game's guild commands (see above).
-- First click: arms it (the label asks to click again). Second click: the game runs the command.
-- It's parented to UIParent, not the menu: a protected child would make the addon's window
-- protected too, so it couldn't hide in combat. All of them hide when the menu does and when
-- combat starts, and the menu's officer entries fall back to "Type ..." in combat.
local overlays = {}
local function HideOverlays()
	if InCombatLockdown and InCombatLockdown() then return end
	for _, o in ipairs(overlays) do
		o:Hide()
		o.armed = false
		o:SetAttribute("type", nil)
		o:SetAttribute("macrotext", nil)
	end
end
Tab.HideOverlays = HideOverlays
pcall(ns.On, "PLAYER_REGEN_DISABLED", HideOverlays) -- just before combat locks them

local function Secure(b)
	if b.secure or b.secureTried then return b.secure end
	if not (SecureCmdOptionParse or SecureActionButton_OnClick) then return false end -- no secure buttons here
	b.secureTried = true
	local ok, s = pcall(CreateFrame, "Button", nil, UIParent, "SecureActionButtonTemplate")
	if not ok or not s then return false end
	s:SetFrameStrata("TOOLTIP")
	s:SetAllPoints(b)
	overlays[#overlays + 1] = s
	if s.RegisterForClicks then s:RegisterForClicks("AnyUp", "AnyDown") end
	local hl = s:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	ns.UI.Fill(hl, ns.UI.COLORS.hover)
	s:HookScript("PostClick", function(self, _, down)
		if down then return end
		if self.armed then
			ns.Print("Sent %s.", self.macro)
			if menu then menu:Hide() end
		elseif not (InCombatLockdown and InCombatLockdown()) then
			self.armed = true
			self:SetAttribute("type", "macro")
			self:SetAttribute("macrotext", self.macro)
			b:SetText(self.confirm)
		end
	end)
	b.secure = s
	return s
end

-- Puts the item's command on the button's secure overlay, unarmed; nil takes it off.
function Tab.SetSecure(b, item)
	local inCombat = InCombatLockdown and InCombatLockdown()
	if inCombat then return false end
	local s = (item and item.macro) and Secure(b) or b.secure
	if not s then return false end
	s:SetAttribute("type", nil)
	s:SetAttribute("macrotext", nil)
	s.armed, s.macro, s.confirm = false, item and item.macro, item and item.confirm
	if item and item.macro then s:Show() else s:Hide() end
	return item and item.macro and true or false
end

function Tab.MenuButton(i) return menu and menu.buttons[i] end

function Tab.HideMenu()
	if menu then menu:Hide() end
end

-- The menu's entries for a row: { label, action }. Officers' entries only when allowed.
function Tab.MenuItems(row)
	local who = row.tell or row.full
	local items = {
		{ "Whisper", function() Tab.Whisper(who) end },
		{ "Invite to group", function() ns.UI.Invite(who) end },
	}
	local promote, demote = Tab.RankActions(who)
	local them = ns.Roster.Get(who)
	local name = ns.Roster.DisplayName(who)
	-- { label, fallback action, macro = the game's command, confirm = the armed label }
	if promote then
		local to = RankName(them.rankIndex - 1)
		items[#items + 1] = { "Promote to " .. to, function() Tab.ChangeRank(who, true) end,
			macro = Tab.RankCommand(who, true), confirm = "Click again: promote" }
	end
	if demote then
		local to = RankName(them.rankIndex + 1)
		items[#items + 1] = { "Demote to " .. to, function() Tab.ChangeRank(who, false) end,
			macro = Tab.RankCommand(who, false), confirm = "Click again: demote" }
	end
	if Tab.CanRemove(who) then
		items[#items + 1] = { "Remove from guild", function() Tab.Remove(who) end,
			macro = Tab.RemoveCommand(who), confirm = "Click again: remove " .. name }
	end
	return items
end

function Tab.ShowMenu(row, line, parent)
	parent = parent or Tab.panel
	if not parent then return end
	if not menu then
		menu = CreateFrame("Frame", nil, parent)
		menu:SetFrameStrata("DIALOG")
		menu:EnableMouse(true)
		ns.UI.Skin(menu, ns.UI.COLORS.bg, ns.UI.COLORS.edge)
		menu.title = menu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		menu.title:SetPoint("TOPLEFT", 8, -6)
		menu.buttons = {}
		-- Closes once the mouse has been away from it for a moment.
		menu:SetScript("OnUpdate", function(self, elapsed)
			if self.IsMouseOver and self:IsMouseOver() then self.away = 0 return end
			self.away = (self.away or 0) + (elapsed or 0)
			if self.away > 1 then self:Hide() end
		end)
	end
	if menu.SetParent then menu:SetParent(parent) end
	if not menu.hooked then
		menu.hooked = true
		menu:HookScript("OnHide", HideOverlays)
	end
	menu:SetFrameStrata("DIALOG")
	local items = Tab.MenuItems(row)
	menu.title:SetText(row.name)
	for i, item in ipairs(items) do
		local b = menu.buttons[i]
		if not b then
			b = ns.UI.Button(menu, "", 150, 20)
			b.secure, b.secureTried = false, false
			b:SetPoint("TOPLEFT", 6, -6 - i * 22)
			menu.buttons[i] = b
		end
		b:SetText(item[1])
		b:SetScript("OnClick", function() menu:Hide(); item[2]() end)
		b:Show()
		Tab.SetSecure(b, item)
	end
	for i = #items + 1, #menu.buttons do
		menu.buttons[i]:Hide()
		if menu.buttons[i].secure then Tab.SetSecure(menu.buttons[i], nil) end
	end
	menu:SetSize(162, 12 + (#items + 1) * 22)
	menu:ClearAllPoints()
	menu:SetPoint("TOPLEFT", line or parent, "TOPLEFT", line and 180 or 200, line and -4 or -60)
	menu.away, menu.row = 0, row
	menu:Show()
	return items
end

ns.UI.AddPage("Members", "Roster", Build, { order = 10 })

-- New data: rebuild the rows (a moment later, once per burst).
local Soon = ns.Coalesce(function() Tab.Refresh(true) end)
ns.Listen("ROSTER_UPDATED", Soon)
ns.Listen("ROSTER_DETAILS", Soon) -- the Where column shows zones, the tooltip notes
ns.Listen("SYNC_CHANGED", function(set) if set == "alts" or set == "profs" or set == "kills" then Soon() end end)

ns.RegisterCommand("roster", "open the roster", function() ns.UI.Open("Roster") end)
ns.RegisterCommand("inactive", "list members away: /iwt inactive 7|14|30", function(rest)
	local days = tonumber(rest) or 14
	local rows = Tab.Rows({ filter = "all", sort = "where", desc = true, groupAlts = true })
	local n = 0
	for _, r in ipairs(rows) do
		if not r.online and r.offlineDays >= days then
			n = n + 1
			if n <= 30 then ns.Print("%s (%s), %d days", r.name, r.rank, r.offlineDays) end
		end
	end
	ns.Print("%d members away %d days or more (counting alts once).", n, days)
end)
