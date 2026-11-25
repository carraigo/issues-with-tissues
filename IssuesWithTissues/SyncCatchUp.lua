-- Catching up with the guild: at login (and when asked) this client sends what it holds, as
-- fingerprints, and guildmates answer with the records it lacks. Records are stored by Sync.lua.
--
-- Messages:
--   SQ  nonce, then set=maxRev:digest for each set   "this is what I hold"
--       and, for sets of 8 or more records, set~<bucket fingerprints>
--   SR  nonce \2 set=digest,...,#=count \30 record \30 record ...   an answer
--   SC  nonce,set,set...                      "I'm answering these sets" (sent first, one packet)
-- An answer only for sets the asker holds nothing of (a new install) is whispered to the asker.
-- Bucket fingerprints let an answerer send only the records in the buckets that differ instead
-- of the whole set (16 buckets from 32 records, 8 below that; old clients send whole sets).
-- Catch-up runs in rounds: ask, take the answers, and ask again only while the round brought
-- something new and our sets still differ from what the answerers hold (at most a few rounds).
-- A round is judged once its answers are in, or after ROUND_WAIT. A fresh install keeps
-- asking every minute, and whenever a guildmate with the addon logs in, until someone answers.

local _, ns = ...

local Sync = ns.Sync
local CatchUp = ns.RegisterModule("SyncCatchUp", {})
local Store, Serialize, Deserialize, RS = Sync.Store, Sync.Serialize, Sync.Deserialize, Sync.RS
local Comm = ns.Comm

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
Sync.BUCKET_MIN = 32     -- 16 buckets from this many records
Sync.SMALL_BUCKETS = 8
Sync.SMALL_MIN = 8       -- 8 buckets from this many; smaller sets are just sent whole
local function Base36(n, width) return ns.Record.B36(n, width) end

-- How many buckets a set of n records is split into for an ask (nil: none, sent whole).
function Sync.BucketCount(n)
	if n >= Sync.BUCKET_MIN then return Sync.BUCKETS end
	if n >= Sync.SMALL_MIN then return Sync.SMALL_BUCKETS end
end

-- One pass gives the set's fingerprint and each key's hashes; bucket fingerprints for a given
-- bucket count are worked out from those (once per count). Cached until a record changes, so
-- answering many asks costs one pass. Returns the set's fingerprint and, when the set is split
-- (count, or by its size), { buckets = "3 base 36 digits per bucket", bucketOf = { key = i } }.
local digestCache = {}
local function Fingerprints(name, count)
	local store = Store(name)
	local c = digestCache[name]
	if not (c and c.gen == Sync.gen and c.store == store) then
		local n, sum, keyHash, recHash = 0, 0, {}, {}
		for key, r in pairs(store) do
			n = n + 1
			local h = Hash(key .. "\1" .. r.rev .. (r.deleted and "d" or ""))
			sum = (sum + h) % 2147483647
			keyHash[key], recHash[key] = Hash(key), h
		end
		c = { gen = Sync.gen, store = store, n = n, digest = n .. "." .. sum, keyHash = keyHash, recHash = recHash, split = {} }
		digestCache[name] = c
	end
	count = count or Sync.BucketCount(c.n)
	if not count then return c end
	local b = c.split[count]
	if not b then
		local sums, bucketOf = {}, {}
		for i = 1, count do sums[i] = 0 end
		for key, k in pairs(c.keyHash) do
			local i = k % count + 1
			bucketOf[key] = i
			sums[i] = (sums[i] + c.recHash[key]) % 2147483647
		end
		local parts = {}
		for i = 1, count do parts[i] = Base36(sums[i] % 46656, 3) end
		b = { buckets = table.concat(parts), bucketOf = bucketOf }
		c.split[count] = b
	end
	return c, b
end

function Sync.Digest(name) return Fingerprints(name).digest end
function Sync.Buckets(name, count)
	local _, b = Fingerprints(name, count)
	return b and b.buckets
end

