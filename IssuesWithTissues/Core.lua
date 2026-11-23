-- Issues with Tissues: core.
-- Namespace, saved variables with defaults, one event frame shared by every module,
-- a module registry and the /iwt slash command router.

local ADDON, ns = ...
ns = ns or {}
ns.ADDON = ADDON or "IssuesWithTissues"
ns.VERSION = "1.3.0"

-- Every setting, declared once: its default and how the Settings page shows it. The page builds
-- itself from this list (Settings.lua); a feature reacts to a change with
-- ns.Settings.OnChange(key, fn). kind:
--   "toggle"    a tick box (label)
--   "choice"    a row of buttons (label, choices = { { id, name }, ... })
--   "dropdown"  a drop-down (label, choices = fn() -> { { id, name }, ... }, reload = applies at /reload)
--   "range"     a slider shown in percent (label, min, max, step)
--   "hidden"    kept, but not on the page
ns.SETTINGS = {
	{ key = "minimap", default = true, kind = "toggle", label = "Show the minimap button" },
	{ key = "guildButton", default = true, kind = "toggle", label = "Show the button on the guild window" },
	{ key = "sounds", default = true, kind = "toggle", label = "Play alert sounds" },
	{ key = "windowSounds", default = true, kind = "toggle", label = "Sounds when the window opens and closes" },
	{ key = "hideInCombat", default = false, kind = "toggle", label = "Hide the window in combat (back after)" },
	{ key = "tooltipCraftable", default = true, kind = "toggle", label = "\"Guild craftable\" on item tooltips" },
	{ key = "chatHistory", default = true, kind = "toggle", label = "Keep guild chat between sessions (this PC)" },
	{ key = "clock24", default = true, kind = "toggle", label = "24-hour times in chat (off: 2:05pm)" },
	{ key = "relativeTimes", default = true, kind = "toggle", label = "\"5 min ago\" times in chat for the last hour" },
	{ key = "debug", default = false, kind = "toggle", label = "Print addon errors in chat" },
	{ key = "theme", default = "default", kind = "dropdown", label = "Theme", reload = true,
		choices = function()
			local out = {}
			for i, t in ipairs(ns.UI.THEMES) do out[i] = { id = t.id, name = t.name } end
			return out
		end },
	{ key = "scale", default = 1, kind = "range", label = "Window size", min = 0.7, max = 1.3, step = 0.05 },
	{ key = "openOn", default = "last", kind = "choice", label = "Open the window on",
		choices = { { id = "last", name = "Last used" }, { id = "Home", name = "Home" }, { id = "Chat", name = "Chat" } } },
	-- rankIndex 0 = Guild Master, 1 = Officer (game ranks 1 and 2); shown as text on the page
	{ key = "officerMaxRank", default = 1, kind = "hidden" },
}
ns.SETTING = {}
for _, s in ipairs(ns.SETTINGS) do ns.SETTING[s.key] = s end

-- Defaults. Copied into IwTDB / IwTCharDB on load without overwriting what is already there.
ns.DEFAULTS = {
	settings = {},
	minimapAngle = 220,
	errors = {},               -- Diagnostics
	log = {},                  -- Diagnostics
	sync = {},                 -- Sync: dataset name -> { rev = n, data = ... }
	perf = { on = false },
	window = {},
}
for _, s in ipairs(ns.SETTINGS) do ns.DEFAULTS.settings[s.key] = s.default end
ns.CHAR_DEFAULTS = {}

