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

local function Hex(r, g, b)
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

function Chat.Format(channel, e)
	local C = ns.UI.COLORS
	local stamp = "|cff" .. Hex(C.stamp[1], C.stamp[2], C.stamp[3]) .. Chat.Time(e.t) .. "|r "
	local sys = "|cff" .. Hex(C.sys[1], C.sys[2], C.sys[3])
	local r, g, b = Chat.ChannelColor(channel)
	if e.k == "motd" then
		return stamp .. "|cff" .. Hex(r, g, b) .. "Message of the day: " .. e.m .. "|r"
	end
	if e.k == "sys" then
		return stamp .. sys .. e.m .. "|r"
	end
	if not e.a then
		return stamp .. sys .. "[Unknown]|r|cff" .. Hex(r, g, b) .. ": " .. e.m .. "|r"
	end
	local key = ns.Roster.ParseName(e.a) or e.a
	local m = ns.Roster.Get(key)
	local cr, cg, cb = ns.UI.ClassColor(m and m.classFile)
	local name = ns.Roster.DisplayName(key)
	local link = "|Hplayer:" .. tostring(e.a or key) .. "|h|cff" .. Hex(cr, cg, cb) .. "[" .. name .. "]|r|h"
	return stamp .. link .. "|cff" .. Hex(r, g, b) .. ": " .. e.m .. "|r"
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

---------------------------------------------------------------------------
-- History kept by the game's server (the guild window's chat), through C_Club
---------------------------------------------------------------------------
Chat.SERVER_COUNT = 100        -- messages asked for per channel
Chat.server = { guild = {}, officer = {} }
Chat.authors = {}              -- server message id -> author name, for this session
local STREAM = { guild = 1, officer = 2 } -- Enum.ClubStreamType.Guild / .Officer

local function StreamType(channel)
	local e = Enum and Enum.ClubStreamType
	if e then return channel == "officer" and e.Officer or e.Guild end
	return STREAM[channel]
end

-- clubId, streamId for a channel, or nil when this client or guild has none.
function Chat.Stream(channel)
	if not (C_Club and C_Club.GetGuildClubId and C_Club.GetStreams) then return nil end
	local clubId = C_Club.GetGuildClubId()
	if not clubId then return nil end
	local want = StreamType(channel)
	for _, st in ipairs(C_Club.GetStreams(clubId) or {}) do
		if st.streamType == want then return clubId, st.streamId end
	end
end

-- Ask the server for recent messages; CLUB_MESSAGE_HISTORY_RECEIVED says when they are in.
function Chat.RequestServer()
	for _, ch in ipairs(Chat.CHANNELS) do
		local ok, err = pcall(function()
			local clubId, streamId = Chat.Stream(ch)
			if clubId and C_Club.RequestMoreMessagesBefore then
				C_Club.RequestMoreMessagesBefore(clubId, streamId, nil, Chat.SERVER_COUNT)
			end
		end)
		if not ok then ns.Log("chat: asking the server for %s history failed: %s", ch, tostring(err)) end
	end
	Chat.ReadServer()
end

-- The server sometimes leaves out a message's author name (it hasn't looked that member up
-- yet): fall back to the character behind the author's GUID, then to the club member record.
function Chat.AuthorName(clubId, author)
	if type(author) ~= "table" then return nil end
	if author.name and author.name ~= "" then return author.name end
	if author.guid and GetPlayerInfoByGUID then
		local ok, _, _, _, _, _, name, realm = pcall(GetPlayerInfoByGUID, author.guid)
		if ok and name and name ~= "" then
			return (realm and realm ~= "") and (name .. "-" .. realm) or name
		end
	end
	if author.memberId and C_Club.GetMemberInfo then
		local ok, info = pcall(C_Club.GetMemberInfo, clubId, author.memberId)
		if ok and type(info) == "table" and info.name and info.name ~= "" then return info.name end
	end
end

