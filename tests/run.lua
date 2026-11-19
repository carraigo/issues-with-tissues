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
	mem.skills = { { "Tailoring", 225, 300 }, { "First Aid", 150, 150 } }
	assert(mem.ns.Professions.UpdateSkills())
	local p = gm.ns.Professions.Of("Mem")
	eq(#p, 2)
	eq(p[1].name, "First Aid"); eq(p[2].name, "Tailoring"); eq(p[2].rank, 225)
	eq(mem.ns.Professions.UpdateSkills(), false, "unchanged skills are not sent again")
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

test("roster tab shows in the window before Settings", function()
	local c = W.NewClient(base, "Mem", Guild2())
	c.ns.UI.Create()
	local order = {}
	for i, t in ipairs(c.ns.UI.tabs) do
		local pages = {}
		for j, p in ipairs(t.pages) do pages[j] = p.title end
		order[i] = t.title .. "(" .. table.concat(pages, "|") .. ")"
	end
	eq(table.concat(order, ","), "Home(Home),Members(Roster|Crafters),Play(Groups|Layers),Guild life(Calendar|Polls|Donations)", "Guild life waits for pages")
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
	mem.skills = { { "Tailoring", 225, 300, 197 }, { "Herbalism", 100, 150, 182 }, { "Cooking", 80, 150, 185 } }
	eq(P.SharedCount("Tailoring"), nil, "not scanned yet")
	assert(P.Scan())
	eq(booked, 1, "the profession book is opened")
	eq(mem.opened, nil, "the protected profession window is never opened by the addon")
	eq(P.scan.total, 2, "Herbalism has no recipes to scan")
	eq(mem.ns.GeneralTab.ScanLabel(), "Scanning (0/2 done)")
	-- The player clicks the Tailoring tab, then the Cooking tab
	mem.tradeSkill = { name = "Tailoring", recipes = { { 1, "Bolt of Linen Cloth", 2996 } } }
	mem.env.__fire("TRADE_SKILL_LIST_UPDATE"); mem.flush()
	eq(P.scan.done, 1)
	mem.tradeSkill = { name = "Cooking", recipes = { { 2, "Roasted Boar Meat", 2888 }, { 3, "Spiced Wolf Meat", 2680 } } }
	mem.env.__fire("TRADE_SKILL_DATA_SOURCE_CHANGED"); mem.flush()
	eq(P.scan, nil, "finished")
	eq(P.SharedCount("Tailoring"), 1); eq(P.SharedCount("Cooking"), 2)
	eq(#gm.ns.Professions.WhoCanMake("meat"), 2, "guildmates see the recipes")
end)

test("recipe scan: quick clicks read only the tab that ends up shown; already shared counts", function()
	local mem = W.NewClient(base, "Mem", Guild2())
	local P = mem.ns.Professions
	mem.skills = { { "Tailoring", 225, 300 }, { "Cooking", 80, 150 } }
	mem.tradeSkill = { name = "Tailoring", recipes = { { 1, "Bolt of Linen Cloth", 2996 } } }
	mem.env.__fire("TRADE_SKILL_SHOW")
	mem.tradeSkill = { name = "Cooking", recipes = { { 2, "Roasted Boar Meat", 2888 } } }
	mem.env.__fire("TRADE_SKILL_LIST_UPDATE")
	mem.flush()
	eq(P.SharedCount("Cooking"), 1); eq(P.SharedCount("Tailoring"), nil, "skipped past before it was read")
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
	eq(#f.profs, 2)
	eq(f.profs[1].recipes, nil); eq(f.profs[2].noRecipes, true)
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
	c.ns.UI.SelectTab(2)
	eq(c.ns.RosterTab.panel:IsShown(), true)
	eq(c.ns.UI.tabs[1].button.selected, false); eq(c.ns.UI.tabs[2].button.selected, true)
	c.ns.UI.Open("Settings")
	eq(c.ns.UI.cog.selected, true); eq(c.ns.UI.tabs[2].button.selected, false)
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
	best.skills = { { "Mining", 50, 75 } }
	assert(exe.ns.Professions.UpdateSkills()); assert(best.ns.Professions.UpdateSkills())
	eq(gm.ns.Professions.Of("Sara Exe")[1].name, "Tailoring")
	eq(gm.ns.Professions.Of("Sara Best")[1].name, "Mining")
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
	db.sync.profs = { records = { Large = { rev = 1, data = "Mining:195:225", by = "Large" } } }
	db.sync.recipes = { records = { ["Magia#Cooking"] = { rev = 1, data = "2681:Roasted Boar Meat", by = "Magia" } } }
	db.accountMain = "Large"
	db.altPending = { Clane = { main = "Large", at = 1 } }
	c.ns.Sync.MigrateNames(); c.ns.Alts.MigrateNames()
	eq(c.ns.Alts.MainOf("Clane Stocious"), "Large Joseph")
	eq(c.ns.Professions.Of("Large Joseph")[1].name, "Mining")
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

test("groups board: a post reaches the guild, ends on time and can be taken down", function()
	local g = { members = { { "Mem", 3, true }, { "Gm", 0, true }, { "Away", 3, false, 2 } } }
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	assert(mem.ns.LFG.Post("need", "Dungeon", 60, "Deadmines, tank |cffff0000red|r"))
	local posts = gm.ns.LFG.Posts()
	eq(#posts, 1); eq(posts[1].who, "Mem"); eq(posts[1].activity, "Dungeon")
	eq(posts[1].note, "Deadmines, tank cffff0000redr", "no colour codes from others")
	local said = table.concat(gm.printed or {}, "\n")
	assert(said:find("Deadmines", 1, true), "a chat line about the new post")
	W.now = W.now + 61 * 60
	eq(#gm.ns.LFG.Posts(), 0, "expired")
	W.now = W.now - 61 * 60
	assert(mem.ns.LFG.Clear())
	eq(#gm.ns.LFG.Posts(), 0, "taken down")
	-- an offline guildmate's post is hidden; nobody can post for someone else
	gm.ns.Sync.Accept("lfg", "Away", { rev = W.now, by = "Away", data = gm.ns.LFG.Encode("need", "Raid", W.now + 600, "x") })
	eq(#gm.ns.LFG.Posts(), 0)
	mem.ns.Comm.Send("SU", mem.ns.Comm.Pack("lfg", "Gm", W.now, "Mem", "", gm.ns.LFG.Encode("need", "Raid", W.now + 600, "fake")))
	eq(gm.ns.Sync.Get("lfg", "Gm"), nil)
	mem.ns.HandleSlash("lfg Stockades")
	eq(gm.ns.LFG.Posts()[1].note, "Stockades")
	mem.ns.HandleSlash("lfg off")
	eq(#gm.ns.LFG.Posts(), 0)
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

test("calendar: officers add events, everyone signs up with a role, Home shows what's on", function()
	local g = { members = { { "Mem", 3, true }, { "Gm", 0, true } } }
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	for _, c in ipairs({ mem, gm }) do
		c.env.time = function(t) if t then return os.time(t) end return W.now end
	end
	local C = gm.ns.Calendar
	local when = C.TimeOf(1, "20:00")
	assert(when and when > W.now)
	eq(C.TimeOf(0, "25:00"), nil); eq(C.TimeOf(0, "soon"), nil)
	eq((mem.ns.Calendar.Add("Deadmines", when)), false, "members can't add events")
	eq(select(2, C.Add("", when)), "Give the event a name.")
	assert(C.Add("Deadmines run", when, "bring potions"))
	assert(C.Add("Old event", W.now - 4 * 3600))
	local list = mem.ns.Calendar.Upcoming()
	eq(#list, 1, "past events drop off"); eq(list[1].title, "Deadmines run"); eq(list[1].note, "bring potions")
	assert(mem.ns.Calendar.SignUp(list[1].id, "T"))
	assert(gm.ns.Calendar.SignUp(list[1].id, "M"))
	local s = gm.ns.Calendar.Signups(list[1].id)
	eq(s.count, 1); eq(s.T[1], "Mem"); eq(s.M[1], "Gm")
	eq(gm.ns.Calendar.RoleSummary(s), "1 tank, 1 maybe")
	eq(mem.ns.Calendar.SignUp(list[1].id, "X"), false)
	assert(mem.ns.Calendar.SignUp(list[1].id, nil))
	eq(gm.ns.Calendar.Signups(list[1].id).count, 0)
	eq(mem.ns.Calendar.When(when):sub(1, 8), "Tomorrow")
	-- Home: What's on
	assert(gm.ns.Polls.Ask("Raid night?", "Fri, Sat"))
	local f = mem.ns.GeneralTab.Facts()
	eq(f.nextEvent.title, "Deadmines run"); eq(f.openPolls, 1); eq(f.donations.title, "Guild bank")
	mem.ns.UI.Toggle()
	mem.ns.GeneralTab.Refresh()
	mem.ns.UI.Open("Calendar")
	eq(mem.ns.Calendar.panel:IsShown(), true)
	eq(mem.ns.UI.tabs[4].title, "Guild life")
	eq(#mem.env.IwTDB.errors, 0)
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
	gm.ns.UI.Open("Crafters")
	eq(#gm.env.IwTDB.errors, 0)
end)

test("layers: an NPC's GUID gives the layer, guildmates share it and get numbered", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	local L = mem.ns.Layers
	eq(L.FromGUID("Creature-0-5250-0-1458-6491-00001A2B3C"), 1458)
	eq(L.FromGUID("Player-5250-0ABCDEF0"), nil)
	eq(L.FromGUID("Pet-0-5250-0-1458-416-0100A2B3C4"), nil)
	mem.env.UnitGUID = function(u) if u == "target" then return "Creature-0-5250-0-1458-6491-00001A2B3C" end end
	mem.env.__fire("PLAYER_TARGET_CHANGED")
	eq(L.mine.id, 1458)
	gm.env.UnitGUID = function(u) if u == "target" then return "Creature-0-5250-0-1012-6491-00001A2B3C" end end
	gm.env.__fire("PLAYER_TARGET_CHANGED")
	local rows = L.Guildmates()
	eq(#rows, 1); eq(rows[1].who, "Gm"); eq(rows[1].same, "other")
	eq(rows[1].label, "Layer 1", "1012 sorts before 1458"); eq(L.Label(0, 1458), "Layer 2")
	-- a guildmate logging in later asks and hears back
	local late = W.NewClient(base, "Vet", g)
	late.ns.Comm.Send("LAYERQ", "")
	eq(#late.ns.Layers.Guildmates(), 2)
end)

test("layer hop: ask, the guildmate invites, and after the hop you can leave", function()
	local g = Guild2()
	local mem = W.NewClient(base, "Mem", g)
	local gm = W.NewClient(base, "Gm", g)
	local invited, left
	gm.env.C_PartyInfo = { InviteUnit = function(n) invited = n end }
	mem.env.C_PartyInfo = { LeaveParty = function() left = true end }
	mem.env.UnitGUID = function(u) if u == "target" then return "Creature-0-5250-0-1458-6491-00001A2B3C" end end
	mem.env.__fire("PLAYER_TARGET_CHANGED")
	assert(mem.ns.Layers.AskHop("Gm"))
	eq(gm.popups[#gm.popups].which, "IWT_HOP"); eq(gm.popups[#gm.popups].arg, "Mem")
	assert(gm.ns.Layers.AnswerHop(true))
	eq(invited, "Mem")
	-- the hop happens: a new id on the same map
	mem.env.UnitGUID = function(u) if u == "target" then return "Creature-0-5250-0-1012-6491-00001A2B3C" end end
	mem.env.__fire("PLAYER_TARGET_CHANGED")
	eq(mem.popups[#mem.popups].which, "IWT_HOP_DONE")
	mem.env.StaticPopupDialogs.IWT_HOP_DONE.OnAccept()
	eq(left, true)
	-- requests can be turned off
	gm.env.IwTDB.settings.hopRequests = false
	local before = #gm.popups
	mem.ns.Layers.AskHop("Gm")
	eq(#gm.popups, before)
	eq(mem.ns.Layers.hop, nil, "told it is off")
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
	eq(UI.tabs[UI.current].title, "Members")
	UI.Open("Home")
	UI.SelectTab(2) -- Members again: back on Crafters
	eq(UI.tabs[2].pages[UI.tabs[2].current].title, "Crafters")
	eq(c.env.IwTDB.window.pages.Members, "Crafters", "remembered across sessions")
	UI.Open("Settings")
	eq(UI.settings.panel:IsShown(), true)
	eq(UI.tabs[2].frame:IsShown(), false)
	UI.cog:GetScript("OnClick")()
	c.env.UnitGUID = function(u) if u == "target" then return "Creature-0-1-0-77-6491-00001A2B3C" end end
	c.env.__fire("PLAYER_TARGET_CHANGED")
	UI.Open("Layers")
	eq(UI.tabs[3].info():find("Layer 1", 1, true) ~= nil, true, "your layer beside Play's sub-tabs")
	eq(#c.env.IwTDB.errors, 0)
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
