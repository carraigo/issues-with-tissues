-- Guild chat inside the window (0.8.0): a Chat tab with the Guild and Officer channels,
-- the message of the day, guildmates coming online and going offline, class-coloured names,
-- clickable item and player links, and a box to type in (Enter sends, Up/Down recall).
--
-- Earlier chat comes from two places: the game's server, which keeps recent guild and officer
-- chat for the guild window (C_Club, read when the Chat tab opens), and the last lines of each
-- channel kept in this character's saved data (IwTCharDB.chat). The two are merged, without
-- duplicates; if the server can't be read, the saved lines are shown on their own. They stay on this PC: never shared with
-- guildmates, never in the diagnostics report or the guild web page. Settings can turn it off.
--
-- The chat lives in four files: Chat.lua (lines, storage, sending, chat events), ChatHistory.lua
-- (the server's history and merging it with ours), ChatOnline.lua (who's online beside the chat)
-- and ChatBox.lua (the page: channel buttons, the lines and the box to type in).
--
-- Nothing of Blizzard's is changed: the addon only listens to chat events and sends with
-- SendChatMessage, which guild and officer chat allow from a key press.

local _, ns = ...

local Chat = ns.RegisterModule("Chat", {})
ns.Chat = Chat

Chat.MAX_LINES = 300           -- kept per channel
Chat.MAX_SENT = 30             -- lines recalled with Up/Down
Chat.CHANNELS = { "guild", "officer" }
Chat.EVENTS = { CHAT_MSG_GUILD = "guild", CHAT_MSG_OFFICER = "officer" }
Chat.SEND = { guild = "GUILD", officer = "OFFICER" }
Chat.live = { guild = {}, officer = {} } -- this session, whether or not history is saved
Chat.unread = 0
Chat.channel = "guild"
Chat.sent = {}

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------
function Chat.Lines(channel)
	if ns.db and ns.db.settings.chatHistory and ns.char then
		ns.char.chat = ns.char.chat or {}
		ns.char.chat[channel] = ns.char.chat[channel] or {}
		return ns.char.chat[channel]
	end
	return Chat.live[channel]
end

function Chat:OnLoad()
	-- History switched off: drop anything saved before.
	if not ns.db.settings.chatHistory and ns.char then ns.char.chat = nil end
	-- Hidden text (see Chat.Hidden) only draws in the session that received it; from an earlier
	-- session it shows as "Unknown". Mark those lines so the server's fresh copy replaces them.
	for _, lines in pairs(ns.char and ns.char.chat or {}) do
		for _, e in ipairs(lines) do
			if e.k == "msg" and Chat.Hidden(e.m) then e.old = true end
		end
	end
end

-- Turning history on keeps this session's lines; turning it off forgets the saved ones.
function Chat.SetHistory(on)
	if on then
		ns.char.chat = ns.char.chat or {}
		for _, ch in ipairs(Chat.CHANNELS) do
			if not ns.char.chat[ch] or #ns.char.chat[ch] == 0 then ns.char.chat[ch] = Chat.live[ch] end
		end
	else
		if ns.char.chat then
			for _, ch in ipairs(Chat.CHANNELS) do Chat.live[ch] = ns.char.chat[ch] or Chat.live[ch] end
		end
		ns.char.chat = nil
	end
end

