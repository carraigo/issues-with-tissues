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
	{ key = "profs", label = "Professions", width = 180 },
}
Tab.state = { filter = "all", sort = "rankIndex", desc = false, groupAlts = true, offset = 0 }

-- Display name: the roster's own spelling ("Clane Stocious"), without the realm.
local function Short(key)
	return ns.Roster.DisplayName(key)
end

local function ProfText(name)
	local parts = {}
	for _, p in ipairs(ns.Professions.Of(name)) do parts[#parts + 1] = p.name .. " " .. p.rank end
	return table.concat(parts, ", ")
end

local function Where(m)
	if m.online then return m.zone or "" end
	local d = m.offlineDays or 0
	if d == 0 then return "today" end
	return d == 1 and "1 day ago" or (d .. " days ago")
end

-- The rows to show, filtered, grouped and sorted. Each row: the roster entry plus name,
-- alts (when grouped), where, profs.
function Tab.Rows(state)
	state = state or Tab.state
	local filter
	for _, f in ipairs(Tab.FILTERS) do if f.key == state.filter then filter = f end end
	filter = filter or Tab.FILTERS[1]

	-- Group: one entry per main. A main not in the guild (alt in guild, main elsewhere) is
	-- represented by the alt itself.
	local groups = {}
	for full, m in pairs(ns.Roster.members) do
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
			row.profs = ProfText(shown)
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
-- The page
---------------------------------------------------------------------------
local ROWS, ROW_H = 17, 18
local lines, headerButtons, filterButtons, countText = {}, {}, {}, nil

local CLASS_COLORS = RAID_CLASS_COLORS

local function ClassColor(token)
	local c = CLASS_COLORS and token and CLASS_COLORS[token]
	if c then return c.r, c.g, c.b end
	return 1, 1, 1
end

function Tab.Refresh()
	if not Tab.panel or not Tab.panel:IsShown() then return end
	local rows = Tab.Rows()
	local maxOffset = math.max(0, #rows - ROWS)
	if Tab.state.offset > maxOffset then Tab.state.offset = maxOffset end
	for i = 1, ROWS do
		local line, row = lines[i], rows[i + Tab.state.offset]
		if row then
			local x = 0
			for c, col in ipairs(Tab.COLUMNS) do
				local text
				if col.key == "name" then
					if row.mainName then
						text = row.name .. " |cff999999(" .. row.mainName .. ")|r"
					else
						text = row.name .. (#row.alts > 0 and (" |cff999999+" .. #row.alts .. "|r") or "")
					end
				elseif col.key == "hk" then
					text = row.hk >= 0 and ns.Kills.Format(row.hk) or "|cff666666-|r"
				else
					text = tostring(row[col.key] or "")
				end
				line.cells[c]:SetText(text)
				x = x + col.width
			end
			line.cells[1]:SetTextColor(ClassColor(row.classFile))
			local shade = row.online and 1 or 0.6
			for c = 2, #Tab.COLUMNS do line.cells[c]:SetTextColor(shade, shade, shade) end
			line.row = row
			line:Show()
		else
			line.row = nil
			line:Hide()
		end
	end
	for _, b in ipairs(filterButtons) do
		ns.UI.SetSelected(b, b.key == Tab.state.filter)
	end
	local online = 0
	for _, r in ipairs(rows) do if r.online then online = online + 1 end end
	countText:SetText(string.format("%d shown, %d online. Guild: %d members, %d online.",
		#rows, online, ns.Roster.count, ns.Roster.online))
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

local function Build(panel)
	Tab.panel = panel
	-- Filters
	local x = 0
	for _, f in ipairs(Tab.FILTERS) do
		local b = ns.UI.Button(panel)
		b:SetSize(84, 22)
		b:SetPoint("TOPLEFT", x, 0)
		b:SetText(f.label)
		b.key = f.key
		b:SetScript("OnClick", function() Tab.state.filter = f.key; Tab.state.offset = 0; Tab.Refresh() end)
		filterButtons[#filterButtons + 1] = b
		x = x + 88
	end
	local group = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	group:SetPoint("TOPLEFT", x + 4, 1)
	local gl = group:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	gl:SetPoint("LEFT", group, "RIGHT", 0, 0)
	gl:SetText("Group alts")
	group:SetChecked(Tab.state.groupAlts)
	group:SetScript("OnClick", function(self) Tab.state.groupAlts = self:GetChecked() and true or false; Tab.Refresh() end)

	-- Column titles (click to sort; click again to reverse)
	x = 4
	for _, col in ipairs(Tab.COLUMNS) do
		local h = CreateFrame("Button", nil, panel)
		h:SetSize(col.width, 18)
		h:SetPoint("TOPLEFT", x, -30)
		local t = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		t:SetPoint("LEFT")
		t:SetText(col.label)
		h:SetScript("OnClick", function()
			if Tab.state.sort == col.key then Tab.state.desc = not Tab.state.desc
			else Tab.state.sort, Tab.state.desc = col.key, (col.key == "level" or col.key == "hk") end
			Tab.Refresh()
		end)
		headerButtons[#headerButtons + 1] = h
		x = x + col.width
	end

	local rule = ns.UI.Fill(panel:CreateTexture(nil, "BORDER"), ns.UI.COLORS.dim)
	rule:SetPoint("TOPLEFT", 0, -47)
	rule:SetPoint("TOPRIGHT", 0, -47)
	rule:SetHeight(1)

	-- Rows
	for i = 1, ROWS do
		local line = CreateFrame("Button", nil, panel)
		line:SetSize(606, ROW_H)
		line:SetPoint("TOPLEFT", 4, -50 - (i - 1) * ROW_H)
		ns.UI.StyleRow(line, i)
		line.cells = {}
		local cx = 0
		for c, col in ipairs(Tab.COLUMNS) do
			local fs = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			fs:SetPoint("LEFT", cx, 0)
			fs:SetWidth(col.width - 4)
			fs:SetJustifyH("LEFT")
			fs:SetWordWrap(false)
			line.cells[c] = fs
			cx = cx + col.width
		end
		line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		line:SetScript("OnClick", function(self, button)
			if not self.row then return end
			if button == "RightButton" then Tab.Whisper(self.row.tell or self.row.full) end
		end)
		line:SetScript("OnEnter", function(self)
			local r = self.row
			if not r then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
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
			GameTooltip:AddLine("Right-click to whisper", 0.5, 0.5, 0.5)
			GameTooltip:Show()
		end)
		line:SetScript("OnLeave", function() GameTooltip:Hide() end)
		lines[i] = line
	end
	panel:EnableMouseWheel(true)
	panel:SetScript("OnMouseWheel", function(_, delta)
		Tab.state.offset = math.max(0, Tab.state.offset - delta * 3)
		Tab.Refresh()
	end)
	countText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	countText:SetPoint("BOTTOMLEFT", 4, 2)
	panel:SetScript("OnShow", function() ns.Roster.Request(); Tab.Refresh() end)
	Tab.Refresh()
end

ns.UI.AddPage("Members", "Roster", Build, { order = 10 })

ns.Listen("ROSTER_UPDATED", function() Tab.Refresh() end)
ns.Listen("SYNC_CHANGED", function(set) if set == "alts" or set == "profs" or set == "kills" then Tab.Refresh() end end)

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
