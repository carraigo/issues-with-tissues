-- Guild kill totals: each character shares its honorable kills and creature kills, and the
-- Home tab adds them up. Only characters running the addon (and still in the guild) count.

local _, ns = ...

local Kills = ns.RegisterModule("Kills", {})
ns.Kills = Kills

ns.Sync.Define("kills", { writer = "owner" })

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

function Kills.Encode(hk, mobs, source)
	return string.format("%d;%d;%s", hk, mobs, source == "stat" and "s" or "c")
end

function Kills.Decode(data)
	local hk, mobs, src = tostring(data or ""):match("^(%d+);(%d+);(%a)$")
	if not hk then return nil end
	return { hk = tonumber(hk), mobs = tonumber(mobs), source = src == "s" and "stat" or "counted" }
end

-- Share this character's numbers (only when they changed).
function Kills.Share()
	Kills.pending = nil
	local me = ns.PlayerName()
	if not me then return false end
	local mobs, source = Kills.Creatures()
	local data = Kills.Encode(Kills.Honor(), mobs, source)
	if data == ns.Sync.Get("kills", me) then return false end
	return ns.Sync.Set("kills", me, data)
end

-- Kills come in bursts: share at most every two minutes.
local function Soon()
	if Kills.pending then return end
	Kills.pending = true
	ns.After(120, Kills.Share)
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

-- 1234567 -> "1,234,567"
function Kills.Format(n)
	local s = tostring(math.floor(n or 0))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- After each fight (and new honorable kills), share the new numbers.
pcall(ns.On, "PLAYER_REGEN_ENABLED", Soon)
pcall(ns.On, "PLAYER_PVP_KILLS_CHANGED", Soon)

function Kills:OnLogin()
	ns.After(15, Kills.Share)
end
