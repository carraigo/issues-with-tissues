-- The live log: /iwt clane (not listed in /iwt help or the docs).
-- Shows, as it happens, what the addon is doing: catch-ups asked and answered (and by whom),
-- every message sent and heard, records taken in and shared, timers, roster changes and
-- errors, from ns.Trace (Core.lua). A separate window that can stay open while playing.
-- Nothing is saved: the log lives in memory (the last ns.TRACE_MAX lines since login).

local _, ns = ...

local Con = ns.RegisterModule("Console", {})
ns.Console = Con

Con.KINDS = {
	sync = { label = "SYNC", color = "4fc3f7" },
	data = { label = "DATA", color = "ce93d8" },
	mine = { label = "MINE", color = "ffd54f" },
	send = { label = "SEND", color = "81c784" },
	recv = { label = "HEAR", color = "ffb74d" },
	comm = { label = "COMM", color = "4db6ac" },
	roster = { label = "GUILD", color = "64b5f6" },
	timer = { label = "TIME", color = "9e9e9e" },
	error = { label = "ERROR", color = "ef5350" },
	log = { label = "NOTE", color = "b0bec5" },
}
Con.FILTERS = {
	{ key = "all", label = "Everything" },
	{ key = "sync", label = "Sync", kinds = { sync = true, data = true, mine = true } },
	{ key = "msgs", label = "Messages", kinds = { send = true, recv = true, comm = true } },
	{ key = "guild", label = "Guild", kinds = { roster = true } },
	{ key = "timers", label = "Timers", kinds = { timer = true } },
	{ key = "problems", label = "Problems", kinds = { error = true } },
}
Con.filter = "all"

local function Shows(e)
	local f
	for _, x in ipairs(Con.FILTERS) do if x.key == Con.filter then f = x end end
	return not f or not f.kinds or f.kinds[e.kind]
end
Con.Shows = Shows

-- A guildmate's name in their class colour, numbers picked out, the rest as it is.
local function Arg(v)
	if type(v) == "number" then return "|cffffffff" .. tostring(v) .. "|r" end
	v = tostring(v)
	local m = ns.Roster and ns.Roster.members and ns.Roster.Get(v)
	if m then
		local r, g, b = ns.UI.ClassColor(m.classFile)
		return string.format("|cff%02x%02x%02x%s|r", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), ns.Roster.DisplayName(v))
	end
	return v
end

-- One log line: time, a coloured tag, the message.
function Con.Format(e, plain)
	local args = {}
	for i = 1, e.n do args[i] = plain and tostring(e[i]) or Arg(e[i]) end
	local ok, text = pcall(string.format, e.fmt, unpack(args, 1, e.n))
	if not ok then text = tostring(e.fmt) end
	local k = Con.KINDS[e.kind] or Con.KINDS.log
	local stamp = date("%H:%M:%S", e.clock) .. string.format(".%d", math.floor((e.at % 1) * 10))
	if plain then return string.format("%s  %-5s  %s", stamp, k.label, text) end
	return string.format("|cff6f6f6f%s|r  |cff%s%-5s|r  %s", stamp, k.color, k.label, text)
end