---------------------------------------------------------------------------
-- Lines
---------------------------------------------------------------------------
-- kind: "msg" (someone said something), "sys" (online/offline), "motd"
function Chat.Add(channel, kind, author, text)
	local lines = Chat.Lines(channel)
	if not lines then return end
	local entry = { t = ns.Now(), k = kind, a = author, m = tostring(text or "") }
	-- The game repeats the message of the day at every login: keep it once until it changes.
	if kind == "motd" then
		for i = #lines, 1, -1 do
			if lines[i].k == "motd" then
				if lines[i].m == entry.m then return nil end
				break
			end
		end
	end
	lines[#lines + 1] = entry
	while #lines > Chat.MAX_LINES do table.remove(lines, 1) end
	if lines ~= Chat.live[channel] then
		local live = Chat.live[channel]
		live[#live + 1] = entry
		while #live > Chat.MAX_LINES do table.remove(live, 1) end
	end
	if not Chat.Visible() and Chat.CountsAsUnread(kind, author) then
		Chat.unread = Chat.unread + 1
		Chat.UpdateBadge()
	end
	ns.Send("CHAT_LINE", channel, entry)
	return entry
end

function Chat.Hex(r, g, b)
	return string.format("%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

function Chat.ChannelColor(channel)
	local own = ns.UI.ChatColor and ns.UI.ChatColor(channel)
	if own then return own[1], own[2], own[3] end
	local info = ChatTypeInfo and ChatTypeInfo[Chat.SEND[channel]]
	if info and info.r then return info.r, info.g, info.b end
	if channel == "officer" then return 0.25, 0.75, 0.25 end
	return 0.25, 1, 0.25
end

-- "[18:04] [Vatic Cane]: hello" with the name in its class colour and clickable.
-- "14:05", or "2:05pm" with 24-hour times off.
function Chat.Time(t)
	if ns.db.settings.clock24 ~= false then return date("%H:%M", t) end
	local h = tonumber(date("%H", t))
	return string.format("%d:%s%s", (h % 12 == 0) and 12 or h % 12, date("%M", t), h < 12 and "am" or "pm")
end

-- The time shown on a line: "just now" and "5 min ago" for the last hour (Settings can turn that
-- off), else the clock time, with the day in front when it wasn't today.
function Chat.Stamp(t, now)
	now = now or ns.Now()
	local age = now - (t or now)
	if ns.db.settings.relativeTimes ~= false and age >= 0 and age < 3600 then
		if age < 60 then return "just now" end
		return math.floor(age / 60) .. " min ago"
	end
	if date("%Y%m%d", t) ~= date("%Y%m%d", now) then return date("%d %b ", t):gsub("^0", "") .. Chat.Time(t) end
	return Chat.Time(t)
end

-- The full time, for the timestamp's tooltip: "Monday 23 November 2026, 14:05:33".
function Chat.FullTime(t)
	local clock = ns.db.settings.clock24 ~= false and date("%H:%M:%S", t) or Chat.Time(t)
	return (date("%A %d %B %Y", t):gsub(" 0", " ")) .. ", " .. clock
end

function Chat.Format(channel, e)
	local C = ns.UI.COLORS
	-- The timestamp is a link: hovering it shows the full date and time.
	local stamp = "|Hiwttime:" .. tostring(e.t or 0) .. "|h|cff" .. Chat.Hex(C.stamp[1], C.stamp[2], C.stamp[3])
		.. Chat.Stamp(e.t) .. "|r|h "
	local sys = "|cff" .. Chat.Hex(C.sys[1], C.sys[2], C.sys[3])
	local r, g, b = Chat.ChannelColor(channel)
	if e.k == "motd" then
		return stamp .. "|cff" .. Chat.Hex(r, g, b) .. "Message of the day: " .. e.m .. "|r"
	end
	if e.k == "sys" then
		return stamp .. sys .. e.m .. "|r"
	end
	if not e.a then
		return stamp .. sys .. "[Unknown]|r|cff" .. Chat.Hex(r, g, b) .. ": " .. e.m .. "|r"
	end
	local key = ns.Roster.ParseName(e.a) or e.a
	local m = ns.Roster.Get(key)
	local cr, cg, cb = ns.UI.ClassColor(m and m.classFile)
	local name = ns.Roster.DisplayName(key)
	local link = "|Hplayer:" .. tostring(e.a or key) .. "|h|cff" .. Chat.Hex(cr, cg, cb) .. "[" .. name .. "]|r|h"
	return stamp .. link .. "|cff" .. Chat.Hex(r, g, b) .. ": " .. e.m .. "|r"
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
-- What the box sends: one line, at most 255 bytes, no surrounding spaces. Commands typed into
-- it ("/w Bob hi", "/roll") go to the game's own chat box instead.
function Chat.Clean(text)
	local s = tostring(text or ""):gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	if #s > 255 then
		s = s:sub(1, 255)
		-- Don't cut a link in half: drop a trailing piece of an unfinished "|H...|h[...]|h".
		local lastStart = s:match(".*()|H")
		if lastStart and not s:find("|h|r", lastStart, true) and not s:find("]|h", lastStart, true) then
			s = s:sub(1, lastStart - 1)
		end
		s = s:gsub("|c%x*$", ""):gsub("%s+$", "")
	end
	return s
end

function Chat.Send(text, channel)
	channel = channel or Chat.channel
	local s = Chat.Clean(text)
	if s == "" then return false end
	if s:sub(1, 1) == "/" then
		if ChatFrame_OpenChat then ChatFrame_OpenChat(s) end
		return false, "command"
	end
	if not SendChatMessage then return false end
	SendChatMessage(s, Chat.SEND[channel] or "GUILD")
	table.insert(Chat.sent, s)
	while #Chat.sent > Chat.MAX_SENT do table.remove(Chat.sent, 1) end
	return true
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
for event, channel in pairs(Chat.EVENTS) do
	ns.On(event, function(_, text, author)
		Chat.Add(channel, "msg", author, text)
	end)
end

-- "<name> has come online." / "<name> has gone offline." for guildmates (the same messages are
-- used for friends, so only names in the roster count).
local function Pattern(fmt)
	if type(fmt) ~= "string" then return nil end
	local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.-)"):gsub("%%%%d", "%%d+")
	return "^" .. p .. "$"
end

function Chat.SystemLine(text)
	text = tostring(text or "")
	for _, fmt in ipairs({ ERR_FRIEND_ONLINE_SS or "|Hplayer:%s|h[%s]|h has come online.", ERR_FRIEND_OFFLINE_S or "%s has gone offline." }) do
		local p = Pattern(fmt)
		local who = p and text:match(p)
		if who and ns.Roster.IsMember(who) then
			local key = ns.Roster.ParseName(who)
			local name = ns.Roster.DisplayName(key)
			local online = fmt:find("online", 1, true) ~= nil
			return name .. (online and " has come online." or " has gone offline."), key, online
		end
	end
end

ns.On("CHAT_MSG_SYSTEM", function(_, text)
	local line, key, online = Chat.SystemLine(text)
	if not line then return end
	Chat.Add("guild", "sys", nil, line)
	-- Keep the online list right away; the next roster scan confirms it.
	local m = ns.Roster.Get(key)
	if m and m.online ~= online then
		m.online = online
		ns.Roster.online = math.max(0, (ns.Roster.online or 0) + (online and 1 or -1))
		Chat.DrawOnlineSoon()
	end
	ns.Roster.Request()
end)

function Chat.MOTD()
	local motd = GetGuildRosterMOTD and GetGuildRosterMOTD()
	if type(motd) == "string" and motd ~= "" then return motd end
end

-- The message of the day is shown at the top of the Guild channel; a new one is added as a line.
pcall(ns.On, "GUILD_MOTD", function(_, motd)
	if type(motd) == "string" and motd ~= "" then Chat.Add("guild", "motd", nil, motd) end
end)
