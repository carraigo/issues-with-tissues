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
-- Every roster scan and every addon message parses names, so results are remembered (names
-- are few: the guild and whoever sends to it).
local parsed, parsedCount = {}, 0
local function Parse(raw)
	raw = raw:match("^%s*(.-)%s*$")
	if raw == "" then return nil end
	local base, suffix = raw:match("^(.-)%-(.+)$")
	if not base or base == "" then return raw end
	if base:find(" ", 1, true) then return base end
	local surname = suffix:match("^([^%-]+)%-") or suffix
	if IsRealm(surname) then return base end
	return base .. " " .. surname
end
function Roster.ParseName(raw)
	raw = ns.Readable(raw)
	if not raw then return nil end
	local key = parsed[raw]
	if key == nil then
		if parsedCount >= 2000 then wipe(parsed) parsedCount = 0 end
		key = Parse(raw) or false
		parsed[raw], parsedCount = key, parsedCount + 1
	end
	return key or nil
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

local function FindMe(byGuid)
	local first = UnitName and UnitName("player")
	if not first then return end
	if byGuid then return byGuid, "guid" end
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

-- The game sends roster updates often (every few seconds while the guild window is open),
-- usually with nothing new, so a scan is the addon's busiest job. It updates the member tables
-- in place and spots changes while reading, instead of building a fresh copy and comparing.
-- Pages hear only about what changed: ROSTER_UPDATED for who is in the guild, online, rank,
-- level or last seen; ROSTER_DETAILS for zones and notes only.
local scanId, seenIn = 0, {}
function Roster.Scan()
	if not IsInGuild or not IsInGuild() then
		wipe(Roster.members)
		wipe(seenIn)
		Roster.count, Roster.online = 0, 0
		return
	end
	local n = GetNumGuildMembers() or 0
	if n == 0 then return end -- roster not loaded yet; keep the old copy
	scanId = scanId + 1
	local members, what, online, seen, known = Roster.members, nil, 0, 0, 0
	local myGuid, byGuid = UnitGUID and UnitGUID("player"), nil
	for _ in pairs(members) do known = known + 1 end
	for i = 1, n do
		local name, rank, rankIndex, level, classLocal, zone, note, officerNote, isOnline, _, classFile,
			_, _, _, _, _, guid = GetGuildRosterInfo(i)
		local full = Roster.ParseName(name)
		if full and seenIn[full] ~= scanId then
			seenIn[full] = scanId
			isOnline = isOnline and true or false
			local days = Roster.OfflineDays(i, isOnline)
			local m = members[full]
			if not m then
				m = {}
				members[full] = m
				what = "members"
			else
				seen = seen + 1
				if what ~= "members" then
					if m.rankIndex ~= rankIndex or m.rank ~= rank or m.level ~= level or m.classFile ~= classFile
						or m.online ~= isOnline or m.offlineDays ~= days then
						what = "members"
					elseif not what and (m.zone ~= zone or m.note ~= note or m.officerNote ~= officerNote) then
						what = "details"
					end
				end
			end
			m.rankIndex, m.rank, m.level, m.class, m.classFile = rankIndex, rank, level, classLocal, classFile
			m.zone, m.online, m.note, m.rosterName = zone, isOnline, note, name
			m.officerNote = officerNote -- empty unless this rank may see officer notes
			m.offlineDays = days
			if guid and guid == myGuid then byGuid = full end
			if isOnline then online = online + 1 end
		end
	end
	if seen < known then -- someone left
		what = "members"
		for key in pairs(members) do
			if seenIn[key] ~= scanId then members[key], seenIn[key] = nil, nil end
		end
	end
	if n ~= Roster.count or online ~= Roster.online then
		ns.Trace("roster", "Roster: %d members, %d online", n, online)
	end
	Roster.count, Roster.online = n, online
	if what == "members" then -- names only change when members do
		local byFirst = {}
		for key in pairs(members) do
			local first = key:match("^(%S+)")
			local list = byFirst[first]
			if not list then list = {} byFirst[first] = list end
			list[#list + 1] = key
		end
		for _, list in pairs(byFirst) do table.sort(list) end
		Roster.byFirst = byFirst
	end
	local me, how = FindMe(byGuid)
	local meChanged = me ~= Roster.me
	Roster.me, Roster.meHow = me, how
	if me and ns.char then ns.char.me = me end
	Roster.updated = ns.Now()
	if what == "members" or meChanged then
		ns.Send("ROSTER_UPDATED")
	elseif what == "details" then
		ns.Send("ROSTER_DETAILS")
	end
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

-- The game can send several roster updates a second (more while the guild window is open).
-- Scan at most once per SCAN_GAP seconds: the first at once, then one more after the gap for
-- anything that came in meanwhile. (Without GetTime, as in tests, every update scans.)
Roster.SCAN_GAP = 1
local lastScan, scanWaiting = nil, false
function Roster.ScanSoon()
	local now = GetTime and GetTime()
	if not now then return Roster.Scan() end
	if scanWaiting then return end
	if not lastScan or now - lastScan >= Roster.SCAN_GAP then
		lastScan = now
		return Roster.Scan()
	end
	scanWaiting = true
	ns.After(Roster.SCAN_GAP - (now - lastScan), function()
		scanWaiting = false
		lastScan = GetTime()
		Roster.Scan()
	end)
end
ns.On("GUILD_ROSTER_UPDATE", function() Roster.ScanSoon() end)
ns.On("PLAYER_GUILD_UPDATE", function() Roster.Request() end)