-- The lines kept, oldest first, that the current filter shows.
function Con.Lines(plain)
	local t, out = ns.traces, {}
	for i = t.first, t.last do
		local e = t[i]
		if e and Shows(e) then out[#out + 1] = Con.Format(e, plain) end
	end
	return out
end

local function KB(n) return string.format("%.1f KB", (n or 0) / 1024) end

-- "Synced with Gm 2 min ago (340 records), Offi 1 hour ago (12)" and the traffic so far.
function Con.Summary()
	local peers = {}
	for who, p in pairs(ns.Sync.peers or {}) do peers[#peers + 1] = { who = who, at = p.at, records = p.records } end
	table.sort(peers, function(a, b) return a.at > b.at end)
	local parts = {}
	for i = 1, math.min(4, #peers) do
		local p = peers[i]
		parts[i] = string.format("%s %s (%d)", Arg(p.who), ns.UI.TimeAgo(p.at), p.records)
	end
	local synced = #parts > 0 and ("Synced with " .. table.concat(parts, ", ")) or "|cffef5350Not synced with anyone yet this session|r"
	local held = 0
	for name in pairs(ns.Sync.sets) do for _ in ns.Sync.Each(name) do held = held + 1 end end
	local C = ns.Comm
	local state = C.Held()
	return synced, string.format("Sent %d (%s)   Heard %d (%s)   Queue %d   Refused %d   Records held %s   %s",
		C.sentCount or 0, KB(C.sentBytes), C.heardCount or 0, KB(C.heardBytes), C.Queued(), C.throttled or 0,
		ns.UI.Number(held), state == "combat" and "|cffef5350In combat: paused|r" or state == "raid" and "|cffffb74dIn an instance: slow|r" or "|cff81c784Normal pace|r")
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------
local win, box, top, bottom, pauseButton
local filterButtons = {}

function Con.Redraw()
	if not win then return end
	box:Clear()
	for _, line in ipairs(Con.Lines()) do box:AddMessage(line) end
	for _, b in ipairs(filterButtons) do ns.UI.SetSelected(b, b.key == Con.filter) end
end

function Con.RefreshSummary()
	if not win or not win:IsShown() then return end
	local a, b = Con.Summary()
	top:SetText(a)
	bottom:SetText(b)
end

local function Create()
	if win then return win end
	local UI = ns.UI
	win = UI.Window("IssuesWithTissuesConsole", 760, 460, "Issues with Tissues: live log", "MEDIUM")
	win:SetPoint("CENTER", 0, 0)
	if win.SetUserPlaced then win:SetUserPlaced(true) end
	top = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	top:SetPoint("TOPLEFT", 12, -40)
	top:SetPoint("TOPRIGHT", -12, -40)
	top:SetJustifyH("LEFT")
	local x = 10
	for _, f in ipairs(Con.FILTERS) do
		local b = UI.Button(win, f.label, 84, 20)
		b:SetPoint("TOPLEFT", x, -58)
		b.key = f.key
		b:SetScript("OnClick", function() Con.filter = f.key; Con.Redraw() end)
		filterButtons[#filterButtons + 1] = b
		x = x + 88
	end
	pauseButton = UI.Button(win, "Pause", 60, 20)
	pauseButton:SetPoint("TOPRIGHT", -140, -58)
	pauseButton:SetScript("OnClick", function()
		Con.paused = not Con.paused
		pauseButton:SetText(Con.paused and "Resume" or "Pause")
		if not Con.paused then Con.Redraw() end
	end)
	local clear = UI.Button(win, "Clear", 60, 20)
	clear:SetPoint("TOPRIGHT", -74, -58)
	clear:SetScript("OnClick", function() Con.Clear() end)
	local copy = UI.Button(win, "Copy", 60, 20)
	copy:SetPoint("TOPRIGHT", -10, -58)
	copy:SetScript("OnClick", function() UI.ShowCopyBox("Live log", table.concat(Con.Lines(true), "\n")) end)

	local frame = CreateFrame("Frame", nil, win)
	frame:SetPoint("TOPLEFT", 8, -84)
	frame:SetPoint("BOTTOMRIGHT", -8, 28)
	UI.Skin(frame, UI.COLORS.input, UI.COLORS.dim)
	box = CreateFrame("ScrollingMessageFrame", nil, frame)
	box:SetPoint("TOPLEFT", 8, -6)
	box:SetPoint("BOTTOMRIGHT", -8, 6)
	box:SetFontObject(_G.ChatFontNormal or "ChatFontNormal")
	box:SetJustifyH("LEFT")
	box:SetMaxLines(ns.TRACE_MAX + 20)
	box:SetFading(false)
	if box.SetIndentedWordWrap then box:SetIndentedWordWrap(true) end
	box:EnableMouseWheel(true)
	box:SetScript("OnMouseWheel", function(self, delta)
		if IsShiftKeyDown and IsShiftKeyDown() then
			if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
		elseif delta > 0 then self:ScrollUp() else self:ScrollDown() end
	end)
	bottom = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	bottom:SetPoint("BOTTOMLEFT", 12, 9)
	bottom:SetPoint("BOTTOMRIGHT", -12, 9)
	bottom:SetJustifyH("LEFT")
	-- The summary line ticks once a second while the window is open.
	local since = 0
	win:SetScript("OnUpdate", function(_, elapsed)
		since = since + (elapsed or 0)
		if since >= 1 then since = 0; Con.RefreshSummary() end
	end)
	win:SetScript("OnShow", function() Con.Redraw(); Con.RefreshSummary() end)
	Con.window, Con.box = win, box
	return win
end

-- New lines go straight in while the window is open (and not paused).
ns.onTrace = function(e)
	if win and win:IsShown() and not Con.paused and Shows(e) then box:AddMessage(Con.Format(e)) end
end

function Con.Clear()
	local t = ns.traces
	for i = t.first, t.last do t[i] = nil end
	t.first, t.last = t.last + 1, t.last
	if box then box:Clear() end
end

function Con.Toggle()
	Create()
	if win:IsShown() then win:Hide() else win:Show(); Con.Redraw(); Con.RefreshSummary() end
	return win:IsShown()
end

ns.RegisterCommand("clane", "the live log", function() Con.Toggle() end, true)
