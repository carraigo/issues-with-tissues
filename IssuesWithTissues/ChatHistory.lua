-- Chat (2 of 4): the history the game's server keeps for the guild window, read through C_Club,
-- and merged with the lines this PC kept, without duplicates.

local _, ns = ...

local Chat = ns.Chat

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
	ns.Later("chatHistory", Chat.RequestServer)
end
