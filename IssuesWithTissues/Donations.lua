-- Guild life > Donations: a goal set by officers (first one: the guild bank) and how much each
-- guildmate has given towards it. Gold put into the guild bank is noted automatically.
--
-- "dgoal" (officers): key "goal" = "id;target;title;owner". Saving keeps the id; a new goal gets
--   a new id, which starts everyone's total from zero. The owner is the officer who set the goal:
--   only they change it. Another officer asks, and the owner's Allow writes the change and hands
--   the goal over. Anyone may change it once the owner has left the guild.
-- "donated" (owner):  key = character, data = "goalId;copper" given towards that goal.

local _, ns = ...

local Don = ns.RegisterModule("Donations", {})
ns.Donations = Don

ns.Sync.Define("dgoal", { writer = "officer" })
ns.Sync.Define("donated", { writer = "owner" })

Don.DEFAULT_TITLE = "Guild bank"

local Clean = ns.CleanText

function Don.Goal()
	local data, rec = ns.Sync.Get("dgoal", "goal")
	local id, target, rest = (data or ""):match("^(%d+);(%d+);(.*)$")
	if not id then return { id = 0, target = 0, title = Don.DEFAULT_TITLE } end
	-- Before 0.6.0 there was no owner field: the officer who wrote it owns it.
	local title, owner = rest:match("^(.*);([^;]*)$")
	if not title then title, owner = rest, nil end
	if not owner or owner == "" then owner = rec and rec.by end
	return { id = tonumber(id), target = tonumber(target), title = title ~= "" and title or Don.DEFAULT_TITLE, owner = owner }
end

-- May this character change the goal? Officers only; once set, only its owner (unless they left).
function Don.CanEdit(who)
	who = who or ns.PlayerName()
	if not ns.Roster.IsOfficer(who) then return false, "officers only" end
	local g = Don.Goal()
	if g.id == 0 or not g.owner or g.owner == who or not ns.Roster.IsMember(g.owner) then return true end
	return false, "owned"
end

local function Write(title, targetGold, fresh, owner)
	local g = Don.Goal()
	local id = (fresh or g.id == 0) and ns.Now() or g.id
	local target = math.max(0, math.floor((tonumber(targetGold) or 0) * 10000))
	title = Clean(title, 40)
	if title == "" then title = g.title end
	return ns.Sync.Set("dgoal", "goal", string.format("%d;%d;%s;%s", id, target, title, Clean(owner, 60)))
end

-- Officers: change the goal's title and target (gold). fresh: start a new goal from zero.
-- Someone else's goal: returns false, "owned" (ask them with Don.RequestChange).
function Don.SetGoal(title, targetGold, fresh)
	local ok, why = Don.CanEdit()
	if not ok then return false, why end
	return Write(title, targetGold, fresh, ns.PlayerName())
end

-- Ask the goal's owner to let this change through.
local lastAsked = {} -- requester -> time, so one officer can't flood the owner with popups
function Don.RequestChange(title, targetGold, fresh)
	local g = Don.Goal()
	if not ns.Roster.IsOfficer(ns.PlayerName()) or not g.owner then return false end
	local m = ns.Roster.Get(g.owner)
	local name = ns.Roster.DisplayName(g.owner)
	if not m or not m.online then
		ns.Print("This goal belongs to %s, who is offline. Ask again when they're online.", name)
		return false, "offline"
	end
	Don.asked = { owner = g.owner, at = ns.Now() }
	ns.Comm.Send("DGQ", ns.Comm.Pack(Clean(title, 40), tostring(tonumber(targetGold) or 0), fresh and "1" or ""), "WHISPER", g.owner)
	ns.Print("This goal belongs to %s. Asked them to allow your change.", name)
	return true
end

