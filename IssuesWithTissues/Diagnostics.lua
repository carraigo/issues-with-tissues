-- Diagnostics: errors raised by this addon are stored (deduplicated, with a count) in
-- IwTDB.errors, plus a short rolling log. /iwt bug opens a copyable report. Both clear
-- themselves after a day: an error not seen for 24 hours goes, and so does a day-old log.

local _, ns = ...

local Diag = ns.RegisterModule("Diagnostics", {})
ns.Diagnostics = Diag

Diag.MAX_ERRORS = 50
Diag.MAX_LOG = 200
Diag.KEEP = 24 * 3600 -- errors and log lines older than a day are cleared (0.9.0)

-- Errors not seen for a day go; the log starts afresh once it's a day old.
function Diag.Expire()
	local db = ns.db
	if not db then return end
	local now = ns.Now()
	for i = #db.errors, 1, -1 do
		local e = db.errors[i]
		if now - (e.last or e.first or 0) > Diag.KEEP then table.remove(db.errors, i) end
	end
	if #db.log == 0 then db.logSince = nil end
	if db.logSince and now - db.logSince > Diag.KEEP then
		wipe(db.log)
		db.logSince = nil
	end
end

local pending = {} -- errors raised before saved variables load

function ns.ReportError(err)
	local text = tostring(err)
	Diag.sessionErrors = (Diag.sessionErrors or 0) + 1
	ns.Trace("error", "%s", text)
	local stack = debugstack and debugstack(2, 8, 0) or ""
	local db = ns.db
	if not db then
		table.insert(pending, { text = text, stack = stack })
		return
	end
	for _, e in ipairs(db.errors) do
		if e.text == text then
			e.count = e.count + 1
			e.last = ns.Now()
			e.version = ns.VERSION -- the version it last happened on
			return
		end
	end
	table.insert(db.errors, 1, { text = text, stack = stack, count = 1, first = ns.Now(), last = ns.Now(), version = ns.VERSION })
	while #db.errors > Diag.MAX_ERRORS do table.remove(db.errors) end
	if db.settings and db.settings.debug then ns.Print("|cffff5555error:|r %s", text) end
end

function ns.Log(fmt, ...)
	local db = ns.db
	if not db then return end
	local line = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
	ns.Trace("log", "%s", line)
	if not db.logSince then db.logSince = ns.Now() end
	table.insert(db.log, date("%H:%M:%S ") .. line)
	while #db.log > Diag.MAX_LOG do table.remove(db.log, 1) end
end

function Diag:OnLoad()
	if ns.db.log[1] and not ns.db.logSince then ns.db.logSince = ns.Now() end -- a log from before 0.9.0
	Diag.Expire()
	for _, e in ipairs(pending) do ns.ReportError(e.text) end
	wipe(pending)
end

-- Catch errors from our own files only, then hand everything to the previous handler.
if geterrorhandler and seterrorhandler then
	local previous = geterrorhandler()
	seterrorhandler(function(msg, ...)
		if type(msg) == "string" and msg:find("IssuesWithTissues", 1, true) then
			ns.ReportError(msg)
		end
		if previous then return previous(msg, ...) end
	end)
end

-- The game blocks some calls from addons (protected functions). It reports those as events,
-- not errors, so the handler above never sees them.
local blocked = CreateFrame and CreateFrame("Frame")
if blocked then
	for _, e in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do pcall(blocked.RegisterEvent, blocked, e) end
	blocked:SetScript("OnEvent", function(_, event, addon, func)
		if addon == "IssuesWithTissues" then
			local extra = ns.registering and (" while registering " .. ns.registering) or ""
			ns.ReportError(string.format("%s: the game blocked %s()%s", event, (tostring(func):gsub("%(%)$", "")), extra))
		end
	end)
end

-- Rough size of what the addon saves, in KB per part (the strings it holds, plus a little per entry).
local function Size(v, seen)
	local t = type(v)
	if t == "string" then return #v + 8 end
	if t ~= "table" then return 8 end
	if seen[v] then return 0 end
	seen[v] = true
	local n = 16
	for k, x in pairs(v) do n = n + Size(k, seen) + Size(x, seen) end
	return n
end

