-- Guild news: who joined, left, reached level 60 or was promoted; the week's Tissue Issuer
-- (Kills.lua) and wishes that came true (Wishlist.lua). Home shows this week in short;
-- Home > Guild news lists the last month. Worked
-- out on this PC from changes in the guild roster, including changes while you were offline,
-- so nothing is shared and nothing extra is sent. Officers also get a nudge in chat when
-- someone joins, to say hi.

local _, ns = ...

local News = ns.RegisterModule("News", {})
ns.News = News

News.WEEK = 7 * 86400   -- Home shows this long
News.KEEP = 30 * 86400  -- kept, for the Guild news page
News.MAX = 200
News.MAX_LEVEL = 60
News.PARTIAL = 0.75     -- a roster smaller than this share of the last one is still loading

local function DB()
	ns.db.news = ns.db.news or {}
	return ns.db.news
end

-- Newest first, the last week (or `keep` seconds).
function News.List(keep)
	local now, out = ns.Now(), {}
	keep = keep or News.WEEK
	for _, e in ipairs(DB()) do
		if now - e.t <= keep then out[#out + 1] = e end
	end
	return out
end

-- A news line short enough for Home's column: "Bo Finch hit 60".
News.SHORT = { join = "joined", leave = "left", ["60"] = "hit " .. 60, promote = "promoted" }
function News.Short(e)
	if e.kind == "week" and e.who and e.gain then
		return string.format("%s won the week with %s kills", ns.Roster.DisplayName(e.who), ns.Kills.Format(e.gain))
	end
	if e.kind == "got" and e.who and e.item then
		local name = ns.Wishlist and ns.Wishlist.Name(e.item)
		return ns.Roster.DisplayName(e.who) .. " got " .. (name or "a wish") .. "!"
	end
	local what = News.SHORT[e.kind]
	if not what or not e.who then return News.Text(e) end
	return ns.Roster.DisplayName(e.who) .. " " .. what
end

-- The full line. A wishlist line ("got") names its item when shown, as the game may only
-- know the item's name later.
function News.Text(e)
	if e.kind == "got" and e.item then
		local name = ns.Wishlist and ns.Wishlist.Name(e.item) or ("an item from their wishlist")
		return string.format("%s got %s from their wishlist", e.who and ns.Roster.DisplayName(e.who) or "Someone", name or "an item")
	end
	return e.text or ""
end

-- One line of news; the same thing about the same person (and item) within a day is kept once.
-- `extra` adds fields: item (an item id, for "got"), gain (kills, for "week").
function News.Add(kind, who, text, extra)
	local list, now = DB(), ns.Now()
	local item = extra and extra.item
	for _, e in ipairs(list) do
		if e.kind == kind and e.who == who and e.item == item and now - e.t < 86400 then return false end
	end
	local e = { t = now, kind = kind, who = who, text = text }
	for k, v in pairs(extra or {}) do e[k] = v end
	table.insert(list, 1, e)
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

-- Home's lines, newest first and short (the full text is on the Guild news page).
function News.Lines(max)
	local list, out = News.List(), {}
	for i = 1, math.min(#list, max or #list) do out[i] = News.Short(list[i]) end
	return out, #list
end

---------------------------------------------------------------------------
-- Home > Guild news: the last month, newest first.
---------------------------------------------------------------------------
News.KINDS = { join = "Joined", leave = "Left", ["60"] = "Level 60", promote = "Promoted", week = "Kills", got = "Wish" }
News.KIND_COLOR = { join = { 0.25, 1, 0.25 }, leave = { 1, 0.45, 0.35 }, ["60"] = { 1, 0.82, 0 }, promote = { 0.45, 0.7, 1 },
	week = { 1, 0.56, 0.31 }, got = { 0.9, 0.6, 1 } }
News.FILTERS = { { key = "all", label = "All" } }
for _, k in ipairs({ "join", "leave", "60", "promote", "week", "got" }) do
	table.insert(News.FILTERS, { key = k, label = News.KINDS[k], test = function(r) return r.kind == k end })
end

-- "Today 14:05", "Yesterday 09:30", "Mon 21:12", "3 Nov"
function News.When(t, now)
	now = now or ns.Now()
	local day = date("%Y%m%d", t)
	if day == date("%Y%m%d", now) then return "Today " .. date("%H:%M", t) end
	if day == date("%Y%m%d", now - 86400) then return "Yesterday " .. date("%H:%M", t) end
	if now - t < 6 * 86400 then return date("%a %H:%M", t) end
	return (date("%d %b", t):gsub("^0", ""))
end

local list
function News.Refresh()
	if not News.panel or not News.panel:IsShown() then return end
	local rows, now = {}, ns.Now()
	for _, e in ipairs(News.List(News.KEEP)) do
		rows[#rows + 1] = { t = e.t, kind = e.kind, who = e.who, text = News.Text(e),
			name = e.who and ns.Roster.DisplayName(e.who) or "" }
	end
	list:SetRows(rows, function(row, key)
		if key == "t" then return News.When(row.t, now), 0.72, 0.69, 0.63 end
		if key == "kind" then
			local c = News.KIND_COLOR[row.kind] or { 1, 1, 1 }
			return News.KINDS[row.kind] or row.kind, c[1], c[2], c[3]
		end
		if key == "text" then return row.text, 1, 1, 1 end
	end)
end

local function Build(panel)
	News.panel = panel
	list = ns.UI.CreateList(panel, {
		top = -30, rows = 19, filters = News.FILTERS, filterWidth = 80, save = "news",
		state = { sort = "t", desc = true },
		columns = {
			{ key = "t", label = "When", width = 110, sort = true, desc = true },
			{ key = "kind", label = "What", width = 90, sort = true },
			{ key = "text", label = "", width = 406 },
		},
		search = { width = 136, hint = "Search names", text = function(r) return r.name end,
			onEnter = function(first) if first.who then ns.UI.Whisper(first.who) end end },
		count = function(shown, all)
			return string.format("%d of %d in the last 30 days. Worked out from the roster on this PC.", #shown, #all)
		end,
		onClick = function(row) if row.who and row.kind ~= "leave" then ns.UI.Whisper(row.who) end end,
	})
	list:SetEmpty("No guild news in the last month. Joins, leavers, level 60s and promotions show up here.")
	panel:SetScript("OnShow", News.Refresh)
	News.list = list
	News.Refresh()
end
ns.UI.AddPage("Home", "Guild news", Build, { order = 30 })
ns.Listen("NEWS_CHANGED", function() News.Refresh() end)

function News:OnLogin()
	DB()
end
