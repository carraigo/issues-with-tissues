-- Layers and layer hop.
--
-- A zone can run as several copies ("layers"). Every NPC's GUID carries the id of the copy it
-- lives in ("Creature-0-server-instance-ZONEUID-npc-spawn"), so targeting or mousing over any
-- NPC tells us our layer. Guildmates share theirs over guild comms (only while it changes, and
-- when someone logs in and asks). Layer numbers are the guild's own: within a zone, the ids
-- seen this session in order, so "Layer 2" means the same copy for everyone looking.
--
-- Hop: ask a guildmate on another layer for an invite. They get a popup; once you are in their
-- group and your layer changes, you are offered to leave the group again.
--
--   /iwt layer         your layer
--   /iwt hop Name      ask Name for a hop invite

local _, ns = ...

local Layers = ns.RegisterModule("Layers", {})
ns.Layers = Layers

Layers.mine = nil      -- { map, id, zone, at }
Layers.seen = {}       -- character -> { map, id, zone, at }
Layers.known = {}      -- map -> { id = true }   every id seen this session, for numbering
Layers.hop = nil       -- { target, from, at }   a hop we asked for
Layers.SHARE_EVERY = 20   -- seconds between our own layer messages at most
Layers.STALE = 30 * 60    -- a guildmate's layer older than this is not shown

-- The layer id in an NPC's GUID (nil for players, pets and objects).
-- The game can hand out "secret" GUIDs (in combat, on this client) that addons may not read;
-- those are skipped, as reading one is an error.
function Layers.FromGUID(guid)
	if issecretvalue and issecretvalue(guid) then return nil end
	if type(guid) ~= "string" then return nil end
	local ok, kind, zoneUID = pcall(string.match, guid, "^(%a+)%-%d+%-%d+%-%d+%-(%d+)%-%d+%-%x+$")
	if not ok then return nil end
	if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
	return tonumber(zoneUID)
end

