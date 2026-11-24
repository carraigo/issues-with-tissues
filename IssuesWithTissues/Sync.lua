-- Shared data sets that every guildmate's addon keeps a copy of (loot notes, polls,
-- alt links, professions...). Each set is a table of records by key; a record carries a
-- revision (server time of the change), who wrote it, and its data as a string.
--
--   Sync.Define("loot", { writer = "officer" })   any officer may write any record
--   Sync.Define("alts", { writer = "owner" })     a record's key is its author's name
--   Sync.Set("loot", id, data)  /  Sync.Delete("loot", id)  /  Sync.Get / Sync.Each
--   ns.Listen("SYNC_CHANGED", function(set, key, record) ... end)
--
-- This file holds the records: storing, accepting, live changes (SU), data versions and old
-- name migration. Catching up with the guild (SQ, SR, SC and the rounds) is SyncCatchUp.lua.
--
-- Messages (GUILD):
--   SU  set,key,rev,by,deleted,data           one change, sent as it is made
-- A record carries its set's data version (field 7; missing = 1). When a set's data format
-- changes, Define it with a higher version and an upgrade function: older records are upgraded
-- as they arrive or load, and records from a newer version than this client knows are left
-- alone, so an old client never stores data it would misread.
-- Saved variables may be wiped (the Forever beta did this every login), so at login the
-- addon asks the guild and rebuilds from whoever is online (SyncCatchUp.lua).

local _, ns = ...

local Sync = ns.RegisterModule("Sync", {})
ns.Sync = Sync

Sync.sets = {}
-- This session's catch-up numbers, for the stats saved at logout (Diagnostics).
Sync.stats = { asks = 0, rounds = 0, got = 0, new = 0, answered = 0, answeredRecords = 0 }
Sync.gen = 0 -- goes up whenever a record changes (caches of decoded data check it)
Sync.ANSWER_DELAY_MAX = 3      -- seconds; a random wait so one guildmate answers
Sync.DELETED_KEEP = 30 * 86400 -- keep deletion marks so an old copy can't bring a record back
local RS = "\30"

local Comm -- set in OnLoad (Comm loads before Sync)

local function Store(name)
	local db = ns.db.sync
	db[name] = db[name] or { records = {} }
	return db[name].records
end

function Sync.Define(name, opts)
	assert(not name:find("[\30\31=,]"), "bad set name")
	opts = opts or {}
	Sync.sets[name] = { writer = opts.writer or "officer", max = opts.max,
		version = opts.version or 1, upgrade = opts.upgrade }
end

-- Bring a record up to its set's data version. False: it's from a newer version than ours.
function Sync.Upgrade(name, rec)
	local def = Sync.sets[name]
	local v = tonumber(rec.v) or 1
	if not def or v > def.version then return false end
	if v < def.version then
		if def.upgrade and not rec.deleted then
			local ok, data = pcall(def.upgrade, rec.data or "", v)
			if not ok or type(data) ~= "string" then return false end
			rec.data = data
		end
		rec.v = def.version
	end
	if rec.v == 1 then rec.v = nil end -- version 1 is the default; not saved
	return true
end

-- May `by` write record `key` of set `name`?
function Sync.CanWrite(name, key, by)
	local def = Sync.sets[name]
	if not def or not by then return false end
	if def.writer == "owner" then return ns.FullName(key) == ns.FullName(by) and ns.Roster.IsMember(by) end
	if def.writer == "member" then return ns.Roster.IsMember(by) end
	return ns.Roster.IsOfficer(by)
end

-- Records in our own name that this character never wrote: someone posed as us (or relayed a
-- made-up record). Only records newer than this character's write log are judged, so a client
-- whose saved data was wiped still takes its own old records back from guildmates.
function Sync.IsForged(name, key, rec)
	local c = ns.char
	if not c or not c.writeLogSince or rec.by ~= ns.PlayerName() then return false end
	if rec.rev <= c.writeLogSince then return false end
	local mine = c.written and c.written[name .. "\1" .. key]
	return not mine or rec.rev > mine
end

local function Serialize(name, key, r)
	return ns.Comm.Pack(name, key, r.rev, r.by, r.deleted and "1" or "", r.data or "", r.v or 1)
end

local function Deserialize(s)
	local name, key, rev, by, deleted, data, v = ns.Comm.Unpack(s)
	rev = tonumber(rev)
	if not name or not key or key == "" or not rev then return nil end
	return name, key, { rev = rev, by = by, deleted = deleted == "1", data = data or "", v = tonumber(v) }
