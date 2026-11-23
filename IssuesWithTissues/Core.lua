-- Issues with Tissues: core.
-- Namespace, saved variables with defaults, one event frame shared by every module,
-- a module registry and the /iwt slash command router.

local ADDON, ns = ...
ns = ns or {}
ns.ADDON = ADDON or "IssuesWithTissues"
ns.VERSION = "1.2.2"

-- Defaults. Copied into IwTDB / IwTCharDB on load without overwriting what is already there.
ns.DEFAULTS = {
	settings = {
		minimap = true,        -- show the minimap button
		guildButton = true,    -- show the button on the guild frame
		sounds = true,
		officerMaxRank = 1,    -- rankIndex 0 = Guild Master, 1 = Officer (game ranks 1 and 2)
		debug = false,
		chatHistory = true,    -- keep guild chat between sessions (this PC only)
		theme = "default",     -- window colours (Themes.lua), applied at /reload
		windowSounds = true,   -- a sound when the window opens, closes or changes tab
		scale = 1,             -- window size, 0.7 to 1.3
		hideInCombat = false,  -- hide the window when combat starts, back after
		clock24 = true,        -- chat times as 14:05 (false: 2:05pm)
		tooltipCraftable = true, -- "Guild craftable" on item tooltips
		openOn = "last",       -- the tab the window opens on: "last" (where you left it), "Home" or "Chat"
	},
	minimapAngle = 220,
	errors = {},               -- Diagnostics
	log = {},                  -- Diagnostics
	sync = {},                 -- Sync: dataset name -> { rev = n, data = ... }
	perf = { on = false },
	window = {},
}
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
	EachModule("OnLogin")
end)

---------------------------------------------------------------------------
-- Slash commands: ns.RegisterCommand("bug", "copyable bug report", fn)
---------------------------------------------------------------------------
ns.commands, ns.commandOrder = {}, {}
function ns.RegisterCommand(word, help, fn)
	ns.commands[word] = { help = help, fn = fn }
	table.insert(ns.commandOrder, word)
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