function Diag.Sizes()
	local out = {}
	local db = ns.db or {}
	for name, set in pairs(db.sync or {}) do out[#out + 1] = { name = name, bytes = Size(set, {}) } end
	out[#out + 1] = { name = "chat", bytes = Size(ns.char and ns.char.chat or {}, {}) }
	out[#out + 1] = { name = "news", bytes = Size(db.news or {}, {}) + Size(db.newsRoster or {}, {}) }
	out[#out + 1] = { name = "log", bytes = Size(db.log or {}, {}) + Size(db.errors or {}, {}) }
	table.sort(out, function(a, b) return a.bytes > b.bytes end)
	return out
end

function Diag.SizesText()
	local parts, total = {}, 0
	for _, s in ipairs(Diag.Sizes()) do
		total = total + s.bytes
		parts[#parts + 1] = string.format("%s %.0f KB", s.name, s.bytes / 1024)
	end
	return string.format("%.0f KB (%s)", total / 1024, table.concat(parts, ", "))
end

function Diag.BuildReport()
	Diag.Expire()
	local db = ns.db or { errors = {}, log = {}, settings = {} }
	local lines = {}
	local function add(s) lines[#lines + 1] = s end
	add("Issues with Tissues bug report")
	add("Version: " .. ns.VERSION)
	if GetBuildInfo then
		local v, build, _, iface = GetBuildInfo()
		add(string.format("Client: %s (%s) interface %s", tostring(v), tostring(build), tostring(iface)))
	end
	add("Locale: " .. (GetLocale and GetLocale() or "?"))
	add("Time: " .. date("%Y-%m-%d %H:%M:%S"))
	local kb = ns.MemoryKB and ns.MemoryKB()
	add("Memory: " .. (kb and string.format("%.0f KB", kb) or "unknown"))
	if ns.StartupText then add("Startup: " .. ns.StartupText()) end
	if ns.char and ns.char.chat then
		local n = 0
		for _, l in pairs(ns.char.chat) do n = n + #l end
		add("Saved chat lines: " .. n)
	end
	add("")
	add("Identity:")
	add("  UnitName: " .. tostring(UnitName and UnitName("player")) .. ", realm: " .. tostring(GetNormalizedRealmName and GetNormalizedRealmName()))
	if ns.Roster then
		local me = ns.PlayerName and ns.PlayerName()
		local m = me and ns.Roster.Get(me)
		add(string.format("  Key: %s, in roster: %s, rank: %s, officer: %s", tostring(me), tostring(m ~= nil),
			tostring(m and m.rankIndex), tostring(ns.Roster.IsOfficer(me))))
		add(string.format("  Roster: %d members, %d online", ns.Roster.count or 0, ns.Roster.online or 0))
		add("  Found self by: " .. tostring(ns.Roster.meHow) .. ", UnitGUID: " .. tostring(UnitGUID and UnitGUID("player") ~= nil)
			.. ", UnitFullName: " .. tostring(UnitFullName and select(2, UnitFullName("player"))))
		local shared = {}
		for _, list in pairs(ns.Roster.byFirst or {}) do
			if #list > 1 then shared[#shared + 1] = table.concat(list, "/") end
		end
		table.sort(shared)
		add("  Shared first names: " .. (#shared > 0 and table.concat(shared, ", ") or "none"))
		add("  Last addon sender seen: " .. tostring(ns.Comm and ns.Comm.lastSender))
		local n = 0
		for key, mm in pairs(ns.Roster.members) do
			if n >= 3 then break end
			n = n + 1
			add(string.format("  Roster name sample: %q -> %s", tostring(mm.rosterName), key))
		end
	end
	if ns.UI then
		local tabs = {}
		for i, t in ipairs(ns.UI.tabs) do
			local b = t.button
			local shown = b and b.IsShown and b:IsShown()
			local where = ""
			if b and b.GetLeft then
				where = string.format(" x=%s w=%s", tostring(b:GetLeft() and math.floor(b:GetLeft())), tostring(b.GetWidth and math.floor(b:GetWidth() or 0)))
			end
			tabs[#tabs + 1] = string.format("%d %s (button %s%s%s)", i, t.title, b and "yes" or "no",
				b and (shown and ", shown" or ", hidden") or "", where)
		end
		add("Tabs: " .. table.concat(tabs, "; "))
	end
	add("Profession window: last read " .. tostring(ns.Professions and ns.Professions.lastRead)
		.. ", ToggleProfessionsBook=" .. type(ToggleProfessionsBook))
	add("APIs: GetProfessions=" .. type(GetProfessions) .. " GetSkillLineInfo=" .. type(GetSkillLineInfo)
		.. " C_TradeSkillUI=" .. type(C_TradeSkillUI)
		.. " GetBaseProfessionInfo=" .. type(C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo)
		.. " GetPVPLifetimeStats=" .. type(GetPVPLifetimeStats) .. " GetStatistic=" .. type(GetStatistic)
		.. " DepositGuildBankMoney=" .. type(DepositGuildBankMoney) .. " GetGuildBankMoney=" .. type(GetGuildBankMoney))
	if ns.Kills then
		local mobs, source = ns.Kills.Creatures()
		add(string.format("Kills: %d honorable, %d creatures (%s)", ns.Kills.Honor(), mobs, source))
	end
	if ns.Sync and ns.db then
		local counts = {}
		for name, set in pairs(ns.db.sync) do
			local c = 0
			for _ in pairs(set.records or {}) do c = c + 1 end
			counts[#counts + 1] = name .. "=" .. c
		end
		table.sort(counts)
		add("Shared data: " .. table.concat(counts, " "))
		local S, C = ns.Sync, ns.Comm
		add(string.format("Sync: last ask %s, last answer %s, rounds %d, catching up %s, queue %d, refused %d, dropped %d",
			S.lastAsk and (ns.Now() - S.lastAsk .. "s ago") or "never", S.lastAnswer and (ns.Now() - S.lastAnswer .. "s ago") or "never",
			S.rounds or 0, tostring(S.catching), C.Queued(), C.throttled or 0, C.dropped or 0))
		add("Saved data: " .. Diag.SizesText())
	end
	add("")
	add("Settings:")
	local keys = {}
	for k in pairs(db.settings or {}) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do add(string.format("  %s = %s", k, tostring(db.settings[k]))) end
	add("")
	add(string.format("Errors (%d):", #db.errors))
	for i, e in ipairs(db.errors) do
		local when = e.last and date("%Y-%m-%d %H:%M", e.last) or "?"
		add(string.format("%d. [x%d, last %s] %s", i, e.count or 1, when, e.text))
		if e.stack and e.stack ~= "" then add(e.stack) end
	end
	add("")
	add("Recent log:")
	for i = math.max(1, #db.log - 30), #db.log do add(db.log[i]) end
	return table.concat(lines, "\n")
end

ns.RegisterCommand("bug", "copyable bug report", function(rest)
	if rest == "clear" then
		wipe(ns.db.errors)
		wipe(ns.db.log)
		ns.db.logSince = nil
		ns.Print("Errors and log cleared.")
		return
	end
	if ns.UI and ns.UI.ShowCopyBox then
		ns.UI.ShowCopyBox("Bug report: press Ctrl+C to copy", Diag.BuildReport())
	else
		ns.Print(Diag.BuildReport())
	end
end)

---------------------------------------------------------------------------
-- Session stats: a small record of how this session went, saved at logout and /reload
-- (db.stats), for the guild site's performance page. Numbers only: no names, no chat.
---------------------------------------------------------------------------
Diag.PERF_TOP = 8

function Diag.SessionStats()
	local now = ns.Now()
	local C, S = ns.Comm, ns.Sync
	local records, sizes = {}, {}
	for name in pairs(S.sets) do
		local n = 0
		for _ in S.Each(name) do n = n + 1 end
		records[name] = n
	end
	for _, s in ipairs(Diag.Sizes()) do sizes[s.name] = math.floor(s.bytes) end
	local startup = 0
	for _, method in ipairs({ "OnLoad", "OnLogin" }) do
		for _, ms in pairs(ns.startup[method] or {}) do startup = startup + ms end
	end
	local perf = {}
	for label, p in pairs(ns.Perf and ns.Perf.stats or {}) do
		perf[#perf + 1] = { label = label, calls = p.calls, total = math.floor(p.total * 100) / 100, max = math.floor(p.max * 100) / 100 }
	end
	table.sort(perf, function(a, b) return a.total > b.total end)
	for i = #perf, Diag.PERF_TOP + 1, -1 do perf[i] = nil end
	local users, week = 0, now - 7 * 86400
	for _, v in pairs(ns.db.versionsSeen or {}) do if (v.at or 0) >= week then users = users + 1 end end
	local st = S.stats or {}
	return {
		at = now, version = ns.VERSION, session = ns.loginAt and (now - ns.loginAt) or 0,
		memoryKB = math.floor((ns.MemoryKB() or 0) + 0.5), startupMs = math.floor(startup * 10 + 0.5) / 10,
		sync = { asks = st.asks or 0, rounds = st.rounds or 0, got = st.got or 0, new = st.new or 0,
			answered = st.answered or 0, answeredRecords = st.answeredRecords or 0, caughtUpAfter = st.caughtUpAfter },
		comm = { sent = C.sentCount or 0, sentBytes = C.sentBytes or 0, heard = C.heardCount or 0,
			heardBytes = C.heardBytes or 0, refused = C.throttled or 0, dropped = C.dropped or 0, peakQueue = C.peakQueue or 0,
			slowest = C.slowest or C.RATE_MAX },
		errors = Diag.sessionErrors or 0, records = records, sizes = sizes, perf = perf,
		members = ns.Roster.count or 0, online = ns.Roster.online or 0, addonUsers = users,
		-- false on a character outside the guild: nothing to sync, so the site leaves it out.
		-- From the roster, not IsInGuild(): the game already says "not in a guild" at logout.
		inGuild = (ns.Roster.count or 0) > 0,
	}
end

pcall(ns.On, "PLAYER_LOGOUT", function()
	if not ns.db then return end
	local ok, stats = pcall(Diag.SessionStats)
	if ok then ns.db.stats = stats end
end)
