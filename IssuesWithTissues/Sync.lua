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
--   SR  nonce \2 set=digest,...,#=count \30 record \30 record ...   an answer
--   SC  nonce,set,set...                      "I'm answering these sets" (sent first, one packet)
-- An answer only for sets the asker holds nothing of (a new install) is whispered to the asker.
-- A big set's ask also carries "set~<16 bucket fingerprints>", so an answerer sends only the
-- records in buckets that differ instead of the whole set (old clients ignore the field).
-- Catch-up runs in rounds: ask, take the answers, and ask again soon while a round still brings
-- something new (at most a few rounds). A fresh install keeps asking every minute, and whenever a
-- guildmate with the addon logs in, until someone answers.
-- A record carries its set's data version (field 7; missing = 1). When a set's data format
-- changes, Define it with a higher version and an upgrade function: older records are upgraded
-- as they arrive or load, and records from a newer version than this client knows are left
-- alone, so an old client never stores data it would misread.
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
	local v = Sync.sets[name].version
	local rec = { rev = rev, by = me, deleted = deleted or nil, data = deleted and "" or data, v = v > 1 and v or nil }
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
	Sync.gen = Sync.gen + 1
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

Sync.BUCKETS = 16
Sync.BUCKET_MIN = 32 -- sets smaller than this are just sent whole
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function Base36(n, width)
	local out = {}
	for i = width, 1, -1 do
		local d = n % 36
		out[i] = B36:sub(d + 1, d + 1)
		n = math.floor(n / 36)
	end
	return table.concat(out)
end

-- One pass gives the set's fingerprint, its 16 bucket fingerprints and each key's bucket.
-- Cached until a record changes, so answering many asks costs one pass.
local digestCache = {}
local function Fingerprints(name)
	local store = Store(name)
	local c = digestCache[name]
	if c and c.gen == Sync.gen and c.store == store then return c end
	local n, sum, buckets, bucketOf = 0, 0, {}, {}
	for i = 1, Sync.BUCKETS do buckets[i] = 0 end
	for key, r in pairs(store) do
		n = n + 1
		local h = Hash(key .. "\1" .. r.rev .. (r.deleted and "d" or ""))
		sum = (sum + h) % 2147483647
		local b = Hash(key) % Sync.BUCKETS + 1
		bucketOf[key] = b
		buckets[b] = (buckets[b] + h) % 2147483647
	end
	local parts = {}
	for i = 1, Sync.BUCKETS do parts[i] = Base36(buckets[i] % 46656, 3) end
	c = { gen = Sync.gen, store = store, n = n, digest = n .. "." .. sum, buckets = table.concat(parts), bucketOf = bucketOf }
	digestCache[name] = c
	return c
end

function Sync.Digest(name) return Fingerprints(name).digest end
function Sync.Buckets(name) return Fingerprints(name).buckets end

-- Catch-up state. round: the ask in progress; catching: still catching up this session.
Sync.ROUND_WAIT = 20     -- seconds an ask waits for answers before it is judged
Sync.ROUND_MAX = 120     -- a round that is still trickling in is judged after this long
Sync.NEXT_ROUND = 10     -- a round brought something new: ask again this soon
Sync.FRESH_RETRY = 60    -- nobody answered a fresh install: ask again this often
Sync.MAX_ROUNDS = 5
Sync.MAX_FRESH_TRIES = 10
Sync.NOW_COOLDOWN = 30   -- "Sync now" at most this often
Sync.rounds, Sync.tries = 0, 0
local claimed = {}       -- nonce -> { set = true } for sets someone is answering
local nextAsk            -- a re-ask already waiting

local function Total()
	local n = 0
	for name in pairs(Sync.sets) do n = n + Fingerprints(name).n end
	return n
end

