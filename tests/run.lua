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
	eq(got, "Mem-Realm|hello")
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
	vet.ns.Comm.Send("SU", vet.ns.Comm.Pack("notes", "n1", W.now, "Vet-Realm", "", "fake"))
	eq(mem.ns.Sync.Get("notes", "n1"), nil)
end)

test("sync: owner sets only take a player's own record", function()
	local g = Guild()
	local mem, vet = W.NewClient(base, "Mem", g), W.NewClient(base, "Vet", g)
	DefineSets(mem, vet)
	assert(mem.ns.Sync.Set("mine", "Mem-Realm", "my alts"))
	eq(vet.ns.Sync.Get("mine", "Mem-Realm"), "my alts")
	eq(mem.ns.Sync.Set("mine", "Vet-Realm", "not mine"), false)
end)

test("sync: older revisions never overwrite newer ones", function()
	local g = Guild()
	local offi, mem = W.NewClient(base, "Offi", g), W.NewClient(base, "Mem", g)
	DefineSets(offi, mem)
	offi.ns.Sync.Set("notes", "n1", "new")
	mem.ns.Sync.Accept("notes", "n1", { rev = W.now - 100, by = "Offi-Realm", data = "old" })
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
	offi.ns.Sync.Set("mine", "Offi-Realm", "offi alts")
	local late = W.NewClient(base, "Mem", g) -- joins after the changes; nothing saved
	DefineSets(late)
	late.ns.Sync.Ask()
	eq(late.ns.Sync.Get("notes", "n1"), "first")
	eq(late.ns.Sync.Get("notes", "n2"), string.rep("long note ", 30))
	eq(late.ns.Sync.Get("mine", "Offi-Realm"), "offi alts")
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

test("bug report lists errors once with a count", function()
	local c = W.NewClient(base, "Mem", Guild())
	c.ns.ReportError("boom")
	c.ns.ReportError("boom")
	eq(#c.env.IwTDB.errors, 1)
	eq(c.env.IwTDB.errors[1].count, 2)
	local report = c.ns.Diagnostics.BuildReport()
	assert(report:find("[x2] boom", 1, true), "report has the error")
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

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
