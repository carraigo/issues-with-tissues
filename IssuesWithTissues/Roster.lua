-- Roster cache: who is in the guild and at which rank. Every receiver uses it to check
-- that a sender really holds the rank a message needs (the game stamps the sender's name;
-- the rank comes from our own copy of the roster, never from the message).

local _, ns = ...

local Roster = ns.RegisterModule("Roster", {})
ns.Roster = Roster

Roster.members = {} -- full name ("Name-Realm") -> { rankIndex, rank, level, class, zone, online, note }
Roster.count, Roster.online = 0, 0
Roster.updated = 0

-- "Name" or "Name-Realm" -> "Name-Realm"
function ns.FullName(name)
	if type(name) ~= "string" or name == "" then return nil end
	if name:find("-", 1, true) then return name end
	local realm = GetNormalizedRealmName and GetNormalizedRealmName()
	if not realm or realm == "" then return name end
	return name .. "-" .. realm
end

function ns.PlayerName()
	return ns.FullName(UnitName("player"))
end

function Roster.Scan()
	if not IsInGuild or not IsInGuild() then
		wipe(Roster.members)
		Roster.count, Roster.online = 0, 0
		return
	end
	local n = GetNumGuildMembers() or 0
	if n == 0 then return end -- roster not loaded yet; keep the old copy
	local fresh, online = {}, 0
	for i = 1, n do
		local name, rank, rankIndex, level, _, zone, note, _, isOnline, _, class = GetGuildRosterInfo(i)
		local full = ns.FullName(name)
		if full then
			fresh[full] = {
				rankIndex = rankIndex, rank = rank, level = level, class = class,
				zone = zone, online = isOnline and true or false, note = note,
			}
			if isOnline then online = online + 1 end
		end
	end
	Roster.members, Roster.count, Roster.online = fresh, n, online
	Roster.updated = ns.Now()
	ns.Send("ROSTER_UPDATED")
end

function Roster.Get(name)
	local full = ns.FullName(name)
	return full and Roster.members[full]
end

function Roster.IsMember(name)
	return Roster.Get(name) ~= nil
end

-- Officers: rankIndex 0 (Guild Master) through settings.officerMaxRank (1 = Officer).
function Roster.IsOfficer(name)
	local m = Roster.Get(name)
	if not m then return false end
	local max = ns.db and ns.db.settings.officerMaxRank or 1
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
