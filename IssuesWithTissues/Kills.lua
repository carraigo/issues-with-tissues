-- Guild kill totals: each character shares its honorable kills and creature kills, and the
-- Home tab adds them up. Only characters running the addon (and still in the guild) count.

local _, ns = ...

local Kills = ns.RegisterModule("Kills", {})
ns.Kills = Kills

-- Data version 2 (1.4.0-beta.2) adds this week's honorable kills: "hk;mobs;s;week;gain".
-- A 1.3 client leaves version 2 records alone (and keeps the last version 1 copy it had).
ns.Sync.Define("kills", { writer = "owner", version = 2,
	upgrade = function(data) return data .. ";0;0" end })

-- "Total kills" in the game's statistics (it includes kills shared with a group). The combat
-- log can't be used instead: this client forbids addons from registering for it.
Kills.STAT_TOTAL = 1197

function Kills.Honor()
	if GetPVPLifetimeStats then
		local ok, hk = pcall(GetPVPLifetimeStats)
		if ok and tonumber(hk) then return tonumber(hk) end
	end
	return 0
end

function Kills.Creatures()
	if GetStatistic then
		local ok, v = pcall(GetStatistic, Kills.STAT_TOTAL)
		v = ok and tonumber(v)
		if v then return v, "stat" end
	end
	return 0, "none"
end

-- Record: "hk;mobs;s|c;week;gain" (s: from the game's statistic, c: counted; week: the weekly
-- reset it counts towards, Kills.Week(); gain: honorable kills since that reset)
function Kills.Encode(k)
	return string.format("%d;%d;%s;%d;%d", k.hk or 0, k.mobs or 0, k.source == "stat" and "s" or "c",
		k.week or 0, k.gain or 0)
end

function Kills.Decode(data)
	local p = ns.Record.Split(data, ";")
	local hk, mobs, src = tonumber(p[1]), tonumber(p[2]), p[3]
	if not hk or not mobs or (src ~= "s" and src ~= "c") then return nil end
	return { hk = hk, mobs = mobs, source = src == "s" and "stat" or "counted",
		week = tonumber(p[4]) or 0, gain = tonumber(p[5]) or 0 }
end
ns.Record.Define("kills", { encode = Kills.Encode, decode = Kills.Decode,
	sample = { hk = 12, mobs = 1500, source = "stat", week = 2968, gain = 4 } })

---------------------------------------------------------------------------
-- The week: Tissue Issuer of the Week is whoever gains the most honorable kills between two
-- weekly resets. A week is named by the time its reset ends it, in whole weeks since 1970.
---------------------------------------------------------------------------
Kills.WEEK = 7 * 86400
-- Without the game's reset timer: Wednesday 07:00 UTC (the EU reset), as seconds into a week
-- counted from 1970's first day, a Thursday.
Kills.RESET_OFFSET = 6 * 86400 + 7 * 3600

function Kills.ResetAt(now)
	now = now or ns.Now()
	local fn = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset
	if fn then
		local ok, secs = pcall(fn)
		if ok and tonumber(secs) and secs > 0 then return now + secs end
	end
	local since = (now - Kills.RESET_OFFSET) % Kills.WEEK
	return now - since + Kills.WEEK
end

function Kills.Week(now)
	return math.floor(Kills.ResetAt(now) / Kills.WEEK)
end

-- Honorable kills since this week's reset: the game's count when it has one, else counted from
-- the total at the first look this week (kept per character).
function Kills.ThisWeek(hk, week)
	if GetPVPThisWeekStats then
		local ok, n = pcall(GetPVPThisWeekStats)
		if ok and tonumber(n) then return tonumber(n) end
	end
	local w = ns.char.hkWeek
	if not w or w.week ~= week then
		w = { week = week, start = hk }
		ns.char.hkWeek = w
	end
	return math.max(0, hk - w.start)
end

-- Share this character's numbers (only when they changed).
function Kills.Share()
	Kills.pending = nil
	local me = ns.PlayerName()
	if not me then return false end
	local mobs, source = Kills.Creatures()
	local hk, week = Kills.Honor(), Kills.Week()
	local data = Kills.Encode({ hk = hk, mobs = mobs, source = source, week = week, gain = Kills.ThisWeek(hk, week) })
	if data == ns.Sync.Get("kills", me) then return false end
	return ns.Sync.Set("kills", me, data)
end

-- Kills come in bursts: share at most every two minutes.
local function Soon()
	if Kills.pending then return end
	Kills.pending = true
	ns.Later("killsEvery", Kills.Share)
end
Kills.Soon = Soon

function Kills.Totals()
	local t = { hk = 0, mobs = 0, chars = 0 }
	for who, data in ns.Sync.Each("kills") do
		local k = ns.Roster.IsMember(who) and Kills.Decode(data)
		if k then
			t.hk, t.mobs, t.chars = t.hk + k.hk, t.mobs + k.mobs, t.chars + 1
		end
	end
	return t
end

-- One character's numbers, or nil when it hasn't shared any (no addon yet).
function Kills.Of(name)
	return Kills.Decode(ns.Sync.Get("kills", ns.FullName(name) or name))
end

-- The guildmate with the most honorable kills: { who, hk }, or nil before anyone has one.
function Kills.EliteSoldier()
	local best
	for who, data in ns.Sync.Each("kills") do
		local k = ns.Roster.IsMember(who) and Kills.Decode(data)
		if k and k.hk > 0 and (not best or k.hk > best.hk or (k.hk == best.hk and who < best.who)) then
			best = { who = who, hk = k.hk }
		end
	end
	return best
end

-- 1234567 -> "1,234,567"
function Kills.Format(n)
	local s = tostring(math.floor(n or 0))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- This week's leader: { who, gain }, or nil before anyone has a kill this week. The best seen
-- is remembered, so the week's winner can go in the guild news once the week is over.
function Kills.WeekLeader(week)
	week = week or Kills.Week()
	local best
	for who, data in ns.Sync.Each("kills") do
		local k = ns.Roster.IsMember(who) and Kills.Decode(data)
		if k and k.week == week and k.gain > 0 and (not best or k.gain > best.gain or (k.gain == best.gain and who < best.who)) then
			best = { who = who, gain = k.gain }
		end
	end
	local db = ns.db
	if best and (not db.weekBest or db.weekBest.week ~= week or best.gain >= db.weekBest.gain) then
		db.weekBest = { week = week, who = best.who, gain = best.gain }
	end
	return best
end

-- A new week: last week's winner goes in the guild news (once).
function Kills.CloseWeek()
	local db, week = ns.db, Kills.Week()
	local b = db.weekBest
	if b and b.week < week and not b.told then
		b.told = true
		if ns.News then
			ns.News.Add("week", b.who, string.format("%s was Tissue Issuer of the Week with %s kills",
				ns.Roster.DisplayName(b.who), Kills.Format(b.gain)), { gain = b.gain })
		end
		return true
	end
	return false
end

-- After each fight (and new honorable kills), share the new numbers.
pcall(ns.On, "PLAYER_REGEN_ENABLED", Soon)
pcall(ns.On, "PLAYER_PVP_KILLS_CHANGED", Soon)

function Kills:OnLogin()
	ns.Later("kills", function()
		Kills.WeekLeader(Kills.Week() - 1) -- last week's records still in, before they move on
		Kills.CloseWeek()
		Kills.Share()
	end)
end
local WeekSoon = ns.Coalesce(function() Kills.WeekLeader(); Kills.CloseWeek() end, 2)
ns.Listen("SYNC_CHANGED", function(set) if set == "kills" then WeekSoon() end end)
