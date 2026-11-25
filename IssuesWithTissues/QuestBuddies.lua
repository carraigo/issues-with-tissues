-- Quest buddies (1.4.0): guildmates on the same group quests as you.
--
-- Each character puts the group quests in its log (elite, dungeon and raid quests; solo ones are
-- left out) into its character sheet (Sheet.lua, third field), by quest log heading. Quest names
-- never travel: each PC names the quests in its own log. Shown on Home > Quest buddies, in the
-- quest log (a small "2 guild" beside a quest) and in quest tooltips.
-- Setting: shareQuests (on by default). Off, the field is left empty.

local _, ns = ...

local Q = ns.RegisterModule("QuestBuddies", {})
ns.QuestBuddies = Q

-- Quest tags that mean "bring friends", by name and by the game's tag id.
Q.GROUP_TAGS = { Elite = true, Group = true, Dungeon = true, Raid = true, Heroic = true }
Q.GROUP_TAG_IDS = { [1] = true, [62] = true, [81] = true, [85] = true, [88] = true, [89] = true }
Q.MAX = 25 -- quests shared at most (the game's log holds 20 or 25)

-- What the log held when last read: { { id, title, level, where, tag }, ... }
Q.mine = {}
-- Quests under a collapsed heading can't be read: what was there last time is kept.
local byHeading = {}

local function TagOf(id, suggested)
	local name, tagId
	local fn = (C_QuestLog and C_QuestLog.GetQuestTagInfo) or GetQuestTagInfo
	if fn and id and id > 0 then
		local ok, a, b = pcall(fn, id)
		if ok then
			if type(a) == "table" then tagId, name = a.tagID, a.tagName else tagId, name = a, b end
		end
	end
	if type(suggested) == "string" and suggested ~= "" then name = name or suggested end
	return tagId, name
end

-- Is this a quest to bring friends for?
function Q.IsGroup(tagId, tagName, suggested)
	if tagId and Q.GROUP_TAG_IDS[tagId] then return true end
	if type(tagName) == "string" and Q.GROUP_TAGS[tagName] then return true end
	if type(suggested) == "number" and suggested > 1 then return true end
	if type(suggested) == "string" and Q.GROUP_TAGS[suggested] then return true end
	return false
end

-- One entry of the log: title, level, suggested group, header?, collapsed?, quest id.
local function Entry(i)
	if GetQuestLogTitle then
		-- Classic: title, level, suggestedGroup, isHeader, isCollapsed, isComplete, frequency, questID
		local title, level, suggested, isHeader, isCollapsed, _, _, id = GetQuestLogTitle(i)
		return title, level, suggested, isHeader, isCollapsed, id
	end
	local info = C_QuestLog and C_QuestLog.GetInfo and C_QuestLog.GetInfo(i)
	if type(info) ~= "table" then return nil end
	return info.title, info.level, info.suggestedGroup, info.isHeader, info.isCollapsed, info.questID
end

local function Count()
	local fn = GetNumQuestLogEntries or (C_QuestLog and C_QuestLog.GetNumQuestLogEntries)
	if not fn then return 0 end
	local ok, n = pcall(fn)
	return ok and tonumber(n) or 0
end

-- Read this character's group quests from the log.
function Q.ReadLog()
	local out, heading, collapsed, seenHeadings = {}, "", false, {}
	for i = 1, Count() do
		local title, level, suggested, isHeader, isCollapsed, id = Entry(i)
		title = ns.Readable(title)
		if isHeader then
			heading, collapsed = title or "", isCollapsed and true or false
			seenHeadings[heading] = true
			if collapsed then
				for _, q in ipairs(byHeading[heading] or {}) do out[#out + 1] = q end
			else
				byHeading[heading] = {}
			end
		elseif title and id and id > 0 and not collapsed then
			local tagId, tagName = TagOf(id, suggested)
			if Q.IsGroup(tagId, tagName, suggested) then
				local q = { id = id, title = title, level = tonumber(level) or 0, where = heading, tag = tagName or "Group" }
				out[#out + 1] = q
				byHeading[heading] = byHeading[heading] or {}
				table.insert(byHeading[heading], q)
			end
		end
	end
	for h in pairs(byHeading) do if not seenHeadings[h] then byHeading[h] = nil end end
	while #out > Q.MAX do table.remove(out) end
	Q.mine = out
	return out
end

-- For the sheet: { { where, ids = {} }, ... } (nil when sharing is off).
function Q.ForSheet()
	if ns.db.settings.shareQuests == false then
		Q.mine = {}
		return nil
	end
	local groups, order = {}, {}
	for _, q in ipairs(Q.ReadLog()) do
		if not groups[q.where] then groups[q.where] = { where = q.where, ids = {} }; order[#order + 1] = q.where end
		table.insert(groups[q.where].ids, q.id)
	end
	local out = {}
	for _, w in ipairs(order) do out[#out + 1] = groups[w] end
	return out
end

---------------------------------------------------------------------------
-- Who is on what
---------------------------------------------------------------------------
-- quest id -> { { full, where }, ... } for every guildmate but us; rebuilt when sheets change.
local index, indexGen
function Q.Index()
	if index and indexGen == ns.Sync.gen then return index end
	index, indexGen = {}, ns.Sync.gen
	local me = ns.PlayerName()
	for who, s in pairs(ns.Sheet.All()) do
		if who ~= me and ns.Roster.IsMember(who) then
			for _, g in ipairs(s.quests or {}) do
				for _, id in ipairs(g.ids) do
					index[id] = index[id] or {}
					table.insert(index[id], { full = who, where = g.where })
				end
			end
		end
	end
	return index
end

-- Guildmates on a quest: { { full, name, level, zone, online, classFile }, ... }, online
-- first, then in your zone, then nearest your level.
function Q.On(id)
	local out = {}
	local myZone = GetRealZoneText and GetRealZoneText() or nil
	local myLevel = UnitLevel and UnitLevel("player") or 0
	for _, e in ipairs(Q.Index()[id] or {}) do
		local m = ns.Roster.Get(e.full)
		if m then
			out[#out + 1] = { full = e.full, name = ns.Roster.DisplayName(e.full), level = m.level or 0,
				zone = m.zone, online = m.online, classFile = m.classFile, days = m.offlineDays or 0,
				here = myZone ~= nil and m.zone == myZone }
		end
	end
	table.sort(out, function(a, b)
		if a.online ~= b.online then return a.online end
		if a.here ~= b.here then return a.here end
		local da, db = math.abs(a.level - myLevel), math.abs(b.level - myLevel)
		if da ~= db then return da < db end
		return a.name < b.name
	end)
	return out
end

-- My quests that guildmates share: { { id, title, where, tag, level, buddies = Q.On(id) } }
function Q.Mine()
	local out = {}
	for _, q in ipairs(Q.mine) do
		local buddies = Q.On(q.id)
		if #buddies > 0 then
			out[#out + 1] = { kind = "quest", id = q.id, name = q.title, title = q.title, where = q.where,
				tag = q.tag, level = q.level, buddies = buddies }
		end
	end
	return out
end

-- Online guildmates' group quests by quest log heading (dungeon or zone):
-- { { where, people = { full... }, quests = n, low, high } }, most people first.
function Q.ByPlace()
	local places = {}
	local me = ns.PlayerName()
	for who, s in pairs(ns.Sheet.All()) do
		local m = who ~= me and ns.Roster.Get(who)
		if m and m.online then
			for _, g in ipairs(s.quests or {}) do
				if g.where ~= "" then
					local p = places[g.where]
					if not p then p = { kind = "place", where = g.where, name = g.where, people = {}, ids = {}, quests = 0 }; places[g.where] = p end
					if not p.people[who] then
						p.people[who] = true
						p.count = (p.count or 0) + 1
						p.low = math.min(p.low or m.level or 0, m.level or 0)
						p.high = math.max(p.high or 0, m.level or 0)
					end
					for _, id in ipairs(g.ids) do
						if not p.ids[id] then p.ids[id] = true; p.quests = p.quests + 1 end
					end
				end
			end
		end
	end
	local out = {}
	for _, p in pairs(places) do out[#out + 1] = p end
	table.sort(out, function(a, b) if a.count ~= b.count then return a.count > b.count end return a.where < b.where end)
	return out
end

-- Tooltip lines about a quest (quest log and quest links).
function Q.AddTooltipLines(tooltip, id)
	if not tooltip or not id or ns.db.settings.shareQuests == false then return end
	local buddies = Q.On(id)
	if #buddies == 0 then return end
	tooltip:AddLine("Guildmates on this quest:", 0.25, 1, 0.25)
	for i, b in ipairs(buddies) do
		if i > 8 then tooltip:AddLine("  and " .. (#buddies - 8) .. " more", 0.6, 0.6, 0.6) break end
		local where = b.online and (b.zone or "") or (b.days > 0 and ("offline " .. b.days .. (b.days == 1 and " day" or " days")) or "offline")
		local r, g, bl = 0.7, 0.94, 0.7
		if not b.online then r, g, bl = 0.55, 0.55, 0.55 end
		tooltip:AddLine(string.format("  %s (%d) %s", b.name, b.level, where), r, g, bl)
	end
end

---------------------------------------------------------------------------
-- The quest log: "2 guild" beside quests guildmates share, and tooltip lines. Our own font
-- strings on the game's quest title buttons; nothing of Blizzard's is changed.
---------------------------------------------------------------------------
local function QuestIdAt(at)
	if not GetQuestLogTitle then return nil end
	local ok, _, _, _, isHeader, _, _, _, id = pcall(GetQuestLogTitle, at)
	if ok and not isHeader then return id end
end

local hooked = {}
local function OnTitleEnter(button)
	local id = button.iwtQuest
	if not id or #Q.On(id) == 0 then return end
	if not GameTooltip:IsOwned(button) then GameTooltip:SetOwner(button, "ANCHOR_RIGHT") end
	Q.AddTooltipLines(GameTooltip, id)
	GameTooltip:Show()
end

function Q.UpdateQuestLog()
	if ns.db.settings.shareQuests == false then return end
	local shown = QUESTS_DISPLAYED or 6
	for i = 1, shown do
		local button = _G["QuestLogTitle" .. i]
		if button and button.GetID then
			local id = button:IsShown() and QuestIdAt(button:GetID()) or nil
			local n = id and #Q.On(id) or 0
			button.iwtQuest = id
			if n > 0 and not button.iwtTag then
				button.iwtTag = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
				button.iwtTag:SetPoint("RIGHT", button, "RIGHT", -4, 0)
				button.iwtTag:SetTextColor(0.25, 1, 0.25)
			end
			if button.iwtTag then
				button.iwtTag:SetText(n > 0 and (n .. " guild") or "")
			end
			if not hooked[button] and button.HookScript then
				hooked[button] = true
				button:HookScript("OnEnter", function(self) pcall(OnTitleEnter, self) end)
			end
		end
	end
end

-- Quest links ("quest:123:40") in chat and on item tooltips.
local function OnLink(tooltip, link)
	local id = type(link) == "string" and tonumber(link:match("quest:(%d+)"))
	if id then pcall(Q.AddTooltipLines, tooltip, id); tooltip:Show() end
end

function Q:OnLogin()
	if hooksecurefunc then
		if QuestLog_Update then
			hooksecurefunc("QuestLog_Update", function() pcall(Q.UpdateQuestLog) end)
		end
		for _, t in ipairs({ ItemRefTooltip, GameTooltip }) do
			if t and t.SetHyperlink then hooksecurefunc(t, "SetHyperlink", OnLink) end
		end
	end
end

-- Sharing turned off: the sheet goes out again without the quests.
ns.Settings.OnChange("shareQuests", function() ns.Sheet.Share() end)

---------------------------------------------------------------------------
-- Home > Quest buddies: your group quests that guildmates share, and (By place) which
-- dungeons and zones online guildmates have group quests in.
---------------------------------------------------------------------------
local list

local function Names(buddies, max)
	local out = {}
	for i, b in ipairs(buddies) do
		if i > max then out[#out + 1] = "+" .. (#buddies - max) break end
		out[#out + 1] = (b.online and "|cff40d070" or "|cff8d8d8d") .. b.name .. "|r " .. b.level
	end
	return table.concat(out, ", ")
end

Q.FILTERS = {
	{ key = "mine", label = "My quests" },
	{ key = "place", label = "By place" },
}

local function Source(state)
	if state.filter == "place" then return Q.ByPlace() end
	return Q.Mine()
end

local function Tooltip(_, row)
	if row.kind == "place" then
		GameTooltip:AddLine(row.where)
		local names = {}
		for who in pairs(row.people) do names[#names + 1] = ns.Roster.DisplayName(who) end
		table.sort(names)
		GameTooltip:AddLine(row.count .. " online with " .. row.quests .. (row.quests == 1 and " group quest here" or " group quests here"), 1, 1, 1)
		GameTooltip:AddLine(table.concat(names, ", "), 0.7, 0.94, 0.7, true)
		GameTooltip:AddLine("Click to whisper one of them", 0.5, 0.5, 0.5)
		return
	end
	GameTooltip:AddLine(row.title)
	GameTooltip:AddLine((row.tag or "Group") .. " · " .. row.where .. (row.level > 0 and (" · Level " .. row.level) or ""), 1, 0.82, 0)
	Q.AddTooltipLines(GameTooltip, row.id)
	GameTooltip:AddLine("Click: whisper the first online · Right-click: invite everyone online", 0.5, 0.5, 0.5, true)
end

local function Online(people)
	local out = {}
	for _, b in ipairs(people) do if b.online then out[#out + 1] = b.full end end
	return out
end

local function OnClick(row, button)
	if row.kind == "place" then
		local first
		for who in pairs(row.people) do first = first or who end
		if first then ns.UI.Whisper(first) end
		return
	end
	local online = Online(row.buddies)
	if button == "RightButton" then
		for _, who in ipairs(online) do ns.UI.Invite(who) end
	elseif online[1] then
		ns.UI.Whisper(online[1])
	elseif row.buddies[1] then
		ns.UI.Whisper(row.buddies[1].full)
	end
end

function Q.Refresh()
	if not Q.panel or not Q.panel:IsShown() then return end
	list:Refresh()
end

local function Build(panel)
	Q.panel = panel
	list = ns.UI.CreateList(panel, {
		top = -30, rows = 18, filters = Q.FILTERS, filterWidth = 90, save = "quests", state = {},
		columns = {
			{ key = "name", label = "Quest or place", width = 220 },
			{ key = "where", label = "Where", width = 150 },
			{ key = "who", label = "Guildmates", width = 236 },
		},
		source = Source,
		cell = function(row, key)
			if row.kind == "place" then
				if key == "name" then return row.where, 1, 0.82, 0 end
				if key == "where" then
					local levels = row.low == row.high and ("level " .. row.low) or ("levels " .. row.low .. " to " .. row.high)
					return row.quests .. (row.quests == 1 and " quest, " or " quests, ") .. levels, 0.72, 0.69, 0.63
				end
				if key == "who" then return row.count .. " online", 0.25, 1, 0.25 end
			end
			if key == "name" then
				local tag = row.tag and row.tag ~= "" and (" |cffff8040(" .. row.tag .. ")|r") or ""
				return row.title .. tag
			end
			if key == "where" then return row.where, 0.72, 0.69, 0.63 end
			if key == "who" then return Names(row.buddies, 3) end
		end,
		count = function(shown)
			if list and list.state.filter == "place" then return "Online guildmates' group quests, by dungeon or zone." end
			return #shown .. (#shown == 1 and " of your group quests has" or " of your group quests have") .. " guildmates on them. Hover for who."
		end,
		onClick = OnClick,
		onEnter = Tooltip,
	})
	list:SetEmpty(ns.db.settings.shareQuests == false
		and "Quest sharing is off (Settings: Share my group quests)."
		or "No guildmate shares any of your group quests yet. Elite, dungeon and raid quests show up here as guildmates with this version pick them up.")
	panel:SetScript("OnShow", function() ns.Sheet.Share(); Q.Refresh() end)
	Q.list = list
	Q.Refresh()
end
ns.UI.AddPage("Home", "Quest buddies", Build, { order = 20 })

local Soon = ns.Coalesce(function() Q.Refresh(); pcall(Q.UpdateQuestLog) end)
ns.Listen("ROSTER_UPDATED", Soon)
ns.Listen("SYNC_CHANGED", function(set) if set == "sheet" then Soon() end end)
