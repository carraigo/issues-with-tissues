-- Guild life > Polls: officers ask a question with a few answers, guildmates vote. One vote
-- per player: alts linked to a main count once (the latest vote wins).
--
-- "polls" (officers): key = id, data = "closes;answer1~answer2~...;question"
-- "votes" (owner):    key = character, data = "id=answer,id=answer" (polls still listed only;
--                     tidied at login, and dropped for characters who left the guild)

local _, ns = ...

local Polls = ns.RegisterModule("Polls", {})
ns.Polls = Polls

ns.Sync.Define("polls", { writer = "officer", max = 40 })
ns.Sync.Define("votes", { writer = "owner" })

Polls.MAX_ANSWERS = 6
Polls.DAYS = { 1, 3, 7 }
Polls.SHOW_CLOSED = 7 * 86400 -- closed polls stay listed this long

local function Clean(text, max) return ns.CleanText(text, max, "~=,") end

-- Poll record: "closes;answer~answer~...;question"
function Polls.Encode(p)
	return string.format("%d;%s;%s", p.closes, table.concat(p.answers, "~"), Clean(p.question, 100))
end

function Polls.Decode(data)
	local closes, answers, question = ns.Record.Fields(data, 3)
	closes = tonumber(closes)
	if not closes then return nil end
	local list = {}
	for a in answers:gmatch("[^~]+") do list[#list + 1] = a end
	return { closes = closes, answers = list, question = question }
end

-- Votes record: "pollId=answer,..." (sorted)
function Polls.EncodeVotes(votes)
	local parts = {}
	for id, n in pairs(votes) do parts[#parts + 1] = id .. "=" .. n end
	table.sort(parts)
	return table.concat(parts, ",")
end

function Polls.DecodeVotes(data)
	local out = {}
	for id, n in tostring(data or ""):gmatch("(%d+)=(%d+)") do out[id] = tonumber(n) end
	return out
end

ns.Record.Define("polls", { encode = Polls.Encode, decode = Polls.Decode,
	sample = { closes = 1795000000, answers = { "Yes", "No", "Maybe" }, question = "Raid on Friday?" } })
ns.Record.Define("votes", { encode = Polls.EncodeVotes, decode = Polls.DecodeVotes,
	sample = { ["1795000000"] = 2, ["1795000123"] = 1 } })

-- Officers: ask. answers is "Yes, No, Maybe" (commas or slashes between answers).
function Polls.Ask(question, answers, days)
	question = Clean(question, 100)
	local list = {}
	for a in tostring(answers or ""):gmatch("[^,/]+") do
		a = Clean(a, 30)
		if a ~= "" and #list < Polls.MAX_ANSWERS then list[#list + 1] = a end
	end
	if question == "" then return false, "Write a question first." end
	if #list == 0 then list = { "Yes", "No" } end
	if #list == 1 then return false, "Give at least two answers." end
	local id = tostring(ns.Now())
	while ns.Sync.Get("polls", id) do id = tostring(tonumber(id) + 1) end
	local closes = ns.Now() + (days or 3) * 86400
	return ns.Sync.Set("polls", id, Polls.Encode({ closes = closes, answers = list, question = question }))
end

-- Officers: close now (results stay) or remove.
function Polls.Close(id)
	local p = Polls.Decode(ns.Sync.Get("polls", id))
	if not p then return false end
	p.closes = ns.Now() - 1
	return ns.Sync.Set("polls", id, Polls.Encode(p))
end
function Polls.Remove(id) return ns.Sync.Delete("polls", id) end

local function MyVotes(who)
	return Polls.DecodeVotes(ns.Sync.Get("votes", who))
end
Polls.VotesOf = MyVotes

function Polls.Vote(id, answer)
	local p = Polls.Decode(ns.Sync.Get("polls", id))
	if not p or p.closes <= ns.Now() or not p.answers[answer] then return false end
	local mine, keep = MyVotes(ns.PlayerName()), {}
	mine[id] = answer
	for pid, n in pairs(mine) do
		local q = Polls.Decode(ns.Sync.Get("polls", pid))
		-- keep votes on recently closed polls: their results are still shown
		if q and q.closes + Polls.SHOW_CLOSED > ns.Now() then keep[pid] = n end
	end
	return ns.Sync.Set("votes", ns.PlayerName(), Polls.EncodeVotes(keep))
end

-- Our own votes record keeps only polls still listed (open, or closed under a week ago); once
-- none are left it is deleted. Run at login, so old votes don't stay in everyone's data.
function Polls.TidyMyVotes()
	local me = ns.PlayerName()
	local data = ns.Sync.Get("votes", me)
	if not data then return false end
	local keep = {}
	for id, n in pairs(Polls.DecodeVotes(data)) do
		local p = Polls.Decode(ns.Sync.Get("polls", id))
		if p and p.closes + Polls.SHOW_CLOSED > ns.Now() then keep[id] = n end
	end
	local tidy = Polls.EncodeVotes(keep)
	if tidy == data then return false end
	if tidy == "" then return ns.Sync.Delete("votes", me) end
	return ns.Sync.Set("votes", me, tidy)
end

-- Counts per answer for poll id, one per player (main), the newest vote winning.
function Polls.Results(id)
	local p = Polls.Decode(ns.Sync.Get("polls", id))
	if not p then return nil end
	local byPlayer = {}
	for who, data, rec in ns.Sync.Each("votes") do
		local n = tonumber(tostring(data):match("%f[%d]" .. id .. "=(%d+)"))
		if n and p.answers[n] and ns.Roster.IsMember(who) then
			local main = ns.Alts.MainOf(who)
			local cur = byPlayer[main]
			if not cur or rec.rev > cur.rev then byPlayer[main] = { n = n, rev = rec.rev } end
		end
	end
	local counts, total = {}, 0
	for i = 1, #p.answers do counts[i] = 0 end
	for _, v in pairs(byPlayer) do counts[v.n] = counts[v.n] + 1; total = total + 1 end
	return counts, total
end

-- Polls to show: open first (closing soonest), then recently closed.
function Polls.List()
	local now, out = ns.Now(), {}
	for id, data, rec in ns.Sync.Each("polls") do
		local p = Polls.Decode(data)
		if p and p.closes > now - Polls.SHOW_CLOSED then
			p.id, p.open, p.by = id, p.closes > now, rec.by
			p.counts, p.total = Polls.Results(id)
			p.mine = MyVotes(ns.PlayerName())[id]
			out[#out + 1] = p
		end
	end
	table.sort(out, function(a, b)
		if a.open ~= b.open then return a.open end
		if a.open then return a.closes < b.closes end
		return a.closes > b.closes
	end)
	return out
end

function Polls.OpenCount()
	local n, first = 0, nil
	for _, p in ipairs(Polls.List()) do
		if p.open then n = n + 1; first = first or p end
	end
	return n, first
end

-- Tell the player about a new poll.
ns.Listen("SYNC_CHANGED", function(set, key, rec)
	if set ~= "polls" or not rec or rec.deleted or rec.by == ns.PlayerName() then return end
	local p = Polls.Decode(rec.data)
	Polls.seen = Polls.seen or {}
	if p and p.closes > ns.Now() and not Polls.seen[key] then
		Polls.seen[key] = true
		ns.Print("New guild poll: %s (open /iwt, Guild life)", p.question)
	end
end)

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------
local list, officerRow, questionBox, answersBox, daysButton, answerButtons, detail, closeButton, removeButton
Polls.form = { days = 2 }

local function Left(p)
	if not p.open then return "closed" end
	local s = p.closes - ns.Now()
	if s >= 86400 then return math.floor(s / 86400) .. "d left" end
	return ns.UI.Ago(s) .. " left"
end

function Polls.Refresh()
	if not Polls.panel or not Polls.panel:IsShown() then return end
	local officer = ns.Roster.IsOfficer(ns.PlayerName())
	officerRow:SetShown(officer)
	daysButton:SetText(Polls.DAYS[Polls.form.days] .. (Polls.DAYS[Polls.form.days] == 1 and " day" or " days"))
	local polls = Polls.List()
	local sel
	for _, p in ipairs(polls) do if p.id == Polls.selected then sel = p end end
	sel = sel or polls[1]
	Polls.selected = sel and sel.id
	list:SetRows(polls, function(p, key)
		local gold = p == sel
		local r, g, b = 1, 1, 1
		if gold then r, g, b = 0.96, 0.82, 0.48 elseif not p.open then r, g, b = 0.6, 0.6, 0.6 end
		if key == "question" then return p.question, r, g, b end
		if key == "votes" then return tostring(p.total), r, g, b end
		if key == "left" then return Left(p), r, g, b end
		if key == "mine" then return p.mine and p.answers[p.mine] or (p.open and "not voted" or ""), r, g, b end
	end)
	for i, b in ipairs(answerButtons) do
		local a = sel and sel.answers[i]
		b:SetShown(a ~= nil)
		if a then
			b:SetText(a .. "  (" .. sel.counts[i] .. ")")
			ns.UI.SetSelected(b, sel.mine == i)
			if sel.open then b:Enable() else b:Disable() end
		end
	end
	if not sel then
		detail:SetText("No polls yet." .. (officer and "" or " Officers can ask the guild a question here."))
	else
		detail:SetText(sel.question .. "  |cff999999" .. (sel.open and "Click an answer to vote (you can change it)."
			or "This poll is closed.") .. "|r")
	end
	closeButton:SetShown(officer and sel ~= nil and sel.open)
	removeButton:SetShown(officer and sel ~= nil)
end

local function Build(panel)
	Polls.panel = panel
	officerRow = CreateFrame("Frame", nil, panel)
	officerRow:SetPoint("TOPLEFT", 0, 0)
	officerRow:SetSize(616, 24)
	questionBox = ns.UI.CreateInput(officerRow, 250, "Question")
	questionBox:SetPoint("TOPLEFT", 4, 0)
	answersBox = ns.UI.CreateInput(officerRow, 170, "Answers: Yes, No")
	answersBox:SetPoint("LEFT", questionBox, "RIGHT", 6, 0)
	daysButton = ns.UI.Button(officerRow, nil, 70, 22)
	daysButton:SetPoint("LEFT", answersBox, "RIGHT", 6, 0)
	daysButton:SetScript("OnClick", function()
		Polls.form.days = Polls.form.days % #Polls.DAYS + 1
		Polls.Refresh()
	end)
	local ask = ns.UI.Button(officerRow, "Ask", 90, 22, "primary")
	ask:SetPoint("LEFT", daysButton, "RIGHT", 6, 0)
	ask:SetScript("OnClick", function()
		local ok, why = Polls.Ask(questionBox:GetText(), answersBox:GetText(), Polls.DAYS[Polls.form.days])
		if ok then
			questionBox:SetText(""); answersBox:SetText("")
		elseif why then
			ns.Print(why)
		end
		Polls.Refresh()
	end)

	list = ns.UI.CreateList(panel, {
		top = -34, rows = 9,
		columns = {
			{ key = "question", label = "Poll", width = 330 },
			{ key = "votes", label = "Votes", width = 60 },
			{ key = "left", label = "Closes", width = 80 },
			{ key = "mine", label = "Your vote", width = 130 },
		},
		onClick = function(p) Polls.selected = p.id; Polls.Refresh() end,
	})

	detail = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	detail:SetPoint("TOPLEFT", 4, -228)
	detail:SetWidth(600)
	detail:SetJustifyH("LEFT")
	answerButtons = {}
	for i = 1, Polls.MAX_ANSWERS do
		local b = ns.UI.Button(panel, nil, 196, 26)
		b:SetPoint("TOPLEFT", 4 + ((i - 1) % 3) * 202, -252 - math.floor((i - 1) / 3) * 32)
		b:SetScript("OnClick", function()
			if Polls.selected then Polls.Vote(Polls.selected, i) end
			Polls.Refresh()
		end)
		answerButtons[i] = b
	end
	closeButton = ns.UI.Button(panel, "Close poll", 100, 22)
	closeButton:SetPoint("TOPLEFT", 4, -326)
	closeButton:SetScript("OnClick", function() if Polls.selected then Polls.Close(Polls.selected) end Polls.Refresh() end)
	removeButton = ns.UI.Button(panel, "Remove", 90, 22)
	removeButton:SetPoint("LEFT", closeButton, "RIGHT", 6, 0)
	removeButton:SetScript("OnClick", function()
		if Polls.selected then Polls.Remove(Polls.selected); Polls.selected = nil end
		Polls.Refresh()
	end)
	panel:SetScript("OnShow", Polls.Refresh)
	Polls.Refresh()
end

ns.UI.AddPage("Guild life", "Polls", Build, { order = 20 })
Polls.RefreshSoon = ns.Coalesce(function() Polls.Refresh() end)

ns.Listen("SYNC_CHANGED", function(set)
	if set == "polls" or set == "votes" then Polls.RefreshSoon(); ns.Send("GUILD_LIFE_CHANGED") end
end)

function Polls:OnLogin()
	ns.Later("tidyVotes", Polls.TidyMyVotes) -- after the catch-up has brought the polls
end