ns.Comm.Register("DGQ", function(sender, payload)
	local g = Don.Goal()
	if g.owner ~= ns.PlayerName() then return end
	local now = ns.Now()
	if lastAsked[sender] and now - lastAsked[sender] < 30 then return end
	lastAsked[sender] = now
	local title, gold, fresh = ns.Comm.Unpack(payload)
	title = Clean(title, 40)
	Don.request = { from = sender, title = title ~= "" and title or g.title, gold = tonumber(gold) or 0, fresh = fresh == "1" }
	local r = Don.request
	if StaticPopup_Show then
		StaticPopup_Show("IWT_DGOAL", ns.Roster.DisplayName(sender),
			string.format("%s, %d gold%s", r.title, r.gold, r.fresh and ", starting from zero" or ""))
	end
end, "officer")

-- The owner's answer: yes writes the requested goal, now owned by the officer who asked.
function Don.AnswerRequest(yes)
	local r = Don.request
	Don.request = nil
	if not r then return false end
	if yes then Write(r.title, r.gold, r.fresh, r.from) end
	ns.Comm.Send("DGA", yes and "yes" or "no", "WHISPER", r.from)
	return true
end

ns.Comm.Register("DGA", function(sender, payload)
	local a = Don.asked
	if not a or a.owner ~= sender then return end
	Don.asked = nil
	ns.Print(payload == "yes" and "%s allowed your change to the donation goal. It's yours now."
		or "%s kept the donation goal as it is.", ns.Roster.DisplayName(sender))
end, "officer")

if StaticPopupDialogs then
	StaticPopupDialogs.IWT_DGOAL = {
		text = "Issues with Tissues: %s asks to change your donation goal to: %s. Allow it?",
		button1 = "Allow",
		button2 = "Keep mine",
		OnAccept = function() Don.AnswerRequest(true) end,
		OnCancel = function() Don.AnswerRequest(false) end,
		timeout = 120,
		whileDead = true,
		hideOnEscape = true,
	}
end

local function Decode(data)
	local id, copper = tostring(data or ""):match("^(%d+);(%d+)$")
	if id then return tonumber(id), tonumber(copper) end
end

function Don.Mine()
	local id, copper = Decode(ns.Sync.Get("donated", ns.PlayerName()))
	if id and id == Don.Goal().id then return copper end
	return 0
end

-- Note copper given by this character towards the current goal.
function Don.Add(copper)
	copper = math.floor(tonumber(copper) or 0)
	if copper <= 0 then return false end
	local total = Don.Mine() + copper
	local ok = ns.Sync.Set("donated", ns.PlayerName(), string.format("%d;%d", Don.Goal().id, total))
	if ok then ns.Print("Thank you! %s noted towards %s.", ns.UI.Money(copper), Don.Goal().title) end
	return ok
end