-- Copy what the server holds into Chat.server[channel] as { t, k, a, m } lines, oldest first.
function Chat.ReadServer()
	for _, ch in ipairs(Chat.CHANNELS) do
		local ok, err = pcall(function()
			local clubId, streamId = Chat.Stream(ch)
			if not clubId or not C_Club.GetMessageRanges or not C_Club.GetMessagesInRange then return end
			local ranges = C_Club.GetMessageRanges(clubId, streamId) or {}
			local last = ranges[#ranges]
			if not last then return end
			local out = {}
			for _, msg in ipairs(C_Club.GetMessagesInRange(clubId, streamId, last.oldestMessageId, last.newestMessageId) or {}) do
				if not msg.destroyed and msg.content and msg.messageId then
					-- A name found once is remembered: later reads (after alt-tabbing, say) can
					-- come back without it.
					local id = tostring(msg.messageId.epoch) .. ":" .. tostring(msg.messageId.position)
					local name = Chat.AuthorName(clubId, msg.author) or Chat.authors[id]
					Chat.authors[id] = name
					out[#out + 1] = { t = math.floor((msg.messageId.epoch or 0) / 1000000), k = "msg",
						a = name, m = msg.content, srv = true }
				end
			end
			table.sort(out, function(a, b) return a.t < b.t end)
			if #out ~= #(Chat.server[ch] or {}) then ns.Log("chat: %d %s messages from the server", #out, ch) end
			Chat.server[ch] = out
		end)
		if not ok then ns.Log("chat: reading %s history from the server failed: %s", ch, tostring(err)) end
	end
end

-- Text as compared between the two histories: colour codes and link wrappers dropped, spaces
-- squeezed, lower case. The game's server and the live chat event don't always spell a
-- message, or its author, the same way.
function Chat.Plain(text)
	local s = tostring(text or "")
	s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1")
	s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
	return s:lower()
end

Chat.SAME_WINDOW = 120         -- seconds between two copies of one message, by text
Chat.HIDDEN_WINDOW = 5         -- seconds, when one copy's text is hidden

-- The game can hand over a message's text as a hidden token ("|Kq12|k") that draws as the
-- words on screen but can't be read by addons. Both the live event and the server's history
-- do this, not always for the same message.
function Chat.Hidden(text)
	return tostring(text or ""):find("|K", 1, true) ~= nil
end

-- The two histories as one: the saved lines plus the server messages they don't already have,
-- oldest first. A saved line hides at most one server message: the same text within two
-- minutes, or, when either text is hidden, the same author within a few seconds. So two
-- people saying "lol" still show twice.
function Chat.View(channel)
	local mine = Chat.Lines(channel) or {}
	local server = Chat.server[channel] or {}
	if #server == 0 then
		local out = {}
		for _, e in ipairs(mine) do if not e.old then out[#out + 1] = e end end
		return out
	end
	local used = {}
	local function First(a) return (ns.Roster.FirstName(a or "") or ""):lower() end
	-- Worked out once per saved line, not once per pair (300 x 300 lines at login).
	local mHidden, mPlain, mFirst = {}, {}, {}
	local function Info(i)
		if mHidden[i] == nil then
			local m = mine[i]
			mHidden[i] = Chat.Hidden(m.m)
			mPlain[i] = mHidden[i] and "" or Chat.Plain(m.m)
			mFirst[i] = First(m.a)
		end
	end
	local function Match(e)
		local hidden, plain, first = Chat.Hidden(e.m), nil, nil
		for i, m in ipairs(mine) do
			if not used[i] and m.k == "msg" then
				local d = math.abs((m.t or 0) - e.t)
				if d <= Chat.SAME_WINDOW or d <= Chat.HIDDEN_WINDOW then
					Info(i)
					if hidden or mHidden[i] then
						first = first or First(e.a)
						if d <= Chat.HIDDEN_WINDOW and first ~= "" and mFirst[i] == first then return i end
					elseif d <= Chat.SAME_WINDOW then
						plain = plain or Chat.Plain(e.m)
						if mPlain[i] == plain then return i end
					end
				end
			end
		end
	end
	local out, replaced = {}, {}
	for _, e in ipairs(server) do
		local i = Match(e)
		if i then
			used[i] = true
			-- A saved line whose hidden text can't draw any more: show the server's copy.
			if mine[i].old then replaced[i] = e end
		else
			out[#out + 1] = e
		end
	end
	for i, e in ipairs(mine) do
		if replaced[i] then out[#out + 1] = replaced[i]
		elseif not e.old then out[#out + 1] = e end -- old hidden lines the server no longer has are dropped
	end
	table.sort(out, function(a, b) return a.t < b.t end)
	while #out > Chat.MAX_LINES do table.remove(out, 1) end
	return out
end

local redrawSoon = ns.Coalesce(function() if Chat.Visible() then Chat.Redraw() end end, 0.3)
pcall(ns.On, "CLUB_MESSAGE_HISTORY_RECEIVED", function()
	Chat.ReadServer()
	redrawSoon()
end)

function Chat:OnLogin()
	ns.After(10, Chat.RequestServer)
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------
function Chat.CanOfficer()
	if ns.Roster.IsOfficer(ns.PlayerName()) then return true end
	return #Chat.View("officer") > 0
end

function Chat.Visible()
	return Chat.panel ~= nil and Chat.panel.IsVisible ~= nil and Chat.panel:IsVisible() and true or false
end

-- Unread: what guildmates said. Not online/offline lines, the message of the day or your own.
function Chat.CountsAsUnread(kind, author)
	if kind ~= "msg" then return false end
	local who = author and ns.Roster.ParseName(author)
	return not (who and ns.FullName(who) == ns.PlayerName())
end

-- On the Chat tab ("Chat (3)") and the minimap button.
function Chat.UpdateBadge()
	for _, g in ipairs(ns.UI.tabs or {}) do
		if g.title == "Chat" and g.button then
			g.button:SetText(Chat.unread > 0 and ("Chat (" .. math.min(Chat.unread, 99) .. ")") or "Chat")
		end
	end
	if ns.UI.SetMinimapBadge then ns.UI.SetMinimapBadge(Chat.unread) end
end

function Chat.Redraw()
	local box = Chat.messages
	if not box then return end
	box:Clear()
	if Chat.channel == "guild" then
		local motd = Chat.MOTD()
		if motd then
			local r, g, b = Chat.ChannelColor("guild")
			box:AddMessage("|cff" .. Hex(r, g, b) .. "Message of the day: " .. motd .. "|r")
		end
	end
	local lines = Chat.View(Chat.channel)
	for _, e in ipairs(lines) do box:AddMessage(Chat.Format(Chat.channel, e)) end
	box:ScrollToBottom()
	Chat.unseen = 0
	Chat.UpdateJump()
	if Chat.hint then Chat.hint:SetShown(#lines == 0) end
end

-- Scrolled up: a "Newest" button, with how many lines came in since, takes you back down.
Chat.unseen = 0
function Chat.ScrolledUp()
	local box = Chat.messages
	local offset = box and box.GetScrollOffset and box:GetScrollOffset()
	return type(offset) == "number" and offset > 0
end

function Chat.UpdateJump()
	local b = Chat.jump
	if not b then return end
	if Chat.ScrolledUp() then
		b:SetText(Chat.unseen > 0 and string.format("Newest (%d new)", math.min(Chat.unseen, 999)) or "Newest")
		b:Show()
	else
		Chat.unseen = 0
		b:Hide()
	end
end

function Chat.JumpToNewest()
	if Chat.messages then Chat.messages:ScrollToBottom() end
	Chat.unseen = 0
	Chat.UpdateJump()
end

function Chat.SetChannel(channel)
	if channel == "officer" and not Chat.CanOfficer() then channel = "guild" end
	Chat.channel = channel
	for ch, b in pairs(Chat.channelButtons or {}) do ns.UI.SetSelected(b, ch == channel) end
	if Chat.input and Chat.input.hint then
		Chat.input.hint:SetText(channel == "officer" and "Type to officers, Enter to send" or "Type to the guild, Enter to send")
	end
	Chat.Redraw()
end

---------------------------------------------------------------------------
-- Who's online, by rank, beside the chat (offline members are left out)
---------------------------------------------------------------------------
Chat.ONLINE_WIDTH = 150
Chat.ONLINE_ROW = 14

-- { {rank = "Guild Master", count = 1}, {key = "Large Joseph", m = member}, ... } with ranks in
-- guild order (Guild Master first) and names A to Z within each rank.
function Chat.OnlineRows()
	local byRank, order = {}, {}
	local total = 0
	for key, m in pairs(ns.Roster.members or {}) do
		if m.online then
			local r = m.rankIndex or 99
			if not byRank[r] then
				byRank[r] = { name = m.rank or ("Rank " .. (r + 1)), list = {} }
				order[#order + 1] = r
			end
			table.insert(byRank[r].list, key)
			total = total + 1
		end
	end
	table.sort(order)
	local rows = {}
	for _, r in ipairs(order) do
		local g = byRank[r]
		table.sort(g.list, function(a, b) return ns.Roster.DisplayName(a) < ns.Roster.DisplayName(b) end)
		rows[#rows + 1] = { rank = g.name, count = #g.list }
		for _, key in ipairs(g.list) do rows[#rows + 1] = { key = key, m = ns.Roster.members[key] } end
	end
	return rows, total
end

function Chat.BuildOnline(panel)
	local UI = ns.UI
	local f = CreateFrame("Frame", nil, panel)
	f:SetPoint("TOPRIGHT", 0, -30)
	f:SetPoint("BOTTOMRIGHT", 0, 34)
	f:SetWidth(Chat.ONLINE_WIDTH)
	UI.Skin(f, UI.COLORS.input, UI.COLORS.dim)
	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	title:SetPoint("TOPLEFT", 8, -6)
	title:SetText("Online")
	f.title = title
	f.rows, f.offset = {}, 0
	f:EnableMouseWheel(true)
	f:SetScript("OnMouseWheel", function(self, delta)
		self.offset = math.max(0, self.offset - delta * 3)
		Chat.DrawOnline()
	end)
	f:SetScript("OnSizeChanged", function() Chat.DrawOnline() end)
	Chat.online = f
end

local function OnlineRow(f, i)
	local row = f.rows[i]
	if row then return row end
	row = CreateFrame("Button", nil, f)
	row:SetHeight(Chat.ONLINE_ROW)
	row:SetPoint("TOPLEFT", 4, -22 - (i - 1) * Chat.ONLINE_ROW)
	row:SetPoint("TOPRIGHT", -4, -22 - (i - 1) * Chat.ONLINE_ROW)
	local hl = ns.UI.Fill(row:CreateTexture(nil, "HIGHLIGHT"), ns.UI.COLORS.hover)
	hl:SetAllPoints()
	row.hl = hl
	local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("LEFT", 4, 0)
	text:SetPoint("RIGHT", -2, 0)
	text:SetJustifyH("LEFT")
	text:SetWordWrap(false)
	row.text = text
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	-- Left-click whispers, right-click invites, like the roster page.
	row:SetScript("OnClick", function(self, button)
		if not self.key then return end
		if button == "RightButton" then ns.UI.Invite(self.key) else ns.UI.Whisper(self.key) end
	end)
	row:SetScript("OnEnter", function(self)
		local m = self.key and ns.Roster.members[self.key]
		if not m then return end
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(ns.Roster.DisplayName(self.key), ns.UI.ClassColor(m.classFile))
		GameTooltip:AddLine(string.format("Level %s %s", tostring(m.level or "?"), m.class or ""), 1, 1, 1)
		if m.zone and m.zone ~= "" then GameTooltip:AddLine(m.zone, 0.8, 0.8, 0.8) end
		GameTooltip:AddLine("Click to whisper, right-click to invite", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.rows[i] = row
	return row
end

function Chat.DrawOnline()
	local f = Chat.online
	if not f then return end
	local rows, total = Chat.OnlineRows()
	f.title:SetText("Online (" .. total .. ")")
	local h = f.GetHeight and f:GetHeight() or 0
	local fit = (h and h > 40) and math.floor((h - 26) / Chat.ONLINE_ROW) or 24
	f.offset = math.min(f.offset, math.max(0, #rows - fit))
	for i = 1, math.max(fit, #f.rows) do
		local data = i <= fit and rows[i + f.offset] or nil
		local row = (data or f.rows[i]) and OnlineRow(f, i)
		if row then
			row.key = data and data.key or nil
			if not data then
				row:Hide()
			elseif data.rank then
				row.text:SetText(data.rank .. " (" .. data.count .. ")")
				row.text:SetTextColor(ns.UI.COLORS.gold[1], ns.UI.COLORS.gold[2], ns.UI.COLORS.gold[3])
				row.text:SetPoint("LEFT", 4, 0)
				row.hl:Hide()
				row:Show()
			else
				row.text:SetText(ns.Roster.DisplayName(data.key))
				row.text:SetTextColor(ns.UI.ClassColor(data.m and data.m.classFile))
				row.text:SetPoint("LEFT", 12, 0)
				row.hl:Show()
				row:Show()
			end
		end
	end
	if ns.UI.ThemeTree then ns.UI.ThemeTree(f) end
	return rows
end

local drawOnlineSoon = ns.Coalesce(function() if Chat.Visible() then Chat.DrawOnline() end end)
function Chat.DrawOnlineSoon() drawOnlineSoon() end
ns.Listen("ROSTER_UPDATED", Chat.DrawOnlineSoon)

local function Build(panel)
	Chat.panel = panel
	local UI = ns.UI
	local guild = UI.Button(panel, "Guild", 80, 22)
	guild:SetPoint("TOPLEFT", 0, 0)
	guild:SetScript("OnClick", function() Chat.SetChannel("guild") end)
	local officer = UI.Button(panel, "Officer", 80, 22)
	officer:SetPoint("LEFT", guild, "RIGHT", 4, 0)
	officer:SetScript("OnClick", function() Chat.SetChannel("officer") end)
	Chat.channelButtons = { guild = guild, officer = officer }

	local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("RIGHT", panel, "TOPRIGHT", -4, -11)
	note:SetText("Shift-click items to link them")

	local frame = CreateFrame("Frame", nil, panel)
	frame:SetPoint("TOPLEFT", 0, -30)
	frame:SetPoint("BOTTOMRIGHT", -(Chat.ONLINE_WIDTH + 6), 34)
	UI.Skin(frame, UI.COLORS.input, UI.COLORS.dim)
	Chat.BuildOnline(panel)

	local box = CreateFrame("ScrollingMessageFrame", nil, frame)
	box:SetPoint("TOPLEFT", 8, -6)
	box:SetPoint("BOTTOMRIGHT", -8, 6)
	box:SetFontObject(_G.ChatFontNormal or "ChatFontNormal")
	UI.PlainFont(box)
	box:SetJustifyH("LEFT")
	box:SetMaxLines(Chat.MAX_LINES + 20)
	box:SetFading(false)
	if box.SetIndentedWordWrap then box:SetIndentedWordWrap(true) end
	if box.SetHyperlinksEnabled then box:SetHyperlinksEnabled(true) end
	box:EnableMouseWheel(true)
	box:SetScript("OnMouseWheel", function(self, delta)
		if IsShiftKeyDown and IsShiftKeyDown() then
			if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
		elseif delta > 0 then self:ScrollUp() else self:ScrollDown() end
		Chat.UpdateJump()
	end)
	-- Item, spell and player links work as in the game's chat (player: left-click whispers,
	-- right-click opens the usual menu).
	box:SetScript("OnHyperlinkClick", function(self, link, text, button)
		if SetItemRef then SetItemRef(link, text, button, self) end
	end)
	box:SetScript("OnHyperlinkEnter", function(self, link)
		local kind = tostring(link):match("^(%a+):")
		if kind == "item" or kind == "spell" or kind == "enchant" then
			GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
			pcall(GameTooltip.SetHyperlink, GameTooltip, link)
			GameTooltip:Show()
		end
	end)
	box:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
	Chat.messages = box

	local jump = UI.Button(frame, "Newest", 130, 20, "primary")
	jump:SetPoint("BOTTOMRIGHT", -10, 8)
	jump:SetFrameLevel((box.GetFrameLevel and box:GetFrameLevel() or 1) + 5)
	jump:SetScript("OnClick", Chat.JumpToNewest)
	jump:Hide()
	Chat.jump = jump

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	hint:SetPoint("CENTER")
	hint:SetText("No messages yet. New guild chat shows up here.")
	Chat.hint = hint

	local input = UI.CreateInput(panel, 300, "Type to the guild, Enter to send")
	input:ClearAllPoints()
	input:SetPoint("BOTTOMLEFT", 0, 0)
	input:SetPoint("BOTTOMRIGHT", -84, 0)
	input:SetHeight(26)
	input:SetMaxLetters(255)
	if input.SetAltArrowKeyMode then input:SetAltArrowKeyMode(false) end
	-- Enter sends and keeps the box open for the next line, like the game's chat.
	input:SetScript("OnEnterPressed", function(self)
		local text = self:GetText() or ""
		if text ~= "" then
			Chat.Send(text)
			self:SetText("")
		end
		Chat.recall = nil
	end)
	input:SetScript("OnArrowPressed", function(self, key)
		local n = #Chat.sent
		if n == 0 then return end
		if key == "UP" then Chat.recall = math.max(1, (Chat.recall or n + 1) - 1)
		elseif key == "DOWN" then Chat.recall = Chat.recall and Chat.recall + 1 or nil
		else return end
		if Chat.recall and Chat.recall > n then Chat.recall = nil end
		self:SetText(Chat.recall and Chat.sent[Chat.recall] or "")
		if self.SetCursorPosition then self:SetCursorPosition(#(self:GetText() or "")) end
	end)
	Chat.input = input

	local send = UI.Button(panel, "Send", 80, 26, "primary")
	send:SetPoint("BOTTOMRIGHT", 0, 0)
	send:SetScript("OnClick", function()
		local text = input:GetText() or ""
		if text ~= "" and Chat.Send(text) then input:SetText("") end
	end)

	panel:SetScript("OnShow", function()
		Chat.RequestServer()
		ns.Roster.Request()
		Chat.DrawOnline()
		officer:SetShown(Chat.CanOfficer())
		Chat.unread = 0
		Chat.UpdateBadge()
		Chat.SetChannel(Chat.channel)
	end)
	Chat.RequestServer()
	officer:SetShown(Chat.CanOfficer())
	Chat.unread = 0
	Chat.UpdateBadge()
	Chat.SetChannel(Chat.channel)
end

ns.UI.AddPage("Chat", "Chat", Build)

-- New lines go straight into the open page.
ns.Listen("CHAT_LINE", function(channel, entry)
	if Chat.messages and channel == Chat.channel then
		Chat.messages:AddMessage(Chat.Format(channel, entry))
		if Chat.hint then Chat.hint:Hide() end
		if Chat.ScrolledUp() then Chat.unseen = Chat.unseen + 1 end
		Chat.UpdateJump()
	end
end)

-- Shift-clicking an item (bags, loot, the auction house...) while our box has focus puts the
-- link in it. A hook after the game's own function: nothing of Blizzard's is replaced.
if hooksecurefunc and ChatEdit_InsertLink then
	hooksecurefunc("ChatEdit_InsertLink", function(link)
		local box = Chat.input
		if box and box.HasFocus and box:HasFocus() and link then box:Insert(link) end
	end)
end

ns.Settings.AddToggle("chatHistory", "Keep guild chat between sessions (this PC)", function(on) Chat.SetHistory(on) end)
ns.Settings.AddToggle("clock24", "24-hour times in chat (off: 2:05pm)", function() Chat.Redraw() end)

ns.RegisterCommand("chat", "open guild chat", function() ns.UI.Open("Chat") end)

