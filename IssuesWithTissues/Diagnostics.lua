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
	add("Settings:")
	local keys = {}
	for k in pairs(db.settings or {}) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do add(string.format("  %s = %s", k, tostring(db.settings[k]))) end
	add("")
	add(string.format("Errors (%d):", #db.errors))
	for i, e in ipairs(db.errors) do
		add(string.format("%d. [x%d] %s", i, e.count or 1, e.text))
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