-- Givers towards the current goal, most first, and the total.
function Don.Givers()
	local goal, out, total = Don.Goal(), {}, 0
	for who, data in ns.Sync.Each("donated") do
		local id, copper = Decode(data)
		if id == goal.id and copper > 0 and ns.Roster.IsMember(who) then
			out[#out + 1] = { who = who, copper = copper, member = ns.Roster.Get(who) }
			total = total + copper
		end
	end
	table.sort(out, function(a, b) return a.copper > b.copper end)
	return out, total
end

function Don.Progress()
	local goal = Don.Goal()
	local givers, total = Don.Givers()
	return { title = goal.title, target = goal.target, total = total, givers = #givers,
		share = goal.target > 0 and math.min(1, total / goal.target) or nil }
end

function Don.ProgressText(p)
	p = p or Don.Progress()
	if p.target > 0 then
		return string.format("%s of %s (%d%%)", ns.UI.Money(p.total), ns.UI.Money(p.target), math.floor(p.share * 100))
	end
	return ns.UI.Money(p.total) .. " given"
end

-- Gold put into the guild bank by this character.
if hooksecurefunc then
	pcall(hooksecurefunc, "DepositGuildBankMoney", function(copper) Don.Add(copper) end)
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------
local list, titleText, progressText, bar, barFill, officerRow, titleBox, targetBox, note, ownerText

function Don.Refresh()
	if not Don.panel or not Don.panel:IsShown() then return end
	local p = Don.Progress()
	titleText:SetText(p.title)
	progressText:SetText(Don.ProgressText(p) .. "  |cff999999from " .. p.givers .. " guildmates|r")
	barFill:SetWidth(math.max(1, 592 * (p.share or 0)))
	barFill:SetShown((p.share or 0) > 0)
	local mine = Don.Mine()
	note:SetText("Put gold into the guild bank and it is noted here automatically."
		.. (mine > 0 and ("  You have given " .. ns.UI.Money(mine) .. ".") or ""))
	local officer = ns.Roster.IsOfficer(ns.PlayerName())
	officerRow:SetShown(officer)
	local g = Don.Goal()
	if g.owner and g.id > 0 then
		ownerText:SetText("Set by " .. ns.Roster.DisplayName(g.owner)
			.. ((officer and not Don.CanEdit()) and ": saving asks them first" or ""))
	else
		ownerText:SetText("")
	end
	list:SetRows((Don.Givers()), function(r, key)
		if key == "name" then return ns.Roster.DisplayName(r.who), ns.UI.ClassColor(r.member and r.member.classFile) end
		if key == "amount" then return ns.UI.Money(r.copper) end
	end)
end

local function Build(panel)
	Don.panel = panel
	ns.UI.Card(panel, 0, 0, 616, 86)
	titleText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	titleText:SetPoint("TOPLEFT", 12, -10)
	progressText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	progressText:SetPoint("TOPLEFT", 12, -34)
	bar = ns.UI.Fill(panel:CreateTexture(nil, "ARTWORK"), ns.UI.COLORS.input)
	bar:SetPoint("TOPLEFT", 12, -56)
	bar:SetSize(592, 12)
	barFill = ns.UI.Fill(panel:CreateTexture(nil, "OVERLAY"), { 0.85, 0.65, 0.2, 1 })
	barFill:SetPoint("TOPLEFT", bar, "TOPLEFT")
	barFill:SetHeight(12)
	note = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	note:SetPoint("TOPLEFT", 4, -96)
	ownerText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ownerText:SetPoint("TOPRIGHT", -12, -12)

	officerRow = CreateFrame("Frame", nil, panel)
	officerRow:SetPoint("TOPLEFT", 0, -114)
	officerRow:SetSize(616, 24)
	titleBox = ns.UI.CreateInput(officerRow, 200, "Goal, e.g. Guild bank")
	titleBox:SetPoint("TOPLEFT", 4, 0)
	targetBox = ns.UI.CreateInput(officerRow, 110, "Target gold")
	targetBox:SetPoint("LEFT", titleBox, "RIGHT", 6, 0)
	local save = ns.UI.Button(officerRow, "Save goal", 100, 22, "primary")
	save:SetPoint("LEFT", targetBox, "RIGHT", 6, 0)
	local function Save(fresh)
		if Don.CanEdit() then Don.SetGoal(titleBox:GetText(), targetBox:GetText(), fresh)
		else Don.RequestChange(titleBox:GetText(), targetBox:GetText(), fresh) end
		Don.Refresh()
	end
	save:SetScript("OnClick", function() Save(false) end)
	local fresh = ns.UI.Button(officerRow, "New goal (from zero)", 150, 22)
	fresh:SetPoint("LEFT", save, "RIGHT", 6, 0)
	fresh:SetScript("OnClick", function() Save(true) end)

	list = ns.UI.CreateList(panel, {
		top = -150, rows = 13,
		columns = { { key = "name", label = "Given by", width = 300 }, { key = "amount", label = "Amount", width = 200 } },
	})
	panel:SetScript("OnShow", Don.Refresh)
	Don.Refresh()
end

ns.UI.AddPage("Guild life", "Donations", Build, { order = 30 })

local Soon = ns.Coalesce(function() Don.Refresh() end)
ns.Listen("SYNC_CHANGED", function(set)
	if set == "dgoal" or set == "donated" then Soon(); ns.Send("GUILD_LIFE_CHANGED") end
end)
ns.Listen("ROSTER_UPDATED", Soon)
