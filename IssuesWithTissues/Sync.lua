-- Shared data sets that every guildmate's addon keeps a copy of (loot notes, polls,
-- alt links, professions...). Each set is a table of records by key; a record carries a
-- revision (server time of the change), who wrote it, and its data as a string.
--
--   Sync.Define("loot", { writer = "officer" })   any officer may write any record
--   Sync.Define("alts", { writer = "owner" })     a record's key is its author's name
--   Sync.Set("loot", id, data)  /  Sync.Delete("loot", id)  /  Sync.Get / Sync.Each
--   ns.Listen("SYNC_CHANGED", function(set, key, record) ... end)
--
-- Messages (GUILD):
--   SU  set,key,rev,by,deleted,data           one change, sent as it is made
--   SQ  nonce, then set=maxRev for each set   "I'm missing anything newer than these"
--   SR  nonce \30 record \30 record ...       an answer; one guildmate answers each ask
-- Saved variables may be wiped (the Forever beta did this every login), so at login the
-- addon asks the guild and rebuilds from whoever is online.

local _, ns = ...

local Sync = ns.RegisterModule("Sync", {})
ns.Sync = Sync

Sync.sets = {}
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
	Sync.sets[name] = { writer = (opts and opts.writer) or "officer", max = opts and opts.max }
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
	return ns.Comm.Pack(name, key, r.rev, r.by, r.deleted and "1" or "", r.data or "")
end

local function Deserialize(s)
	local name, key, rev, by, deleted, data = ns.Comm.Unpack(s)
	rev = tonumber(rev)
	if not name or not key or key == "" or not rev then return nil end
	return name, key, { rev = rev, by = by, deleted = deleted == "1", data = data or "" }
end

-- Take a record if it is allowed and newer than ours. Returns true when it changed something.
function Sync.Accept(name, key, rec)
	if not Sync.sets[name] or not Sync.CanWrite(name, key, rec.by) then return false end
	if rec.data and (rec.data:find(RS, 1, true) or rec.data:find(Comm.SEP, 1, true)) then return false end
	if rec.rev > ns.Now() + 300 then return false end -- from the future: never let it win for good
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
	ns.Send("SYNC_CHANGED", name, key, rec)
	return true
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
	local rec = { rev = rev, by = me, deleted = deleted or nil, data = deleted and "" or data }
	if ns.char then
		ns.char.written = ns.char.written or {}
		ns.char.written[name .. "\1" .. key] = rev
	end
	store[key] = rec
	Sync.gen = Sync.gen + 1
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
end

---------------------------------------------------------------------------
-- Catch-up
---------------------------------------------------------------------------
local answered = {}  -- nonce -> { [set .. "=" .. digest] = true } for answers already heard

-- A fingerprint of everything held in a set (deletion marks included): two clients with the
-- same fingerprint hold the same records. Comparing only the newest revision missed records:
-- one fresh change from someone would hide every older record the asker never had.
local function Hash(str)
	local h = 5381
	for i = 1, #str do h = (h * 33 + str:byte(i)) % 2147483647 end
	return h
end

function Sync.Digest(name)
	local n, sum = 0, 0
	for key, r in pairs(Store(name)) do
		n = n + 1
		sum = (sum + Hash(key .. "\1" .. r.rev .. (r.deleted and "d" or ""))) % 2147483647
	end
	return n .. "." .. sum
end

