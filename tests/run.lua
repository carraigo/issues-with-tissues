-- Offline tests. Run from the repository root:  luajit tests/run.lua
local base = arg and arg[1] or "."
package.path = base .. "/tests/?.lua;" .. package.path
local W = dofile(base .. "/tests/wow.lua")
W.ReadToc(base)

local passed, failed = 0, 0
local function test(name, fn)
	W.Reset()
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL " .. name .. "\n     " .. tostring(err))
	end
end
local function eq(a, b, msg)
	if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function Guild()
	return { members = {
		{ "Gm", 0, true }, { "Offi", 1, true }, { "Vet", 2, true }, { "Mem", 3, true }, { "Newbie", 4, true },
	} }
end

test("addon loads and fills defaults", function()
	local c = W.NewClient(base, "Mem", Guild())
	eq(c.env.IwTDB.settings.officerMaxRank, 1)
	eq(c.env.IwTDB.settings.minimap, true)
	eq(type(c.env.SlashCmdList.ISSUESWITHTISSUES), "function")
end)

test("saved settings are kept over defaults", function()
	local g = Guild()
	local W2 = W
	local c = W2.NewClient(base, "Mem", g)
	c.env.IwTDB.settings.minimap = false
	-- reload: load again into the same environment with the old saved variables
	c.env.__fire("ADDON_LOADED", "IssuesWithTissues")
	eq(c.env.IwTDB.settings.minimap, false)
end)

test("rank checks: GM and Officer are officers, Veteran is not", function()
	local c = W.NewClient(base, "Mem", Guild())
	local R = c.ns.Roster
	eq(R.IsOfficer("Gm"), true, "GM")
	eq(R.IsOfficer("Offi-Realm"), true, "Officer")
	eq(R.IsOfficer("Vet"), false, "Veteran")
	eq(R.IsOfficer("Stranger"), false, "not in guild")
	eq(R.IsMember("Newbie"), true)
end)

test("short message is delivered in one packet", function()
	local g = Guild()
	local a = W.NewClient(base, "Mem", g)
	local b = W.NewClient(base, "Vet", g)
	local got
	b.ns.Comm.Register("TEST", function(sender, payload) got = sender .. "|" .. payload end)
	a.ns.Comm.Send("TEST", "hello")
	eq(got, "Mem|hello")
end)

