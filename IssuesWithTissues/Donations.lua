-- Guild life > Donations: a goal set by officers (first one: the guild bank) and how much each
-- guildmate has given towards it. Gold put into the guild bank is noted automatically.
--
-- "dgoal" (officers): key "goal" = "id;target;title". Saving keeps the id; a new goal gets a
--   new id, which starts everyone's total from zero.
-- "donated" (owner):  key = character, data = "goalId;copper" given towards that goal.

local _, ns = ...

local Don = ns.RegisterModule("Donations", {})
ns.Donations = Don

ns.Sync.Define("dgoal", { writer = "officer" })
ns.Sync.Define("donated", { writer = "owner" })

Don.DEFAULT_TITLE = "Guild bank"

local function Clean(text, max)
	return (tostring(text or ""):gsub("[|;\30\31]", ""):gsub("^%s+", ""):gsub("%s+$", "")):sub(1, max)
end

function Don.Goal()
	local id, target, title = (ns.Sync.Get("dgoal", "goal") or ""):match("^(%d+);(%d+);(.*)$")
	if not id then return { id = 0, target = 0, title = Don.DEFAULT_TITLE } end
	return { id = tonumber(id), target = tonumber(target), title = title ~= "" and title or Don.DEFAULT_TITLE }
end

-- Officers: change the goal's title and target (gold). fresh: start a new goal from zero.
function Don.SetGoal(title, targetGold, fresh)
	local g = Don.Goal()
	local id = (fresh or g.id == 0) and ns.Now() or g.id
	local target = math.max(0, math.floor((tonumber(targetGold) or 0) * 10000))
	title = Clean(title, 40)
	if title == "" then title = g.title end
	return ns.Sync.Set("dgoal", "goal", string.format("%d;%d;%s", id, target, title))
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
local list, titleText, progressText, bar, barFill, officerRow, titleBox, targetBox, note

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
	officerRow:SetShown(ns.Roster.IsOfficer(ns.PlayerName()))
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

	officerRow = CreateFrame("Frame", nil, panel)
	officerRow:SetPoint("TOPLEFT", 0, -114)
	officerRow:SetSize(616, 24)
	titleBox = ns.UI.CreateInput(officerRow, 200, "Goal, e.g. Guild bank")
	titleBox:SetPoint("TOPLEFT", 4, 0)
	targetBox = ns.UI.CreateInput(officerRow, 110, "Target gold")
	targetBox:SetPoint("LEFT", titleBox, "RIGHT", 6, 0)
	local save = ns.UI.Button(officerRow, "Save goal", 100, 22, "primary")
	save:SetPoint("LEFT", targetBox, "RIGHT", 6, 0)
	save:SetScript("OnClick", function()
		Don.SetGoal(titleBox:GetText(), targetBox:GetText(), false)
		Don.Refresh()
	end)
	local fresh = ns.UI.Button(officerRow, "New goal (from zero)", 150, 22)
	fresh:SetPoint("LEFT", save, "RIGHT", 6, 0)
	fresh:SetScript("OnClick", function()
		Don.SetGoal(titleBox:GetText(), targetBox:GetText(), true)
		Don.Refresh()
	end)

	list = ns.UI.CreateList(panel, {
		top = -150, rows = 13,
		columns = { { key = "name", label = "Given by", width = 300 }, { key = "amount", label = "Amount", width = 200 } },
	})
	panel:SetScript("OnShow", Don.Refresh)
	Don.Refresh()
end

ns.UI.AddPage("Guild life", "Donations", Build, { order = 30 })

ns.Listen("SYNC_CHANGED", function(set)
	if set == "dgoal" or set == "donated" then Don.Refresh(); ns.Send("GUILD_LIFE_CHANGED") end
end)
ns.Listen("ROSTER_UPDATED", function() Don.Refresh() end)