function Sync.Ask()
	local parts = { tostring(math.random(1, 2 ^ 30)) }
	for name in pairs(Sync.sets) do parts[#parts + 1] = name .. "=" .. Sync.MaxRev(name) .. ":" .. Sync.Digest(name) end
	Comm.Send("SQ", table.concat(parts, ","))
	Sync.lastAsk = ns.Now()
end

-- What to send an asker: for a set whose fingerprint differs from theirs, every record we
-- hold (they may lack old ones); without a fingerprint, records newer than their newest.
-- wants = { set = { since = rev, digest = "n.h" or nil } }; skip = { set = true }.
function Sync.BuildAnswer(wants, skip)
	local out = {}
	for name, want in pairs(wants) do
		if type(want) == "number" then want = { since = want } end
		local def = Sync.sets[name]
		if def and not (skip and skip[name]) and want.digest ~= Sync.Digest(name) then
			local since = want.digest and -1 or want.since
			for key, r in pairs(Store(name)) do
				if r.rev > since then out[#out + 1] = { rev = r.rev, s = Serialize(name, key, r) } end
			end
		end
	end
	table.sort(out, function(a, b) return a.rev > b.rev end)
	local strings = {}
	for i, o in ipairs(out) do strings[i] = o.s end
	return strings
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

Comm.Register("SQ", function(sender, payload)
	local fields = {}
	for f in (payload .. ","):gmatch("([^,]*),") do fields[#fields + 1] = f end
	local nonce = fields[1]
	if not nonce or nonce == "" then return end
	local wants = {}
	for i = 2, #fields do
		local name, rev, digest = fields[i]:match("^(.-)=(%d+):?([%d%.]*)$")
		if name then wants[name] = { since = tonumber(rev), digest = digest ~= "" and digest or nil } end
	end
	if #Sync.BuildAnswer(wants) == 0 then return end
	-- Several guildmates may hold different records, so each one answers for the sets where
	-- nobody with the same records has answered yet.
	local function answer()
		local heard = answered[nonce] or {}
		answered[nonce] = heard
		local skip, mine = {}, {}
		for name in pairs(wants) do
			local d = Sync.sets[name] and Sync.Digest(name)
			if d then
				if heard[name .. "=" .. d] then skip[name] = true end
				mine[#mine + 1] = name .. "=" .. d
			end
		end
		local records = Sync.BuildAnswer(wants, skip)
		if #records == 0 then return end
		for _, m in ipairs(mine) do heard[m] = true end
		local head = nonce .. "\2" .. table.concat(mine, ",")
		-- Split into answers of at most ~2,000 bytes so no single message gets too long.
		local batch, size = {}, 0
		local function flush()
			if #batch > 0 then Comm.Send("SR", head .. RS .. table.concat(batch, RS)) end
			batch, size = {}, 0
		end
		for _, s in ipairs(records) do
			if size + #s > 2000 then flush() end
			batch[#batch + 1] = s
			size = size + #s + 1
		end
		flush()
	end
	if Comm.immediate then answer() else ns.After(math.random() * Sync.ANSWER_DELAY_MAX, answer) end
end)

-- A catch-up at login can bring hundreds of records at once. Accepting them all in one go made
-- the game hitch, so they're taken a batch per frame (tests take them at once).
Sync.ACCEPT_PER_FRAME = 40
local queue, head, tail = {}, 1, 0
local function Drain()
	local stop = head + Sync.ACCEPT_PER_FRAME
	while head < stop and queue[head] do
		local piece = queue[head]
		queue[head] = nil
		head = head + 1
		local name, key, rec = Deserialize(piece)
		if name then Sync.Accept(name, key, rec) end
	end
	if head <= tail then ns.After(0, Drain) else queue, head, tail = {}, 1, 0 end
end
function Sync.Pending() return tail - head + 1 end

Comm.Register("SR", function(sender, payload)
	Sync.lastAnswer = ns.Now()
	local first = true
	for piece in (payload .. RS):gmatch("(.-)" .. RS) do
		if first then
			first = false
			local nonce, digests = piece:match("^([^\2]*)\2?(.*)$")
			local heard = answered[nonce] or {}
			answered[nonce] = heard
			for d in digests:gmatch("[^,]+") do heard[d] = true end -- these sets are answered
		elseif Comm.immediate then
			local name, key, rec = Deserialize(piece)
			if name then Sync.Accept(name, key, rec) end
		else
			local idle = head > tail
			tail = tail + 1
			queue[tail] = piece
			if idle then ns.After(0, Drain) end
		end
	end
end)

function Sync:OnLoad()
	ns.char.writeLogSince = ns.char.writeLogSince or ns.Now()
	-- Sets of features that were taken out (0.6.0: the calendar and the Groups board).
	for name in pairs(ns.db.sync) do
		if not Sync.sets[name] then ns.db.sync[name] = nil end
	end
	Sync.Prune()
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

function Sync:OnLogin()
	ns.After(8, Sync.Ask) -- after the roster has loaded, so rank checks work
	ns.After(600, Sync.Ask) -- and once more later, for anything a guildmate logging in since has
end
