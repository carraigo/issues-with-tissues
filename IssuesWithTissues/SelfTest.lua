-- /iwt selftest: checks, in the game, that the addon's parts work on this client, and shows a
-- copyable list (passed, failed, notes). It also sends one hidden guild message and waits for
-- the game to echo it back, which shows guild addon messages go out.

local _, ns = ...

local Test = ns.RegisterModule("SelfTest", {})
ns.SelfTest = Test

Test.ECHO_WAIT = 5

ns.Comm.Register("STP", function() end, "member") -- the self-test ping; nothing to do

local function Check(results, name, ok, detail)
	results[#results + 1] = { name = name, ok = ok, detail = detail }
end

-- The checks that need no waiting. Returns a list of { name, ok (true/false/nil=note), detail }.
function Test.Quick()
	local r = {}
	Check(r, "Saved variables loaded", ns.db ~= nil and ns.char ~= nil)
	Check(r, "In a guild", IsInGuild and IsInGuild() or false, GetGuildInfo and GetGuildInfo("player") or nil)
	local R = ns.Roster
	Check(r, "Guild roster read", (R.count or 0) > 0, (R.count or 0) .. " members")
	local me = ns.PlayerName()
	Check(r, "Found this character in the roster", R.IsMember(me), tostring(me) .. " (by " .. tostring(R.meHow) .. ")")
	Check(r, "Officer", nil, R.IsOfficer(me) and "yes: can write guild data" or "no: officer pages are read-only")
	local registered
	if C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered then
		registered = C_ChatInfo.IsAddonMessagePrefixRegistered(ns.Comm.PREFIX)
	end
	Check(r, "Addon message prefix registered", registered ~= false, registered == nil and "can't check on this client" or nil)

	-- Every page builds without an error.
	local before = #ns.db.errors
	local shown = ns.UI.window and ns.UI.window:IsShown()
	local was = ns.UI.current
	local pages = 0
	ns.UI.Create()
	for _, g in ipairs(ns.UI.tabs) do
		for _, page in ipairs(g.pages) do
			ns.UI.Open(page.title)
			pages = pages + 1
		end
	end
	ns.UI.Open("Settings")
	if shown then ns.UI.SelectTab(was or 1) else ns.UI.window:Hide() end
	local newErrors = #ns.db.errors - before
	Check(r, "Every page opens", newErrors == 0, pages .. " pages and Settings" .. (newErrors > 0 and (", " .. newErrors .. " errors: see /iwt bug") or ""))

	-- Game functions the features use.
	local missing = {}
	for _, api in ipairs({ "GetGuildRosterInfo", "GetProfessions", "GetStatistic", "GetPVPLifetimeStats",
		"DepositGuildBankMoney", "hooksecurefunc", "UnitGUID" }) do
		if type(_G[api]) ~= "function" then missing[#missing + 1] = api end
	end
	if not (C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo) then missing[#missing + 1] = "C_TradeSkillUI" end
	Check(r, "Game functions present", #missing == 0, #missing > 0 and ("missing: " .. table.concat(missing, ", ")) or nil)

	if ns.LootNotes then
		local hooks = ns.LootNotes.hooks or {}
		Check(r, "Shift-click items into loot notes", #hooks > 0, #hooks > 0 and ("via " .. table.concat(hooks, ", ")) or "no link function to watch")
	end

	-- Shared data
	local sets, records = 0, 0
	for name in pairs(ns.Sync.sets) do
		sets = sets + 1
		for _ in ns.Sync.Each(name) do records = records + 1 end
	end
	Check(r, "Shared data", nil, records .. " records in " .. sets .. " sets")
	local others = 0
	for who in pairs(ns.Comm.versions) do if who ~= me then others = others + 1 end end
	Check(r, "Guildmates seen with the addon", nil, others .. " this session")

	local recent = 0
	for _, e in ipairs(ns.db.errors) do if (e.last or 0) >= (Test.loginTime or 0) then recent = recent + 1 end end
	Check(r, "No errors this session", recent == 0, recent > 0 and (recent .. " errors: see /iwt bug") or nil)
	return r
end

function Test.Format(results)
	local lines, passed, failed = { "Issues with Tissues self-test, " .. ns.VERSION .. ", " .. date("%Y-%m-%d %H:%M"), "" }, 0, 0
	for _, c in ipairs(results) do
		local mark
		if c.ok == true then mark, passed = "PASS", passed + 1
		elseif c.ok == false then mark, failed = "FAIL", failed + 1
		else mark = "NOTE" end
		lines[#lines + 1] = string.format("%s  %s%s", mark, c.name, c.detail and (": " .. c.detail) or "")
	end
	table.insert(lines, 2, string.format("%d passed, %d failed", passed, failed))
	return table.concat(lines, "\n"), passed, failed
end

-- Run everything; done(text, passed, failed) is called once the echo wait is over.
function Test.Run(done)
	local results = Test.Quick()
	local sent = ns.Now()
	local inGuild = IsInGuild and IsInGuild()
	if inGuild then ns.Comm.Send("STP", "") end
	ns.After(Test.ECHO_WAIT, function()
		if inGuild then
			local back = (ns.Comm.echoes.STP or 0) >= sent
			Check(results, "Guild addon messages go out", back, back and nil or "the game did not echo our message back")
		end
		local text, passed, failed = Test.Format(results)
		Test.last = { results = results, passed = passed, failed = failed, at = ns.Now() } -- for /iwt report
		ns.Log("selftest: %d passed, %d failed", passed, failed)
		if done then done(text, passed, failed) end
	end)
end

ns.RegisterCommand("selftest", "check the addon works on this client", function()
	ns.Print("Self-test running (%d seconds)...", Test.ECHO_WAIT)
	Test.Run(function(text, passed, failed)
		ns.Print("Self-test: %d passed, %d failed.", passed, failed)
		ns.UI.ShowCopyBox("Issues with Tissues self-test", text)
	end)
end)

function Test:OnLogin()
	Test.loginTime = ns.Now()
end