local function CopyDefaults(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			CopyDefaults(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
	return dst
end
ns.CopyDefaults = CopyDefaults

function ns.Print(fmt, ...)
	local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cff7fd4ffIwT|r " .. msg)
	end
end

-- The live log (/iwt clane, Console.lua): what the addon is doing, kept in memory only.
--   ns.Trace("sync", "Asked the guild (round %d)", n)
-- Cheap: the text is only formatted when the window shows it. Kinds: sync, send, recv, data,
-- mine, comm, timer, roster, error, log.
ns.TRACE_MAX = 500
ns.traces = { first = 1, last = 0 }
function ns.Trace(kind, fmt, ...)
	local t = ns.traces
	t.last = t.last + 1
	t[t.last] = { at = GetTime and GetTime() or 0, clock = time and time() or 0, kind = kind, fmt = fmt,
		n = select("#", ...), ... }
	if t.last - t.first >= ns.TRACE_MAX then
		t[t.first] = nil
		t.first = t.first + 1
	end
	if ns.onTrace then ns.onTrace(t[t.last]) end
end

function ns.Now()
	if GetServerTime then return GetServerTime() end
	return time()
end

---------------------------------------------------------------------------
-- Events: modules call ns.On(event, fn). One frame, many listeners.
---------------------------------------------------------------------------
local listeners = {}
local frame = CreateFrame("Frame")
ns.eventFrame = frame

function ns.On(event, fn)
	if not listeners[event] then
		listeners[event] = {}
		ns.registering = event -- named in /iwt bug if the game blocks it
		frame:RegisterEvent(event)
		ns.registering = nil
	end
	table.insert(listeners[event], fn)
end

function ns.Fire(event, ...)
	local list = listeners[event]
	if not list then return end
	for i = 1, #list do
		local ok, err = pcall(list[i], event, ...)
		if not ok and ns.ReportError then ns.ReportError(err) end
	end
end

frame:SetScript("OnEvent", function(_, event, ...) ns.Fire(event, ...) end)

-- Internal messages between modules (not game events).
local callbacks = {}
function ns.Listen(name, fn)
	callbacks[name] = callbacks[name] or {}
	table.insert(callbacks[name], fn)
end
function ns.Send(name, ...)
	local list = callbacks[name]
	if not list then return end
	for i = 1, #list do
		local ok, err = pcall(list[i], ...)
		if not ok and ns.ReportError then ns.ReportError(err) end
	end
end

-- Text typed by a player, made safe to share: no colour/link codes ("|"), none of the
-- separators shared data uses (";" and extra), no surrounding spaces, at most max letters.
function ns.CleanText(text, max, extra)
	local s = tostring(text or ""):gsub("[|;\30\31" .. (extra or "") .. "]", "")
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	return s:sub(1, max)
end

-- A function that runs fn once, a moment later, however often it is called in between. Pages
-- redraw through this: a catch-up brings hundreds of records in a burst, and redrawing a page
-- for each one froze the game for seconds. Runs at once where there are no timers.
function ns.Coalesce(fn, delay)
	local pending = false
	return function()
		if pending then return end
		if not (C_Timer and C_Timer.After) then return fn() end
		pending = true
		C_Timer.After(delay or 0.1, function()
			pending = false
			local ok, err = pcall(fn)
			if not ok and ns.ReportError then ns.ReportError(err) end
		end)
	end
end

-- Timers (C_Timer when present).
function ns.After(seconds, fn)
	if C_Timer and C_Timer.After then
		C_Timer.After(seconds, function()
			local ok, err = pcall(fn)
			if not ok and ns.ReportError then ns.ReportError(err) end
		end)
	end
end

-- Every timed job in one place, in seconds. At login the jobs are spread out so the addon
-- never does everything in the same frame, in this order:
ns.TIMERS = {
	hello = 5,          -- Comm: tell the guild our version
	welcome = 6,        -- Welcome card or What's new
	catchUp = 8,        -- Sync: first catch-up (the roster has loaded by then)
	chatHistory = 10,   -- Chat: ask the server for guild chat history
	alts = 11,          -- Alts: pending link requests (after the chat history)
	profs = 12,         -- Professions: share skills
	sheet = 14,         -- Sheet: ask for saved raids, then share attunements and lockouts
	kills = 15,         -- Kills: share kill counts
	recipeNames = 30,   -- Professions: ask the game for recipe item names this PC lacks
	tidyVotes = 90,     -- Polls: drop our votes on polls no longer listed (after the catch-up)
	lateCatchUp = 600,  -- Sync: a second catch-up, for whoever logged in since
	-- Repeating and event-driven waits:
	killsEvery = 120,   -- Kills: share at most this often after fights
	skillsChanged = 2,  -- Professions: after SKILL_LINES_CHANGED
	recipeRead = 0.6,   -- Professions: after the profession window changes
	welcomeRetry = 10,  -- Welcome: waiting for combat to end
	sheetChanged = 3,   -- Sheet: after a quest hand-in or the game's raid info
	sheetBags = 10,     -- Sheet: after the bags change (keys)
	sheetBoss = 5,      -- Sheet: after a boss kill, ask for saved raids again
}
-- ns.Later("kills", fn): run fn after ns.TIMERS.kills seconds.
function ns.Later(name, fn)
	local seconds = ns.TIMERS[name]
	assert(seconds, "unknown timer " .. tostring(name))
	ns.Trace("timer", "%s in %ss", name, seconds)
	ns.After(seconds, fn)
end

---------------------------------------------------------------------------
-- Modules: ns.RegisterModule(name, { OnLoad = fn, OnLogin = fn })
---------------------------------------------------------------------------
ns.modules, ns.moduleOrder = {}, {}
function ns.RegisterModule(name, mod)
	ns.modules[name] = mod
	table.insert(ns.moduleOrder, name)
	return mod
end

-- How long each module's OnLoad and OnLogin took, in ms (shown in /iwt bug and /iwt perf).
ns.startup = { OnLoad = {}, OnLogin = {} }
local clock = debugprofilestop or function() return os.clock() * 1000 end

local function EachModule(method, ...)
	local times = ns.startup[method]
	for _, name in ipairs(ns.moduleOrder) do
		local mod = ns.modules[name]
		if type(mod[method]) == "function" then
			local start = clock()
			local ok, err = pcall(mod[method], mod, ...)
			if times then times[name] = clock() - start end
			if not ok and ns.ReportError then ns.ReportError(name .. "." .. method .. ": " .. tostring(err)) end
		end
	end
end

-- "OnLoad 4.1 ms, OnLogin 0.6 ms; slowest: Chat 2.3, Sync 1.1"
function ns.StartupText()
	local parts, all = {}, {}
	for _, method in ipairs({ "OnLoad", "OnLogin" }) do
		local total = 0
		for name, ms in pairs(ns.startup[method]) do
			total = total + ms
			all[name] = (all[name] or 0) + ms
		end
		parts[#parts + 1] = string.format("%s %.1f ms", method, total)
	end
	local list = {}
	for name, ms in pairs(all) do list[#list + 1] = { name = name, ms = ms } end
	table.sort(list, function(a, b) return a.ms > b.ms end)
	local slow = {}
	for i = 1, math.min(3, #list) do slow[i] = string.format("%s %.1f", list[i].name, list[i].ms) end
	return table.concat(parts, ", ") .. (#slow > 0 and ("; slowest: " .. table.concat(slow, ", ")) or "")
end

-- This addon's memory in KB (the game's count; refreshing it costs a moment, so only on demand).
function ns.MemoryKB()
	if not (UpdateAddOnMemoryUsage and GetAddOnMemoryUsage) then return nil end
	pcall(UpdateAddOnMemoryUsage)
	local ok, kb = pcall(GetAddOnMemoryUsage, ns.ADDON)
	return ok and type(kb) == "number" and kb or nil
end
ns.EachModule = EachModule

ns.On("ADDON_LOADED", function(_, name)
	if name ~= ns.ADDON then return end
	IwTDB = CopyDefaults(type(IwTDB) == "table" and IwTDB or {}, ns.DEFAULTS)
	IwTCharDB = CopyDefaults(type(IwTCharDB) == "table" and IwTCharDB or {}, ns.CHAR_DEFAULTS)
	ns.db, ns.char = IwTDB, IwTCharDB
	IwTDB.settings.hopRequests = nil -- layer hopping was removed in 0.9.0
	EachModule("OnLoad")
end)

ns.On("PLAYER_LOGIN", function()
	ns.loginAt = ns.Now()
	EachModule("OnLogin")
end)

---------------------------------------------------------------------------
-- Slash commands: ns.RegisterCommand("bug", "copyable bug report", fn)
---------------------------------------------------------------------------
ns.commands, ns.commandOrder = {}, {}
-- hidden: works, but isn't listed in /iwt help.
function ns.RegisterCommand(word, help, fn, hidden)
	ns.commands[word] = { help = help, fn = fn }
	if not hidden then table.insert(ns.commandOrder, word) end
end

function ns.HandleSlash(msg)
	msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local word, rest = msg:match("^(%S+)%s*(.*)$")
	word = word and word:lower()
	if not word then
		if ns.UI and ns.UI.Toggle then ns.UI.Toggle() end
		return
	end
	local cmd = ns.commands[word]
	if cmd then
		cmd.fn(rest or "")
		return
	end
	ns.Print("Commands:")
	ns.Print("  /iwt - open or close the window")
	for _, w in ipairs(ns.commandOrder) do
		ns.Print("  /iwt %s - %s", w, ns.commands[w].help)
	end
end

SLASH_ISSUESWITHTISSUES1, SLASH_ISSUESWITHTISSUES2 = "/iwt", "/tissues"
-- Never assign the SlashCmdList global itself: that taints it, and every macro (/target,
-- /tm...) reads it, so the game blocks the macro's action and blames this addon.
if SlashCmdList then SlashCmdList.ISSUESWITHTISSUES = function(msg) ns.HandleSlash(msg) end end

ns.RegisterCommand("version", "show the addon version", function()
	ns.Print("Issues with Tissues %s", ns.VERSION)
end)

_G.IssuesWithTissues = ns -- for /dump and other addons; read-only by convention
