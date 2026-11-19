-- Diagnostics: errors raised by this addon are stored (deduplicated, with a count) in
-- IwTDB.errors, plus a short rolling log. /iwt bug opens a copyable report.

local _, ns = ...

local Diag = ns.RegisterModule("Diagnostics", {})
ns.Diagnostics = Diag

Diag.MAX_ERRORS = 50
Diag.MAX_LOG = 200

local pending = {} -- errors raised before saved variables load

function ns.ReportError(err)
	local text = tostring(err)
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
			return
		end
	end
	table.insert(db.errors, 1, { text = text, stack = stack, count = 1, first = ns.Now(), last = ns.Now() })
	while #db.errors > Diag.MAX_ERRORS do table.remove(db.errors) end
	if db.settings and db.settings.debug then ns.Print("|cffff5555error:|r %s", text) end
end

function ns.Log(fmt, ...)
	local db = ns.db
	if not db then return end
	local line = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
	table.insert(db.log, date("%H:%M:%S ") .. line)
	while #db.log > Diag.MAX_LOG do table.remove(db.log, 1) end
end

function Diag:OnLoad()
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
			ns.ReportError(string.format("%s: the game blocked %s()%s", event, tostring(func), extra))
		end
	end)
end

function Diag.BuildReport()
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
		for first, list in pairs(ns.Roster.byFirst or {}) do
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
		ns.Print("Errors and log cleared.")
		return
	end
	if ns.UI and ns.UI.ShowCopyBox then
		ns.UI.ShowCopyBox("Bug report: press Ctrl+C to copy", Diag.BuildReport())
	else
		ns.Print(Diag.BuildReport())
	end
end)