function Sync.Ask()
	-- A catch-up can bring hundreds of records: not during a fight or a raid.
	if Comm.Held() then
		ns.After(30, Sync.Ask)
		return
	end
	local nonce = tostring(math.random(1, 2 ^ 30))
	local parts = { nonce }
	for name in pairs(Sync.sets) do
		local f = Fingerprints(name)
		parts[#parts + 1] = name .. "=" .. Sync.MaxRev(name) .. ":" .. f.digest
		if f.n >= Sync.BUCKET_MIN then parts[#parts + 1] = name .. "~" .. f.buckets end
	end
	Sync.lastAsk = ns.Now()
	Sync.round = { nonce = nonce, started = ns.Now(), expected = {}, got = 0, new = 0 }
	if Sync.catching == nil then Sync.catching, Sync.fresh = true, Total() == 0 end
	Comm.Send("SQ", table.concat(parts, ","))
	ns.Send("SYNC_PROGRESS")
	if not Comm.immediate then ns.After(Sync.ROUND_WAIT, Sync.CheckRound) end
end

local function AskLater(seconds)
	if nextAsk then return end
	nextAsk = true
	ns.After(seconds, function()
		nextAsk = nil
		Sync.Ask()
	end)
end

-- Judge the round: ask again while answers keep bringing new records; a fresh install that
-- nobody answered keeps trying. Waits while answers are still arriving or being taken in.
function Sync.CheckRound()
	local r = Sync.round
	if not r then return end
	local now = ns.Now()
	local busy = not Comm.immediate and (Sync.Pending() > 0 or (r.lastHeard and now - r.lastHeard < 10))
	if busy and now - r.started < Sync.ROUND_MAX then
		if not Comm.immediate then ns.After(5, Sync.CheckRound) end
		return
	end
	Sync.round = nil
	Sync.rounds = Sync.rounds + 1
	if r.lastHeard then
		Sync.answeredEver = true
		if r.new > 0 and Sync.rounds < Sync.MAX_ROUNDS then
			AskLater(Sync.NEXT_ROUND)
		else
			Sync.catching = false
		end
	elseif Sync.fresh and not Sync.answeredEver and Sync.tries < Sync.MAX_FRESH_TRIES then
		Sync.tries = Sync.tries + 1
		AskLater(Sync.FRESH_RETRY)
	else
		Sync.catching = false
	end
	ns.Send("SYNC_PROGRESS")
end

-- For Home: nil when nothing is happening, else { got, expected } (expected may be 0: unknown).
function Sync.Progress()
	local r = Sync.round
	if not Sync.catching or not r then return nil end
	local expected = 0
	for _, n in pairs(r.expected) do expected = expected + n end
	return { got = r.got, expected = expected, waiting = r.lastHeard == nil }
end

function Sync.Status()
	local p = Sync.Progress()
	if p and p.waiting then return "Asking the guild for shared data..." end
	if p and p.expected > 0 then
		return string.format("Syncing with the guild: %d of %d", math.min(p.got, p.expected), p.expected)
	end
	if p then return string.format("Syncing with the guild: %d received", p.got) end
	if Sync.catching and nextAsk then return "Syncing with the guild..." end
end

-- "Sync now" (Settings, /iwt sync): start a fresh catch-up. False, reason when it can't.
function Sync.AskNow()
	if Comm.Held() then return false, "not in combat or a raid" end
	if Sync.round or (Sync.lastAsk and ns.Now() - Sync.lastAsk < Sync.NOW_COOLDOWN) then
		return false, "already syncing"
	end
	Sync.catching, Sync.rounds = true, 0
	Sync.Ask()
	return true
end

-- What to send an asker: for a set whose fingerprint differs from theirs, every record we
-- hold in the buckets that differ (all buckets when they sent none: they may lack old ones);
-- without a fingerprint, records newer than their newest.
-- wants = { set = { since = rev, digest = "n.h" or nil, buckets = "..." or nil } }; skip = { set = true }.
function Sync.BuildAnswer(wants, skip)
	local out = {}
	for name, want in pairs(wants) do
		if type(want) == "number" then want = { since = want } end
		local def = Sync.sets[name]
		local f = def and Fingerprints(name)
		if def and not (skip and skip[name]) and want.digest ~= f.digest then
			local since = want.digest and -1 or want.since or 0
			local differ
			if want.buckets and #want.buckets == #f.buckets then
				differ = {}
				for i = 1, Sync.BUCKETS do
					local j = (i - 1) * 3 + 1
					if want.buckets:sub(j, j + 2) ~= f.buckets:sub(j, j + 2) then differ[i] = true end
				end
			end
			for key, r in pairs(Store(name)) do
				if r.rev > since and (not differ or differ[f.bucketOf[key]]) then
					out[#out + 1] = { rev = r.rev, s = Serialize(name, key, r) }
				end
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
	if Comm.Held() then return end -- someone not fighting or raiding answers
	local wants = {}
	for i = 2, #fields do
		local name, rev, digest = fields[i]:match("^(.-)=(%d+):?([%d%.]*)$")
		if name then
			wants[name] = wants[name] or {}
			wants[name].since, wants[name].digest = tonumber(rev), digest ~= "" and digest or nil
		else
			local set, buckets = fields[i]:match("^(.-)~(%w+)$")
			if set then
				wants[set] = wants[set] or {}
				wants[set].buckets = buckets
			end
		end
	end
	for name, w in pairs(wants) do if not w.since then wants[name] = nil end end
	if #Sync.BuildAnswer(wants) == 0 then return end
	-- Several guildmates may hold different records, so each one answers for the sets where
	-- nobody with the same records has answered yet. A set the asker has nothing of takes one
	-- answer: anything that one lacked comes in the asker's next round.
	local function answer()
		if Comm.Held() then return end
		local heard = answered[nonce] or {}
		answered[nonce] = heard
		local taken = claimed[nonce] or {}
		local skip, mine, sets = {}, {}, {}
		for name, w in pairs(wants) do
			local d = Sync.sets[name] and Sync.Digest(name)
			if d then
				if heard[name .. "=" .. d] then skip[name] = true end
				if taken[name] and (w.digest == "0.0" or not w.digest) then skip[name] = true end
				mine[#mine + 1] = name .. "=" .. d
			end
		end
		local records = Sync.BuildAnswer(wants, skip)
		if #records == 0 then return end
		for _, m in ipairs(mine) do heard[m] = true end
		-- Only sets the asker has nothing of (a new install): whisper the answer to them alone,
		-- so the rest of the guild doesn't unpack records it already holds.
		local private = true
		for name in pairs(wants) do
			if not skip[name] then
				sets[#sets + 1] = name
				if wants[name].digest ~= "0.0" then private = false end
			end
		end
		Comm.Send("SC", nonce .. "," .. table.concat(sets, ","))
		mine[#mine + 1] = "#=" .. #records
		local head = nonce .. "\2" .. table.concat(mine, ",")
		-- Split into answers of at most ~2,000 bytes so no single message gets too long.
		local batch, size = {}, 0
		local function flush()
			if #batch > 0 then
				local body = head .. RS .. table.concat(batch, RS)
				if private then Comm.Send("SR", body, "WHISPER", sender) else Comm.Send("SR", body) end
			end
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

Comm.Register("SC", function(_, payload)
	local nonce, rest = tostring(payload):match("^([^,]+),?(.*)$")
	if not nonce then return end
	local taken = claimed[nonce] or {}
	claimed[nonce] = taken
	for set in rest:gmatch("[^,]+") do taken[set] = true end
end)

-- A catch-up at login can bring hundreds of records at once. Accepting them all in one go made
-- the game hitch, so they're taken a batch per frame (tests take them at once).
Sync.ACCEPT_PER_FRAME = 40
local queue, head, tail = {}, 1, 0
local ours = {} -- queue index -> the round it answers (to count what was new)
local function Drain()
	if InCombatLockdown and InCombatLockdown() then -- take the rest once combat ends
		ns.After(1, Drain)
		return
	end
	local stop = head + Sync.ACCEPT_PER_FRAME
	while head < stop and queue[head] do
		local piece, round = queue[head], ours[head]
		queue[head], ours[head] = nil, nil
		head = head + 1
		local name, key, rec = Deserialize(piece)
		if name and Sync.Accept(name, key, rec) and round then round.new = round.new + 1 end
	end
	if head <= tail then ns.After(0, Drain) else queue, head, tail, ours = {}, 1, 0, {} end
end
function Sync.Pending() return tail - head + 1 end

Comm.Register("SR", function(sender, payload)
	Sync.lastAnswer = ns.Now()
	local first, round = true, nil
	for piece in (payload .. RS):gmatch("(.-)" .. RS) do
		if first then
			first = false
			local nonce, digests = piece:match("^([^\2]*)\2?(.*)$")
			local heard = answered[nonce] or {}
			answered[nonce] = heard
			local taken = claimed[nonce] or {}
			claimed[nonce] = taken
			for d in digests:gmatch("[^,]+") do
				heard[d] = true -- these sets are answered
				local set = d:match("^(.-)=")
				if set and set ~= "#" then taken[set] = true end
			end
			if Sync.round and nonce == Sync.round.nonce then
				round = Sync.round
				round.lastHeard = ns.Now()
				round.expected[sender] = tonumber(digests:match("#=(%d+)")) or round.expected[sender] or 0
			end
		else
			if round then round.got = round.got + 1 end
			if Comm.immediate then
				local name, key, rec = Deserialize(piece)
				if name and Sync.Accept(name, key, rec) and round then round.new = round.new + 1 end
			else
				local idle = head > tail
				tail = tail + 1
				queue[tail], ours[tail] = piece, round
				if idle then ns.After(0, Drain) end
			end
		end
	end
	if round then ns.Send("SYNC_PROGRESS") end
end)

-- A guildmate with the addon logged in: if we're still waiting for anyone to answer, ask them.
ns.Listen("ADDON_HELLO", function(sender, isReply)
	if isReply or not Sync.catching or Sync.answeredEver or Sync.round or nextAsk then return end
	if sender == ns.PlayerName() then return end
	AskLater(3 + math.random() * 5)
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
function Sync.StartCatchUp()
	if Sync.round then return end
	Sync.rounds = 0
	Sync.Ask()
end

function Sync:OnLogin()
	ns.Later("catchUp", Sync.StartCatchUp)
	ns.Later("lateCatchUp", Sync.StartCatchUp)
end