-- Catch-up state. round: the ask in progress; catching: still catching up this session.
Sync.ROUND_WAIT = 20     -- seconds an ask waits for answers before it is judged
Sync.ROUND_MAX = 120     -- a round that is still trickling in is judged after this long
Sync.NEXT_ROUND = 10     -- a round brought something new: ask again this soon
Sync.FRESH_RETRY = 60    -- nobody answered a fresh install: ask again this often
Sync.MAX_ROUNDS = 5
Sync.MAX_FRESH_TRIES = 10
Sync.NOBODY_RETRY = 60   -- nobody answered (not a fresh install): ask again this soon
Sync.NOBODY_RETRIES = 2
Sync.NOW_COOLDOWN = 30   -- "Sync now" at most this often
Sync.QUIET = 5           -- a round with all its answers in is judged after this long without news
Sync.rounds, Sync.tries = 0, 0
local claimed = {}       -- nonce -> { set = true } for sets someone is answering
local nextAsk            -- a re-ask already waiting

local function Total()
	local n = 0
	for name in pairs(Sync.sets) do n = n + Fingerprints(name).n end
	return n
end

function Sync.Ask()
	-- A catch-up can bring hundreds of records: not during a fight, a raid or a dungeon.
	if Comm.Held() then
		ns.Trace("sync", "Catch-up waits: in combat, a raid or a dungeon (again in 30s)")
		ns.After(30, Sync.Ask)
		return
	end
	local nonce = tostring(math.random(1, 2 ^ 30))
	local parts = { nonce }
	for name in pairs(Sync.sets) do
		local f, split = Fingerprints(name)
		parts[#parts + 1] = name .. "=" .. Sync.MaxRev(name) .. ":" .. f.digest
		if split then parts[#parts + 1] = name .. "~" .. split.buckets end
	end
	Sync.lastAsk = ns.Now()
	Sync.stats.asks = Sync.stats.asks + 1
	Sync.round = { nonce = nonce, started = ns.Now(), expected = {}, got = 0, new = 0, theirs = {} }
	ns.Trace("sync", "Asking the guild for anything newer (round %d, holding %d records)", (Sync.rounds or 0) + 1, Total())
	if Sync.catching == nil then Sync.catching, Sync.fresh = true, Total() == 0 end
	Comm.Send("SQ", table.concat(parts, ","))
	ns.Send("SYNC_PROGRESS")
	local round = Sync.round
	if not Comm.immediate then ns.After(Sync.ROUND_WAIT, function() Sync.CheckRound(round) end) end
end

-- How long to wait before answering an ask: a random moment in the first ANSWER_DELAY_MAX
-- seconds, so usually one guildmate answers. Having answered in the last ANSWER_RECENT seconds
-- adds ANSWER_BACKOFF, so someone who hasn't answered lately (and whose answer takes a moment to
-- arrive) gets there first and the work is shared out. We still answer if nobody with our
-- records does. Being away (AFK) adds ANSWER_IDLE on top: a guildmate at the keyboard is
-- playing anyway, so their game does the work and ours stays quiet.
Sync.ANSWER_RECENT = 300
Sync.ANSWER_BACKOFF = 5
Sync.ANSWER_IDLE = 8
function Sync.IsIdle()
	return UnitIsAFK ~= nil and UnitIsAFK("player") and true or false
end
function Sync.AnswerDelay()
	local wait = math.random() * Sync.ANSWER_DELAY_MAX
	if Sync.lastAnswered and ns.Now() - Sync.lastAnswered < Sync.ANSWER_RECENT then
		wait = wait + Sync.ANSWER_BACKOFF
	end
	if Sync.IsIdle() then wait = wait + Sync.ANSWER_IDLE end
	return wait
end

local function AskLater(seconds)
	if nextAsk then return end
	nextAsk = true
	ns.After(seconds, function()
		nextAsk = nil
		Sync.Ask()
	end)
end

-- True while any set we hold differs from what every answerer said they hold: another round
-- may bring more. Once ours matches an answerer's, there is nothing left to ask them for.
function Sync.StillBehind(r)
	for set, digests in pairs(r.theirs or {}) do
		if Sync.sets[set] and not digests[Sync.Digest(set)] then return true end
	end
	return false
end

-- Judge the round: ask again while answers bring new records and our sets still differ from
-- the answerers'; a fresh install that nobody answered keeps trying. Waits while answers are
-- still arriving or being taken in. round: the round a timer was set for (nil: the current one).
function Sync.CheckRound(round)
	local r = Sync.round
	if not r or (round and round ~= r) then return end
	local now = ns.Now()
	local busy = not Comm.immediate and (Sync.Pending() > 0 or (r.lastHeard and now - r.lastHeard < Sync.QUIET))
	if busy and now - r.started < Sync.ROUND_MAX then
		if not Comm.immediate then ns.After(Sync.QUIET, function() Sync.CheckRound(r) end) end
		return
	end
	Sync.round = nil
	Sync.rounds = Sync.rounds + 1
	local st = Sync.stats
	st.rounds = st.rounds + 1
	local who = {}
	for name in pairs(r.expected) do who[#who + 1] = name end
	table.sort(who)
	local summary = string.format("Round %d done: %d records from %s, %d new", Sync.rounds, r.got,
		#who > 0 and table.concat(who, ", ") or "nobody", r.new)
	if r.lastHeard then
		Sync.answeredEver = true
		if r.new > 0 and Sync.rounds < Sync.MAX_ROUNDS and Sync.StillBehind(r) then
			ns.Trace("sync", "%s. Asking again in %ds.", summary, Sync.NEXT_ROUND)
			AskLater(Sync.NEXT_ROUND)
		else
			ns.Trace("sync", "%s. Caught up with the guild.", summary)
			Sync.catching = false
		end
	elseif Sync.fresh and not Sync.answeredEver and Sync.tries < Sync.MAX_FRESH_TRIES then
		Sync.tries = Sync.tries + 1
		ns.Trace("sync", "Nobody answered. Asking again in %ds (try %d of %d).", Sync.FRESH_RETRY, Sync.tries, Sync.MAX_FRESH_TRIES)
		AskLater(Sync.FRESH_RETRY)
	elseif not Sync.fresh and Sync.addonPeers then
		-- Nobody answered, but guildmates with the addon are online: nobody holds anything we
		-- lack (they answer only when they do), so we are up to date.
		ns.Trace("sync", "Nobody answered: we hold what the guild holds. Caught up.")
		Sync.catching, Sync.upToDate = false, true
	elseif not Sync.fresh and not Sync.answeredEver and (Sync.retries or 0) < Sync.NOBODY_RETRIES then
		-- Nobody answered and no guildmate's addon has said hello yet (still loading, or nobody
		-- on): try again soon rather than waiting for the next catch-up.
		Sync.retries = (Sync.retries or 0) + 1
		ns.Trace("sync", "Nobody answered. Asking again in %ds.", Sync.NOBODY_RETRY)
		AskLater(Sync.NOBODY_RETRY)
	else
		ns.Trace("sync", "%s. Done.", summary)
		Sync.catching = false
	end
	if not Sync.catching and (r.lastHeard or Sync.upToDate) and not st.caughtUpAfter and ns.loginAt then
		st.caughtUpAfter = ns.Now() - ns.loginAt -- seconds from login to caught up
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
	if Comm.Held() then return false, "not in combat, a raid or a dungeon" end
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
			-- The asker split the set into buckets (16, or 8 for a small set): send only the
			-- records in the buckets that differ from ours, split the same way.
			local count = want.buckets and #want.buckets / 3
			local split
			if count == Sync.BUCKETS or count == Sync.SMALL_BUCKETS then
				_, split = Fingerprints(name, count)
				differ = {}
				for i = 1, count do
					local j = (i - 1) * 3 + 1
					if want.buckets:sub(j, j + 2) ~= split.buckets:sub(j, j + 2) then differ[i] = true end
				end
			end
			for key, r in pairs(Store(name)) do
				if r.rev > since and (not differ or differ[split.bucketOf[key]]) then
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

Comm.Register("SQ", function(sender, payload)
	local fields = {}
	for f in (payload .. ","):gmatch("([^,]*),") do fields[#fields + 1] = f end
	local nonce = fields[1]
	if not nonce or nonce == "" then return end
	if Comm.Held() then return end -- someone not fighting, raiding or in a dungeon answers
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
	if #Sync.BuildAnswer(wants) == 0 then
		ns.Trace("sync", "%s asked for a catch-up: they have everything we have", sender)
		return
	end
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
		if #records == 0 then
			ns.Trace("sync", "%s asked for a catch-up: someone else already answered", sender)
			return
		end
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
		ns.Trace("sync", "Answering %s's catch-up: %d records (%s)%s", sender, #records, table.concat(sets, ", "),
			private and ", whispered" or "")
		Sync.lastAnswered = ns.Now()
		Sync.stats.answered = Sync.stats.answered + 1
		Sync.stats.answeredRecords = Sync.stats.answeredRecords + #records
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
	if Comm.immediate then answer() else ns.After(Sync.AnswerDelay(), answer) end
end)

Comm.Register("SC", function(sender, payload)
	local nonce, rest = tostring(payload):match("^([^,]+),?(.*)$")
	if not nonce then return end
	ns.Trace("sync", "%s is answering a catch-up (%s)", sender, rest ~= "" and rest:gsub(",", ", ") or "nothing")
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
		if name and Sync.Accept(name, key, rec) and round then round.new = round.new + 1; Sync.stats.new = Sync.stats.new + 1 end
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
			local mine = Sync.round and nonce == Sync.round.nonce and Sync.round
			for d in digests:gmatch("[^,]+") do
				heard[d] = true -- these sets are answered
				local set, digest = d:match("^(.-)=(.*)$")
				if set and set ~= "#" then
					taken[set] = true
					if mine then -- what this answerer holds, for judging the round
						mine.theirs[set] = mine.theirs[set] or {}
						mine.theirs[set][digest] = true
					end
				end
			end
			if mine then
				round = mine
				round.lastHeard = ns.Now()
				round.expected[sender] = tonumber(digests:match("#=(%d+)")) or round.expected[sender] or 0
				Sync.peers = Sync.peers or {}
				local p = Sync.peers[sender] or { records = 0 }
				Sync.peers[sender], p.at = p, ns.Now()
				ns.Trace("sync", "Answer from %s for our catch-up (%d records in all)", sender, round.expected[sender])
			end
		else
			if round then
				round.got = round.got + 1
				Sync.stats.got = Sync.stats.got + 1
				Sync.peers[sender].records = Sync.peers[sender].records + 1
				-- Every record the answerers announced is in: judge the round once it goes quiet
				-- instead of waiting out ROUND_WAIT.
				if not round.settling and not Comm.immediate then
					local expected = 0
					for _, n in pairs(round.expected) do expected = expected + n end
					if round.got >= expected then
						round.settling = true
						local r = round
						ns.After(Sync.QUIET, function() Sync.CheckRound(r) end)
					end
				end
			end
			if Comm.immediate then
				local name, key, rec = Deserialize(piece)
				if name and Sync.Accept(name, key, rec) and round then round.new = round.new + 1; Sync.stats.new = Sync.stats.new + 1 end
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
	if sender ~= ns.PlayerName() then Sync.addonPeers = true end
	if isReply or not Sync.catching or Sync.answeredEver or Sync.round or nextAsk then return end
	if sender == ns.PlayerName() then return end
	AskLater(3 + math.random() * 5)
end)

function Sync.StartCatchUp()
	if Sync.round then return end
	Sync.rounds = 0
	Sync.Ask()
end

function CatchUp:OnLogin()
	ns.Later("catchUp", Sync.StartCatchUp)
	ns.Later("lateCatchUp", Sync.StartCatchUp)
end
