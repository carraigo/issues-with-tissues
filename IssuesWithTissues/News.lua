-- Guild news for Home: who joined, left, reached level 60 or was promoted this week. Worked
-- out on this PC from changes in the guild roster, including changes while you were offline,
-- so nothing is shared and nothing extra is sent. Officers also get a nudge in chat when
-- someone joins, to say hi.

local _, ns = ...

local News = ns.RegisterModule("News", {})
ns.News = News

News.KEEP = 7 * 86400   -- a week
News.MAX = 40
News.MAX_LEVEL = 60
News.PARTIAL = 0.75     -- a roster smaller than this share of the last one is still loading

local function DB()
	ns.db.news = ns.db.news or {}
	return ns.db.news
end

-- Newest first, the last week only.
function News.List()
	local now, out = ns.Now(), {}
	for _, e in ipairs(DB()) do
		if now - e.t <= News.KEEP then out[#out + 1] = e end
	end
	return out
end

-- One line of news; the same thing about the same person within a day is kept once.
function News.Add(kind, who, text)
	local list, now = DB(), ns.Now()
	for _, e in ipairs(list) do
		if e.kind == kind and e.who == who and now - e.t < 86400 then return false end
	end
	table.insert(list, 1, { t = now, kind = kind, who = who, text = text })
	for i = #list, 1, -1 do
		if i > News.MAX or now - list[i].t > News.KEEP then table.remove(list, i) end
	end
	ns.Send("NEWS_CHANGED")
	return true
end

-- What changed between two rosters ({ [name] = { r = rankIndex, l = level, rank = name } }).
function News.Diff(old, new)
	local out = {}
	for name, m in pairs(new) do
		local o = old[name]
		if not o then
			out[#out + 1] = { "join", name, " joined the guild" }
		else
			if (o.l or 0) < News.MAX_LEVEL and (m.l or 0) >= News.MAX_LEVEL then
				out[#out + 1] = { "60", name, " reached level " .. News.MAX_LEVEL }
			end
			if o.r and m.r and m.r < o.r then
				out[#out + 1] = { "promote", name, " was promoted to " .. (m.rank or ("rank " .. (m.r + 1))) }
			end
		end
	end
	for name in pairs(old) do
		if not new[name] then out[#out + 1] = { "leave", name, " left the guild" } end
	end
	table.sort(out, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
	return out
end

local function Count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

function News.OnRoster()
	if not ns.Roster.count or ns.Roster.count == 0 then return end
	local cur = {}
	for name, m in pairs(ns.Roster.members) do cur[name] = { r = m.rankIndex, l = m.level, rank = m.rank } end
	local old = ns.db.newsRoster
	if old then
		if Count(cur) < Count(old) * News.PARTIAL then return end -- still loading: wait
		for _, e in ipairs(News.Diff(old, cur)) do
			News.Add(e[1], e[2], ns.Roster.DisplayName(e[2]) .. e[3])
		end
	end
	ns.db.newsRoster = cur
end
ns.Listen("ROSTER_UPDATED", News.OnRoster)

-- "Sara Exe has joined the guild." Officers get a nudge to say hi.
local function Pattern(fmt)
	if type(fmt) ~= "string" then return nil end
	local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.-)")
	return "^" .. p .. "$"
end

function News.Joined(text)
	text = ns.Readable(text)
	if not text then return nil end
	local p = Pattern(ERR_GUILD_JOIN_S or "%s has joined the guild.")
	local who = p and text:match(p)
	if not who or who == "" then return nil end
	who = who:gsub("|H.-|h%[?(.-)%]?|h", "%1") -- a player link, when the game sends one
	return who
end

function News.Nudge(who)
	local me = ns.Roster.me
	if not me or not ns.Roster.IsOfficer(me) then return false end
	ns.Print("|cff40ff40%s just joined the guild. Say hi!|r", who)
	if ns.db.settings.sounds and PlaySound then
		pcall(PlaySound, (SOUNDKIT and SOUNDKIT.TELL_MESSAGE) or 3081)
	end
	return true
end

pcall(ns.On, "CHAT_MSG_SYSTEM", function(_, text)
	local who = News.Joined(text)
	if not who then return end
	News.Nudge(who)
	ns.Roster.Request() -- the roster change adds the news line
end)

-- Home's three lines, newest first, and the rest for its tooltip.
function News.Lines(max)
	local list, out = News.List(), {}
	for i = 1, math.min(#list, max or #list) do out[i] = list[i].text end
	return out, #list
end

function News:OnLogin()
	DB()
end
