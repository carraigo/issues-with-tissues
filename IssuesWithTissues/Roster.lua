-- Roster cache: who is in the guild and at which rank. Every receiver uses it to check
-- that a sender really holds the rank a message needs (the game stamps the sender's name;
-- the rank comes from our own copy of the roster, never from the message).

local _, ns = ...

local Roster = ns.RegisterModule("Roster", {})
ns.Roster = Roster

Roster.members = {} -- character name (see ns.FullName) -> { rankIndex, rank, level, class, classFile, zone, online, note, offlineDays, rosterName }
Roster.count, Roster.online = 0, 0
Roster.updated = 0

-- One spelling for a character everywhere: "First Surname" (no realm).
-- WoW: Forever characters have a first name and a surname. The roster writes a name as
-- "First Surname-Realm" or "First-Surname"; UnitName and addon senders give only the first
-- name, and the realm part is an internal id ("CAMWOWEU5Realm6PvP"). Guildmates can share a
-- first name ("Sara Exe", "Sara Best"), so the key is the whole name; a bare first name is
-- resolved through the roster when only one guildmate has it.
local function IsRealm(s)
	local realm = GetNormalizedRealmName and GetNormalizedRealmName()
	return s == realm or s:find("Realm", 1, true) ~= nil
end

-- Spelling only, no roster: "First Surname-Realm", "First-Surname", "First-Surname-Realm",
-- "First-Realm", "First Surname", "First" -> "First Surname" / "First"
function Roster.ParseName(raw)
	if type(raw) ~= "string" then return nil end
	raw = raw:match("^%s*(.-)%s*$")
	if raw == "" then return nil end
	local base, suffix = raw:match("^(.-)%-(.+)$")
	if not base or base == "" then return raw end
	if base:find(" ", 1, true) then return base end
	local surname = suffix:match("^([^%-]+)%-") or suffix
	if IsRealm(surname) then return base end
	return base .. " " .. surname
end

function Roster.FirstName(name)
	local key = Roster.ParseName(name)
	return key and key:match("^(%S+)")
end

Roster.byFirst = {} -- first name -> { key, ... }

function ns.FullName(name)
	local key = Roster.ParseName(name)
	if not key or key:find(" ", 1, true) then return key end
	local list = Roster.byFirst[key]
	if list and #list == 1 then return list[1] end
	return key
end

-- This character's key. Found in the roster by GUID (exact), else by UnitFullName's surname,
-- else as the only guildmate with our first name; remembered for the next login.
Roster.me, Roster.meHow = nil, "not yet"
function ns.PlayerName()
	if Roster.me then return Roster.me end
	if ns.char and ns.char.me and Roster.FirstName(ns.char.me) == UnitName("player") then return ns.char.me end
	return ns.FullName(UnitName("player"))
end

local function FindMe(guids)
	local first = UnitName and UnitName("player")
	if not first then return end
	local guid = UnitGUID and UnitGUID("player")
	if guid and guids[guid] then return guids[guid], "guid" end
	if UnitFullName then
		local f, second = UnitFullName("player")
		if f == first and type(second) == "string" and second ~= "" and not IsRealm(second) then
			local key = first .. " " .. second
			if Roster.members[key] then return key, "surname" end
		end
	end
	local list = Roster.byFirst[first]
	if list and #list == 1 then return list[1], "only one " .. first end
	if list then return nil, #list .. " guildmates named " .. first end
	return nil, "not in roster"
end

-- Whole days since the member was last online (0 while online or unknown).
function Roster.OfflineDays(i, isOnline)
	if isOnline or not GetGuildRosterLastOnline then return 0 end
	local y, m, d = GetGuildRosterLastOnline(i)
	if not y then return 0 end
	return (y or 0) * 365 + (m or 0) * 30 + (d or 0)
end

