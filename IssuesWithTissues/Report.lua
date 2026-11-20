-- Diagnostics report: /iwt report (or Settings > Diagnostics report) packs what helps fine-tune
-- the addon into one string to copy: version and client, errors, the profiler's numbers, the
-- last self-test, shared-data health, settings and light usage counters. The guild page
-- (carraigo.github.io/iwt-stats/#report) unpacks it, shows it, and files it as a GitHub issue.
--
-- No chat, no log lines and no other players' names. This character's name only with
-- "/iwt report name".
--
-- Format: "IWT1." .. base64(JSON) .. "." .. Adler-32 of the JSON as 8 hex digits.

local _, ns = ...

local Report = ns.RegisterModule("Report", {})
ns.Report = Report

Report.PREFIX = "IWT1"
Report.SITE = "carraigo.github.io/iwt-stats/#report"
Report.MAX_ERRORS = 15
Report.MAX_PERF = 15

---------------------------------------------------------------------------
-- Usage counters (kept in IwTDB.usage)
---------------------------------------------------------------------------
local function Usage()
	local db = ns.db
	if not db then return nil end
	if type(db.usage) ~= "table" then db.usage = { since = ns.Now(), pages = {}, commands = {}, logins = 0 } end
	local u = db.usage
	u.pages, u.commands = u.pages or {}, u.commands or {}
	return u
end

function Report.Count(kind, name)
	local u = Usage()
	if not u then return end
	if kind == "logins" then u.logins = (u.logins or 0) + 1 return end
	local t = u[kind]
	if t and name then t[name] = (t[name] or 0) + 1 end
end

-- Page opens and slash commands, counted where they happen.
local selectPage = ns.UI.SelectPage
local lastPage, lastAt
ns.UI.SelectPage = function(g, j)
	local page = g and g.pages and g.pages[j]
	-- Opening a page by name selects it twice (its tab, then the page): count it once.
	if page and not (page == lastPage and ns.Now() - (lastAt or 0) < 2) then Report.Count("pages", page.title) end
	lastPage, lastAt = page, ns.Now()
	return selectPage(g, j)
end
local showSettings = ns.UI.ShowSettings
ns.UI.ShowSettings = function(...)
	Report.Count("pages", "Settings")
	return showSettings(...)
end
local handleSlash = ns.HandleSlash
ns.HandleSlash = function(msg)
	local word = tostring(msg or ""):match("^%s*(%S+)")
	Report.Count("commands", word and word:lower() or "(window)")
	return handleSlash(msg)
end

function Report:OnLogin()
	Report.Count("logins")
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------
local function JsonString(s)
	s = tostring(s):gsub('[%c"\\]', function(c)
		if c == '"' then return '\\"' elseif c == "\\" then return "\\\\"
		elseif c == "\n" then return "\\n" elseif c == "\t" then return "\\t" end
		return string.format("\\u%04x", c:byte())
	end)
	return '"' .. s .. '"'
end

-- Plain tables only: a table with [1] is an array, anything else an object (keys sorted).
function Report.Json(v)
	local t = type(v)
	if t == "nil" then return "null" end
	if t == "boolean" then return tostring(v) end
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "null" end
		if v == math.floor(v) then return string.format("%d", v) end
		return string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", "")
	end
	if t == "table" then
		local out = {}
		if v[1] ~= nil or next(v) == nil and getmetatable(v) == Report.ARRAY then
			for i = 1, #v do out[i] = Report.Json(v[i]) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local val = v[k]
			if val == nil then val = v[tonumber(k)] end
			out[#out + 1] = JsonString(k) .. ":" .. Report.Json(val)
		end
		return "{" .. table.concat(out, ",") .. "}"
	end
	return JsonString(v)
end
Report.ARRAY = {} -- setmetatable({}, Report.ARRAY) marks an empty table as [] instead of {}
local function Array(t) return setmetatable(t or {}, Report.ARRAY) end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function Report.Base64(s)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = s:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1, c2 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64
		local c3, c4 = math.floor(n / 64) % 64, n % 64
		out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
			.. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
	end
	return table.concat(out)
end

function Report.Adler32(s)
	local a, b = 1, 0
	for i = 1, #s do
		a = (a + s:byte(i)) % 65521
		b = (b + a) % 65521
	end
	return string.format("%04x%04x", b, a)
end

function Report.Encode(data)
	local json = Report.Json(data)
	return Report.PREFIX .. "." .. Report.Base64(json) .. "." .. Report.Adler32(json), json
end

---------------------------------------------------------------------------
-- What goes in
---------------------------------------------------------------------------
local function Short(text, max)
	text = tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	text = text:gsub("Interface[/\\]AddOns[/\\]", "")
	return #text > max and (text:sub(1, max) .. "...") or text
end

function Report.Data(opts)
	opts = opts or {}
	local db = ns.db or { errors = {}, settings = {} }
	local d = { v = 1, addon = ns.VERSION, time = ns.Now(), locale = GetLocale and GetLocale() or nil }
	if GetBuildInfo then
		local version, build, _, iface = GetBuildInfo()
		d.client = { version = version, build = build, interface = iface }
	end
	local me = ns.PlayerName()
	if opts.name then d.character = me end
	d.officer = ns.Roster.IsOfficer(me) and true or false
	d.roster = { members = ns.Roster.count or 0, online = ns.Roster.online or 0, foundBy = ns.Roster.meHow }
	local users = 0
	for who in pairs(ns.Comm.versions) do if who ~= me then users = users + 1 end end
	d.addonUsersSeen = users

	local settings = {}
	for k, val in pairs(db.settings or {}) do
		if type(val) == "boolean" or type(val) == "number" then settings[k] = val end
	end
	d.settings = settings

	d.errors = Array()
	for i, e in ipairs(db.errors or {}) do
		if i > Report.MAX_ERRORS then break end
		local where = e.stack and e.stack:match("([%w_]+%.lua:%d+)")
		d.errors[#d.errors + 1] = { text = Short(e.text, 300), count = e.count or 1, first = e.first, last = e.last, at = where }
	end
	d.errorTotal = #(db.errors or {})

	local perf = Array()
	for label, s in pairs(ns.Perf.stats) do perf[#perf + 1] = { what = label, calls = s.calls, ms = s.total, max = s.max } end
	table.sort(perf, function(a, b) return a.ms > b.ms end)
	for i = #perf, Report.MAX_PERF + 1, -1 do perf[i] = nil end
	for _, p in ipairs(perf) do
		p.ms = math.floor(p.ms * 100 + 0.5) / 100
		p.max = math.floor(p.max * 100 + 0.5) / 100
	end
	d.perf = { on = ns.Perf.IsOn() and true or false, top = perf }

	if ns.SelfTest and ns.SelfTest.last then
		local st = ns.SelfTest.last
		d.selftest = { passed = st.passed, failed = st.failed, at = st.at, checks = Array() }
		for _, c in ipairs(st.results or {}) do
			if c.ok ~= nil then d.selftest.checks[#d.selftest.checks + 1] = { name = c.name, ok = c.ok } end
		end
	end

	local sync = {}
	for name in pairs(ns.Sync.sets) do
		local n = 0
		for _ in ns.Sync.Each(name) do n = n + 1 end
		sync[name] = n
	end
	d.sync = { records = sync, lastAsk = ns.Sync.lastAsk, lastAnswer = ns.Sync.lastAnswer }

	local u = Usage() or {}
	d.usage = { since = u.since, logins = u.logins or 0, pages = u.pages or {}, commands = u.commands or {} }
	d.hooks = { lootLinks = ns.LootNotes and #(ns.LootNotes.hooks or {}) or 0 }
	return d
end

function Report.Build(opts)
	return (Report.Encode(Report.Data(opts)))
end

function Report.Show(opts)
	local text = Report.Build(opts)
	ns.UI.ShowCopyBox("Diagnostics report: press Ctrl+C, then paste it at " .. Report.SITE, text)
	ns.Log("report: built, %d characters", #text)
	return text
end

ns.RegisterCommand("report", "diagnostics report to send: /iwt report (add 'name' to include this character)", function(rest)
	Report.Show({ name = (rest or ""):lower() == "name" })
end)