test("long message is split and put back together", function()
	local g = Guild()
	local a = W.NewClient(base, "Mem", g)
	local b = W.NewClient(base, "Vet", g)
	local long = string.rep("abcdefghij", 120) -- 1,200 bytes
	local packets = a.ns.Comm.Encode("TEST", long)
	assert(#packets >= 5, "expected several packets")
	local got
	b.ns.Comm.Register("TEST", function(_, payload) got = payload end)
	a.ns.Comm.Send("TEST", long)
	eq(got, long)
end)

test("pieces arriving out of order still rebuild the message", function()
	local g = Guild()
	local b = W.NewClient(base, "Vet", g)
	local a = W.NewClient(base, "Mem", g)
	local long = string.rep("0123456789", 60)
	local packets = a.ns.Comm.Encode("TEST", long)
	local got
	b.ns.Comm.Register("TEST", function(_, payload) got = payload end)
	for i = #packets, 1, -1 do b.ns.Comm.Receive("IWT", packets[i], "GUILD", "Mem-Realm") end
	eq(got, long)
end)

test("officer-only messages from a Veteran are dropped", function()
	local g = Guild()
	local vet = W.NewClient(base, "Vet", g)
	local offi = W.NewClient(base, "Offi", g)
	local mem = W.NewClient(base, "Mem", g)
	local count = 0
	mem.ns.Comm.Register("OFFICERTHING", function() count = count + 1 end, "officer")
	vet.ns.Comm.Send("OFFICERTHING", "x")
	eq(count, 0, "veteran")
	offi.ns.Comm.Send("OFFICERTHING", "x")
	eq(count, 1, "officer")
end)

test("messages from outside the guild roster are dropped", function()
	local c = W.NewClient(base, "Mem", Guild())
	local count = 0
	c.ns.Comm.Register("TEST", function() count = count + 1 end)
	c.ns.Comm.Receive("IWT", "STEST\tx", "WHISPER", "Stranger-Realm")
	eq(count, 0)
end)

test("own guild messages are ignored", function()
	local c = W.NewClient(base, "Mem", Guild())
	local count = 0
	c.ns.Comm.Register("TEST", function() count = count + 1 end)
	c.ns.Comm.Send("TEST", "x")
	eq(count, 0)
end)

test("Pack and Unpack keep empty fields", function()
	local c = W.NewClient(base, "Mem", Guild())
	local a, b, cc = c.ns.Comm.Unpack(c.ns.Comm.Pack("one", "", "three"))
	eq(a, "one"); eq(b, ""); eq(cc, "three")
end)

local function DefineSets(...)
	for _, c in ipairs({ ... }) do
		c.ns.Sync.Define("notes", { writer = "officer" })
		c.ns.Sync.Define("mine", { writer = "owner" })
	end
end

test("sync: an officer's change reaches everyone", function()
	local g = Guild()
	local offi, mem = W.NewClient(base, "Offi", g), W.NewClient(base, "Mem", g)
	DefineSets(offi, mem)
	assert(offi.ns.Sync.Set("notes", "n1", "Belt to Ann"))
	eq(mem.ns.Sync.Get("notes", "n1"), "Belt to Ann")
end)

test("sync: a Veteran cannot write officer data", function()
	local g = Guild()
	local vet, mem = W.NewClient(base, "Vet", g), W.NewClient(base, "Mem", g)
	DefineSets(vet, mem)
	local ok = vet.ns.Sync.Set("notes", "n1", "fake")
	eq(ok, false, "local write refused")
	-- even a forged packet is refused by the receiver
	vet.ns.Comm.Send("SU", vet.ns.Comm.Pack("notes", "n1", W.now, "Vet", "", "fake"))
	eq(mem.ns.Sync.Get("notes", "n1"), nil)
end)

test("sync: owner sets only take a player's own record", function()
	local g = Guild()
	local mem, vet = W.NewClient(base, "Mem", g), W.NewClient(base, "Vet", g)
	DefineSets(mem, vet)
	assert(mem.ns.Sync.Set("mine", "Mem", "my alts"))
	eq(vet.ns.Sync.Get("mine", "Mem"), "my alts")
	eq(mem.ns.Sync.Set("mine", "Vet", "not mine"), false)
end)

test("sync: older revisions never overwrite newer ones", function()
	local g = Guild()
	local offi, mem = W.NewClient(base, "Offi", g), W.NewClient(base, "Mem", g)
	DefineSets(offi, mem)
	offi.ns.Sync.Set("notes", "n1", "new")
	mem.ns.Sync.Accept("notes", "n1", { rev = W.now - 100, by = "Offi", data = "old" })
	eq(mem.ns.Sync.Get("notes", "n1"), "new")
end)

test("sync: deletes spread and hide the record", function()
	local g = Guild()
	local offi, mem = W.NewClient(base, "Offi", g), W.NewClient(base, "Mem", g)
	DefineSets(offi, mem)
	offi.ns.Sync.Set("notes", "n1", "x")
	W.now = W.now + 1
	offi.ns.Sync.Delete("notes", "n1")
	eq(mem.ns.Sync.Get("notes", "n1"), nil)
	local n = 0
	for _ in mem.ns.Sync.Each("notes") do n = n + 1 end
	eq(n, 0)
end)

test("sync: a client with wiped data catches up at login", function()
	local g = Guild()
	local offi = W.NewClient(base, "Offi", g)
	DefineSets(offi)
	offi.ns.Sync.Set("notes", "n1", "first")
	offi.ns.Sync.Set("notes", "n2", string.rep("long note ", 30))
	offi.ns.Sync.Set("mine", "Offi", "offi alts")
	local late = W.NewClient(base, "Mem", g) -- joins after the changes; nothing saved
	DefineSets(late)
	late.ns.Sync.Ask()
	eq(late.ns.Sync.Get("notes", "n1"), "first")
	eq(late.ns.Sync.Get("notes", "n2"), string.rep("long note ", 30))
	eq(late.ns.Sync.Get("mine", "Offi"), "offi alts")
end)

test("sync: only one guildmate answers an ask", function()
	local g = Guild()
	local offi, vet = W.NewClient(base, "Offi", g), W.NewClient(base, "Vet", g)
	DefineSets(offi, vet)
	offi.ns.Sync.Set("notes", "n1", "x")
	local late = W.NewClient(base, "Mem", g)
	DefineSets(late)
	local answers = 0
	local orig = late.ns.Comm.handlers.SR.fn
	late.ns.Comm.handlers.SR.fn = function(...) answers = answers + 1 return orig(...) end
	late.ns.Sync.Ask()
	eq(answers, 1)
end)

test("sync: an older record isn't missed because a newer one arrived first", function()
	local g = Guild()
	local offi = W.NewClient(base, "Offi", g)
	DefineSets(offi)
	offi.ns.Sync.Set("notes", "old", "written before the others installed")
	-- Two guildmates install later; the second hears only a fresh live change from the first.
	W.now = W.now + 3600
	local a = W.NewClient(base, "Gm", g)
	DefineSets(a)
	local b = W.NewClient(base, "Mem", g)
	DefineSets(b)
	local saved = offi.ns.Comm.handlers.SU.fn
	offi.ns.Comm.handlers.SU.fn = function() end -- (offi misses it; doesn't matter)
	a.ns.Sync.Set("notes", "new", "fresh")
	offi.ns.Comm.handlers.SU.fn = saved
	eq(b.ns.Sync.Get("notes", "new"), "fresh")
	eq(b.ns.Sync.Get("notes", "old"), nil)
	b.ns.Sync.Ask()
	eq(b.ns.Sync.Get("notes", "old"), "written before the others installed", "the old record still arrives")
end)

test("sync: guildmates holding different records each answer, the same records only once", function()
	local g = Guild()
	local offi, vet = W.NewClient(base, "Offi", g), W.NewClient(base, "Vet", g)
	DefineSets(offi, vet)
	-- offi and vet each hold a record the other never got
	offi.ns.Sync.Accept("notes", "x", { rev = W.now, by = "Offi", data = "only offi" })
	vet.ns.Sync.Accept("notes", "y", { rev = W.now, by = "Offi", data = "only vet" })
	local late = W.NewClient(base, "Mem", g)
	DefineSets(late)
	late.ns.Sync.Ask()
	-- An empty set takes one answer; the next round brings what that one lacked.
	local first = (late.ns.Sync.Get("notes", "x") and 1 or 0) + (late.ns.Sync.Get("notes", "y") and 1 or 0)
	eq(first, 1, "one guildmate answers an empty set")
	late.ns.Sync.CheckRound()
	late.ns.Sync.Ask()
	eq(late.ns.Sync.Get("notes", "x"), "only offi"); eq(late.ns.Sync.Get("notes", "y"), "only vet")
end)

test("sync: a new install's catch-up is whispered, so others don't unpack it", function()
	local g = Guild()
	local offi, vet = W.NewClient(base, "Offi", g), W.NewClient(base, "Vet", g)
	DefineSets(offi, vet)
	offi.ns.Sync.Set("notes", "n1", "x")
	local late = W.NewClient(base, "Mem", g)
	DefineSets(late)
	local heard = 0
	local orig = vet.ns.Comm.handlers.SR.fn
	vet.ns.Comm.handlers.SR.fn = function(...) heard = heard + 1 return orig(...) end
	late.ns.Sync.Ask()
	eq(late.ns.Sync.Get("notes", "n1"), "x")
	eq(heard, 0, "vet never sees the answer")
end)

test("sync: a big set sends only the buckets that differ", function()
	local g = Guild()
	local offi = W.NewClient(base, "Offi", g)
	DefineSets(offi)
	for i = 1, 200 do offi.ns.Sync.Set("notes", "n" .. i, "note " .. i) end
	local late = W.NewClient(base, "Mem", g)
	DefineSets(late)
	late.ns.Sync.Ask()
	eq(late.ns.Sync.round.got, 200, "a fresh install gets everything")
	late.ns.Sync.CheckRound()
	-- One record changes while Mem doesn't hear it.
	local saved = late.ns.Comm.handlers.SU.fn
	late.ns.Comm.handlers.SU.fn = function() end
	offi.ns.Sync.Set("notes", "n7", "changed")
	late.ns.Comm.handlers.SU.fn = saved
	late.ns.Sync.Ask()
	eq(late.ns.Sync.Get("notes", "n7"), "changed")
	local got = late.ns.Sync.round.got
	assert(got < 40, "only one bucket's records come back, got " .. got)
	eq(late.ns.Sync.round.new, 1)
	eq(late.ns.Sync.round.expected.Offi, got, "the answer says how many records it brings")
end)

test("sync: catch-up asks again while rounds bring news, and a fresh install keeps trying", function()
	local g = Guild()
	local alone = W.NewClient(base, "Mem", g)
	DefineSets(alone)
	alone.ns.Sync.StartCatchUp()
	eq(alone.ns.Sync.Status(), "Asking the guild for shared data...")
	alone.ns.Sync.CheckRound() -- nobody answered
	eq(alone.ns.Sync.catching, true, "a fresh install keeps catching up")
	eq(alone.ns.Sync.tries, 1)
	-- A guildmate with the addon logs in: the fresh install asks them (once a re-ask isn't waiting).
	local offi = W.NewClient(base, "Offi", g)
	DefineSets(offi)
	local saved = alone.ns.Comm.handlers.SU.fn
	alone.ns.Comm.handlers.SU.fn = function() end -- (written before Mem was online)
	offi.ns.Sync.Set("notes", "n1", "hello")
	alone.ns.Comm.handlers.SU.fn = saved
	alone.timers = {}
	alone.ns.Sync.CheckRound() -- (no round open: nothing happens)
	local before = #alone.timers
	alone.ns.Send("ADDON_HELLO", "Offi", false)
	eq(#alone.timers, before, "a re-ask is already waiting, so no second one")
	alone.ns.Sync.Ask()
	eq(alone.ns.Sync.Get("notes", "n1"), "hello")
	local S = alone.ns.Sync
	-- The round brought news, but our sets now match what the answerer holds: done, no extra round.
	eq(S.StillBehind(S.round), false)
	S.CheckRound()
	eq(S.catching, false, "caught up: no second round needed")
	eq(S.Status(), nil)
	-- Still different from every answerer after news: one more round.
	S.catching, S.rounds = true, 0
	S.Ask()
	S.round.new, S.round.lastHeard = 1, W.now
	S.round.theirs.notes = { ["9.12345"] = true }
	eq(S.StillBehind(S.round), true)
	S.CheckRound()
	eq(S.catching, true, "that round brought news and we still differ: one more round")
	S.Ask()
	S.CheckRound()
	eq(S.catching, false, "a round with nothing new ends the catch-up")
end)

test("sync: small sets are split into 8 buckets, so one change sends a few records, not the set", function()
	local g = Guild()
	local offi = W.NewClient(base, "Offi", g)
	DefineSets(offi)
	for i = 1, 20 do offi.ns.Sync.Set("notes", "n" .. i, "note " .. i) end
	local late = W.NewClient(base, "Mem", g)
	DefineSets(late)
	late.ns.Sync.Ask()
	eq(late.ns.Sync.Digest("notes"), offi.ns.Sync.Digest("notes"))
	eq(#late.ns.Sync.Buckets("notes"), 8 * 3)
	eq(late.ns.Sync.Buckets("notes", 16), offi.ns.Sync.Buckets("notes", 16), "any split agrees")
	-- One record changes while Mem is away: the next catch-up brings far fewer than 20.
	local saved = late.ns.Comm.handlers.SU.fn
	late.ns.Comm.handlers.SU.fn = function() end
	offi.ns.Sync.Set("notes", "n7", "changed")
	late.ns.Comm.handlers.SU.fn = saved
	late.ns.Sync.Ask()
	eq(late.ns.Sync.Get("notes", "n7"), "changed")
	local got = late.ns.Sync.round.got
	assert(got >= 1 and got <= 8, "sent " .. got .. " records")
	-- a set under 8 records is still sent whole
	eq(late.ns.Sync.BucketCount(7), nil); eq(late.ns.Sync.BucketCount(8), 8); eq(late.ns.Sync.BucketCount(32), 16)
end)

test("sync: Sync now waits out a recent ask", function()
	local c = W.NewClient(base, "Mem", Guild())
	DefineSets(c)
	c.ns.Sync.StartCatchUp()
	local ok, why = c.ns.Sync.AskNow()
	eq(ok, false); eq(why, "already syncing")
	c.ns.Sync.CheckRound()
	W.now = W.now + 60
	eq(c.ns.Sync.AskNow(), true)
end)

test("comm: a packet the game refuses for speed is sent again, in order", function()
	local c = W.NewClient(base, "Mem", Guild())
	local C = c.ns.Comm
	eq(C.Refused(true), false); eq(C.Refused(nil), false); eq(C.Refused(0), false)
	eq(C.Refused(3), true); eq(C.Refused(false), true)
	C.immediate = false
	local calls = 0
	C.sendHook = function() calls = calls + 1 return calls == 1 and 3 or 0 end
	C.Send("TEST", "hi")
	eq(calls, 1)
	eq(C.Queued(), 1, "kept for another try")
	eq(C.Peek().tries, 1)
	C.Pump()
	eq(C.Queued(), 0)
	eq(C.throttled, 1)
	-- A long queue keeps its order, including a refused packet put back in front
	local sent = {}
	calls = 0
	C.sendHook = function(_, packet) calls = calls + 1; if calls == 3 then return 3 end; sent[#sent + 1] = packet; return 0 end
	C.pumping = true -- queue without sending yet
	for i = 1, 500 do C.Send("T" .. i, "x") end
	eq(C.Queued(), 500)
	for _ = 1, 501 do C.Pump() end
	eq(#sent, 500); eq(C.Queued(), 0)
	for i = 1, 500 do assert(sent[i]:find("\tT" .. i .. "\t", 1, true), "packet " .. i .. " in order") end
	C.pumping = false
	C.immediate, C.sendHook = true, nil
end)

test("bug report lists errors once with a count", function()
	local c = W.NewClient(base, "Mem", Guild())
	c.ns.ReportError("boom")
	c.ns.ReportError("boom")
	eq(#c.env.IwTDB.errors, 1)
	eq(c.env.IwTDB.errors[1].count, 2)
	local report = c.ns.Diagnostics.BuildReport()
	assert(report:find("%[x2, last [^%]]+%] boom"), "report has the error")
	assert(report:find("interface 16010", 1, true), "report has the client")
end)

test("profiler measures comm handlers only while on", function()
	local g = Guild()
	local a, b = W.NewClient(base, "Mem", g), W.NewClient(base, "Vet", g)
	b.ns.Comm.Register("TEST", function() end)
	a.ns.Comm.Send("TEST", "x")
	eq(b.ns.Perf.stats["comm TEST"], nil, "off")
	b.env.IwTDB.perf.on = true
	a.ns.Comm.Send("TEST", "x")
	eq(b.ns.Perf.stats["comm TEST"].calls, 1, "on")
	assert(b.ns.Perf.Report():find("comm TEST", 1, true))
end)

test("slash: unknown word prints help, bug opens a copy box", function()
	local c = W.NewClient(base, "Mem", Guild())
	c.ns.HandleSlash("nonsense")
	assert(c.printed and #c.printed > 2, "help printed")
	local shown
	c.ns.UI.ShowCopyBox = function(title, text) shown = text end
	c.ns.HandleSlash("bug")
	assert(shown and shown:find("Issues with Tissues bug report", 1, true))
end)

test("window opens on a tab without errors", function()
	local c = W.NewClient(base, "Mem", Guild())
	c.ns.HandleSlash("")
	eq(c.ns.UI.window:IsShown(), true)
	eq(#c.env.IwTDB.errors, 0, "no errors while building tabs")
end)


---------------------------------------------------------------------------
-- Milestone 2: roster tab, alt links, professions
---------------------------------------------------------------------------
local function Guild2()
	-- name, rankIndex, online, days offline, level
	return { members = {
		{ "Gm", 0, true, 0, 60 }, { "Offi", 1, false, 3, 58 }, { "Vet", 2, false, 20, 40 },
		{ "Mem", 3, true, 0, 30 }, { "Memalt", 4, false, 40, 12 }, { "Gone", 4, false, 45, 9 },
	} }
end

test("roster: pages hear only real changes", function()
	local g = Guild2()
	local c = W.NewClient(base, "Mem", g)
	local updates, details = 0, 0
	c.ns.Listen("ROSTER_UPDATED", function() updates = updates + 1 end)
	c.ns.Listen("ROSTER_DETAILS", function() details = details + 1 end)
	c.env.__fire("GUILD_ROSTER_UPDATE")
	eq(updates, 0, "nothing changed: no redraws")
	eq(details, 0)
	g.members[2][3] = true -- Offi comes online
	c.env.__fire("GUILD_ROSTER_UPDATE")
	eq(updates, 1)
	g.members[6] = nil -- Gone leaves
	c.env.__fire("GUILD_ROSTER_UPDATE")
	eq(updates, 2)
	local R = c.ns.Roster
	local a = { X = { level = 60, online = true, zone = "Orgrimmar" } }
	eq(R.Changes(a, { X = { level = 60, online = true, zone = "Orgrimmar" } }), nil)
	eq(R.Changes(a, { X = { level = 60, online = true, zone = "Ironforge" } }), "details")
	eq(R.Changes(a, { X = { level = 60, online = false, zone = "Ironforge" } }), "members")
	eq(R.Changes(a, {}), "members")
	eq(R.Changes({}, a), "members")
end)

-- Timing tests: messages go through the paced queue and timers run in order (W.Run).
local function Timed(...)
	for _, c in ipairs({ ... }) do c.ns.Comm.immediate = false; c.timers = {} end
end

test("timed: a catch-up ends a few seconds after its answer is in, in one round", function()
	local g = Guild()
	local offi = W.NewClient(base, "Offi", g)
	DefineSets(offi)
	for i = 1, 40 do offi.ns.Sync.Set("notes", "n" .. i, "note " .. i) end
	local late = W.NewClient(base, "Mem", g)
	DefineSets(late)
	Timed(offi, late)
	late.ns.Sync.StartCatchUp()
	W.Run(15, { offi, late })
	eq(late.ns.Sync.Digest("notes"), offi.ns.Sync.Digest("notes"), "has everything")
	eq(late.ns.Sync.catching, false, "judged well before the 20 second wait")
	eq(late.ns.Sync.stats.rounds, 1, "no second round: nothing left to ask for")
	W.Run(60, { offi, late })
	eq(late.ns.Sync.stats.asks, 1, "and it doesn't ask again")
end)

test("timed: nobody answers but guildmates' addons are online: already up to date", function()
	local g = Guild()
	local offi = W.NewClient(base, "Offi", g)
	DefineSets(offi)
	offi.ns.Sync.Set("notes", "n1", "same")
	local mem = W.NewClient(base, "Mem", g)
	DefineSets(mem)
	mem.ns.Sync.Ask() -- gets n1 at once
	mem.ns.Sync.round, mem.ns.Sync.catching, mem.ns.Sync.rounds = nil, nil, 0
	mem.ns.Send("ADDON_HELLO", "Offi", true)
	Timed(offi, mem)
	mem.ns.loginAt = W.now
	mem.ns.Sync.StartCatchUp()
	W.Run(30, { offi, mem })
	eq(mem.ns.Sync.catching, false)
	eq(mem.ns.Sync.stats.asks, 2, "no retries")
	assert(mem.ns.Sync.stats.caughtUpAfter and mem.ns.Sync.stats.caughtUpAfter <= 25, "counted as caught up")
	-- with no addon heard at all, a quiet round is asked again a minute later
	local alone = W.NewClient(base, "Vet", Guild())
	DefineSets(alone)
	alone.ns.Sync.Set("mine", "Vet", "x") -- not a fresh install
	Timed(alone)
	alone.ns.Sync.StartCatchUp()
	W.Run(30, { alone })
	eq(alone.ns.Sync.catching, true, "retry waiting")
	W.Run(200, { alone })
	eq(alone.ns.Sync.stats.asks, 1 + alone.ns.Sync.NOBODY_RETRIES)
	eq(alone.ns.Sync.catching, false, "gives up after the retries")
end)

test("timed: refused packets slow the pace, which recovers, and nothing is lost", function()
	local c = W.NewClient(base, "Mem", Guild())
	local C = c.ns.Comm
	Timed(c)
	local sent, calls = {}, 0
	C.sendHook = function(_, packet) calls = calls + 1; if calls == 3 or calls == 5 then return 3 end; sent[#sent + 1] = packet; return 0 end
	for i = 1, 30 do C.Send("T" .. i, string.rep("x", 200)) end
	W.Run(5, { c })
	assert(C.rate < C.RATE_MAX, "slowed down")
	eq(C.slowest, C.RATE_MAX / 4, "halved twice")
	W.Run(120, { c })
	eq(#sent, 30); eq(C.Queued(), 0)
	for i = 1, 30 do assert(sent[i]:find("\tT" .. i .. "\t", 1, true), "in order") end
	eq(C.throttled, 2); eq(C.dropped, nil)
	-- recovery: a minute without refusals and the next send goes at full pace again
	C.Send("U", "y")
	W.Run(5, { c })
	eq(C.rate, C.RATE_MAX, "back to full pace")
	C.sendHook = nil
end)

test("timed: a guildmate who answered recently lets someone else answer", function()
	local g = Guild()
	local offi = W.NewClient(base, "Offi", g)
	local vet = W.NewClient(base, "Vet", g)
	DefineSets(offi, vet)
	for i = 1, 20 do offi.ns.Sync.Set("notes", "n" .. i, "note " .. i) end
	eq(vet.ns.Sync.Digest("notes"), offi.ns.Sync.Digest("notes"))
	local S = offi.ns.Sync
	assert(S.AnswerDelay() < S.ANSWER_DELAY_MAX)
	S.lastAnswered = W.now
	assert(S.AnswerDelay() >= S.ANSWER_BACKOFF)
	local late = W.NewClient(base, "Mem", g)
	DefineSets(late)
	Timed(offi, vet, late)
	late.ns.Sync.StartCatchUp()
	W.Run(30, { offi, vet, late })
	eq(late.ns.Sync.Digest("notes"), offi.ns.Sync.Digest("notes"))
	eq(vet.ns.Sync.stats.answered, 1, "the one who hadn't answered lately did")
	eq(offi.ns.Sync.stats.answered, 0, "and the other stood back")
end)

test("roster: updates in a burst scan once, then once more after a second", function()
	local g = Guild2()
	local c = W.NewClient(base, "Mem", g)
	Timed(c)
	c.env.GetTime = function() return W.now end
	local scans = 0
	local real = c.ns.Roster.Scan
	c.ns.Roster.Scan = function() scans = scans + 1; return real() end
	for _ = 1, 10 do c.env.__fire("GUILD_ROSTER_UPDATE") end
	eq(scans, 1, "the first at once")
	W.Run(2, { c })
	eq(scans, 2, "the rest in one more")
	c.ns.Roster.Scan = real
end)

test("secret chat text and names (shown but unreadable) never error, and lost lines are dropped", function()
	local c = W.NewClient(base, "Mem", Guild())
	local Chat, ns = c.ns.Chat, c.ns
	-- A stand-in for the game's secret strings: joining works (the result is secret too), but
	-- reading, matching or comparing one errors.
	local SECRET = {}
	local function Secret(text)
		return setmetatable({ text = text }, SECRET)
	end
	SECRET.__index = function() error("attempt to index a secret string value") end
	SECRET.__eq = function() error("attempt to compare a secret string value") end
	SECRET.__lt = SECRET.__eq
	SECRET.__concat = function() return Secret("joined") end
	c.env.issecretvalue = function(v) return getmetatable(v) == SECRET end
	eq(ns.IsSecret(Secret("x")), true); eq(ns.IsSecret("x"), false); eq(ns.IsSecret(nil), false)
	eq(ns.Roster.ParseName(Secret("Gm-Realm")), nil)
	eq(Chat.Hidden(Secret("hi")), true); eq(Chat.Plain(Secret("hi")), "")
	eq(Chat.SystemLine(Secret("Gm has come online.")), nil)
	eq(ns.News.Joined(Secret("Bob has joined the guild.")), nil)
	c.ns.UI.Open("Chat")
	c.env.__fire("CHAT_MSG_GUILD", Secret("hello"), Secret("Gm-Realm"))
	c.env.__fire("CHAT_MSG_GUILD", Secret("hello"), "Gm-Realm")
	c.env.__fire("CHAT_MSG_SYSTEM", Secret("Gm has come online."))
	c.env.__fire("GUILD_MOTD", Secret("motd"))
	local lines = Chat.Lines("guild")
	assert(lines[#lines].secret, "kept for this session, marked secret")
	Chat.Redraw()
	for _, e in ipairs(Chat.View("guild")) do assert(Chat.Display("guild", e) ~= nil) end
	eq(#c.env.IwTDB.errors, 0, "no errors")
	-- After a reload the saved copies come back without their text: dropped, not drawn as nil
	for _, e in ipairs(lines) do if e.secret then e.m, e.a = nil, nil end end
	Chat:OnLoad()
	for _, e in ipairs(Chat.Lines("guild")) do eq(type(e.m), "string") end
	Chat.Redraw()
	eq(#c.env.IwTDB.errors, 0)
	-- the server's copy and ours, both secret and a moment apart, show once
	Chat.server.guild = { { t = W.now, k = "msg", a = Secret("Gm"), m = Secret("x"), srv = true, secret = true } }
	local before = #Chat.View("guild")
	Chat.Add("guild", "msg", Secret("Gm"), Secret("x"))
	eq(#Chat.View("guild"), before, "matched, not shown twice")
	eq(#c.env.IwTDB.errors, 0)
end)

test("roster reads days offline", function()
	local c = W.NewClient(base, "Mem", Guild2())
	eq(c.ns.Roster.Get("Vet").offlineDays, 20)
	eq(c.ns.Roster.Get("Gm").offlineDays, 0)
end)

test("roster tab filters: online and away 14+/30+", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local T = c.ns.RosterTab
	local function names(state)
		local out = {}
		for _, r in ipairs(T.Rows(state)) do out[#out + 1] = r.name end
		table.sort(out)
		return table.concat(out, ",")
	end
	eq(names({ filter = "online", groupAlts = false }), "Gm,Mem")
	eq(names({ filter = "away14", groupAlts = false }), "Gone,Memalt,Vet")
	eq(names({ filter = "away30", groupAlts = false }), "Gone,Memalt")
	eq(#T.Rows({ filter = "all", groupAlts = false }), 6)
end)

test("roster tab sorts by rank, then by level descending", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local T = c.ns.RosterTab
	local rows = T.Rows({ filter = "all", sort = "rankIndex", groupAlts = false })
	eq(rows[1].name, "Gm"); eq(rows[2].name, "Offi")
	rows = T.Rows({ filter = "all", sort = "level", desc = true, groupAlts = false })
	eq(rows[1].level, 60); eq(rows[#rows].level, 9)
end)

test("alt link: request on main, confirm on alt, everyone sees it", function()
	local g = Guild2()
	local main = W.NewClient(base, "Mem", g)
	local other = W.NewClient(base, "Gm", g)
	assert(main.ns.Alts.Request("Memalt"))
	-- log on to the alt (same account: same IwTDB)
	local alt = W.NewClient(base, "Memalt", g, { account = main })
	alt.ns.Alts.CheckPending()
	eq(alt.popups[1] and alt.popups[1].which, "IWT_ALT_CONFIRM", "popup asked")
	eq(alt.popups[1].arg, "Mem")
	assert(alt.ns.Alts.Confirm())
	eq(other.ns.Alts.MainOf("Memalt"), "Mem")
	eq(table.concat(other.ns.Alts.AltsOf("Mem"), ","), "Memalt")
end)

test("alt link: grouped roster counts the player once and away uses their freshest character", function()
	local g = Guild2()
	local main = W.NewClient(base, "Mem", g)
	main.ns.Alts.Request("Memalt")
	local alt = W.NewClient(base, "Memalt", g, { account = main })
	alt.ns.Alts.Confirm()
	local rows = main.ns.RosterTab.Rows({ filter = "all", groupAlts = true })
	eq(#rows, 5, "Memalt folded into Mem")
	local away = main.ns.RosterTab.Rows({ filter = "away30", groupAlts = true })
	eq(#away, 1, "only Gone: Mem is online so Memalt doesn't count as away")
	eq(away[1].name, "Gone")
end)

test("alt link: nobody can claim another player's character", function()
	local g = Guild2()
	local vet = W.NewClient(base, "Vet", g)
	local mem = W.NewClient(base, "Mem", g)
	eq(vet.ns.Sync.Set("alts", "Mem", "Vet"), false, "local write refused")
	vet.ns.Comm.Send("SU", vet.ns.Comm.Pack("alts", "Mem", W.now, "Vet", "", "Vet"))
	eq(mem.ns.Alts.MainOf("Mem"), "Mem", "forged link ignored")
end)

test("alt link: removing from the main waits for the alt to log on", function()
	local g = Guild2()
	local main = W.NewClient(base, "Mem", g)
	main.ns.Alts.Request("Memalt")
	local alt = W.NewClient(base, "Memalt", g, { account = main })
	alt.ns.Alts.Confirm()
	W.now = W.now + 5
	assert(main.ns.Alts.Remove("Memalt"))
	eq(main.ns.Alts.MainOf("Memalt"), "Mem", "still linked until the alt logs on")
	alt.ns.Alts.CheckPending()
	eq(main.ns.Alts.MainOf("Memalt"), "Memalt", "unlinked")
end)

test("professions: skills are shared with the guild", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	mem.skills = { { "Tailoring", 225, 300 }, { "First Aid", 150, 150 }, { "Alchemy", 75, 150 }, { "Mining", 100, 150 }, { "Cooking", 75, 150 } }
	assert(mem.ns.Professions.UpdateSkills())
	local p = gm.ns.Professions.Of("Mem")
	eq(#p, 2, "only crafting professions (0.9.0), and no Cooking (1.3.0)")
	eq(p[1].name, "Alchemy"); eq(p[2].name, "Tailoring"); eq(p[2].rank, 225)
	eq(mem.ns.Sync.Get("profs", "Mem"), "Alchemy:75:150,Tailoring:225:300", "gathering ones and Cooking aren't shared")
	eq(mem.ns.Professions.UpdateSkills(), false, "unchanged skills are not sent again")
end)

test("professions: skills refused before the roster loaded are shared once it has (Vatic's bug)", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	mem.skills = { { "Alchemy", 120, 150 } }
	mem.env.__fire("GUILD_ROSTER_UPDATE")
	mem.flush()
	eq(#gm.ns.Professions.Of("Mem"), 1, "shared after the roster update")
end)

test("addon users: someone already online answers a new HELLO, so both see each other", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	mem.ns.Comm.Send("HELLO", mem.ns.VERSION) -- Mem logs in after Gm
	eq(gm.ns.Comm.versions["Mem"], mem.ns.VERSION)
	eq(mem.ns.Comm.versions["Gm"], gm.ns.VERSION, "Gm whispered back")
	local sent = 0
	gm.ns.Comm.sendHook = function() sent = sent + 1 end
	mem.ns.Comm.Send("HELLO", mem.ns.VERSION)
	eq(sent, 0, "only answered once")
	gm.ns.Comm.sendHook = nil
end)

test("minimap button sits on the rim of a bigger or square minimap (Vatic's bug)", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local off = c.ns.UI.MinimapOffset
	local x, y = off(0, 140, 140, "ROUND"); eq(math.floor(x + 0.5), 80); eq(math.floor(y + 0.5), 0)
	x = off(0, 200, 200, "ROUND"); eq(math.floor(x + 0.5), 110, "bigger map, further out")
	x, y = off(45, 140, 140, "SQUARE"); eq(math.floor(x + 0.5), 80); eq(math.floor(y + 0.5), 80)
end)

test("professions: recipes from an open window, and who can make it", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	mem.tradeSkill = { name = "Tailoring", recipes = {
		{ 1, "Bolt of Linen Cloth", 2996 }, { 2, "Linen Bandage? no", 0, false }, { 3, "Brown Linen Robe", 6238 },
	} }
	assert(mem.ns.Professions.ReadOpenWindow(false))
	local found = gm.ns.Professions.WhoCanMake("linen")
	eq(#found, 2, "unlearned recipe left out")
	eq(found[1].name, "Bolt of Linen Cloth"); eq(found[1].crafter, "Mem"); eq(found[1].item, 2996)
	eq(found[1].profession, "Tailoring")
end)

test("professions: a guildmate cannot publish recipes for someone else", function()
	local g = Guild2()
	local vet = W.NewClient(base, "Vet", g)
	local gm = W.NewClient(base, "Gm", g)
	vet.ns.Comm.Send("SU", vet.ns.Comm.Pack("recipes", "Gm#Tailoring", W.now, "Vet", "", "1:Fake"))
	eq(#gm.ns.Professions.WhoCanMake("fake"), 0)
end)

test("professions: a large recipe list survives catch-up sync", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	local recipes = {}
	for i = 1, 250 do recipes[i] = { i, "Recipe number " .. i, 1000 + i } end
	mem.tradeSkill = { name = "Blacksmithing", recipes = recipes }
	assert(mem.ns.Professions.ReadOpenWindow(false))
	local late = W.NewClient(base, "Gm", g)
	late.ns.Sync.Ask()
	eq(#late.ns.Professions.WhoCanMake("recipe number"), 250)
end)

test("recipes: shared as ids, names looked up in game, older records upgraded", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	mem.tradeSkill = { name = "Enchanting", recipes = {
		{ 7421, "Runed Copper Rod", 6218 }, { 7418, "Enchant Bracer - Minor Health" }, -- no item: an enchant
	} }
	assert(mem.ns.Professions.ReadOpenWindow(false))
	local data = mem.ns.Sync.Get("recipes", "Mem#Enchanting")
	eq(data, "i4sq;s5q2", "ids only, in base 36")
	local _, rec = mem.ns.Sync.Get("recipes", "Mem#Enchanting")
	eq(rec.v, 3)
	-- Gm's game knows the item but has never seen the enchant's spell name: remembered names fill in.
	gm.env.GetSpellInfo = function(id) if id == 7418 then return "Enchant Bracer - Minor Health" end end
	eq(#gm.ns.Professions.WhoCanMake("runed copper"), 1)
	eq(#gm.ns.Professions.WhoCanMake("minor health"), 1)
	-- An item the game hasn't loaded yet: found once its name arrives.
	local late = W.NewClient(base, "Vet", g)
	late.unknownItems = { [6218] = true }
	late.ns.Sync.Ask()
	eq(#late.ns.Professions.WhoCanMake("runed copper"), 0)
	eq(late.ns.Professions.PrefetchNames(), 1, "the missing name is asked for")
	eq(late.ns.Professions.PrefetchNames(), 0, "not twice")
	late.unknownItems = nil
	late.env.__fire("GET_ITEM_INFO_RECEIVED", 6218, true)
	eq(#late.ns.Professions.WhoCanMake("runed copper"), 1, "the last name in: refreshed at once")
	-- A record from a 1.2 client (version 1, names inline) is upgraded as it arrives.
	mem.ns.Comm.Send("SU", mem.ns.Comm.Pack("recipes", "Mem#Alchemy", W.now + 5, "Mem", "", "118:Minor Healing Potion;0:Secret Elixir", 1))
	eq(gm.ns.Sync.Get("recipes", "Mem#Alchemy"), "i3a;nSecret Elixir")
	eq(#gm.ns.Professions.WhoCanMake("minor healing"), 1)
	eq(#gm.ns.Professions.WhoCanMake("secret elixir"), 1)
end)

test("recipes: a batch of missing names refreshes the list once, when they're all in", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	local recipes = {}
	for i = 1, 250 do recipes[i] = { i, "Batch Recipe " .. i, 50000 + i } end
	mem.tradeSkill = { name = "Tailoring", recipes = recipes }
	assert(mem.ns.Professions.ReadOpenWindow(false))
	local late = W.NewClient(base, "Vet", g)
	late.unknownItems = {}
	for i = 1, 250 do late.unknownItems[50000 + i] = true end
	late.ns.Sync.Ask()
	local P = late.ns.Professions
	local asked = {}
	late.env.C_Item = { RequestLoadItemDataByID = function(id) asked[#asked + 1] = id end }
	eq(P.PrefetchNames(), 250)
	eq(#asked, 100, "the first batch now, the rest a moment later")
	late.unknownItems = nil
	local gen = P.namesGen
	for i = 1, 249 do late.env.__fire("GET_ITEM_INFO_RECEIVED", 50000 + i, true) end
	eq(P.namesGen, gen, "no rebuild per item")
	late.env.__fire("GET_ITEM_INFO_RECEIVED", 50250, true)
	eq(P.namesGen, gen + 1, "one rebuild when the last arrives")
	eq(#P.WhoCanMake("batch recipe"), 250)
end)

test("recipes: the shared data is much smaller than before", function()
	local list = {}
	for i = 1, 100 do list[i] = { item = 10000 + i, name = "Heavy Runecloth Bandolier " .. i } end
	local c = W.NewClient(base, "Mem", Guild2())
	local old = {}
	for _, r in ipairs(list) do old[#old + 1] = r.item .. ":" .. r.name end
	local new = c.ns.Professions.EncodeRecipes(list)
	assert(#new * 4 < #table.concat(old, ";"), "at least 4x smaller: " .. #new)
end)

test("themes: Kawaii Day has its own readable class colours", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local UI = c.ns.UI
	UI.ApplyTheme("kawaiiDay")
	local seen = {}
	for _, token in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do
		local r, g, b = UI.ClassColor(token)
		assert(UI.Contrast({ r, g, b }, UI.theme.ref) >= 4.5, token .. " is readable")
		local k = string.format("%.2f%.2f%.2f", r, g, b)
		assert(not seen[k], token .. " differs from the others"); seen[k] = true
	end
	local r, g, b = UI.ClassColor("PRIEST")
	eq(string.format("%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5)), "52607a")
	UI.ApplyTheme("default")
	r = UI.ClassColor("PRIEST")
	eq(r, 1, "other themes keep the game's colours")
end)

test("officers page: only officers see it; away list and addon versions", function()
	local g = Guild2()
	local gm, mem = W.NewClient(base, "Gm", g), W.NewClient(base, "Mem", g)
	local O = gm.ns.OfficerTab
	eq(O.Visible(), true); eq(mem.ns.OfficerTab.Visible(), false)
	gm.ns.UI.Create(); mem.ns.UI.Create()
	local function Page(c)
		for _, t in ipairs(c.ns.UI.tabs) do
			for _, p in ipairs(t.pages) do if p.title == "Officers" then return p, t end end
		end
	end
	mem.ns.UI.Open("Members")
	local p, t = Page(mem)
	eq(p.subButton:IsShown(), false, "hidden for members")
	mem.ns.UI.Open("Officers")
	eq(t.current, 1, "a member asking for it gets the roster")
	gm.ns.UI.Open("Officers")
	p = Page(gm)
	eq(p.subButton:IsShown(), true)
	eq(p.panel:IsShown(), true)
	-- Who's away 30 days or more
	local away = O.AwayRows()
	for _, r in ipairs(away) do assert(not r.online and r.offlineDays >= 30) end
	-- Versions: heard at login, remembered; older ones first
	gm.ns.Send("VERSION_SEEN", "Vet", "1.2.1")
	gm.ns.Send("VERSION_SEEN", "Mem", gm.ns.VERSION)
	local rows, never = O.VersionRows()
	eq(rows[1].name, "Vet"); eq(rows[1].old, true)
	for i = 2, #rows do eq(rows[i].old, false) end
	assert(never >= 0)
	eq(gm.env.IwTDB.versionsSeen["Vet"].v, "1.2.1", "remembered for next time")
	eq(#gm.env.IwTDB.errors, 0); eq(#mem.env.IwTDB.errors, 0)
end)

test("roster tab shows in the window before Settings", function()
	local c = W.NewClient(base, "Mem", Guild2())
	c.ns.UI.Create()
	local order = {}
	for i, t in ipairs(c.ns.UI.tabs) do
		local pages = {}
		for j, p in ipairs(t.pages) do pages[j] = p.title end
		order[i] = t.title .. "(" .. table.concat(pages, "|") .. ")"
	end
	eq(table.concat(order, ","), "Home(Home),Chat(Chat),Members(Roster|Raid|Officers),Crafting(Crafters),Guild life(Polls|Donations|Loot notes)", "Guild life waits for pages")
	c.ns.HandleSlash("roster")
	eq(c.ns.RosterTab.panel:IsShown(), true)
	c.ns.RosterTab.Refresh() -- draws the rows
	c.ns.HandleSlash("inactive 30")
	eq(#c.env.IwTDB.errors, 0, "no errors building the roster tab")
end)

test("Forever names: surname and odd realm ids still match the roster (Craig's bug)", function()
	-- Roster gives "First Surname-Realm"; UnitName gives "First"; addon senders give "First-Realm".
	local g = { members = { { "Large Joseph", 3, true }, { "Clane Stocious", 4, false, 1 }, { "Boss Man", 0, true } } }
	local main = W.NewClient(base, "Large Joseph", g)
	main.env.GetNormalizedRealmName = function() return "CAMWOWEU5Realm6PvP" end
	eq(main.ns.PlayerName(), "Large Joseph")
	eq(main.ns.Roster.IsMember(main.ns.PlayerName()), true, "player found in roster")
	eq(main.ns.Roster.IsOfficer("Boss-CAMWOWEU5Realm6PvP"), true, "sender with realm id")
	main.skills = { { "Tailoring", 100, 150 } }
	assert(main.ns.Professions.UpdateSkills(), "skills published")
	-- typed with the surname, as Craig did
	assert(main.ns.Alts.Request("Clane Stocious"))
	local alt = W.NewClient(base, "Clane Stocious", g, { account = main })
	alt.ns.Alts.CheckPending()
	eq(alt.popups[1] and alt.popups[1].arg, "Large Joseph", "popup on the alt shows the full name")
	assert(alt.ns.Alts.Confirm())
	eq(main.ns.Alts.MainOf("Clane Stocious"), "Large Joseph")
	assert(main.ns.Diagnostics.BuildReport():find("in roster: true", 1, true))
end)

test("roster shows first name and surname in either Forever spelling", function()
	local g = { members = { { "Large Joseph", 3, true }, { "Clane-Stocious", 4, true }, { "Pork", 4, true } } }
	local c = W.NewClient(base, "Mem", g)
	-- the stub adds "-Realm": "Large Joseph-Realm", "Clane-Stocious-Realm", "Pork-Realm"
	c.env.GetNormalizedRealmName = function() return "CAMWOWEU5Realm6PvP" end
	c.env.GetGuildRosterInfo = function(i)
		local raw = ({ "Large Joseph-CAMWOWEU5Realm6PvP", "Clane-Stocious", "Pork-CAMWOWEU5Realm6PvP" })[i]
		return raw, "R", 4, 10, "Mage", "Zone", "", "", true, 0, "MAGE"
	end
	c.env.__fire("GUILD_ROSTER_UPDATE")
	eq(c.ns.Roster.DisplayName("Large"), "Large Joseph")
	eq(c.ns.Roster.DisplayName("Clane"), "Clane Stocious")
	eq(c.ns.Roster.DisplayName("Pork"), "Pork")
	local rows = c.ns.RosterTab.Rows({ filter = "all", groupAlts = false, sort = "name" })
	eq(rows[1].name, "Clane Stocious")
end)

test("alt link: set a main, other guild characters offer to link themselves", function()
	local g = Guild2()
	local main = W.NewClient(base, "Mem", g)
	local other = W.NewClient(base, "Gm", g)
	assert(main.ns.Alts.SetMain())
	local alt = W.NewClient(base, "Memalt", g, { account = main })
	alt.ns.Alts.CheckPending()
	eq(alt.popups[1] and alt.popups[1].arg, "Mem", "offered without /iwt alt add")
	alt.ns.Alts.Confirm()
	eq(other.ns.Alts.MainOf("Memalt"), "Mem")
	-- logging on again offers nothing: already linked
	local again = W.NewClient(base, "Memalt", g, { account = main })
	eq(again.ns.Alts.CheckPending(), false)
	-- the main itself is never offered
	local mainAgain = W.NewClient(base, "Mem", g, { account = main })
	eq(mainAgain.ns.Alts.CheckPending(), false)
end)

test("alt link: No is remembered per character; outside the guild nothing is offered", function()
	local g = Guild2()
	local main = W.NewClient(base, "Mem", g)
	main.ns.Alts.SetMain()
	local alt = W.NewClient(base, "Gone", g, { account = main })
	alt.ns.Alts.CheckPending()
	alt.ns.Alts.Decline()
	local again = W.NewClient(base, "Gone", g, { account = main })
	eq(again.ns.Alts.CheckPending(), false, "declined stays declined")
	again.ns.HandleSlash("alt ask")
	eq(#again.popups, 1, "/iwt alt ask offers again")
	local stranger = W.NewClient(base, "Elsewhere", g, { account = main })
	eq(stranger.ns.Alts.CheckPending(), false, "not in the guild")
end)

test("roster: officers and the Guild Master can promote and demote, following the game's rules", function()
	local gm = W.NewClient(base, "Gm", Guild2())
	local off = W.NewClient(base, "Offi", Guild2())
	local mem = W.NewClient(base, "Mem", Guild2())
	local function Acts(c, who) local p, d = c.ns.RosterTab.RankActions(who); return tostring(p) .. "," .. tostring(d) end
	-- Guild Master: anyone below Officer can go up; nobody goes below the lowest rank
	eq(Acts(gm, "Offi"), "false,true", "nobody becomes a second Guild Master")
	eq(Acts(gm, "Vet"), "true,true")
	eq(Acts(gm, "Gone"), "true,false", "already the lowest rank")
	eq(Acts(gm, "Gm"), "false,false", "not yourself")
	-- Officer: never to their own rank, never someone at or above it
	eq(Acts(off, "Vet"), "false,true")
	eq(Acts(off, "Mem"), "true,true")
	eq(Acts(off, "Gm"), "false,false")
	-- Members see neither, and their menu is whisper and invite only
	eq(mem.ns.RosterTab.CanManage(), false)
	eq(Acts(mem, "Gone"), "false,false")
	eq(#mem.ns.RosterTab.MenuItems({ full = "Gone", name = "Gone" }), 2)
	-- The game's own permission wins
	gm.env.CanGuildPromote = function() return false end
	eq(Acts(gm, "Vet"), "false,true")
	gm.env.CanGuildPromote = nil
	-- The menu, the question, then the change
	gm.ns.UI.Open("Roster")
	local items = gm.ns.RosterTab.ShowMenu({ full = "Vet", name = "Vet" })
	eq(#items, 5); eq(items[3][1], "Promote to Officer"); eq(items[4][1], "Demote to Member")
	eq(items[5][1], "Remove from guild")
	-- Forever forbids GuildPromote from addons: the game's own command goes in the chat box,
	-- and the player's Enter runs it.
	local typed
	gm.env.GuildPromote = function() error("forbidden on Forever") end
	gm.env.ChatFrame_OpenChat = function(text) typed = text end
	items[3][2]()
	eq(typed, "/gpromote Vet")
	items[4][2]()
	eq(typed, "/gdemote Vet")
	assert(gm.printed[#gm.printed]:find("Press Enter to demote Vet to Member", 1, true))
	items[5][2]()
	eq(typed, "/gremove Vet")
	eq(mem.ns.RosterTab.CanRemove("Gone"), false, "members can't remove")
	eq(off.ns.RosterTab.CanRemove("Gm"), false, "nobody at or above your rank")
	-- Members can't get there even by calling it directly
	mem.env.ChatFrame_OpenChat = function() error("should not be called") end
	eq(mem.ns.RosterTab.ChangeRank("Gone", true), false)
	gm.ns.RosterTab.HideMenu()
	eq(#gm.env.IwTDB.errors, 0); eq(#mem.env.IwTDB.errors, 0)
end)

test("roster tooltip: the public note for everyone, the officer note for officers", function()
	local g = Guild2()
	g.members[3][6], g.members[3][7] = "Tank, raids Fridays", "Trial until December"
	local gm = W.NewClient(base, "Gm", g)
	local mem = W.NewClient(base, "Mem", g)
	local n = gm.ns.RosterTab.Notes("Vet")
	eq(#n, 2); eq(n[1][1], "Note: Tank, raids Fridays"); eq(n[2][1], "Officer note: Trial until December")
	n = mem.ns.RosterTab.Notes("Vet")
	eq(#n, 1, "members see the public note only")
	eq(#mem.ns.RosterTab.Notes("Offi"), 0, "no notes: no lines")
	eq(gm.ns.Roster.Snapshot().members[1].note, nil, "notes never go in the web export")
end)

test("roster: online on an alt shows that alt with the main beside it", function()
	local g = Guild2()
	g.members[4][3] = false -- Mem (main) offline
	g.members[5][3] = true  -- Memalt online
	local main = W.NewClient(base, "Mem", g)
	main.ns.Alts.SetMain()
	local alt = W.NewClient(base, "Memalt", g, { account = main })
	alt.ns.Alts.Confirm()
	local rows = alt.ns.RosterTab.Rows({ filter = "online", groupAlts = true })
	local row
	for _, r in ipairs(rows) do if r.full == "Mem" then row = r end end
	assert(row, "group listed as online")
	eq(row.name, "Memalt"); eq(row.mainName, "Mem"); eq(row.level, 12); eq(row.tell, "Memalt")
	eq(#row.otherAlts, 0, "the alt shown is not listed again in the tooltip")
end)

test("whisper uses the full Forever name, not the first name", function()
	local g = { members = { { "Large Joseph", 3, true }, { "Mem", 3, true } } }
	local c = W.NewClient(base, "Mem", g)
	local told
	c.env.ChatFrame_SendTell = function(name) told = name end
	c.ns.RosterTab.Whisper("Large")
	eq(told, "Large Joseph")
end)

test("alt popup comes as soon as the roster lists the character", function()
	local g = Guild2()
	local main = W.NewClient(base, "Mem", g)
	main.ns.Alts.SetMain()
	-- NewClient fires GUILD_ROSTER_UPDATE during login: no 10-second wait (no timers in tests)
	local alt = W.NewClient(base, "Memalt", g, { account = main })
	eq(#alt.popups, 1, "asked on the first roster update")
	alt.env.__fire("GUILD_ROSTER_UPDATE")
	eq(#alt.popups, 1, "asked once")
end)

test("recipe scan: clicking through the profession tabs reads each one", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	local P = mem.ns.Professions
	local booked = 0
	mem.env.ToggleProfessionsBook = function() booked = booked + 1 end
	mem.skills = { { "Tailoring", 225, 300, 197 }, { "Herbalism", 100, 150, 182 }, { "Alchemy", 80, 150, 171 } }
	eq(P.SharedCount("Tailoring"), nil, "not scanned yet")
	assert(P.Scan())
	eq(booked, 1, "the profession book is opened")
	eq(mem.opened, nil, "the protected profession window is never opened by the addon")
	eq(P.scan.total, 2, "Herbalism has no recipes to scan")
	eq(mem.ns.GeneralTab.ScanLabel(), "Scanning (0/2 done)")
	-- The player clicks the Tailoring tab, then the Alchemy tab
	mem.tradeSkill = { name = "Tailoring", recipes = { { 1, "Bolt of Linen Cloth", 2996 } } }
	mem.env.__fire("TRADE_SKILL_LIST_UPDATE"); mem.flush()
	eq(P.scan.done, 1)
	mem.tradeSkill = { name = "Alchemy", recipes = { { 2, "Minor Healing Potion", 118 }, { 3, "Lesser Healing Potion", 858 } } }
	mem.env.__fire("TRADE_SKILL_DATA_SOURCE_CHANGED"); mem.flush()
	eq(P.scan, nil, "finished")
	eq(P.SharedCount("Tailoring"), 1); eq(P.SharedCount("Alchemy"), 2)
	eq(#gm.ns.Professions.WhoCanMake("healing potion"), 2, "guildmates see the recipes")
end)

test("recipe scan: quick clicks read only the tab that ends up shown; already shared counts", function()
	local mem = W.NewClient(base, "Mem", Guild2())
	local P = mem.ns.Professions
	mem.skills = { { "Tailoring", 225, 300 }, { "Alchemy", 80, 150 } }
	mem.tradeSkill = { name = "Tailoring", recipes = { { 1, "Bolt of Linen Cloth", 2996 } } }
	mem.env.__fire("TRADE_SKILL_SHOW")
	mem.tradeSkill = { name = "Alchemy", recipes = { { 2, "Minor Healing Potion", 118 } } }
	mem.env.__fire("TRADE_SKILL_LIST_UPDATE")
	mem.flush()
	eq(P.SharedCount("Alchemy"), 1); eq(P.SharedCount("Tailoring"), nil, "skipped past before it was read")
	-- A scan asks for both again; showing an unchanged tab still ticks it off
	P.Scan()
	mem.env.__fire("TRADE_SKILL_LIST_UPDATE"); mem.flush()
	eq(P.scan.done, 1)
end)

test("blocked calls from the game land in the bug report", function()
	local c = W.NewClient(base, "Mem", Guild2())
	c.env.__fire("ADDON_ACTION_BLOCKED", "IssuesWithTissues", "C_TradeSkillUI.OpenTradeSkill")
	c.env.__fire("ADDON_ACTION_BLOCKED", "SomeOtherAddon", "Foo")
	eq(#c.env.IwTDB.errors, 1)
	c.ns.UI.Toggle()
	c.ns.HandleSlash("bug")
end)

test("general tab: guild overview, this character and its professions", function()
	local g = { name = "Issues with Tissues", members = {
		{ "Mem", 3, true }, { "Memalt", 4, false, 2 }, { "Gm", 0, true }, { "Old", 3, false, 45 },
	} }
	local mem = W.NewClient(base, "Mem", g)
	mem.ns.Alts.SetMain()
	local alt = W.NewClient(base, "Memalt", g, { account = mem })
	alt.ns.Alts.Confirm()
	mem.skills = { { "Tailoring", 225, 300, 197 }, { "Skinning", 50, 75, 393 } }
	local f = mem.ns.GeneralTab.Facts()
	eq(f.guild, "Issues with Tissues")
	eq(f.members, 4); eq(f.online, 2); eq(f.players, 3, "alt counted once"); eq(f.away30, 1)
	eq(f.isMain, true); eq(f.accountMain, "Mem"); eq(f.alts[1], "Memalt")
	eq(#f.profs, 1, "Skinning isn't tracked")
	eq(f.profs[1].name, "Tailoring"); eq(f.profs[1].recipes, nil)
	local fa = alt.ns.GeneralTab.Facts()
	eq(fa.isMain, false); eq(fa.main, "Mem"); eq(fa.alts[1], "Mem (main)")
	-- The window opens on General without errors
	mem.ns.UI.Toggle()
	eq(mem.ns.GeneralTab.panel:IsShown(), true)
	mem.ns.GeneralTab.Refresh()
	eq(#mem.env.IwTDB.errors, 0)
end)

test("the window draws its own tabs: Blizzard's tab code is not used, and the current tab is marked", function()
	local c = W.NewClient(base, "Mem", Guild2())
	c.env.PanelTemplates_SetNumTabs = function() error("Blizzard_SharedXML: bad tab") end
	c.env.PanelTemplates_SetTab = function() error("Blizzard_SharedXML: bad tab") end
	c.ns.UI.Toggle()
	for i, t in ipairs(c.ns.UI.tabs) do assert(t.button, "button " .. i) eq(t.button:IsShown(), true) end
	eq(c.ns.UI.tabs[1].button.selected, true)
	c.ns.UI.SelectTab(3)
	eq(c.ns.RosterTab.panel:IsShown(), true)
	eq(c.ns.UI.tabs[1].button.selected, false); eq(c.ns.UI.tabs[3].button.selected, true)
	c.ns.UI.Open("Settings")
	eq(c.ns.UI.cog.selected, true); eq(c.ns.UI.tabs[3].button.selected, false)
	eq(#c.env.IwTDB.errors, 0)
end)

local function Saras()
	return { members = { { "Sara Exe", 1, true }, { "Sara Best", 3, true }, { "Gm", 0, true }, { "Mem", 3, true } } }
end

test("same first name: two Saras are two characters everywhere", function()
	local g = Saras()
	local exe = W.NewClient(base, "Sara Exe", g)
	local best = W.NewClient(base, "Sara Best", g)
	local gm = W.NewClient(base, "Gm", g)
	eq(exe.ns.PlayerName(), "Sara Exe"); eq(best.ns.PlayerName(), "Sara Best")
	eq(exe.ns.Roster.meHow, "guid")
	exe.skills = { { "Tailoring", 100, 150 } }
	best.skills = { { "Alchemy", 50, 75 } }
	assert(exe.ns.Professions.UpdateSkills()); assert(best.ns.Professions.UpdateSkills())
	eq(gm.ns.Professions.Of("Sara Exe")[1].name, "Tailoring")
	eq(gm.ns.Professions.Of("Sara Best")[1].name, "Alchemy")
	local rows = gm.ns.RosterTab.Rows({ filter = "all", groupAlts = true, sort = "name" })
	local names = {}
	for _, r in ipairs(rows) do names[r.name] = true end
	assert(names["Sara Exe"] and names["Sara Best"], "both in the roster tab")
	local told
	gm.env.ChatFrame_SendTell = function(n) told = n end
	gm.ns.RosterTab.Whisper("Sara Best")
	eq(told, "Sara Best")
	eq(gm.ns.FullName("Sara"), "Sara", "a bare shared first name is not guessed")
	eq(gm.ns.FullName("Gm"), "Gm")
end)

test("same first name: rank checks over comms use the lower rank", function()
	local gm = W.NewClient(base, "Gm", Saras())
	eq(gm.ns.Roster.IsOfficer("Sara Exe"), true, "the roster shows her as officer")
	eq(gm.ns.Roster.IsOfficer("Sara Exe", true), false, "but Sara Best could pose as her")
	eq(gm.ns.Roster.IsOfficer("Gm", true), true)
end)

test("same first name: a record forged in your name is put right by you", function()
	local g = Saras()
	local exe = W.NewClient(base, "Sara Exe", g)
	local best = W.NewClient(base, "Sara Best", g)
	local gm = W.NewClient(base, "Gm", g)
	exe.skills = { { "Tailoring", 100, 150 } }
	assert(exe.ns.Professions.UpdateSkills())
	W.now = W.now + 10
	-- Sara Best sends a change claiming to be Sara Exe; the game stamps "Sara" either way
	local P = best.ns.Comm
	local body = "Sara Exe\tSU\t" .. P.Pack("profs", "Sara Exe", W.now, "Sara Exe", "", "Fishing:1:75")
	W.Deliver(best, "IWT", "S" .. body, "GUILD")
	W.now = W.now + 10
	eq(gm.ns.Professions.Of("Sara Exe")[1].name, "Tailoring", "Sara Exe sent her own version straight back")
	eq(exe.ns.Professions.Of("Sara Exe")[1].name, "Tailoring")
	assert(exe.env.IwTDB.errors[1].text:find("in your name"), "noted in the bug report")
end)

test("same first name: a claimed name must match the first name the game stamped", function()
	local g = Saras()
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	local body = "Gm\tSU\t" .. mem.ns.Comm.Pack("profs", "Gm", W.now, "Gm", "", "Fishing:1:75")
	W.Deliver(mem, "IWT", "S" .. body, "GUILD") -- stamped "Mem", claims "Gm"
	eq(#gm.ns.Professions.Of("Gm"), 0, "taken as Mem, who cannot write Gm's record")
end)

test("names: 0.2 saved data keyed by first name becomes first name and surname", function()
	local g = { members = { { "Large Joseph", 3, true }, { "Clane Stocious", 4, true }, { "Magia Musculorum", 4, true } } }
	local c = W.NewClient(base, "Magia Musculorum", g)
	local db = c.env.IwTDB
	db.sync.alts = { records = { Clane = { rev = 1, data = "Large", by = "Clane" } } }
	db.sync.profs = { records = { Large = { rev = 1, data = "Alchemy:195:225", by = "Large" } } }
	db.sync.recipes = { records = { ["Magia#Cooking"] = { rev = 1, data = "i22h", by = "Magia", v = 3 } } }
	db.accountMain = "Large"
	db.altPending = { Clane = { main = "Large", at = 1 } }
	c.ns.Sync.MigrateNames(); c.ns.Alts.MigrateNames()
	eq(c.ns.Alts.MainOf("Clane Stocious"), "Large Joseph")
	eq(c.ns.Professions.Of("Large Joseph")[1].name, "Alchemy")
	eq(c.ns.Professions.SharedCount("Cooking"), 1)
	eq(db.accountMain, "Large Joseph")
	assert(db.altPending["Clane Stocious"]); eq(db.altPending["Clane Stocious"].main, "Large Joseph")
end)

test("alt link: a leftover request for a link that already exists asks nothing", function()
	local g = Guild2()
	local main = W.NewClient(base, "Mem", g)
	main.ns.Alts.Request("Memalt")
	local alt = W.NewClient(base, "Memalt", g, { account = main })
	eq(#alt.popups, 1)
	alt.ns.Sync.Set("alts", "Memalt", "Mem") -- linked another way
	main.env.IwTDB.altPending.Memalt = { main = "Mem", at = 1 }
	alt.popups = {}
	alt.ns.Alts.CheckPending()
	eq(#alt.popups, 0)
	eq(main.env.IwTDB.altPending.Memalt, nil, "cleared")
end)

test("same first name: when the game stamps the surname, that is the sender", function()
	local g = Saras()
	local best = W.NewClient(base, "Sara Best", g, { fullSender = true })
	local exe = W.NewClient(base, "Sara Exe", g, { fullSender = true })
	local gm = W.NewClient(base, "Gm", g, { fullSender = true })
	exe.skills = { { "Tailoring", 100, 150 } }
	assert(exe.ns.Professions.UpdateSkills())
	-- Sara Best claims to be Sara Exe; the game says Sara Best
	local body = "Sara Exe\tSU\t" .. best.ns.Comm.Pack("profs", "Sara Exe", W.now + 5, "Sara Exe", "", "Fishing:1:75")
	W.Deliver(best, "IWT", "S" .. body, "GUILD")
	eq(gm.ns.Professions.Of("Sara Exe")[1].name, "Tailoring", "claim ignored")
	eq(#exe.env.IwTDB.errors, 0, "nothing reached Sara Exe in her name")
	-- a verified officer is an officer, even with a non-officer namesake
	eq(gm.ns.Comm.Allowed("officer", "Sara Exe", "GUILD", true), true)
	eq(gm.ns.Comm.Allowed("officer", "Sara Exe", "GUILD", false), false)
end)

test("guild kills: each character shares its kills and Home adds them up", function()
	local g = { members = { { "Mem", 3, true }, { "Gm", 0, true }, { "Gone", 3, true } } }
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	-- Mem's client has the game's statistics; Gm's doesn't (its creature kills count as 0).
	mem.env.GetPVPLifetimeStats = function() return 12, 0, 0 end
	mem.env.GetStatistic = function(id) if id == 1197 then return "1500" end return "--" end
	gm.env.GetPVPLifetimeStats = function() return 3, 0 end
	-- No addon may register for the combat log on this client.
	assert(not mem.ns.eventFrame.events.COMBAT_LOG_EVENT_UNFILTERED)
	assert(mem.ns.Kills.Share())
	eq(mem.ns.Kills.Share(), false, "nothing new to share")
	assert(gm.ns.Kills.Share())
	local t = mem.ns.Kills.Totals()
	eq(t.hk, 15); eq(t.mobs, 1500); eq(t.chars, 2)
	-- a character who left the guild no longer counts; nobody can post kills for someone else
	gm.ns.Sync.Accept("kills", "Left", { rev = W.now, by = "Left", data = "9999;9999;s" })
	mem.ns.Comm.Send("SU", mem.ns.Comm.Pack("kills", "Gm", W.now + 1, "Mem", "", "100000;1;c"))
	eq(gm.ns.Kills.Totals().hk, 15)
	eq(mem.ns.Kills.Format(1234567), "1,234,567"); eq(mem.ns.Kills.Format(999), "999")
	assert(mem.ns.GeneralTab.Facts().kills.mobs == 1500)
	assert(mem.ns.Diagnostics.BuildReport():find("Kills: 12 honorable, 1500 creatures (stat)", 1, true))
	-- Elite Soldier on Home, and each character's honourable kills on the roster
	local elite = mem.ns.GeneralTab.Facts().elite
	eq(elite.who, "Mem"); eq(elite.hk, 12)
	local rows = mem.ns.RosterTab.Rows({ filter = "all", sort = "hk", desc = true, groupAlts = false })
	eq(rows[1].name, "Mem"); eq(rows[1].hk, 12); eq(rows[2].hk, 3); eq(rows[3].hk, -1, "Gone hasn't shared")
	local keys = {}
	for _, col in ipairs(mem.ns.RosterTab.COLUMNS) do keys[#keys + 1] = col.key end
	eq(table.concat(keys, ","), "name,level,class,hk,rankIndex,where", "professions moved to the Crafting tab (1.1.0)")
	mem.ns.UI.Open("Roster")
	mem.ns.GeneralTab.Refresh()
	eq(#mem.env.IwTDB.errors, 0)
end)

test("donations: officers set and edit the goal, deposits are noted, a new goal starts from zero", function()
	local g = { members = { { "Mem", 3, true }, { "Gm", 0, true }, { "Alt", 4, true } } }
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	local D = mem.ns.Donations
	eq(D.Goal().title, "Guild bank", "the first goal is the guild bank")
	eq(D.SetGoal("Raid fund", 100), false, "members can't set the goal")
	assert(gm.ns.Donations.SetGoal("", 500))
	eq(D.Goal().title, "Guild bank"); eq(D.Goal().target, 500 * 10000)
	assert(D.Add(123456)) -- 12g 34s 56c
	assert(gm.ns.Donations.Add(50000))
	local p = gm.ns.Donations.Progress()
	eq(p.total, 173456); eq(p.givers, 2)
	eq(gm.ns.Donations.Givers()[1].who, "Mem")
	eq(mem.ns.UI.Money(123456), "12g 34s"); eq(mem.ns.UI.Money(305), "3s 5c"); eq(mem.ns.UI.Money(12345678), "1,234g 56s")
	assert(D.ProgressText():find("of 500g", 1, true))
	-- editing keeps the progress; a new goal starts from zero
	assert(gm.ns.Donations.SetGoal("Guild bank tab 2", 800))
	eq(D.Progress().total, 173456); eq(D.Goal().title, "Guild bank tab 2")
	W.now = W.now + 5
	assert(gm.ns.Donations.SetGoal("Mounts", 1000, true))
	eq(D.Progress().total, 0); eq(D.Mine(), 0)
	assert(D.Add(10000)); eq(gm.ns.Donations.Progress().total, 10000)
	-- the guild bank deposit hook
	assert(mem.ns.Donations.Add(0) == false)
	mem.ns.UI.Open("Donations")
	eq(D.panel:IsShown(), true)
	eq(#mem.env.IwTDB.errors, 0)
end)

test("donations: only the officer who set the goal changes it, unless they allow it or the Guild Master does", function()
	local g = { members = { { "Mem", 3, true }, { "Gm", 0, true }, { "Off", 1, true } } }
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	local off = W.NewClient(base, "Off", g)
	assert(gm.ns.Donations.SetGoal("Guild bank", 500))
	eq(off.ns.Donations.Goal().owner, "Gm")
	local ok, why = off.ns.Donations.SetGoal("Mounts", 1000, true)
	eq(ok, false); eq(why, "owned")
	eq(mem.ns.Donations.Goal().title, "Guild bank", "nothing changed")
	-- Off asks; Gm says no, then yes
	assert(off.ns.Donations.RequestChange("Mounts", 1000, true))
	eq(gm.popups[#gm.popups].which, "IWT_DGOAL"); eq(gm.popups[#gm.popups].arg, "Off")
	assert(gm.ns.Donations.AnswerRequest(false))
	eq(mem.ns.Donations.Goal().title, "Guild bank")
	W.now = W.now + 31
	assert(off.ns.Donations.RequestChange("Mounts", 1000, true))
	gm.env.StaticPopupDialogs.IWT_DGOAL.OnAccept()
	W.now = W.now + 1
	local goal = mem.ns.Donations.Goal()
	eq(goal.title, "Mounts"); eq(goal.target, 1000 * 10000); eq(goal.owner, "Off", "handed over")
	assert(off.ns.Donations.SetGoal("Mounts", 1200))
	-- The Guild Master can always change it (0.9.0) and then owns it; officers still have to ask.
	W.now = W.now + 1
	assert(gm.ns.Donations.SetGoal("Back to bank", 5), "Guild Master overrides")
	eq(mem.ns.Donations.Goal().title, "Back to bank"); eq(mem.ns.Donations.Goal().owner, "Gm")
	eq(select(2, off.ns.Donations.SetGoal("Mounts again", 5)), "owned", "an officer still asks")
	-- a goal saved before 0.6.0 (no owner field) belongs to whoever wrote it
	W.now = W.now + 1
	mem.ns.Sync.Accept("dgoal", "goal", { rev = W.now, by = "Gm", data = "7;100;Old goal" })
	eq(mem.ns.Donations.Goal().owner, "Gm"); eq(mem.ns.Donations.Goal().title, "Old goal")
	-- an owner who left the guild doesn't block anyone
	W.now = W.now + 1
	mem.ns.Sync.Accept("dgoal", "goal", { rev = W.now, by = "Gm", data = "8;100;Stuck;Gone Person" })
	eq(mem.ns.Donations.CanEdit("Off"), true)
	eq(#gm.env.IwTDB.errors, 0); eq(#off.env.IwTDB.errors, 0)
end)

test("polls: our votes on polls no longer listed are tidied away", function()
	local g = Guild2()
	local gm, mem = W.NewClient(base, "Gm", g), W.NewClient(base, "Mem", g)
	local t0 = W.now
	assert(gm.ns.Polls.Ask("Raid night?", "Fri, Sat", 1))
	assert(gm.ns.Polls.Ask("Bank tabs?", "Yes, No", 7))
	local ids = {}
	for id in mem.ns.Sync.Each("polls") do ids[#ids + 1] = id end
	table.sort(ids)
	assert(mem.ns.Polls.Vote(ids[1], 1)); assert(mem.ns.Polls.Vote(ids[2], 2))
	W.now = t0 + 3 * 86400 -- the first poll has closed: its result is still shown
	eq(mem.ns.Polls.TidyMyVotes(), false)
	assert(mem.ns.Polls.Vote(ids[2], 1))
	assert(mem.ns.Sync.Get("votes", "Mem"):find(ids[1] .. "=1", 1, true), "voting again keeps a recently closed poll's vote")
	W.now = t0 + 9 * 86400 -- closed over a week ago: no longer listed
	assert(mem.ns.Polls.TidyMyVotes())
	eq(gm.ns.Sync.Get("votes", "Mem"), ids[2] .. "=1")
	W.now = t0 + 20 * 86400
	assert(mem.ns.Polls.TidyMyVotes())
	eq(gm.ns.Sync.Get("votes", "Mem"), nil, "nothing left: deleted")
	W.now = t0
end)

test("polls: officers ask, one vote per player (alts once), votes can change, closed polls stop voting", function()
	local g = { members = { { "Mem", 3, true }, { "Gm", 0, true }, { "Other", 3, true } } }
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	local other = W.NewClient(base, "Other", g)
	eq((mem.ns.Polls.Ask("Raid night?", "Fri, Sat")), false, "members can't ask")
	eq(select(2, gm.ns.Polls.Ask("x", "only one")), "Give at least two answers.")
	assert(gm.ns.Polls.Ask("Raid night?", "Friday, Saturday / Sunday", 3))
	local poll = mem.ns.Polls.List()[1]
	eq(poll.question, "Raid night?"); eq(#poll.answers, 3); eq(poll.open, true)
	assert(mem.ns.Polls.Vote(poll.id, 1))
	assert(other.ns.Polls.Vote(poll.id, 2))
	assert(mem.ns.Polls.Vote(poll.id, 3)) -- changed mind
	local counts, total = gm.ns.Polls.Results(poll.id)
	eq(total, 2); eq(counts[1], 0); eq(counts[2], 1); eq(counts[3], 1)
	eq(mem.ns.Polls.List()[1].mine, 3)
	eq(mem.ns.Polls.OpenCount(), 1)
	assert(gm.ns.Polls.Close(poll.id))
	eq(mem.ns.Polls.Vote(poll.id, 1), false, "closed")
	eq(mem.ns.Polls.List()[1].open, false)
	eq(mem.ns.Polls.OpenCount(), 0)
	assert(gm.ns.Polls.Remove(poll.id))
	eq(#mem.ns.Polls.List(), 0)
	mem.ns.UI.Open("Polls")
	eq(#mem.env.IwTDB.errors, 0)
end)

test("home: what's on shows open polls and the donation goal; the calendar is gone", function()
	local g = { members = { { "Mem", 3, true }, { "Gm", 0, true } } }
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	eq(mem.ns.Calendar, nil); eq(mem.ns.LFG, nil)
	assert(gm.ns.Polls.Ask("Raid night?", "Fri, Sat"))
	local f = mem.ns.GeneralTab.Facts()
	eq(f.nextEvent, nil); eq(f.openPolls, 1); eq(f.donations.title, "Guild bank")
	mem.ns.UI.Toggle()
	mem.ns.GeneralTab.Refresh()
	eq(mem.ns.UI.tabs[5].title, "Guild life"); eq(mem.ns.UI.tabs[6], nil, "no Hop tab since 0.9.0")
	eq(#mem.env.IwTDB.errors, 0)
end)

test("saved data of removed features is dropped at load", function()
	local g = { members = { { "Mem", 3, true } } }
	local c = W.NewClient(base, "Mem", g)
	c.env.IwTDB.sync.events = { records = { x = { rev = 1, by = "Gm", data = "y" } } }
	c.env.IwTDB.sync.lfg = { records = {} }
	c.ns.Sync:OnLoad()
	eq(c.env.IwTDB.sync.events, nil); eq(c.env.IwTDB.sync.lfg, nil)
end)

test("loot notes: the name box suggests guildmates as you type, like the mailbox", function()
	local g = { members = { { "Mem", 3, true }, { "Gm", 0, true }, { "Sara Exe", 3, false, 2 }, { "Sara Best", 3, true }, { "Large Joseph", 3, true } } }
	local gm = W.NewClient(base, "Gm", g)
	local UI = gm.ns.UI
	local function names(list) local o = {} for i, k in ipairs(list) do o[i] = gm.ns.Roster.DisplayName(k) end return table.concat(o, ",") end
	eq(names(UI.NameMatches("sa")), "Sara Best,Sara Exe", "online first")
	eq(names(UI.NameMatches("jos")), "Large Joseph", "surname works")
	eq(names(UI.NameMatches("e")), "Sara Exe,Large Joseph,Mem,Sara Best", "starts-with words first, then contains")
	eq(#UI.NameMatches(""), 0)
	gm.ns.UI.Open("Loot notes")
	local box = gm.ns.LootNotes.playerBox
	local s = box.suggest
	s.Update("sara")
	eq(#s.keys, 2)
	s.Move(1)
	local picked
	box.onPick = function(key) picked = key end
	assert(s.Pick())
	eq(gm.ns.Roster.DisplayName(picked), "Sara Exe")
	eq(#s.keys, 0, "the list closes")
	s.Update("Sara Exe")
	eq(#s.keys, 0, "nothing to suggest for an exact full name")
	eq(#gm.env.IwTDB.errors, 0)
end)

test("loot notes: officers note who got what, everyone can search, notes only", function()
	local g = { members = { { "Mem", 3, true }, { "Gm", 0, true }, { "Sara Exe", 3, true }, { "Sara Best", 3, true } } }
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	local L = gm.ns.LootNotes
	eq(L.ParseItem("|cffa335ee|Hitem:19019::::::::60:::::|h[Thunderfury]|h|r"), 19019)
	eq(select(2, L.ParseItem("[Onyxia Scale Cloak]")), "Onyxia Scale Cloak")
	eq((mem.ns.LootNotes.Add("Mem", "Thunderfury", "")), false, "members can't add notes")
	eq(select(2, L.Add("Nobody", "Thunderfury")), "Give the name of a guildmate.")
	eq((L.Add("Sara", "Thunderfury")), false, "two Saras: the full name is needed")
	eq(select(2, L.Add("Mem", "")), "Give the item (shift-click it into the box, or type its name).")
	assert(L.Add("Mem", "|cffa335ee|Hitem:19019::::::::60:::::|h[Thunderfury]|h|r", "main spec; MC"))
	W.now = W.now + 1
	assert(L.Add("Sara Exe", "Onyxia Scale Cloak", "for the Nef fight"))
	local list = mem.ns.LootNotes.List()
	eq(#list, 2); eq(list[1].player, "Sara Exe"); eq(list[2].itemID, 19019); eq(list[2].item, "Thunderfury")
	eq(list[2].note, "main spec MC", "no separators in notes")
	eq(#mem.ns.LootNotes.List("thunder"), 1); eq(#mem.ns.LootNotes.List("sara exe"), 1); eq(#mem.ns.LootNotes.List("nef"), 1)
	eq(mem.ns.LootNotes.CountFor("Mem"), 1)
	assert(gm.ns.LootNotes.Remove(list[1].key))
	eq(#mem.ns.LootNotes.List(), 1)
	gm.ns.UI.Open("Loot notes")
	eq(gm.ns.LootNotes.panel:IsShown(), true)
	-- shift-click: taken only while the item box has (or just had) focus
	local box = gm.ns.LootNotes.itemBox
	local got
	box.IsVisible = function() return true end
	box.HasFocus = function() return false end
	box.SetText = function(_, t) got = t end
	eq(L.TakeLink("|cff1eff00|Hitem:2589::|h[Linen Cloth]|h|r"), nil, "box not in focus")
	box.HasFocus = function() return true end
	eq(L.TakeLink("|cff1eff00|Hitem:2589::|h[Linen Cloth]|h|r"), true)
	assert(got:find("Linen Cloth", 1, true))
	eq(L.TakeLink("|Hspell:123|h[Fireball]|h"), nil, "only items")
	mem.ns.UI.Open("Loot notes")
	eq(mem.ns.LootNotes.panel:IsShown(), true)
	eq(#mem.env.IwTDB.errors, 0)
end)

test("self-test: checks pass offline, the guild echo is seen, and the report is copyable", function()
	local mem = W.NewClient(base, "Mem", Guild2())
	for _, api in ipairs({ "GetStatistic", "GetPVPLifetimeStats", "DepositGuildBankMoney", "hooksecurefunc" }) do
		mem.env[api] = mem.env[api] or function() end
	end
	mem.ns.LootNotes.hooks = { "ChatEdit_InsertLink" }
	local done
	mem.ns.SelfTest.ECHO_WAIT = 1
	mem.ns.SelfTest.Run(function(text, passed, failed) done = { text = text, passed = passed, failed = failed } end)
	mem.flush()
	assert(done, "finished")
	eq(done.failed, 0, done.text)
	assert(done.text:find("PASS  Guild addon messages go out", 1, true), done.text)
	assert(done.text:find("PASS  Every page opens", 1, true))
	eq(mem.ns.UI.window:IsShown(), false, "the window is left as it was")
	mem.ns.HandleSlash("selftest")
	mem.flush()
	eq(#mem.env.IwTDB.errors, 0)
end)

test("every Lua file in the addon folder is listed in the TOC", function()
	local toc = io.open(base .. "/IssuesWithTissues/IssuesWithTissues.toc"):read("*a")
	local listed = {}
	for line in toc:gmatch("[^\r\n]+") do if line:match("%.lua$") then listed[line] = true end end
	local ok, p = pcall(io.popen, 'ls "' .. base .. '/IssuesWithTissues"')
	if not ok or not p then return end -- this Lua can't list folders
	for f in p:lines() do
		if f:match("%.lua$") then assert(listed[f], f .. " is not in the TOC") end
	end
	p:close()
end)

test("crafters board: search shows crafters online first, empty search lists by profession", function()
	local g = { members = { { "Mem", 3, true }, { "Gm", 0, true }, { "Off", 3, false, 1 } } }
	local mem = W.NewClient(base, "Mem", g)
	local off = W.NewClient(base, "Off", g)
	local gm = W.NewClient(base, "Gm", g)
	mem.skills = { { "Tailoring", 120, 150 } }; mem.ns.Professions.UpdateSkills()
	off.skills = { { "Tailoring", 200, 225 } }; off.ns.Professions.UpdateSkills()
	mem.tradeSkill = { name = "Tailoring", recipes = { { 1, "Bolt of Linen Cloth", 2996 } } }
	mem.ns.Professions.ReadOpenWindow(false)
	off.tradeSkill = { name = "Tailoring", recipes = { { 1, "Bolt of Linen Cloth", 2996 }, { 2, "Linen Bag", 4238 } } }
	off.ns.Professions.ReadOpenWindow(false)
	local C = gm.ns.CraftersTab
	local rows = C.Search("linen")
	eq(#rows, 3)
	eq(rows[1].name, "Bolt of Linen Cloth"); eq(rows[1].who, "Mem", "online crafter first"); eq(rows[1].rank, 120)
	eq(rows[2].who, "Off")
	eq(#C.Search("linen", true), 1, "online only")
	local byProf = C.ByProfession()
	eq(byProf[1].who, "Off", "highest skill first"); eq(byProf[1].recipes, 2)
	-- the tree: professions closed until clicked, then their crafters underneath
	local tree = C.Tree()
	eq(tree[1].header, true); eq(tree[1].profession, "Tailoring"); eq(tree[1].crafters, 2); eq(tree[1].online, 1)
	for _, r in ipairs(tree) do eq(r.header, true, "all closed at first") end
	C.Toggle("Tailoring")
	tree = C.Tree()
	eq(tree[2].who, "Off"); eq(tree[3].who, "Mem"); eq(tree[3].header, nil)
	eq(#C.Tree(true), 2, "online only: Tailoring and its online crafter")
	C.Toggle("Tailoring")
	eq(C.Tree()[2] == nil or C.Tree()[2].header, true, "closed again")
	gm.ns.UI.Open("Crafters")
	eq(#gm.env.IwTDB.errors, 0)
end)

test("tooltips: a green \"Guild craftable\" line when someone knows the recipe, nothing otherwise", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	local off = W.NewClient(base, "Gm", g)
	off.skills = { { "Tailoring", 200, 225 } }; off.ns.Professions.UpdateSkills()
	off.tradeSkill = { name = "Tailoring", recipes = { { 1, "Bolt of Linen Cloth", 2996 }, { 2, "Linen Bag", 4238 } } }
	off.ns.Professions.ReadOpenWindow(false)
	local T = mem.ns.Tooltip
	local function Tip(name, id)
		local t = { lines = {} }
		function t:GetItem() return name, id and ("|cffffffff|Hitem:" .. id .. "::::|h[" .. name .. "]|h|r") end
		function t:AddLine(text, r, g, b) self.lines[#self.lines + 1] = { text, r, g, b } end
		function t:Show() end
		T.Add(t)
		return t.lines, t
	end
	local lines = Tip("Linen Bag", 4238)
	eq(#lines, 1); eq(lines[1][1], "Guild craftable"); eq(lines[1][3], 1, "green")
	eq(#Tip("Pattern: Linen Bag", 5771), 1, "a pattern for a recipe someone knows")
	eq(#Tip("Plans: Arcanite Reaper", 12345), 0, "nobody knows it: no line, not \"no\"")
	eq(#Tip("Linen Cloth", 2589), 0)
	-- once per item, even when the game asks twice
	local _, t = Tip("Linen Bag", 4238)
	T.Add(t)
	eq(#t.lines, 1)
	-- new recipes show up straight away
	off.tradeSkill = { name = "Tailoring", recipes = { { 1, "Bolt of Linen Cloth", 2996 }, { 2, "Linen Bag", 4238 }, { 3, "Brown Linen Robe", 6238 } } }
	off.ns.Professions.ReadOpenWindow(false)
	eq(#Tip("Brown Linen Robe", 6238), 1)
	-- Settings can turn it off
	mem.env.IwTDB.settings.tooltipCraftable = false
	eq(#Tip("Linen Bag", 4238), 0)
	mem.env.IwTDB.settings.tooltipCraftable = true
	eq(T.hooked, true, "hooked at login")
	eq(#mem.env.IwTDB.errors, 0)
end)

test("sync: records carry a data version; older ones are upgraded, newer ones left alone", function()
	local g = Guild2()
	local old = W.NewClient(base, "Gm", g)
	local new = W.NewClient(base, "Mem", g)
	old.ns.Sync.Define("vtest", { writer = "member" })
	new.ns.Sync.Define("vtest", { writer = "member", version = 2, upgrade = function(data, from)
		return "v" .. from .. ">" .. data
	end })
	-- a version 1 record reaches the newer client and is upgraded on the way in
	assert(old.ns.Sync.Set("vtest", "a", "hello"))
	eq(new.ns.Sync.Get("vtest", "a"), "v1>hello")
	eq(new.env.IwTDB.sync.vtest.records.a.v, 2)
	-- a version 2 record is left alone by the older client
	assert(new.ns.Sync.Set("vtest", "b", "fresh"))
	eq(old.ns.Sync.Get("vtest", "b"), nil)
	eq(old.ns.Sync.newer, 1)
	-- saved version 1 records are upgraded at load; version 1 isn't written to saved data
	eq(old.env.IwTDB.sync.vtest.records.a.v, nil)
	local saved = new.env.IwTDB.sync.vtest.records
	saved.c = { rev = 1, by = "Gm", data = "kept" }
	saved.d = { rev = 1, by = "Gm", data = "future", v = 3 }
	new.ns.Sync.UpgradeSaved()
	eq(saved.c.data, "v1>kept"); eq(saved.c.v, 2)
	eq(saved.d, nil, "from a newer version: dropped")
	eq(#old.env.IwTDB.errors, 0); eq(#new.env.IwTDB.errors, 0)
end)

test("comms wait in combat, go slowly in a raid or dungeon, and skip catch-ups there", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local Comm = c.ns.Comm
	local sent = {}
	Comm.sendHook = function(_, packet) sent[#sent + 1] = packet end
	Comm.immediate = false
	c.timers = {}
	-- combat: nothing goes out; it looks again in a moment
	c.env.InCombatLockdown = function() return true end
	eq(Comm.Held(), "combat")
	Comm.Send("X", "one")
	eq(#sent, 0); eq(c.timers[#c.timers].sec, Comm.HOLD_CHECK)
	local asked = 0
	Comm.sendHook = function(_, packet) sent[#sent + 1] = packet; if packet:find("\tSQ\t") then asked = asked + 1 end end
	c.ns.Sync.Ask()
	eq(asked, 0, "no catch-up in combat")
	-- out of combat, in a raid: one packet, then a second's wait
	c.env.InCombatLockdown = function() return false end
	c.env.IsInInstance = function() return true, "raid" end
	eq(Comm.Held(), "raid")
	Comm.Send("X", "two") -- already pumping: just queued
	Comm.Pump()
	eq(#sent, 1); eq(c.timers[#c.timers].sec, Comm.RAID_INTERVAL)
	-- in a dungeon: slow too, and no catch-up
	c.env.IsInInstance = function() return true, "party" end
	eq(Comm.Held(), "raid")
	asked = 0
	c.ns.Sync.Ask()
	eq(asked, 0, "no catch-up in a dungeon")
	-- a battleground or the open world: the usual pace
	c.env.IsInInstance = function() return true, "pvp" end
	eq(Comm.Held(), nil)
	c.env.IsInInstance = function() return false, "none" end
	eq(Comm.Held(), nil)
	Comm.Pump()
	eq(#sent, 2)
	eq(#c.env.IwTDB.errors, 0)
end)

test("guild news: joins, leaves, level 60s and promotions this week, from roster changes", function()
	local g = Guild2()
	local gm = W.NewClient(base, "Gm", g)
	local N = gm.ns.News
	eq(#N.List(), 0, "the first roster is only remembered")
	eq(gm.ns.GeneralTab.NewsText():find("Nothing new", 1, true) ~= nil, true)
	-- a join, a leave, a 60 and a promotion
	table.insert(g.members, { "Newbie", 4, true, 0, 5 })
	table.remove(g.members, 6) -- Gone
	g.members[4][5] = 60       -- Mem dings 60
	g.members[3][2] = 1        -- Vet promoted to Officer
	gm.env.__fire("GUILD_ROSTER_UPDATE")
	local texts = {}
	for _, e in ipairs(N.List()) do texts[#texts + 1] = e.text end
	table.sort(texts)
	eq(table.concat(texts, "|"), "Gone left the guild|Mem reached level 60|Newbie joined the guild|Vet was promoted to Rank1")
	-- seen again: no repeats
	gm.env.__fire("GUILD_ROSTER_UPDATE")
	eq(#N.List(), 4)
	-- Home shows three and "and 1 more"
	local text = gm.ns.GeneralTab.NewsText()
	assert(text:find("and 1 more", 1, true), text)
	-- a roster that's still loading isn't taken as everyone leaving
	local saved = g.members
	g.members = { saved[1] }
	gm.env.__fire("GUILD_ROSTER_UPDATE")
	eq(#N.List(), 4)
	g.members = saved
	-- a week later it's gone
	W.now = W.now + 8 * 86400
	eq(#N.List(), 0)
	eq(#gm.env.IwTDB.errors, 0)
end)

test("new member nudge: officers are told to say hi, members aren't", function()
	local g = Guild2()
	local gm = W.NewClient(base, "Gm", g)
	local mem = W.NewClient(base, "Mem", g)
	eq(gm.ns.News.Joined("Sara Exe has joined the guild."), "Sara Exe")
	eq(gm.ns.News.Joined("Sara Exe has come online."), nil)
	local before = #(gm.printed or {})
	gm.env.__fire("CHAT_MSG_SYSTEM", "Sara Exe has joined the guild.")
	eq(#gm.printed, before + 1)
	assert(gm.printed[#gm.printed]:find("Sara Exe just joined the guild. Say hi!", 1, true))
	local mb = #(mem.printed or {})
	mem.env.__fire("CHAT_MSG_SYSTEM", "Sara Exe has joined the guild.")
	eq(#(mem.printed or {}), mb)
	eq(#gm.env.IwTDB.errors, 0); eq(#mem.env.IwTDB.errors, 0)
end)

test("unread chat: guildmates' messages count on the Chat tab and minimap; online lines and your own don't", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	local Chat = mem.ns.Chat
	mem.ns.UI.CreateMinimapButton()
	Chat.unread = 0
	mem.env.__fire("CHAT_MSG_GUILD", "hello", "Gm-Realm")
	mem.env.__fire("CHAT_MSG_GUILD", "me again", "Mem-Realm")
	mem.env.__fire("CHAT_MSG_SYSTEM", "Gm has gone offline.")
	eq(Chat.unread, 1)
	eq(Chat.CountsAsUnread("sys", nil), false); eq(Chat.CountsAsUnread("msg", "Mem-Realm"), false)
	eq(Chat.CountsAsUnread("msg", "Gm-Realm"), true)
	-- the minimap summary: online, open polls, the donation goal, unread chat
	assert(gm.ns.Polls.Ask("Raid night?", "Fri, Sat"))
	local lines = mem.ns.UI.MinimapSummary()
	assert(lines[1]:find("online", 1, true) and lines[1]:find("1 open poll", 1, true), lines[1])
	eq(lines[2], "|cffffd1001 unread in guild chat|r")
	-- opening Chat clears it
	mem.ns.UI.Open("Chat")
	eq(Chat.unread, 0)
	eq(#mem.ns.UI.MinimapSummary(), 1)
	eq(#mem.env.IwTDB.errors, 0)
end)

test("empty lists say why, so they never look broken", function()
	local g = Guild2()
	local gm = W.NewClient(base, "Gm", g)
	local mem = W.NewClient(base, "Mem", g)
	local C = mem.ns.CraftersTab
	assert(C.EmptyText(false, false):find("Nobody has shared recipes yet", 1, true))
	gm.skills = { { "Tailoring", 200, 225 } }; gm.ns.Professions.UpdateSkills()
	gm.tradeSkill = { name = "Tailoring", recipes = { { 1, "Linen Bag", 4238 } } }
	gm.ns.Professions.ReadOpenWindow(false)
	assert(C.EmptyText(true, false):find("Nobody in the guild has shared a recipe like that", 1, true))
	assert(C.EmptyText(true, true):find("Nobody online", 1, true))
	mem.ns.UI.Open("Crafters")
	C.state.search = "zzz"; C.Refresh()
	assert(C.panel and true)
	C.state.search = ""
	-- loot notes: officers are told how to add one
	assert(gm.ns.LootNotes.EmptyText(true):find("Shift-click", 1, true))
	assert(mem.ns.LootNotes.EmptyText(false):find("Officers note", 1, true))
	mem.ns.UI.Open("Loot notes")
	eq(#mem.env.IwTDB.errors, 0); eq(#gm.env.IwTDB.errors, 0)
end)

test("settings: the window opens on the last tab, Home or Chat", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local UI = c.ns.UI
	local function Current() return UI.tabs[UI.current].title end
	eq(c.env.IwTDB.settings.openOn, "last")
	UI.Open("Crafters"); UI.Toggle(); UI.Toggle()
	eq(Current(), "Crafting", "last used")
	c.env.IwTDB.settings.openOn = "Chat"
	UI.Toggle(); UI.Toggle()
	eq(Current(), "Chat")
	c.env.IwTDB.settings.openOn = "Home"
	UI.Toggle(); UI.Toggle()
	eq(Current(), "Home")
	-- the buttons in Settings
	UI.Open("Settings")
	c.ns.Settings.openButtons.Chat:GetScript("OnClick")()
	eq(c.env.IwTDB.settings.openOn, "Chat")
	eq(#c.env.IwTDB.errors, 0)
end)

test("guild key: the welcome card offers to make J open the addon, only on a click", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local W2 = c.ns.Welcome
	local binds = { J = "TOGGLEGUILDTAB" }
	c.env.GetBindingKey = function(action) for k, a in pairs(binds) do if a == action then return k end end end
	c.env.GetBindingAction = function(key) return binds[key] or "" end
	local saved
	c.env.SetBinding = function(key, action) binds[key] = action; return true end
	c.env.SaveBindings = function(set) saved = set end
	c.env.GetCurrentBindingSet = function() return 2 end
	eq(W2.GuildKey(), "J"); eq(W2.KeyIsOurs(), false)
	-- the welcome says so and shows the button; nothing changes yet
	W2.ShowWelcome()
	local card = c.env.IwTWelcomeCard or select(1, W2.ShowWelcome())
	eq(binds.J, "TOGGLEGUILDTAB")
	-- the click
	eq(W2.UseGuildKey(), "J")
	eq(binds.J, "IWT_TOGGLE"); eq(saved, 2)
	eq(W2.KeyIsOurs(), true)
	-- in combat it won't
	binds.J = "TOGGLEGUILDTAB"
	c.env.InCombatLockdown = function() return true end
	eq(W2.UseGuildKey(), false); eq(binds.J, "TOGGLEGUILDTAB")
	assert(card)
	eq(#c.env.IwTDB.errors, 0)
end)

test("every tab builds without errors", function()
	local c = W.NewClient(base, "Mem", Guild2())
	for _, t in ipairs(c.ns.UI.tabs) do c.ns.UI.Open(t.title) end
	eq(#c.env.IwTDB.errors, 0)
end)

test("layout: pages open by name, tabs remember their sub-tab, Settings is behind the cog", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local UI = c.ns.UI
	UI.Open("Crafters")
	eq(c.ns.CraftersTab.panel:IsShown(), true)
	eq(UI.tabs[UI.current].title, "Crafting")
	UI.Open("Donations")
	eq(UI.tabs[UI.current].title, "Guild life")
	UI.Open("Home")
	UI.SelectTab(5) -- Guild life again: back on Donations
	eq(UI.tabs[5].pages[UI.tabs[5].current].title, "Donations")
	eq(c.env.IwTDB.window.pages["Guild life"], "Donations", "remembered across sessions")
	UI.Open("Settings")
	eq(UI.settings.panel:IsShown(), true)
	eq(UI.tabs[5].frame:IsShown(), false)
	UI.cog:GetScript("OnClick")()
	UI.Open("Polls")
	eq(UI.tabs[5].title, "Guild life"); eq(UI.tabs[5].frame:IsShown(), true)
	eq(#c.env.IwTDB.errors, 0)
end)

test("no file assigns a Blizzard global like SlashCmdList (that taints every macro)", function()
	for _, f in ipairs(W.TOC_FILES) do
		local src = io.open(base .. "/IssuesWithTissues/" .. f):read("*a")
		for _, g in ipairs({ "SlashCmdList", "StaticPopupDialogs", "UISpecialFrames", "ChatFrame_OpenChat", "ChatEdit_InsertLink" }) do
			assert(not src:find("\n%s*" .. g .. "%s*=[^=]"), f .. " assigns " .. g)
		end
	end
end)

test("a burst of shared records redraws an open page once, not once per record", function()
	local g = Guild2()
	local c = W.NewClient(base, "Mem", g)
	c.ns.UI.Open("Roster")
	local T, builds = c.ns.RosterTab, 0
	local rows = T.Rows
	T.Rows = function(...) builds = builds + 1 return rows(...) end
	c.flush()
	builds = 0
	for i = 1, 200 do
		c.ns.Sync.Accept("kills", "Gm", { rev = W.now + i, by = "Gm", data = i .. ";0;s" })
	end
	eq(builds, 0, "nothing redrawn during the burst")
	c.flush()
	eq(builds, 1, "one redraw after it")
	-- scrolling repaints without rebuilding
	T.Refresh(false)
	eq(builds, 1)
	eq(c.ns.CleanText("  a|b;c  ", 3), "abc"); eq(c.ns.CleanText("x~y", nil, "~"), "xy")
	eq(#c.env.IwTDB.errors, 0)
end)

test("logout saves a roster snapshot for the web page export", function()
	local c = W.NewClient(base, "Mem", Guild2())
	c.env.__fire("PLAYER_LOGOUT")
	local snap = c.env.IwTDB.snapshot
	assert(snap and #snap.members > 0, "snapshot written")
	eq(snap.version, c.ns.VERSION)
	for _, m in ipairs(snap.members) do assert(m.name and m.note == nil) end
end)

test("diagnostics report: one string with errors, timings and usage, no names unless asked", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local R = c.ns.Report
	eq(R.Base64("Man"), "TWFu"); eq(R.Base64("Ma"), "TWE="); eq(R.Base64("M"), "TQ==")
	eq(R.Adler32("Wikipedia"), "11e60398")
	eq(R.Json({ a = 1, b = { 1, 2 }, c = "x\"y\n", d = true, e = 1.5 }), '{"a":1,"b":[1,2],"c":"x\\"y\\n","d":true,"e":1.5}')
	c.ns.ReportError("Interface/AddOns/IssuesWithTissues/UI.lua:10: boom")
	c.ns.HandleSlash("roster")
	c.ns.UI.Open("Polls")
	c.env.IwTDB.perf.on = true
	c.ns.Measure("test thing", function() end)
	local text = c.ns.HandleSlash("report") or R.Build()
	local s, json = R.Encode(R.Data())
	assert(s:match("^IWT1%.[A-Za-z0-9+/=]+%.%x%x%x%x%x%x%x%x$"), "format")
	assert(json:find('"addon":"' .. c.ns.VERSION .. '"', 1, true))
	assert(json:find("IssuesWithTissues/UI.lua:10: boom", 1, true), "error text, without the Interface/AddOns path")
	assert(not json:find("Interface/AddOns", 1, true))
	assert(json:find('"roster":1', 1, true), "roster command counted")
	assert(json:find('"Polls":1', 1, true), "page open counted")
	assert(json:find('"test thing"', 1, true), "profiler numbers")
	assert(not json:find('"character"', 1, true), "no name by default")
	assert(json:find('"version":"' .. c.ns.VERSION .. '"', 1, true), "errors carry the version they last happened on")
	assert(R.Encode(R.Data({ name = true })):len() > 0)
	assert(select(2, R.Encode(R.Data({ name = true }))):find('"character":"Mem"', 1, true))
	assert(#s < 6000, "short enough for a link: " .. #s)
	eq(#c.env.IwTDB.errors, 1)
end)

test("chat: guild and officer lines are kept apart, with class-coloured clickable names", function()
	local c = W.NewClient(base, "Mem", Guild2())
	c.env.RAID_CLASS_COLORS = { WARRIOR = { r = 1, g = 0.5, b = 0 } }
	c.env.__fire("CHAT_MSG_GUILD", "hello |cffffffff|Hitem:2589::::|h[Linen Cloth]|h|r", "Gm-Realm")
	c.env.__fire("CHAT_MSG_OFFICER", "secret", "Offi-Realm")
	local Chat = c.ns.Chat
	eq(#Chat.Lines("guild"), 1); eq(#Chat.Lines("officer"), 1)
	local line = Chat.Format("guild", Chat.Lines("guild")[1])
	assert(line:find("|Hplayer:Gm-Realm|h|cffff8000[Gm]|r|h", 1, true), line)
	assert(line:find("[Linen Cloth]", 1, true), "item links kept")
	eq(Chat.unread, 2, "counted while the chat page is closed")
	c.ns.UI.Open("Chat")
	eq(#c.env.IwTDB.errors, 0, "chat page builds")
	eq(Chat.unread, 0)
end)

test("chat: Enter sends to the right channel; commands go to the game's chat box", function()
	local c = W.NewClient(base, "Gm", Guild2())
	local sent, opened = {}, nil
	c.env.SendChatMessage = function(m, ch) sent[#sent + 1] = ch .. ":" .. m end
	c.env.ChatFrame_OpenChat = function(t) opened = t end
	local Chat = c.ns.Chat
	assert(Chat.Send("  hi all \n"))
	eq(sent[1], "GUILD:hi all")
	assert(Chat.Send("officers only", "officer"))
	eq(sent[2], "OFFICER:officers only")
	eq(Chat.Send("   "), false, "nothing to send")
	eq(Chat.Send("/roll"), false); eq(opened, "/roll"); eq(#sent, 2)
	assert(Chat.Send(string.rep("a", 300)))
	eq(#sent[3], #"GUILD:" + 255, "cut to 255 bytes")
	eq(Chat.sent[#Chat.sent], string.rep("a", 255), "kept for Up-arrow recall")
end)

test("chat: history stays on this PC, capped, and can be switched off", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local Chat = c.ns.Chat
	for i = 1, Chat.MAX_LINES + 5 do c.env.__fire("CHAT_MSG_GUILD", "line " .. i, "Gm-Realm") end
	eq(#c.env.IwTCharDB.chat.guild, Chat.MAX_LINES, "saved, capped")
	eq(c.env.IwTCharDB.chat.guild[1].m, "line 6", "oldest dropped")
	c.env.__fire("PLAYER_LOGOUT")
	local _, json = c.ns.Report.Encode(c.ns.Report.Data())
	assert(not json:find("line 1", 1, true), "never in the diagnostics report")
	assert(not (c.env.IwTDB.snapshot and c.env.IwTDB.snapshot.chat), "never in the web page snapshot")
	c.env.IwTDB.settings.chatHistory = false
	Chat.SetHistory(false)
	eq(c.env.IwTCharDB.chat, nil, "saved lines forgotten")
	eq(#Chat.Lines("guild"), Chat.MAX_LINES, "this session's lines still shown")
	c.env.__fire("CHAT_MSG_GUILD", "after", "Gm-Realm")
	eq(c.env.IwTCharDB.chat, nil, "nothing saved while off")
end)

test("chat: guildmates coming online show in the guild channel, friends outside the guild don't", function()
	local c = W.NewClient(base, "Mem", Guild2())
	c.env.__fire("CHAT_MSG_SYSTEM", "|Hplayer:Vet-Realm|h[Vet-Realm]|h has come online.")
	c.env.__fire("CHAT_MSG_SYSTEM", "Stranger has gone offline.")
	c.env.__fire("CHAT_MSG_SYSTEM", "Gone-Realm has gone offline.")
	local lines = c.ns.Chat.Lines("guild")
	eq(#lines, 2)
	eq(lines[1].m, "Vet has come online."); eq(lines[2].m, "Gone has gone offline.")
end)

test("key bindings: the window and guild chat can be bound to a key (J, for example)", function()
	local c = W.NewClient(base, "Mem", Guild2())
	eq(c.env.BINDING_HEADER_ISSUESWITHTISSUES, "Issues with Tissues")
	assert(c.env.BINDING_NAME_IWT_TOGGLE and c.env.BINDING_NAME_IWT_CHAT)
	local xml = io.open(base .. "/IssuesWithTissues/Bindings.xml"):read("*a")
	assert(xml:find('name="IWT_TOGGLE"', 1, true) and xml:find("IssuesWithTissues_Toggle()", 1, true))
	assert(not xml:find("header=", 1, true), "no header attribute (the Forever client shows it as a stray bind row)")
	local _, n = xml:gsub('category="BINDING_HEADER_ISSUESWITHTISSUES"', "")
	eq(n, 2, "both bindings in the addon's own category")
	assert(xml:find("IssuesWithTissues_Chat()", 1, true))
	c.env.IssuesWithTissues_Toggle()
	eq(c.ns.UI.window:IsShown(), true)
	c.env.IssuesWithTissues_Chat()
	eq(#c.env.IwTDB.errors, 0)
end)

test("chat: history from the game's server is merged with the saved lines, without duplicates", function()
	local c = W.NewClient(base, "Offi", Guild2())
	local now = W.now
	local server = {
		[1] = { { content = "old news", author = { name = "Gm" }, epoch = (now - 3600) * 1000000 },
		        { content = "hi", author = { name = "Gm" }, epoch = (now - 5) * 1000000 } },
		[2] = { { content = "officer stuff", author = { name = "Offi" }, epoch = (now - 100) * 1000000 } },
	}
	local asked = 0
	c.env.C_Club = {
		GetGuildClubId = function() return 215753832 end,
		GetStreams = function() return { { streamId = "g", streamType = 1 }, { streamId = "o", streamType = 2 } } end,
		RequestMoreMessagesBefore = function() asked = asked + 1 end,
		GetMessageRanges = function() return { { oldestMessageId = {}, newestMessageId = {} } } end,
		GetMessagesInRange = function(_, stream)
			local out = {}
			for i, m in ipairs(server[stream == "g" and 1 or 2]) do
				out[i] = { content = m.content, author = m.author, messageId = { epoch = m.epoch, position = i } }
			end
			return out
		end,
	}
	c.env.__fire("CHAT_MSG_GUILD", "hi", "Gm-Realm") -- also heard live: shown once
	local Chat = c.ns.Chat
	Chat.RequestServer()
	eq(asked, 2, "both channels asked for")
	local view = Chat.View("guild")
	eq(#view, 2); eq(view[1].m, "old news"); eq(view[2].m, "hi")
	eq(view[2].srv, nil, "the live copy is kept, the server's duplicate dropped")
	eq(#Chat.View("officer"), 1)
	eq(#c.env.IwTCharDB.chat.guild, 1, "server messages are shown, not saved")
	c.ns.UI.Open("Chat")
	eq(#c.env.IwTDB.errors, 0)
end)

test("chat: if the server's history can't be read, the saved lines still show", function()
	local c = W.NewClient(base, "Mem", Guild2())
	c.env.C_Club = { GetGuildClubId = function() error("not available") end, GetStreams = function() return {} end }
	c.env.__fire("CHAT_MSG_GUILD", "still here", "Gm-Realm")
	c.ns.Chat.RequestServer()
	eq(#c.ns.Chat.View("guild"), 1)
	c.ns.UI.Open("Chat")
	eq(#c.env.IwTDB.errors, 0, "logged, not an error")
end)

test("chat: online list shows only online guildmates, grouped by rank, Guild Master first", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local Chat = c.ns.Chat
	local rows, total = Chat.OnlineRows()
	eq(total, 2)
	eq(#rows, 4)
	eq(rows[1].rank, "Rank0"); eq(rows[2].key, "Gm")
	eq(rows[3].rank, "Rank3"); eq(rows[4].key, "Mem")
	c.env.__fire("CHAT_MSG_SYSTEM", "|Hplayer:Vet-Realm|h[Vet-Realm]|h has come online.")
	c.env.__fire("CHAT_MSG_SYSTEM", "Gm-Realm has gone offline.")
	rows, total = Chat.OnlineRows()
	eq(total, 2, "updated straight from the online/offline lines")
	eq(rows[1].rank, "Rank2"); eq(rows[2].key, "Vet")
	c.ns.UI.Open("Chat")
	assert(Chat.online, "the list is beside the chat")
	eq(#Chat.DrawOnline(), 4, "two ranks, two names")
	eq(#c.env.IwTDB.errors, 0)
end)

test("chat: the message of the day is kept once until it changes", function()
	local c = W.NewClient(base, "Mem", Guild2())
	for _ = 1, 3 do c.env.__fire("GUILD_MOTD", "Tabard designed") end
	c.env.__fire("CHAT_MSG_GUILD", "hi", "Gm-Realm")
	c.env.__fire("GUILD_MOTD", "Tabard designed")
	c.env.__fire("GUILD_MOTD", "Raid at 8")
	local lines = c.ns.Chat.Lines("guild")
	eq(#lines, 3); eq(lines[1].m, "Tabard designed"); eq(lines[3].m, "Raid at 8")
end)

test("chat: a server message without an author name falls back to the GUID or member record", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local Chat = c.ns.Chat
	c.env.C_Club = { GetMemberInfo = function(_, id) return id == 7 and { name = "Vet" } or nil end }
	c.env.GetPlayerInfoByGUID = function(g) if g == "Player-Gm" then return "Warrior", "WARRIOR", "", "", 0, "Gm", "" end end
	eq(Chat.AuthorName(1, { name = "Offi" }), "Offi")
	eq(Chat.AuthorName(1, { guid = "Player-Gm" }), "Gm")
	eq(Chat.AuthorName(1, { memberId = 7 }), "Vet")
	eq(Chat.AuthorName(1, {}), nil)
	local line = Chat.Format("guild", { t = W.now, k = "msg", m = "hi" })
	assert(line:find("[Unknown]", 1, true), line)
end)

test("chat: a server copy spelt differently still counts as the same message; two people saying the same thing both show", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local now = W.now
	local msgs = {
		{ content = "Go get him ", author = { name = "Gm-Surname-CAMWOWEU5Realm6PvP" }, epoch = (now + 30) * 1000000 },
		{ content = "lol", author = { name = "Gm" }, epoch = now * 1000000 },
		{ content = "lol", author = { name = "Mem" }, epoch = now * 1000000 },
	}
	local names = true
	c.env.C_Club = {
		GetGuildClubId = function() return 1 end,
		GetStreams = function() return { { streamId = "g", streamType = 1 } } end,
		GetMessageRanges = function() return { { oldestMessageId = {}, newestMessageId = {} } } end,
		GetMessagesInRange = function()
			local out = {}
			for i, m in ipairs(msgs) do
				out[i] = { content = m.content, author = { name = names and m.author.name or nil }, messageId = { epoch = m.epoch, position = i } }
			end
			return out
		end,
	}
	c.env.__fire("CHAT_MSG_GUILD", "Go get him", "Gm-Realm")
	c.env.__fire("CHAT_MSG_GUILD", "lol", "Gm-Realm")
	local Chat = c.ns.Chat
	Chat.ReadServer()
	local view = Chat.View("guild")
	eq(#view, 3, "the live 'Go get him' and 'lol' hide their server copies; the second 'lol' stays")
	names = false -- a later read without names keeps the ones found before
	Chat.ReadServer()
	for _, e in ipairs(Chat.server.guild) do assert(e.a, "author remembered") end
end)

test("chat: a server copy with hidden text matches the live line from the same person at the same time", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local now = W.now
	c.env.C_Club = {
		GetGuildClubId = function() return 1 end,
		GetStreams = function() return { { streamId = "g", streamType = 1 }, { streamId = "o", streamType = 2 } } end,
		GetMessageRanges = function() return { { oldestMessageId = {}, newestMessageId = {} } } end,
		GetMessagesInRange = function(_, stream)
			if stream == "o" then
				return { { content = "|Kq7|k", author = { name = "Gm" }, messageId = { epoch = now * 1000000, position = 1 } } }
			end
			return {
				{ content = "|Kq1|k", author = { name = "Gm" }, messageId = { epoch = now * 1000000, position = 1 } },
				{ content = "|Kq2|k", author = { name = "Gm" }, messageId = { epoch = (now + 1) * 1000000, position = 2 } },
				{ content = "|Kq3|k", author = { name = "Vet" }, messageId = { epoch = (now + 60) * 1000000, position = 3 } },
			}
		end,
	}
	c.env.__fire("CHAT_MSG_GUILD", "first", "Gm-Realm")
	c.env.__fire("CHAT_MSG_OFFICER", "|Kx1|k", "Gm-Realm")
	local Chat = c.ns.Chat
	Chat.ReadServer()
	local view = Chat.View("guild")
	eq(#view, 3, "Gm's live line hides one copy; Gm's second message and Vet's stay")
	eq(view[1].m, "first")
	eq(#Chat.View("officer"), 1, "officer copy matched too")
end)

test("chat: hidden text saved in an earlier session is replaced by the server's copy, or dropped", function()
	local c = W.NewClient(base, "Gm", Guild2())
	local now = W.now
	local Chat = c.ns.Chat
	c.env.__fire("CHAT_MSG_OFFICER", "|Kx1|k", "Gm-Realm")
	c.env.__fire("CHAT_MSG_OFFICER", "|Kx2|k", "Gm-Realm")
	c.env.IwTCharDB.chat.officer[2].t = now - 7200
	Chat:OnLoad() -- as after logging back in
	assert(c.env.IwTCharDB.chat.officer[1].old)
	eq(#Chat.View("officer"), 0, "nothing that would show as Unknown")
	c.env.C_Club = {
		GetGuildClubId = function() return 1 end,
		GetStreams = function() return { { streamId = "o", streamType = 2 } } end,
		GetMessageRanges = function() return { { oldestMessageId = {}, newestMessageId = {} } } end,
		GetMessagesInRange = function()
			return { { content = "|Kq9|k", author = { name = "Gm" }, messageId = { epoch = now * 1000000, position = 1 } } }
		end,
	}
	Chat.ReadServer()
	local view = Chat.View("officer")
	eq(#view, 1); eq(view[1].m, "|Kq9|k", "the server's fresh copy")
end)

test("themes: Default leaves every colour as it was", function()
	local c = W.NewClient(base, "Mem", Guild2())
	c.env.RAID_CLASS_COLORS = { ROGUE = { r = 1, g = 0.96, b = 0.41 } }
	local UI = c.ns.UI
	eq(UI.theme.id, "default")
	local r, g, b = UI.ClassColor("ROGUE")
	eq(r, 1); eq(g, 0.96); eq(b, 0.41)
	eq(UI.Recolor("|cffffd100Elite|r"), "|cffffd100Elite|r")
	eq(UI.COLORS.tabtext[1], 0.78)
end)

test("themes: a saved theme applies at load; faint class colours and words are made readable", function()
	local first = W.NewClient(base, "Mem", Guild2())
	first.env.IwTDB.settings.theme = "kawaiiDay"
	local c = W.NewClient(base, "Mem", Guild2(), { account = first })
	c.env.RAID_CLASS_COLORS = { ROGUE = { r = 1, g = 0.96, b = 0.41 }, PRIEST = { r = 1, g = 1, b = 1 }, MAGE = { r = 0.41, g = 0.8, b = 0.94 } }
	local UI = c.ns.UI
	eq(UI.theme.id, "kawaiiDay")
	eq(UI.COLORS.bg[1] > 0.9, true, "light panels")
	for _, cls in ipairs({ "ROGUE", "PRIEST", "MAGE" }) do
		local r, g, b = UI.ClassColor(cls)
		assert(UI.Contrast({ r, g, b }, UI.theme.ref) >= UI.MIN_CONTRAST, cls .. " readable")
	end
	assert(UI.Recolor("|cffffd100Elite|r") ~= "|cffffd100Elite|r", "yellow words darkened")
	eq(UI.Recolor("plain"), "plain")
	local r = select(1, c.ns.Chat.ChannelColor("guild"))
	eq(math.floor(r * 255 + 0.5), 0x1d, "the theme's own chat colour")
	for _, ch in ipairs({ "guild", "officer" }) do
		local cr, cg, cb = c.ns.Chat.ChannelColor(ch)
		assert(UI.Contrast({ cr, cg, cb }, UI.theme.ref) >= UI.MIN_CONTRAST, ch .. " chat readable on Kawaii Day")
	end
	-- the game's outlined chat font loses its outline on a light theme
	local font = { flags = "OUTLINE" }
	function font:GetFont() return "Fonts\\ARIALN.TTF", 14, self.flags end
	function font:SetFont(_, _, flags) self.flags = flags end
	function font:SetShadowColor(_, _, _, a) self.shadow = a end
	eq(UI.PlainFont(font), true); eq(font.flags, ""); eq(font.shadow, 0)
	UI.Open("Chat"); UI.Open("Settings"); UI.Open("Roster")
	eq(#c.env.IwTDB.errors, 0)
end)

test("themes: every theme has every colour, and picking one in Settings waits for a reload", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local UI = c.ns.UI
	local keys = {}
	for k in pairs(UI.COLORS) do keys[#keys + 1] = k end
	for _, t in ipairs(UI.THEMES) do
		if t.colors then
			for _, k in ipairs(keys) do assert(t.colors[k], t.id .. " has " .. k) end
			assert(t.ink and t.ref, t.id)
			eq(UI.Contrast(t.colors.text, t.ref) >= UI.MIN_CONTRAST, true, t.id .. " body text readable")
			eq(UI.Contrast(t.colors.gold, t.ref) >= UI.MIN_CONTRAST, true, t.id .. " headings readable")
			eq(UI.Contrast(t.colors.primarytext, t.colors.primary) >= UI.MIN_CONTRAST, true, t.id .. " Send button readable")
		end
	end
	UI.Open("Settings")
	-- The theme drop-down: click to list them, pick one, the list closes
	local S = c.ns.Settings
	S.themePick:GetScript("OnClick")()
	eq(S.themeList:IsShown(), true)
	assert(S.themeButtons.solarizedDark and S.themeButtons.solarizedLight, "both Solarized themes listed")
	S.themeButtons.solarizedDark:GetScript("OnClick")()
	eq(c.env.IwTDB.settings.theme, "solarizedDark"); eq(S.themeList:IsShown(), false)
	c.env.IwTDB.settings.theme = "midnight"
	eq(UI.theme.id, "default", "applies at the next reload")
	eq(#c.env.IwTDB.errors, 0)
end)

test("welcome: a first install gets the welcome card; an update gets What's new once", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local Welcome = c.ns.Welcome
	Welcome.updating = false
	c.env.IwTDB.seenVersion = nil
	Welcome.Check()
	eq(Welcome.shown, "Welcome to Issues with Tissues")
	eq(c.env.IwTDB.seenVersion, c.ns.VERSION)
	Welcome.shown = nil
	Welcome.Check()
	eq(Welcome.shown, nil, "only once")
	c.env.IwTDB.seenVersion = "0.7.2"
	Welcome.Check()
	eq(Welcome.shown, "What's new in Issues with Tissues")
	local notes = Welcome.NotesSince("0.7.2")
	eq(#notes, 2, "at most two versions"); eq(notes[1].version, c.ns.VERSION:match("^%d+%.%d+%.%d+"))
	eq(#Welcome.NotesSince(c.ns.VERSION), 0)
	-- someone updating from an older version without seenVersion yet: What's new, not Welcome
	c.env.IwTDB.seenVersion = nil
	Welcome.updating = true
	Welcome.shown = nil
	Welcome.Check()
	eq(Welcome.shown, "What's new in Issues with Tissues")
	eq(#c.env.IwTDB.errors, 0)
end)

test("welcome: a first install can take the tour of Home, Chat and Crafting", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local Wl = c.ns.Welcome
	local card = Wl.ShowWelcome()
	eq(card.tour, true, "the button takes the tour")
	card.open:GetScript("OnClick")()
	eq(Wl.tourAt, 1)
	eq(c.ns.UI.tabs[c.ns.UI.current].title, "Home")
	Wl.TourStep(2)
	eq(c.ns.UI.tabs[c.ns.UI.current].title, "Chat")
	local step = Wl.TourStep(3)
	eq(step.page, "Crafters"); eq(c.ns.UI.tabs[c.ns.UI.current].title, "Crafting")
	Wl.TourStep(4)
	eq(Wl.tourAt, nil, "past the last step ends it")
	-- What's new keeps the plain button
	eq(Wl.ShowWhatsNew("1.0.0").tour, false)
	eq(#c.env.IwTDB.errors, 0)
end)

test("welcome: every release has What's new notes (keep Welcome.NOTES up to date)", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local W2 = c.ns.Welcome
	local a, b, d = W2.ParseVersion(c.ns.VERSION)
	eq(W2.NOTES[1].version, string.format("%d.%d.%d", a, b, d), "the newest notes are for this version")
end)

test("versions compare as numbers, and a release beats its betas", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local N = c.ns.Welcome.Newer
	eq(N("0.10.0", "0.9.9"), true); eq(N("0.8.1", "0.8.0"), true); eq(N("0.8.0", "0.8.0"), false)
	eq(N("0.8.0", "0.8.0-beta.3"), true); eq(N("0.8.0-beta.3", "0.8.0"), false)
	eq(N("0.8.0-beta.10", "0.8.0-beta.9"), true); eq(N("junk", "0.8.0"), false)
end)

test("updates: told once when a guildmate has a newer release; betas ignored", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local printed = {}
	c.env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) printed[#printed + 1] = m end }
	local U = c.ns.Updates
	c.ns.VERSION = "1.0.0" -- someone on a release (the build under test may be a beta)
	eq(U.Consider("Gm", "9.0.0-beta.1"), false, "a beta doesn't nag people on a release")
	eq(U.Consider("Gm", c.ns.VERSION), false)
	eq(U.Consider("Gm", "9.0.0"), true)
	eq(#printed, 1); assert(printed[1]:find("9.0.0", 1, true) and printed[1]:find("/iwt update", 1, true), printed[1])
	U.Consider("Vet", "9.0.0")
	eq(#printed, 1, "once per version")
	c.ns.HandleSlash("update")
	eq(#c.env.IwTDB.errors, 0)
end)

test("game options: a page under AddOns that opens the addon's settings", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local registered
	c.env.Settings = { RegisterCanvasLayoutCategory = function(panel, name) return { panel = panel, name = name } end,
		RegisterAddOnCategory = function(cat) registered = cat end }
	c.ns.GameOptions.Register()
	eq(registered.name, "Issues with Tissues")
	eq(c.ns.GameOptions.how, "Settings")
	c.env.Settings = nil
	local added
	c.env.InterfaceOptions_AddCategory = function(p) added = p end
	c.ns.GameOptions.Register()
	eq(added.name, "Issues with Tissues")
	eq(#c.env.IwTDB.errors, 0)
end)

test("professions: a guildmate's older record with gathering skills shows only the crafting ones", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	mem.env.IwTDB.sync.profs = { records = { Gm = { rev = 1, data = "Herbalism:300:300,Mining:250:300,Tailoring:300:300", by = "Gm" } } }
	mem.env.IwTDB.sync.recipes = { records = { ["Gm#Mining"] = { rev = 1, data = "2840:Smelt Copper", by = "Gm" } } }
	local p = mem.ns.Professions.Of("Gm")
	eq(#p, 1); eq(p[1].name, "Tailoring")
	eq(#mem.ns.Professions.WhoCanMake("copper"), 0, "smelting isn't listed")
end)

test("feel: window sounds follow their setting", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local played = {}
	c.env.PlaySound = function(id) played[#played + 1] = id end
	local UI = c.ns.UI
	eq(UI.Sound("open"), true); eq(played[1], 839)
	c.env.SOUNDKIT = { IG_CHARACTER_INFO_CLOSE = 12345 }
	UI.Sound("close"); eq(played[2], 12345, "SOUNDKIT when the client has it")
	c.env.IwTDB.settings.windowSounds = false
	eq(UI.Sound("tab"), false); eq(#played, 2)
end)

test("feel: window size is kept between 70% and 130% in steps of 5", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local UI = c.ns.UI
	local f = UI.Create()
	local got
	f.SetScale = function(_, v) got = v end
	eq(UI.SetScale(2), 1.3); eq(got, 1.3)
	eq(UI.SetScale(0.83), 0.85)
	eq(UI.SetScale(0.1), 0.7)
	c.ns.HandleSlash("scale 90")
	eq(c.env.IwTDB.settings.scale, 0.9); eq(got, 0.9)
	UI.Open("Settings")
	assert(c.ns.Settings.scaleSlider, "the slider is on the Settings page")
end)

test("feel: with the option on, the window hides in combat and comes back after", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local UI = c.ns.UI
	local played = 0
	c.env.PlaySound = function() played = played + 1 end
	UI.Open("Home")
	c.env.__fire("PLAYER_REGEN_DISABLED")
	eq(UI.window:IsShown(), true, "off by default")
	c.env.__fire("PLAYER_REGEN_ENABLED")
	c.env.IwTDB.settings.hideInCombat = true
	c.env.__fire("PLAYER_REGEN_DISABLED")
	eq(UI.window:IsShown(), false)
	c.env.__fire("PLAYER_REGEN_ENABLED")
	eq(UI.window:IsShown(), true, "back after combat")
	-- Closed before combat: stays closed after.
	UI.window:Hide()
	c.env.__fire("PLAYER_REGEN_DISABLED"); c.env.__fire("PLAYER_REGEN_ENABLED")
	eq(UI.window:IsShown(), false)
	eq(UI.quiet, false)
end)

test("keyboard: Ctrl+F jumps to the search on Roster, Crafters and Loot notes; Enter picks the first result", function()
	local g = Guild2()
	local gm = W.NewClient(base, "Gm", g)
	local UI = gm.ns.UI
	UI.Open("Roster")
	assert(UI.keys, "the window listens for Ctrl+F")
	local focused
	local function Watch(box) box.SetFocus = function(self) focused = self end end
	Watch(gm.ns.RosterTab.searchBox)
	gm.env.IsControlKeyDown = function() return true end
	UI.window.scripts.OnKeyDown(UI.window, "F")
	eq(focused, gm.ns.RosterTab.searchBox)
	-- Searching names, then Enter
	local told
	gm.env.ChatFrame_SendTell = function(n) told = n end
	gm.ns.RosterTab.searchBox.onChange(" VE ")
	local rows = gm.ns.RosterTab.Rows()
	eq(#rows, 1); eq(rows[1].full, "Vet", "any case, spaces trimmed")
	gm.ns.RosterTab.searchBox.onEnter("ve")
	eq(told, "Vet")
	-- Crafters
	UI.Open("Crafters")
	Watch(gm.ns.CraftersTab.searchBox)
	UI.window.scripts.OnKeyDown(UI.window, "F")
	eq(focused, gm.ns.CraftersTab.searchBox)
	-- Plain F (no Ctrl) does nothing
	focused = nil
	gm.env.IsControlKeyDown = function() return false end
	UI.window.scripts.OnKeyDown(UI.window, "F")
	eq(focused, nil)
	UI.Open("Loot notes")
	eq(UI.FocusSearch(), true, "loot notes search too")
	-- Chat has no search: nothing happens
	gm.env.IsControlKeyDown = function() return true end
	UI.Open("Chat")
	eq(UI.FocusSearch(), false)
end)

test("keyboard: opened in combat, the window starts listening after combat", function()
	local c = W.NewClient(base, "Mem", Guild2())
	c.env.InCombatLockdown = function() return true end
	c.ns.UI.Open("Home")
	eq(c.ns.UI.keys, nil); eq(c.ns.UI.keyboardPending, true)
	c.env.InCombatLockdown = function() return false end
	c.env.__fire("PLAYER_REGEN_ENABLED")
	eq(c.ns.UI.keys, true)
end)

test("chat: scrolled up, a Newest button counts new lines and jumps back down", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local Chat = c.ns.Chat
	c.ns.UI.Open("Chat")
	local box = Chat.messages
	local offset = 0
	box.GetScrollOffset = function() return offset end
	box.ScrollToBottom = function() offset = 0 end
	c.env.__fire("CHAT_MSG_GUILD", "one", "Gm-Realm")
	eq(Chat.jump:IsShown(), false, "at the bottom: no button")
	offset = 3
	c.env.__fire("CHAT_MSG_GUILD", "two", "Gm-Realm")
	c.env.__fire("CHAT_MSG_GUILD", "three", "Gm-Realm")
	eq(Chat.unseen, 2); eq(Chat.jump:IsShown(), true)
	Chat.jump.scripts.OnClick(Chat.jump)
	eq(offset, 0); eq(Chat.unseen, 0); eq(Chat.jump:IsShown(), false)
end)

test("chat: 12 or 24-hour times", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local Chat = c.ns.Chat
	local t = os.time({ year = 2026, month = 11, day = 23, hour = 14, min = 5 })
	eq(Chat.Time(t), "14:05")
	c.env.IwTDB.settings.clock24 = false
	eq(Chat.Time(t), "2:05pm")
	eq(Chat.Time(os.time({ year = 2026, month = 11, day = 23, hour = 0, min = 30 })), "12:30am")
	eq(Chat.Time(os.time({ year = 2026, month = 11, day = 23, hour = 12, min = 0 })), "12:00pm")
	assert(Chat.Format("guild", { t = t, k = "msg", a = "Gm-Realm", m = "hi" }):find("2:05pm", 1, true))
end)

test("times: how long ago a moment was, and how long a span is, are separate helpers", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local UI = c.ns.UI
	local now = W.now
	eq(UI.TimeAgo(now - 120, now), "2 min ago")
	eq(UI.TimeAgo(now - 3 * 3600, now), "3 hours ago")
	eq(UI.TimeAgo(now - 86400 - 5, now), "yesterday")
	eq(UI.TimeAgo(now - 5), "just now", "defaults to now")
	eq(UI.Ago(300), "5m", "Polls' time left still works")
end)

test("chat: recent lines say how long ago, with the full time on hover", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local Chat = c.ns.Chat
	local now = os.time({ year = 2026, month = 11, day = 23, hour = 14, min = 30 })
	eq(Chat.Stamp(now - 20, now), "just now")
	eq(Chat.Stamp(now - 120, now), "2 min ago")
	eq(Chat.Stamp(now - 7200, now), "12:30", "earlier today: the clock time")
	eq(Chat.Stamp(now - 86400, now), "22 Nov 14:30", "another day: the date too")
	c.env.IwTDB.settings.relativeTimes = false
	eq(Chat.Stamp(now - 120, now), "14:28")
	eq(Chat.FullTime(now - 7200), "Monday 23 November 2026, 12:30:00")
	local line = Chat.Format("guild", { t = now - 7200, k = "msg", a = "Gm-Realm", m = "hi" })
	assert(line:find("|Hiwttime:" .. (now - 7200) .. "|h", 1, true), "the stamp is a hover link")
end)

test("bug report: memory use and startup times", function()
	local c = W.NewClient(base, "Mem", Guild2())
	c.env.UpdateAddOnMemoryUsage = function() end
	c.env.GetAddOnMemoryUsage = function(name) if name == "IssuesWithTissues" then return 1234.4 end end
	local report = c.ns.Diagnostics.BuildReport()
	assert(report:find("Memory: 1234 KB", 1, true), "memory line")
	assert(report:find("Startup: OnLoad %d"), "startup line")
	assert(c.ns.Perf.Report():find("Memory: 1234 KB", 1, true))
	assert(c.ns.startup.OnLoad.Chat, "each module timed")
end)

test("smoother login: a big catch-up is taken a batch per frame", function()
	local g = Guild2()
	local gm = W.NewClient(base, "Gm", g)
	for i = 1, 60 do gm.ns.Sync.Set("loot", "n" .. i, string.format("%d;Mem;0;Item %d;", W.now, i)) end
	local mem = W.NewClient(base, "Mem", g)
	mem.ns.Comm.immediate = false
	local recs = gm.ns.Sync.BuildAnswer({ loot = { since = 0 } })
	eq(#recs, 60)
	gm.ns.Comm.Send("SR", "x1\2" .. "\30" .. table.concat(recs, "\30", 1, 30))
	gm.ns.Comm.Send("SR", "x2\2" .. "\30" .. table.concat(recs, "\30", 31, 60))
	local function Count() local n = 0; for _ in mem.ns.Sync.Each("loot") do n = n + 1 end; return n end
	eq(Count(), 0, "nothing taken in the same frame")
	eq(mem.ns.Sync.Pending(), 60)
	mem.flush(); eq(Count(), 40)
	mem.flush(); eq(Count(), 60); eq(mem.ns.Sync.Pending(), 0)
end)

test("bug log: errors and log lines clear themselves after 24 hours", function()
	local t0 = W.now
	local c = W.NewClient(base, "Mem", Guild2())
	local D = c.ns.Diagnostics
	c.ns.ReportError("old problem")
	c.ns.Log("something happened")
	W.now = W.now + 3600
	c.ns.ReportError("newer problem")
	W.now = W.now + 23 * 3600 + 60 -- the first error is now a day old, the second 23 hours
	D.BuildReport()
	local db = c.env.IwTDB
	eq(#db.errors, 1); eq(db.errors[1].text, "newer problem")
	eq(#db.log, 0, "a day-old log starts afresh")
	c.ns.Log("fresh line")
	eq(#db.log, 1)
	-- at the next login too
	W.now = W.now + 2 * 86400
	c.env.__fire("ADDON_LOADED", "IssuesWithTissues")
	eq(#db.errors, 0); eq(#db.log, 0)
	W.now = t0
end)

test("professions: characters who left the guild are forgotten after three days", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	local t0 = W.now
	local P = mem.ns.Professions
	local db = mem.env.IwTDB
	db.sync.profs.records["Quitter"] = { rev = 1, by = "Quitter", data = "Tailoring:300:300" }
	db.sync.recipes = db.sync.recipes or { records = {} }
	db.sync.recipes.records["Quitter#Tailoring"] = { rev = 1, by = "Quitter", data = "4334:Formal White Shirt" }
	db.sync.recipes.records["Gm#Cooking"] = { rev = 1, by = "Gm", data = "2681:Roasted Boar Meat" }
	db.sync.kills = db.sync.kills or { records = {} }
	db.sync.kills.records["Quitter"] = { rev = 1, by = "Quitter", data = "5:10" }
	eq(P.ForgetLeavers(), 0, "just noticed")
	W.now = W.now + 2 * 86400
	eq(P.ForgetLeavers(), 0, "not yet")
	-- A roster that comes back much smaller (half loaded) is ignored
	local full = mem.ns.Roster.count
	mem.ns.Roster.count = 2
	W.now = W.now + 2 * 86400
	eq(P.ForgetLeavers(), 0)
	mem.ns.Roster.count = full
	eq(P.ForgetLeavers(), 3, "the profession, recipe and kill records go")
	eq(db.sync.profs.records["Quitter"], nil); eq(db.sync.recipes.records["Quitter#Tailoring"], nil)
	eq(db.sync.kills.records["Quitter"], nil)
	assert(db.sync.recipes.records["Gm#Cooking"], "members keep theirs")
	eq(#P.WhoCanMake("shirt"), 0)
	eq(db.leftAt["Quitter"], nil, "nothing left to track")
	-- someone who comes back before the three days is kept
	db.sync.profs.records["Vet"] = { rev = 1, by = "Vet", data = "Alchemy:1:75" }
	eq(P.ForgetLeavers(), 0); eq(db.leftAt["Vet"], nil)
	W.now = t0
end)

test("professions: recipes are capped at 1,500 records, oldest first", function()
	local mem = W.NewClient(base, "Mem", Guild2())
	eq(mem.ns.Sync.sets.recipes.max, 1500)
end)

test("bug report: saved data sizes", function()
	local c = W.NewClient(base, "Mem", Guild2())
	c.env.IwTDB.sync.recipes = { records = { ["Gm#Cooking"] = { rev = 1, by = "Gm", data = string.rep("x", 4096) } } }
	local text = c.ns.Diagnostics.SizesText()
	assert(text:find("recipes 4 KB", 1, true), text)
	assert(c.ns.Diagnostics.BuildReport():find("Saved data: ", 1, true))
end)

test("layer hopping is gone (0.9.0): no Hop tab, no commands, its setting dropped, old messages ignored", function()
	local first = W.NewClient(base, "Mem", Guild2())
	first.env.IwTDB.settings.hopRequests = true
	local c = W.NewClient(base, "Mem", Guild2(), { account = first })
	eq(c.ns.Layers, nil)
	eq(c.env.IwTDB.settings.hopRequests, nil, "old setting dropped")
	for _, g in ipairs(c.ns.UI.groups) do assert(g.title ~= "Hop") end
	c.ns.HandleSlash("layer"); c.ns.HandleSlash("hop Gm")
	local gm = W.NewClient(base, "Gm", Guild2())
	gm.ns.Comm.Send("LAYER", "1;2;Elwynn") -- from someone still on 0.8
	eq(#c.env.IwTDB.errors, 0)
end)

-- A character with attunement quests done, key items in the bags and saved raids.
local function Attune(c, quests, items, saves)
	c.env.C_QuestLog = { IsQuestFlaggedCompleted = function(id) return quests[id] == true end }
	c.env.GetItemCount = function(id) return items[id] or 0 end
	c.env.GetNumSavedInstances = function() return #saves end
	c.env.GetSavedInstanceInfo = function(i)
		local s = saves[i]
		-- name, id, reset, difficulty, locked, extended, mostSig, isRaid, maxPlayers, diffName, total, done
		return s[1], i, s[2], 1, s[5] ~= false, false, 0, true, 40, "Normal", s[3], s[4]
	end
	c.env.RequestRaidInfo = function() c.askedRaidInfo = (c.askedRaidInfo or 0) + 1 end
end

test("character sheet: attunements, keys and saved raids, shared once and read by guildmates", function()
	local g = Guild2()
	local mem, gm = W.NewClient(base, "Mem", g), W.NewClient(base, "Gm", g)
	local S = mem.ns.Sheet
	Attune(mem, { [7848] = true, [6602] = true }, { [12344] = 1, [18249] = 1 },
		{ { "Molten Core", 3 * 86400 + 7, 10, 7 }, { "Onyxia's Lair", 86400, 1, 1, false } })
	local data = S.Read()
	eq(data, "mc.ony.ubrs.dm;Molten Core:" .. (math.floor((W.now + 3 * 86400 + 7) / 300 + 0.5) * 300) .. ":7:10", "unlocked raids left out")
	assert(S.Share())
	eq(S.Share(), false, "nothing changed: nothing sent")
	-- the reset time read a few seconds later is the same lockout
	local now = W.now
	W.now = now + 3
	eq(S.Share(), false, "rounded reset time")
	W.now = now
	local s = gm.ns.Sheet.Of("Mem")
	eq(s.has.mc, true); eq(s.has.ony, true); eq(s.has.bwl, nil); eq(s.has.ubrs, true)
	eq(#s.locks, 1); eq(s.locks[1].name, "Molten Core"); eq(s.locks[1].done, 7)
	-- a lockout that has reset no longer shows
	eq(#gm.ns.Sheet.Decode(gm.ns.Sync.Get("sheet", "Mem"), W.now + 4 * 86400).locks, 0)
	-- codes from a newer version are kept; bad text is no record
	assert(S.Decode("mc.zz;").has.zz)
	eq(#S.Decode("junk").locks, 0)
	-- nobody else may write Mem's sheet
	gm.ns.Comm.Send("SU", gm.ns.Comm.Pack("sheet", "Mem", W.now + 5, "Gm", "", "naxx;"))
	eq(mem.ns.Sheet.Of("Mem").has.naxx, nil)
	-- names can't break the format
	eq(S.Encode({ has = {}, locks = { { name = "A:b/c;d.e", resetAt = 600, done = 1, total = 2 } } }), ";Abcde:600:1:2")
	assert(mem.ns.Professions.LEAVER_SETS[5] == "sheet")
	eq(#mem.env.IwTDB.errors, 0); eq(#gm.env.IwTDB.errors, 0)
end)

test("character sheet: read at login, after hand-ins, bags and boss kills", function()
	local c = W.NewClient(base, "Mem", Guild2())
	Attune(c, {}, {}, {})
	c.timers = {}
	c.ns.Sheet:OnLogin()
	eq(c.timers[1].sec, c.ns.TIMERS.sheet)
	c.timers[1].fn()
	eq(c.askedRaidInfo, 1, "asks the game for saved raids")
	c.timers = {}
	c.env.__fire("UPDATE_INSTANCE_INFO")
	eq(c.timers[1].sec, c.ns.TIMERS.sheetChanged)
	c.timers[1].fn()
	eq(c.ns.Sync.Get("sheet", "Mem"), ";", "shared, even with nothing yet")
	c.env.GetItemCount = function(id) return id == 13704 and 1 or 0 end
	c.timers = {}
	c.env.__fire("BAG_UPDATE_DELAYED"); c.env.__fire("BAG_UPDATE_DELAYED")
	eq(#c.timers, 1, "a burst of bag changes reads once")
	c.timers[1].fn()
	eq(c.ns.Sync.Get("sheet", "Mem"), "scholo;")
	c.timers = {}
	c.env.__fire("BOSS_KILL", 1, "Ragnaros")
	eq(c.timers[1].sec, c.ns.TIMERS.sheetBoss)
	c.ns.HandleSlash("raid")
	eq(#c.env.IwTDB.errors, 0)
end)

test("raid page: rows, filters, search, sorting, and the choice is remembered", function()
	local g = Guild2()
	local gm, mem = W.NewClient(base, "Gm", g), W.NewClient(base, "Mem", g)
	Attune(mem, { [7848] = true }, {}, { { "Molten Core", 86400, 10, 3 } })
	Attune(gm, { [7848] = true, [7761] = true, [6502] = true }, { [12382] = 1 }, {})
	assert(mem.ns.Sheet.Share()); assert(gm.ns.Sheet.Share())
	-- Offi shares a sheet then is offline
	gm.ns.Sync.Accept("sheet", "Offi", { rev = W.now, by = "Offi", data = "mc.ony;" })
	eq(mem.ns.RaidTab.Visible(), false, "members don't see the Raid page"); eq(gm.ns.RaidTab.Visible(), true)
	gm.ns.UI.Create()
	gm.ns.UI.Open("Raid")
	local R = gm.ns.RaidTab
	assert(R.panel:IsShown())
	R.Refresh()
	local list = R.list
	eq(#list.rows, 3)
	eq(list.rows[1].name, "Gm", "most raids attuned first")
	eq(R.Marks(list.rows[1].has, true), "|cff66dd66MC|r |cff66dd66Ony|r |cff66dd66BWL|r |cff555555Naxx|r")
	eq(R.Saved(gm.ns.Sheet.Of("Mem").locks), "MC 3/10")
	assert(R.Summary(list.rows):find("Attuned: MC 3, Ony 2, BWL 1, Naxx 0   Saved: MC 1", 1, true), R.Summary(list.rows))
	eq(R.Until(W.now + 3 * 86400 + 4 * 3600, W.now), "3d 4h"); eq(R.Until(W.now + 600, W.now), "10m")
	-- filters
	list.filterButtons[2].scripts.OnClick()
	eq(#list.rows, 2, "online only")
	list.filterButtons[4].scripts.OnClick()
	eq(#list.rows, 2, "not saved: Gm and Offi")
	list.filterButtons[1].scripts.OnClick()
	-- search
	list.searchBox.onChange("me")
	eq(#list.rows, 1); eq(list.rows[1].name, "Mem")
	list.searchBox.onChange("")
	-- sort by name, then reversed
	list:SortBy("name")
	eq(list.rows[1].name, "Gm")
	list:SortBy("name")
	eq(list.rows[1].name, "Offi")
	eq(gm.env.IwTDB.lists.raid.sort, "name"); eq(gm.env.IwTDB.lists.raid.desc, true)
	list.filterButtons[2].scripts.OnClick()
	-- a reload keeps the sort and filter
	local again = W.NewClient(base, "Gm", g, { account = gm })
	again.ns.UI.Create(); again.ns.UI.Open("Raid"); again.ns.RaidTab.Refresh()
	eq(again.ns.RaidTab.list.state.sort, "name"); eq(again.ns.RaidTab.list.state.filter, "online")
	eq(#gm.env.IwTDB.errors, 0); eq(#again.env.IwTDB.errors, 0)
end)

test("list builder: sorts numbers, text and booleans, keeps ties by name, and is backward compatible", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local UI = c.ns.UI
	local cols = { { key = "n", sort = true }, { key = "on", sort = true }, { key = "x", sort = function(r) return -r.n end }, { key = "plain" } }
	local rows = { { name = "b", n = 2, on = true }, { name = "a", n = 2, on = false }, { name = "c", n = 1, on = true } }
	UI.SortRows(rows, cols, "n", false)
	eq(rows[1].name .. rows[2].name .. rows[3].name, "cab")
	UI.SortRows(rows, cols, "on", true)
	eq(rows[3].name, "a")
	UI.SortRows(rows, cols, "x", false)
	eq(rows[1].name .. rows[2].name .. rows[3].name, "abc")
	UI.SortRows(rows, cols, "plain", false) -- not sortable: left alone
	eq(rows[1].name, "a")
	-- an old-style list (no filters, no sort) still just shows what it's given
	local panel = c.env.CreateFrame("Frame")
	local list = UI.CreateList(panel, { top = -10, rows = 3, columns = { { key = "name", label = "Name", width = 100 } } })
	list:SetRows({ { name = "z" }, { name = "y" } }, function(r) return r.name end)
	eq(list.rows[1].name, "z"); eq(list.lines[1].row.name, "z"); eq(#list.rows, 2)
end)

test("roster page runs on the list builder: filters, sort and search still work", function()
	local g = Guild2()
	local gm = W.NewClient(base, "Gm", g)
	gm.ns.UI.Create(); gm.ns.UI.Open("Roster")
	local T = gm.ns.RosterTab
	local list = T.list
	eq(#list.filterButtons, 5)
	list.filterButtons[2].scripts.OnClick()
	for _, r in ipairs(list.rows) do assert(r.online) end
	list.filterButtons[1].scripts.OnClick()
	list:SortBy("level")
	eq(list.rows[1].level, 60, "level sorts highest first")
	eq(T.state.sort, "level")
	eq(gm.env.IwTDB.lists.roster.sort, "level")
	T.searchBox.onChange("gm")
	eq(#list.rows, 1)
	eq(#gm.env.IwTDB.errors, 0)
end)

test("cooking is dropped (1.3.0): not read, not shown, and your old cooking recipes are deleted", function()
	local g = Guild2()
	local mem, gm = W.NewClient(base, "Mem", g), W.NewClient(base, "Gm", g)
	local P = mem.ns.Professions
	eq(P.IsCrafting("Cooking", 185), false)
	-- old records: Mem's own and Gm's (from a 1.2 client)
	for _, c in ipairs({ mem, gm }) do
		c.ns.Sync.Accept("recipes", "Mem#Cooking", { rev = W.now - 10, by = "Mem", data = "2888;2680", v = 2 })
		c.ns.Sync.Accept("recipes", "Gm#Cooking", { rev = W.now - 10, by = "Gm", data = "2888", v = 2 })
		c.ns.Sync.Accept("recipes", "Mem#Tailoring", { rev = W.now - 10, by = "Mem", data = "2996", v = 2 })
	end
	W.itemNames[2888] = "Roasted Boar Meat"; W.itemNames[2996] = "Bolt of Linen Cloth"
	eq(#gm.ns.Professions.WhoCanMake("boar"), 0, "never shown")
	eq(#gm.ns.Professions.WhoCanMake("linen"), 1)
	-- the cooking window is not read
	mem.skills = { { "Cooking", 80, 150 } }
	mem.tradeSkill = { name = "Cooking", recipes = { { 2, "Spiced Wolf Meat", 2680 } } }
	mem.env.__fire("TRADE_SKILL_SHOW"); mem.flush()
	eq(P.SharedCount("Cooking"), 2, "unchanged by the read")
	-- at login Mem deletes its own; Gm's copy follows, and Gm's own record is left to Gm
	eq(P.DropUntracked(), 1)
	eq(mem.ns.Sync.Get("recipes", "Mem#Cooking"), nil)
	eq(gm.ns.Sync.Get("recipes", "Mem#Cooking"), nil, "the deletion reached guildmates")
	assert(gm.ns.Sync.Get("recipes", "Gm#Cooking"))
	assert(mem.ns.Sync.Get("recipes", "Mem#Tailoring"))
	eq(P.DropUntracked(), 0, "nothing left to delete")
	eq(#mem.env.IwTDB.errors, 0); eq(#gm.env.IwTDB.errors, 0)
end)

test("record formats: every shared set has a codec, and each sample round-trips", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local R, n = c.ns.Record, 0
	for set in pairs(c.ns.Sync.sets) do
		local codec = R.codecs[set]
		assert(codec, "no record codec for set " .. set)
		assert(codec.sample ~= nil, "no sample for set " .. set)
		local text = R.Encode(set, codec.sample)
		assert(type(text) == "string" and text ~= "", set .. " encodes to text")
		assert(not text:find("[\30\31|]"), set .. " never holds a separator")
		local back = R.Decode(set, text)
		assert(back ~= nil, set .. " decodes its own text")
		eq(R.Encode(set, back), text, set .. " round-trips")
		-- rubbish never breaks a decoder
		for _, junk in ipairs({ "", ";;;", "x", "1;2", "\30" }) do pcall(R.Decode, set, junk) end
		local ok = pcall(R.Decode, set, "")
		assert(ok, set .. " decodes an empty record without error")
		n = n + 1
	end
	assert(n >= 10, "all sets checked: " .. n)
	-- helpers
	eq(R.B36(0), "0"); eq(R.B36(35), "z"); eq(R.B36(36), "10"); eq(R.B36(36, 3), "010"); eq(R.Num36("zz"), 1295)
	eq(R.Gaps({ 2997, 2996, 3001, 2996, 0 }), "2b8.1.4"); eq(table.concat(R.Ungaps("2b8.1.4"), ","), "2996,2997,3001")
	eq(#R.Ungaps(""), 0)
	local a, b, rest = R.Fields("1;2;x;y", 3); eq(a, "1"); eq(b, "2"); eq(rest, "x;y")
	eq(R.Fields("1;2", 3), nil)
	eq(table.concat(R.Split("a;;b", ";"), "|"), "a||b")
end)

test("recipes version 3: base 36 gaps are a third smaller than version 2, and v2 records upgrade", function()
	local g = Guild2()
	local c = W.NewClient(base, "Mem", g)
	local P = c.ns.Professions
	-- a crafter with 150 recipes spread over the item ids, as tailoring is
	local list, v2 = {}, {}
	for i = 1, 150 do list[i] = { item = 2500 + i * 113 + (i % 7) } end
	for i = 1, 20 do list[#list + 1] = { spell = 7400 + i * 3 } end
	for _, r in ipairs(list) do v2[#v2 + 1] = r.item and tostring(r.item) or ("s" .. r.spell) end
	table.sort(v2)
	local old, new = table.concat(v2, ";"), P.EncodeRecipes(list)
	assert(#new * 3 <= #old * 2, string.format("v3 %d bytes vs v2 %d", #new, #old))
	-- the same recipes back
	local items, spells = P.RecipeIds(new)
	eq(#items, 150); eq(#spells, 20); eq(items[1], 2500 + 113 + 1)
	-- a 1.3.0-beta.1 record (version 2) is upgraded as it arrives
	local gm = W.NewClient(base, "Gm", g)
	gm.ns.Comm.Send("SU", gm.ns.Comm.Pack("recipes", "Gm#Tailoring", W.now + 5, "Gm", "", "2996;2997;s7418;nOld Name", 2))
	eq(c.ns.Sync.Get("recipes", "Gm#Tailoring"), "i2b8.1;s5q2;nOld Name")
	local _, rec = c.ns.Sync.Get("recipes", "Gm#Tailoring")
	eq(rec.v, 3)
	-- a version 1 record too
	eq(P.UpgradeRecipes("2996:Bolt of Linen Cloth;0:Secret Stew", 1), "i2b8;nSecret Stew")
	eq(#c.env.IwTDB.errors, 0)
end)

test("declared settings: one list gives the defaults and the page; Set checks values", function()
	local c = W.NewClient(base, "Mem", Guild2())
	local S, db = c.ns.Settings, c.env.IwTDB.settings
	for _, def in ipairs(c.ns.SETTINGS) do
		eq(db[def.key], def.default, def.key .. " default")
		assert(def.kind == "hidden" or def.label, def.key .. " has a label")
	end
	c.ns.UI.Open("Settings")
	local toggles = 0
	for _, def in ipairs(c.ns.SETTINGS) do
		if def.kind == "toggle" then toggles = toggles + 1; assert(S.checks[def.key], def.key .. " has a tick box") end
	end
	assert(toggles >= 10)
	-- a tick box saves and tells the feature
	local heard
	S.OnChange("sounds", function(v) heard = v end)
	S.checks.sounds:SetChecked(false)
	S.checks.sounds:GetScript("OnClick")(S.checks.sounds)
	eq(db.sounds, false); eq(heard, false)
	-- values are checked against the declaration
	eq(S.Set("scale", 5), 1.3); eq(db.scale, 1.3)
	eq(S.Set("scale", 0.83), 0.85)
	eq(S.Set("openOn", "Nowhere"), nil); eq(db.openOn, "last")
	eq(S.Set("theme", "solarizedLight"), "solarizedLight")
	eq(S.Set("nonsense", 1), nil); eq(db.nonsense, nil)
	eq(#c.env.IwTDB.errors, 0)
end)

test("live log (/iwt clane): secret, shows catch-ups, messages and records as they happen", function()
	local g = Guild2()
	local gm = W.NewClient(base, "Gm", g)
	gm.ns.Sync.Set("loot", "1", "1800000000;Mem;19019;Thunderfury;Main tank")
	local mem = W.NewClient(base, "Mem", g)
	local Con = mem.ns.Console
	-- not listed in /iwt help
	mem.printed = {}
	mem.ns.HandleSlash("help")
	for _, line in ipairs(mem.printed) do assert(not line:find("clane"), "the secret stays secret") end
	-- a catch-up: asked, answered by Gm, records taken in
	mem.ns.Sync.Ask()
	mem.ns.Sync.CheckRound()
	mem.flush()
	local text = table.concat(Con.Lines(true), "\n")
	assert(text:find("SYNC   Asking the guild for anything newer", 1, true), text)
	assert(text:find("Answer from Gm", 1, true), text)
	assert(text:find("SEND   SQ to the guild", 1, true), text)
	assert(text:find("HEAR   SR from Gm", 1, true), text)
	assert(text:find("Took 1 new record: loot 1 (loot 1 by Gm)", 1, true), text)
	assert(text:find("Round 1 done: 1 records from Gm, 1 new", 1, true), text)
	-- the summary says who we synced with
	local synced, traffic = Con.Summary()
	assert(synced:find("Synced with", 1, true) and synced:find("Gm", 1, true), synced)
	assert(traffic:find("Records held", 1, true), traffic)
	-- the window: opens, names in class colours, filters, pause, clear
	mem.ns.HandleSlash("clane")
	assert(Con.window:IsShown())
	assert(Con.Format({ at = 1.25, clock = W.now, kind = "recv", fmt = "%s from %s", n = 2, "SU", "Gm" }):find("|cff", 1, true))
	Con.filter = "problems"
	eq(#Con.Lines(), 0, "no problems")
	mem.ns.ReportError("boom")
	eq(#Con.Lines(), 1)
	Con.filter = "all"
	Con.Clear()
	eq(#Con.Lines(), 0)
	mem.ns.Trace("sync", "%d things", 3)
	eq(#Con.Lines(), 1)
	-- the buffer stays bounded
	for i = 1, mem.ns.TRACE_MAX + 50 do mem.ns.Trace("timer", "tick %d", i) end
	eq(#Con.Lines(), mem.ns.TRACE_MAX)
	mem.ns.HandleSlash("clane")
	eq(Con.window:IsShown(), false)
end)

test("logout saves this session's stats for the site's performance page: numbers only", function()
	local g = Guild()
	local offi = W.NewClient(base, "Offi", g)
	DefineSets(offi)
	offi.ns.Sync.Set("notes", "n1", "first")
	local late = W.NewClient(base, "Mem", g)
	DefineSets(late)
	late.ns.Sync.Ask()
	late.ns.ReportError("boom")
	late.env.__fire("PLAYER_LOGOUT")
	offi.env.__fire("PLAYER_LOGOUT")
	local st = late.env.IwTDB.stats
	assert(st, "stats written")
	eq(st.version, late.ns.VERSION)
	eq(st.errors, 1)
	assert(st.sync.asks >= 1 and st.sync.got >= 1, "catch-up counted " .. late.ns.Report.Json(st.sync))
	assert(st.comm.sent >= 1 and st.comm.heard >= 1, "traffic counted")
	eq(st.records.notes, 1)
	assert(st.sizes.notes and st.memoryKB >= 0 and st.members > 0)
	assert(offi.env.IwTDB.stats.sync.answered >= 1, "the answer counted")
	eq(st.inGuild, true)
	-- the game reports "not in a guild" during logout; the roster still knows
	late.env.IsInGuild = function() return false end
	eq(late.ns.Diagnostics.SessionStats().inGuild, true)
	-- no names anywhere in it
	local text = late.ns.Report.Json(st)
	assert(not text:find("Mem") and not text:find("Offi"), text)
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
