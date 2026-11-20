-- Issues with Tissues: core.
-- Namespace, saved variables with defaults, one event frame shared by every module,
-- a module registry and the /iwt slash command router.

local ADDON, ns = ...
ns = ns or {}
ns.ADDON = ADDON or "IssuesWithTissues"
ns.VERSION = "0.6.1"

-- Defaults. Copied into IwTDB / IwTCharDB on load without overwriting what is already there.
ns.DEFAULTS = {
	settings = {
		minimap = true,        -- show the minimap button
		guildButton = true,    -- show the button on the guild frame
		sounds = true,
		officerMaxRank = 1,    -- rankIndex 0 = Guild Master, 1 = Officer (game ranks 1 and 2)
		debug = false,
		hopRequests = true,    -- let guildmates ask you for a layer-hop invite
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

local function EachModule(method, ...)
	for _, name in ipairs(ns.moduleOrder) do
		local mod = ns.modules[name]
		if type(mod[method]) == "function" then
			local ok, err = pcall(mod[method], mod, ...)
			if not ok and ns.ReportError then ns.ReportError(name .. "." .. method .. ": " .. tostring(err)) end
		end
	end
end
ns.EachModule = EachModule

ns.On("ADDON_LOADED", function(_, name)
	if name ~= ns.ADDON then return end
	IwTDB = CopyDefaults(type(IwTDB) == "table" and IwTDB or {}, ns.DEFAULTS)
	IwTCharDB = CopyDefaults(type(IwTCharDB) == "table" and IwTCharDB or {}, ns.CHAR_DEFAULTS)
	ns.db, ns.char = IwTDB, IwTCharDB
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