end

-- Take a record if it is allowed and newer than ours. Returns true when it changed something.
function Sync.Accept(name, key, rec)
	if not Sync.sets[name] or not Sync.CanWrite(name, key, rec.by) then return false end
	if rec.data and (rec.data:find(RS, 1, true) or rec.data:find(Comm.SEP, 1, true)) then return false end
	if rec.rev > ns.Now() + 300 then return false end -- from the future: never let it win for good
	if not Sync.Upgrade(name, rec) then
		Sync.newer = (Sync.newer or 0) + 1 -- from a guildmate on a newer version
		return false
	end
	local store = Store(name)
	local old = store[key]
	if old and old.rev >= rec.rev then return false end
	if Sync.IsForged(name, key, rec) then
		Sync.Heal(name, key, rec.rev)
		return false
	end
	store[key] = rec
	Sync.gen = Sync.gen + 1
	Sync.Trim(name)
	Sync.NoteTaken(name, key, rec)
	ns.Send("SYNC_CHANGED", name, key, rec)
	return true
end

-- For the live log: new records are added up and logged once per burst ("Took 120 new records:
-- recipes 80, profs 40"), not one line each.
local tookSets, takenKeys, takenCount = {}, {}, 0
local function LogTaken()
	if takenCount == 0 then return end
	local parts = {}
	for set, n in pairs(tookSets) do parts[#parts + 1] = set .. " " .. n end
	table.sort(parts)
	local detail = takenCount <= 3 and (" (" .. table.concat(takenKeys, ", ") .. ")") or ""
	ns.Trace("data", "Took %d new record%s: %s%s", takenCount, takenCount == 1 and "" or "s", table.concat(parts, ", "), detail)
	tookSets, takenKeys, takenCount = {}, {}, 0
end
local logTakenSoon = ns.Coalesce(LogTaken, 1)
function Sync.NoteTaken(name, key, rec)
	tookSets[name] = (tookSets[name] or 0) + 1
	takenCount = takenCount + 1
	if takenCount <= 3 then takenKeys[takenCount] = name .. " " .. key .. (rec.deleted and " deleted" or "") .. " by " .. tostring(rec.by) end
	logTakenSoon()
end

-- Keep a set under its size limit by dropping the oldest records.
function Sync.Trim(name)
	local def = Sync.sets[name]
	if not def or not def.max then return end
	local store = Store(name)
	local list = {}
	for k, r in pairs(store) do list[#list + 1] = { k = k, rev = r.rev } end
	if #list <= def.max then return end
	table.sort(list, function(a, b) return a.rev > b.rev end)
	for i = def.max + 1, #list do store[list[i].k] = nil end
	Sync.gen = Sync.gen + 1
end

local function Write(name, key, data, deleted, minRev)
	local me = ns.PlayerName()
	if not Sync.CanWrite(name, key, me) then
		ns.Log("sync: %s may not write %s/%s (in roster: %s, officer: %s)", tostring(me), name, tostring(key),
			tostring(ns.Roster.IsMember(me)), tostring(ns.Roster.IsOfficer(me)))
		return false, "not allowed"
	end
	data = tostring(data or ""):gsub("[\30\31]", "")
	local store = Store(name)
	local old = store[key]
	local rev = ns.Now()
	if old and old.rev >= rev then rev = old.rev + 1 end
	if minRev and rev <= minRev then rev = minRev + 1 end
	local v = Sync.sets[name].version
	local rec = { rev = rev, by = me, deleted = deleted or nil, data = deleted and "" or data, v = v > 1 and v or nil }
	if ns.char then
		ns.char.written = ns.char.written or {}
		ns.char.written[name .. "\1" .. key] = rev
	end
	store[key] = rec
	Sync.gen = Sync.gen + 1
	ns.Trace("mine", "%s your %s record (%s, %d bytes)", deleted and "Deleted" or "Shared", name, key, #rec.data)
	ns.Send("SYNC_CHANGED", name, key, rec)
	Comm.Send("SU", Serialize(name, key, rec))
	return true
end

function Sync.Set(name, key, data) return Write(name, key, data, false) end

-- Put our own version back out, newer than the record someone wrote in our name.
function Sync.Heal(name, key, theirRev)
	local cur = Store(name)[key]
	ns.ReportError(string.format("sync: someone wrote %s/%s in your name; your version was sent back", name, key))
	if cur and not cur.deleted then return Write(name, key, cur.data, false, theirRev) end
	return Write(name, key, "", true, theirRev)
end
function Sync.Delete(name, key) return Write(name, key, "", true) end

function Sync.Get(name, key)
	local r = Store(name)[key]
	if r and not r.deleted then return r.data, r end
end

-- Iterate live records: for key, data, record in Sync.Each("loot") do ... end
function Sync.Each(name)
	local store = Store(name)
	local k
	return function()
		local r
		repeat
			k, r = next(store, k)
		until k == nil or not r.deleted
		if k ~= nil then return k, r.data, r end
	end
end

function Sync.MaxRev(name)
	local max = 0
	for _, r in pairs(Store(name)) do if r.rev > max then max = r.rev end end
	return max
end

function Sync.Prune()
	local cutoff = ns.Now() - Sync.DELETED_KEEP
	for name in pairs(Sync.sets) do
		local store = Store(name)
		for k, r in pairs(store) do
			if r.deleted and r.rev < cutoff then store[k] = nil end
		end
	end
	Sync.gen = Sync.gen + 1
end

Comm = ns.Comm

Comm.Register("SU", function(sender, payload, _, _, verified)
	local name, key, rec = Deserialize(payload)
	if not name or ns.FullName(rec.by) ~= sender then return end -- a live change is the sender's own
	-- Sender known only by first name: officer data needs every guildmate with it to be an officer.
	local def = Sync.sets[name]
	if not verified and def and def.writer == "officer" and not ns.Roster.IsOfficer(sender, true) then return end
	Sync.Accept(name, key, rec)
end)

function Sync:OnLoad()
	ns.char.writeLogSince = ns.char.writeLogSince or ns.Now()
	-- Sets of features that were taken out (0.6.0: the calendar and the Groups board).
	for name in pairs(ns.db.sync) do
		if not Sync.sets[name] then ns.db.sync[name] = nil end
	end
	Sync.UpgradeSaved()
	Sync.Prune()
end

-- Saved records from before a set's data format changed are upgraded at load; any the upgrade
-- can't read are dropped, and a guildmate will send them again in the new format.
function Sync.UpgradeSaved()
	for name, set in pairs(ns.db.sync) do
		for key, rec in pairs(set.records or {}) do
			if not Sync.Upgrade(name, rec) then set.records[key] = nil end
		end
	end
end

-- Version 0.2 saved characters by first name alone ("Large"); now they are "Large Joseph".
-- Once the roster is in, rename what it can resolve (a first name only one guildmate has).
local function Up(name)
	if type(name) ~= "string" or name == "" or name:find(" ", 1, true) then return name end
	return ns.FullName(name)
end
Sync.renameKey = {
	recipes = function(key)
		local who, prof = key:match("^(.-)#(.*)$")
		if who then return Up(who) .. "#" .. prof end
		return key
	end,
}
Sync.renameData = { alts = Up } -- an alt record's data is its main

function Sync.MigrateNames()
	local changed = 0
	for name, set in pairs(ns.db.sync) do
		local fresh = {}
		local rk = Sync.renameKey[name] or (Sync.sets[name] and Sync.sets[name].writer == "owner" and Up)
		local rd = Sync.renameData[name]
		for key, rec in pairs(set.records or {}) do
			local k = rk and rk(key) or key
			local by = Up(rec.by)
			local data = rd and not rec.deleted and rd(rec.data) or rec.data
			if k ~= key or by ~= rec.by or data ~= rec.data then changed = changed + 1 end
			rec.by, rec.data = by, data
			if not fresh[k] or fresh[k].rev < rec.rev then fresh[k] = rec end
		end
		set.records = fresh
		Sync.gen = Sync.gen + 1
	end
	if changed > 0 then ns.Log("names: %d saved records now use first name and surname", changed) end
	return changed
end

local migrated = false
ns.Listen("ROSTER_UPDATED", function()
	if migrated or ns.Roster.count == 0 then return end
	migrated = true
	Sync.MigrateNames()
	ns.Send("SYNC_CHANGED")
end)

-- A catch-up: a first round, then more while they bring something new.
-- For SyncCatchUp.lua.
Sync.Store, Sync.Serialize, Sync.Deserialize, Sync.RS = Store, Serialize, Deserialize, RS