local function MapNow()
	local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	local zone = (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or ""
	return map or 0, zone
end

local function Remember(map, id)
	Layers.known[map] = Layers.known[map] or {}
	Layers.known[map][id] = true
end

-- "Layer 2" for an id in a map (by the ids this session has seen there).
function Layers.Number(map, id)
	if not map or not id then return nil end
	Remember(map, id)
	local ids = {}
	for i in pairs(Layers.known[map]) do ids[#ids + 1] = i end
	table.sort(ids)
	for n, i in ipairs(ids) do if i == id then return n end end
end

function Layers.Label(map, id)
	local n = Layers.Number(map, id)
	return n and ("Layer " .. n) or "unknown"
end

---------------------------------------------------------------------------
-- Our layer
---------------------------------------------------------------------------
local lastShare, sharePending = 0, false

function Layers.Share(force)
	local m = Layers.mine
	if not m then return false end
	local now = ns.Now()
	if not force and now - lastShare < Layers.SHARE_EVERY then
		if not sharePending then
			sharePending = true
			ns.After(Layers.SHARE_EVERY - (now - lastShare), function() sharePending = false; Layers.Share(true) end)
		end
		return false
	end
	lastShare = now
	return ns.Comm.Send("LAYER", ns.Comm.Pack(m.map, m.id, m.zone))
end

-- A unit we can see: if it is an NPC, its GUID tells our layer.
function Layers.See(unit)
	if not UnitGUID then return end
	local id = Layers.FromGUID(UnitGUID(unit))
	if not id then return end
	local map, zone = MapNow()
	local old = Layers.mine
	if old and old.map == map and old.id == id then
		old.at = ns.Now()
		return
	end
	Layers.mine = { map = map, id = id, zone = zone, at = ns.Now() }
	Remember(map, id)
	Layers.Share()
	ns.Send("LAYER_CHANGED", old, Layers.mine)
	if Layers.Refresh then Layers.Refresh() end
end

-- Zone change: the old id means nothing here.
local function Forget()
	Layers.mine = nil
	if Layers.Refresh then Layers.Refresh() end
end

pcall(ns.On, "PLAYER_TARGET_CHANGED", function() Layers.See("target") end)
pcall(ns.On, "UPDATE_MOUSEOVER_UNIT", function() Layers.See("mouseover") end)
pcall(ns.On, "NAME_PLATE_UNIT_ADDED", function(_, unit) Layers.See(unit) end)
pcall(ns.On, "ZONE_CHANGED_NEW_AREA", Forget)

---------------------------------------------------------------------------
-- Guildmates' layers
---------------------------------------------------------------------------
ns.Comm.Register("LAYER", function(sender, payload)
	local map, id, zone = ns.Comm.Unpack(payload)
	map, id = tonumber(map), tonumber(id)
	if not map or not id then return end
	Layers.seen[sender] = { map = map, id = id, zone = zone or "", at = ns.Now() }
	Remember(map, id)
	if Layers.Refresh then Layers.Refresh() end
end)

-- Someone logged in and asks: answer if we know ours.
ns.Comm.Register("LAYERQ", function()
	if not Layers.mine then return end
	if ns.Comm.immediate then Layers.Share(true) else ns.After(math.random() * 4, function() Layers.Share(true) end) end
end)

-- Online guildmates with a known layer: { who, map, id, zone, at, member, label, same }.
function Layers.Guildmates()
	local now, rows = ns.Now(), {}
	local mine = Layers.mine
	for who, l in pairs(Layers.seen) do
		local m = ns.Roster.Get(who)
		if m and m.online and now - l.at <= Layers.STALE and who ~= ns.PlayerName() then
			local same
			if mine and mine.map == l.map then same = (mine.id == l.id) and "same" or "other" else same = "zone" end
			rows[#rows + 1] = {
				who = who, map = l.map, id = l.id, zone = l.zone, at = l.at, member = m,
				label = Layers.Label(l.map, l.id), same = same,
			}
		end
	end
	local order = { other = 1, same = 2, zone = 3 }
	table.sort(rows, function(a, b)
		if order[a.same] ~= order[b.same] then return order[a.same] < order[b.same] end
		return a.who < b.who
	end)
	return rows
end

---------------------------------------------------------------------------
-- Hop
---------------------------------------------------------------------------
local lastAsked = {} -- requester -> time, so one guildmate cannot flood us with popups

function Layers.AskHop(name)
	local target = ns.FullName(name)
	if not target or not ns.Roster.IsMember(target) then
		ns.Print("Usage: /iwt hop Name (an online guildmate)")
		return false
	end
	local m = ns.Roster.Get(target)
	if not m.online then
		ns.Print("%s is offline.", ns.Roster.DisplayName(target))
		return false
	end
	if target == ns.PlayerName() then return false end
	Layers.hop = { target = target, from = Layers.mine and Layers.mine.id, at = ns.Now() }
	ns.Comm.Send("HOPQ", ns.Comm.Pack(Layers.mine and Layers.mine.zone or ""), "WHISPER", target)
	ns.Print("Asked %s for a hop invite. Accept it when it comes.", ns.Roster.DisplayName(target))
	return true
end

ns.Comm.Register("HOPQ", function(sender, payload)
	local zone = ns.Comm.Unpack(payload)
	if ns.db.settings.hopRequests == false then
		ns.Comm.Send("HOPA", "off", "WHISPER", sender)
		return
	end
	local now = ns.Now()
	if lastAsked[sender] and now - lastAsked[sender] < 30 then return end
	lastAsked[sender] = now
	Layers.asking = sender
	if StaticPopup_Show then
		StaticPopup_Show("IWT_HOP", ns.Roster.DisplayName(sender), (zone and zone ~= "") and zone or "another layer")
	end
end)

function Layers.AnswerHop(yes)
	local who = Layers.asking
	Layers.asking = nil
	if not who then return false end
	if yes then ns.UI.Invite(who) end
	ns.Comm.Send("HOPA", yes and "yes" or "no", "WHISPER", who)
	return true
end

ns.Comm.Register("HOPA", function(sender, payload)
	local hop = Layers.hop
	if not hop or hop.target ~= sender then return end
	local name = ns.Roster.DisplayName(sender)
	if payload == "yes" then
		ns.Print("%s is inviting you. Once you're in their group, target any NPC to see your new layer.", name)
	elseif payload == "off" then
		ns.Print("%s doesn't take hop requests.", name)
		Layers.hop = nil
	else
		ns.Print("%s said no to the hop.", name)
		Layers.hop = nil
	end
end)

-- After a hop: our layer changed while in the group of the guildmate we asked.
ns.Listen("LAYER_CHANGED", function(old, new)
	local hop = Layers.hop
	if not hop or not old or not new or old.map ~= new.map then return end
	if ns.Now() - hop.at > 300 then Layers.hop = nil return end
	if hop.from and new.id == hop.from then return end
	Layers.hop = nil
	ns.Print("Hopped: you're now on %s.", Layers.Label(new.map, new.id))
	if StaticPopup_Show then StaticPopup_Show("IWT_HOP_DONE", ns.Roster.DisplayName(hop.target)) end
end)

function Layers.LeaveGroup()
	local fn = (C_PartyInfo and C_PartyInfo.LeaveParty) or LeaveParty
	if fn then pcall(fn) end
end

if StaticPopupDialogs then
	StaticPopupDialogs.IWT_HOP = {
		text = "Issues with Tissues: %s asks to hop to your layer (from %s). Invite them to your group?",
		button1 = "Invite",
		button2 = NO or "No",
		OnAccept = function() Layers.AnswerHop(true) end,
		OnCancel = function() Layers.AnswerHop(false) end,
		timeout = 60,
		whileDead = true,
		hideOnEscape = true,
	}
	StaticPopupDialogs.IWT_HOP_DONE = {
		text = "Issues with Tissues: you're now on %s's layer. Leave the group?",
		button1 = "Leave group",
		button2 = "Stay",
		OnAccept = function() Layers.LeaveGroup() end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
	}
end

function Layers:OnLogin()
	ns.After(10, function() ns.Comm.Send("LAYERQ", "") end)
end

---------------------------------------------------------------------------
-- The tab
---------------------------------------------------------------------------
local list, mineText, status

local COLUMNS = {
	{ key = "name", label = "Name", width = 160 },
	{ key = "zone", label = "Zone", width = 150 },
	{ key = "layer", label = "Layer", width = 80 },
	{ key = "same", label = "", width = 130 },
	{ key = "ago", label = "Seen", width = 60 },
}
local SAME_TEXT = {
	same = { "Same layer as you", 0.5, 1, 0.5 },
	other = { "Other layer: click to hop", 1, 0.82, 0 },
	zone = { "Another zone", 0.6, 0.6, 0.6 },
}

function Layers.Refresh()
	ns.UI.RefreshInfo()
	if not Layers.panel or not Layers.panel:IsShown() then return end
	local m = Layers.mine
	if m then
		mineText:SetText(string.format("You: %s, |cff7fd4ff%s|r  |cff999999(id %d)|r", m.zone, Layers.Label(m.map, m.id), m.id))
	else
		mineText:SetText("Your layer is not known yet: target or mouse over any NPC.")
	end
	local rows = Layers.Guildmates()
	local now = ns.Now()
	list:SetRows(rows, function(r, key)
		if key == "name" then return ns.Roster.DisplayName(r.who), ns.UI.ClassColor(r.member.classFile) end
		if key == "zone" then return r.zone end
		if key == "layer" then return r.label end
		if key == "same" then
			local t = SAME_TEXT[r.same]
			return t[1], t[2], t[3], t[4]
		end
		if key == "ago" then return ns.UI.Ago(now - r.at) end
	end)
	status:SetText(#rows == 0 and "No online guildmate has shared a layer yet (they need the addon too)."
		or "Click a guildmate to ask for a hop invite. Hopping works best in the same zone. Right-click to whisper.")
end

local function Build(panel)
	Layers.panel = panel
	mineText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	mineText:SetPoint("TOPLEFT", 4, -4)
	local allow = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	allow:SetPoint("TOPRIGHT", -150, 2)
	local al = allow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	al:SetPoint("LEFT", allow, "RIGHT", 0, 0)
	al:SetText("Take hop requests")
	allow:SetChecked(ns.db.settings.hopRequests ~= false)
	allow:SetScript("OnClick", function(self) ns.db.settings.hopRequests = self:GetChecked() and true or false end)

	list = ns.UI.CreateList(panel, {
		top = -30, rows = 16, columns = COLUMNS,
		onClick = function(r, button)
			if button == "RightButton" then ns.UI.Whisper(r.who) else Layers.AskHop(r.who) end
		end,
		onEnter = function(_, r)
			GameTooltip:AddLine(ns.Roster.DisplayName(r.who), ns.UI.ClassColor(r.member.classFile))
			GameTooltip:AddLine(r.zone .. ", " .. r.label .. " (id " .. r.id .. ")", 1, 1, 1)
			GameTooltip:AddLine("Click: ask for a hop invite. Right-click: whisper.", 0.5, 0.5, 0.5)
		end,
	})
	status = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	status:SetPoint("BOTTOMLEFT", 4, 2)
	panel:SetScript("OnShow", Layers.Refresh)
	Layers.Refresh()
end

-- The Hop tab holds only this page, so it has no sub-tab row; your layer is the page's first line.
ns.UI.AddPage("Hop", "Layers", Build, { order = 10 })
ns.Settings.AddToggle("hopRequests", "Let guildmates ask me for a layer-hop invite")
ns.Listen("ROSTER_UPDATED", function() Layers.Refresh() end)

ns.RegisterCommand("layer", "your layer and guildmates' layers", function()
	local m = Layers.mine
	if m then ns.Print("You: %s, %s (id %d).", m.zone, Layers.Label(m.map, m.id), m.id)
	else ns.Print("Your layer is not known yet: target or mouse over any NPC.") end
	for _, r in ipairs(Layers.Guildmates()) do
		ns.Print("  %s: %s, %s", ns.Roster.DisplayName(r.who), r.zone, r.label)
	end
end)
ns.RegisterCommand("hop", "ask a guildmate for a layer-hop invite: /iwt hop Name", function(rest)
	Layers.AskHop(rest)
end)