function Roster.Scan()
	if not IsInGuild or not IsInGuild() then
		wipe(Roster.members)
		Roster.count, Roster.online = 0, 0
		return
	end
	local n = GetNumGuildMembers() or 0
	if n == 0 then return end -- roster not loaded yet; keep the old copy
	local fresh, online, byFirst, guids = {}, 0, {}, {}
	for i = 1, n do
		local name, rank, rankIndex, level, classLocal, zone, note, officerNote, isOnline, _, classFile,
			_, _, _, _, _, guid = GetGuildRosterInfo(i)
		local full = Roster.ParseName(name)
		if full then
			local first = full:match("^(%S+)")
			byFirst[first] = byFirst[first] or {}
			table.insert(byFirst[first], full)
			if guid then guids[guid] = full end
			fresh[full] = {
				rankIndex = rankIndex, rank = rank, level = level, class = classLocal, classFile = classFile,
				zone = zone, online = isOnline and true or false, note = note,
				officerNote = officerNote, -- empty unless this rank may see officer notes
				offlineDays = Roster.OfflineDays(i, isOnline), rosterName = name,
			}
			if isOnline then online = online + 1 end
		end
	end
	if n ~= Roster.count or online ~= Roster.online then
		ns.Trace("roster", "Roster: %d members, %d online", n, online)
	end
	Roster.members, Roster.count, Roster.online, Roster.byFirst = fresh, n, online, byFirst
	local me, how = FindMe(guids)
	Roster.me, Roster.meHow = me, how
	if me and ns.char then ns.char.me = me end
	Roster.updated = ns.Now()
	ns.Send("ROSTER_UPDATED")
end

-- A copy of the roster in the saved data, written on logout and /reload, for tools outside
-- the game (the guild web page export). No notes: only what the roster shows everyone.
function Roster.Snapshot()
	local list = {}
	for key, m in pairs(Roster.members) do
		list[#list + 1] = { name = key, level = m.level, class = m.class, classFile = m.classFile,
			rank = m.rank, rankIndex = m.rankIndex, days = m.offlineDays or 0 }
	end
	if #list == 0 then return nil end
	return { at = ns.Now(), guild = GetGuildInfo and GetGuildInfo("player") or nil, version = ns.VERSION, members = list }
end
pcall(ns.On, "PLAYER_LOGOUT", function()
	local snap = Roster.Snapshot()
	if snap and ns.db then ns.db.snapshot = snap end
end)

-- The name to show: the key is already "First Surname".
function Roster.DisplayName(key)
	return ns.FullName(key) or key or ""
end

-- Everyone with this character's first name ("Sara" -> "Sara Exe", "Sara Best").
function Roster.SameFirstName(name)
	local first = Roster.FirstName(name)
	return first and Roster.byFirst[first] or {}
end

function Roster.Get(name)
	local full = ns.FullName(name)
	return full and Roster.members[full]
end

function Roster.IsMember(name)
	return Roster.Get(name) ~= nil
end

-- Officers: rankIndex 0 (Guild Master) through settings.officerMaxRank (1 = Officer).
-- strict (used for anything that arrives over comms): the game cannot tell guildmates with the
-- same first name apart, so every one of them must be an officer.
function Roster.IsOfficer(name, strict)
	local m = Roster.Get(name)
	if not m then return false end
	local max = ns.db and ns.db.settings.officerMaxRank or 1
	if strict then
		for _, other in ipairs(Roster.SameFirstName(name)) do
			local o = Roster.members[other]
			if not o or o.rankIndex == nil or o.rankIndex > max then return false end
		end
	end
	return m.rankIndex ~= nil and m.rankIndex <= max
end

function Roster.IsGuildMaster(name)
	local m = Roster.Get(name)
	return m ~= nil and m.rankIndex == 0
end

-- Rank names in order, for the settings page.
function Roster.RankNames()
	local names = {}
	if GuildControlGetNumRanks and GuildControlGetRankName then
		for i = 1, GuildControlGetNumRanks() do names[i] = GuildControlGetRankName(i) end
	end
	return names
end

local requested = 0
function Roster.Request()
	local now = ns.Now()
	if now - requested < 10 then return end
	requested = now
	if C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	elseif GuildRoster then
		GuildRoster()
	end
end

function Roster:OnLogin()
	Roster.Request()
end

ns.On("GUILD_ROSTER_UPDATE", function() Roster.Scan() end)
ns.On("PLAYER_GUILD_UPDATE", function() Roster.Request() end)
