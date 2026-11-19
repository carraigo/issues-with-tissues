-- Shared data sets that every guildmate's addon keeps a copy of (loot notes, calendar,
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
	local store = Store(name)
	local old = store[key]
	if old and old.rev >= rec.rev then return false end
	store[key] = rec
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
end

local function Write(name, key, data, deleted)
	local me = ns.PlayerName()
	if not Sync.CanWrite(name, key, me) then return false, "not allowed" end
	data = tostring(data or ""):gsub("[\30\31]", "")
	local store = Store(name)
	local old = store[key]
	local rev = ns.Now()
	if old and old.rev >= rev then rev = old.rev + 1 end
	local rec = { rev = rev, by = me, deleted = deleted or nil, data = deleted and "" or data }
	store[key] = rec
	ns.Send("SYNC_CHANGED", name, key, rec)
	Comm.Send("SU", Serialize(name, key, rec))
	return true
end

function Sync.Set(name, key, data) return Write(name, key, data, false) end
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
local answered = {}  -- nonce -> true once someone answered it (us or another guildmate)

function Sync.Ask()
	local parts = { tostring(math.random(1, 2 ^ 30)) }
	for name in pairs(Sync.sets) do parts[#parts + 1] = name .. "=" .. Sync.MaxRev(name) end
	Comm.Send("SQ", table.concat(parts, ","))
end

-- Records newer than the asker's revisions, newest first.
function Sync.BuildAnswer(wants)
	local out = {}
	for name, since in pairs(wants) do
		if Sync.sets[name] then
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

Comm.Register("SU", function(sender, payload)
	local name, key, rec = Deserialize(payload)
	if not name or ns.FullName(rec.by) ~= sender then return end -- a live change is the sender's own
	Sync.Accept(name, key, rec)
end)

Comm.Register("SQ", function(sender, payload)
	local fields = {}
	for f in (payload .. ","):gmatch("([^,]*),") do fields[#fields + 1] = f end
	local nonce = fields[1]
	if not nonce or nonce == "" then return end
	local wants = {}
	for i = 2, #fields do
		local name, rev = fields[i]:match("^(.-)=(%d+)$")
		if name then wants[name] = tonumber(rev) end
	end
	local records = Sync.BuildAnswer(wants)
	if #records == 0 then return end
	local function answer()
		if answered[nonce] then return end
		answered[nonce] = true
		-- Split into answers of at most ~2,000 bytes so no single message gets too long.
		local batch, size = {}, 0
		local function flush()
			if #batch > 0 then Comm.Send("SR", nonce .. RS .. table.concat(batch, RS)) end
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

Comm.Register("SR", function(sender, payload)
	local nonce
	for piece in (payload .. RS):gmatch("(.-)" .. RS) do
		if not nonce then
			nonce = piece
			answered[nonce] = true -- someone answered; we stay quiet
		else
			local name, key, rec = Deserialize(piece)
			if name then Sync.Accept(name, key, rec) end
		end
	end
end)

function Sync:OnLoad()
	Sync.Prune()
end

function Sync:OnLogin()
	ns.After(8, Sync.Ask) -- after the roster has loaded, so rank checks work
end
