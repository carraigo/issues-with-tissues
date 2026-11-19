-- The Groups tab (LFG board): guildmates post what they are looking for, everyone sees it.
-- A post is the poster's own record in the "lfg" set (owner type, key = character), so only
-- its owner can change or clear it. It ends on its own after its time runs out, and is hidden
-- while its poster is offline.
--
--   /iwt lfg Deadmines tank     post "need a group" for a dungeon with that note
--   /iwt lfg off                take your post down

local _, ns = ...

local LFG = ns.RegisterModule("LFG", {})
ns.LFG = LFG

ns.Sync.Define("lfg", { writer = "owner", max = 300 })

LFG.KINDS = {
	{ key = "need", label = "Need a group" },
	{ key = "lfm", label = "Group needs players" },
}
LFG.ACTIVITIES = { "Dungeon", "Raid", "Quest", "PvP", "Other" }
LFG.DURATIONS = { 30, 60, 120 } -- minutes
LFG.form = { kind = "need", activity = 1, duration = 2, note = "" }

local function KindLabel(kind)
	for _, k in ipairs(LFG.KINDS) do if k.key == kind then return k.label end end
	return kind
end

-- "need;Dungeon;1800003600;Deadmines, tank"
function LFG.Encode(kind, activity, expires, note)
	note = tostring(note or ""):gsub("[|\30\31]", ""):sub(1, 80)
	return string.format("%s;%s;%d;%s", kind, activity, expires, note)
end

function LFG.Decode(data)
	local kind, activity, expires, note = (data or ""):match("^(%a+);(%a+);(%d+);(.*)$")
	if not kind then return nil end
	return { kind = kind, activity = activity, expires = tonumber(expires), note = note }
end

function LFG.Post(kind, activity, minutes, note)
	local expires = ns.Now() + (minutes or 60) * 60
	local ok = ns.Sync.Set("lfg", ns.PlayerName(), LFG.Encode(kind or "need", activity or "Dungeon", expires, note))
	if ok then ns.Print("Posted on the Groups board for %d minutes.", minutes or 60) end
	return ok
end

function LFG.Clear()
	if not ns.Sync.Get("lfg", ns.PlayerName()) then return false end
	return ns.Sync.Delete("lfg", ns.PlayerName())
end

function LFG.Mine()
	local post = LFG.Decode(ns.Sync.Get("lfg", ns.PlayerName()))
	if post and post.expires > ns.Now() then return post end
end

-- Live posts, newest first: { who, kind, activity, note, expires, posted, member }.
function LFG.Posts()
	local now, out = ns.Now(), {}
	for who, data, rec in ns.Sync.Each("lfg") do
		local post = LFG.Decode(data)
		local m = ns.Roster.Get(who)
		if post and post.expires > now and m and (m.online or who == ns.PlayerName()) then
			post.who, post.posted, post.member = who, rec.rev, m
			out[#out + 1] = post
		end
	end
	table.sort(out, function(a, b) return a.posted > b.posted end)
	return out
end

-- Tell the player about a new post from someone else.
ns.Listen("SYNC_CHANGED", function(set, key, rec)
	if set ~= "lfg" or not rec or rec.deleted or key == ns.PlayerName() then return end
	if ns.db.settings.lfgAlerts == false then return end
	local post = LFG.Decode(rec.data)
	if not post or post.expires <= ns.Now() then return end
	ns.Print("%s: %s (%s) %s", ns.Roster.DisplayName(key), KindLabel(post.kind), post.activity, post.note)
	if ns.db.settings.sounds and PlaySound then pcall(PlaySound, 3175) end -- a soft "ping"
	if LFG.Refresh then LFG.Refresh() end
end)

---------------------------------------------------------------------------
-- The tab
---------------------------------------------------------------------------
local list, kindButton, activityButton, durationButton, noteBox, postButton, clearButton, status

local COLUMNS = {
	{ key = "name", label = "Name", width = 150 },
	{ key = "level", label = "Lvl", width = 32 },
	{ key = "what", label = "Looking for", width = 170 },
	{ key = "note", label = "Note", width = 190 },
	{ key = "left", label = "Left", width = 60 },
}

function LFG.Refresh()
	if not LFG.panel or not LFG.panel:IsShown() then return end
	local f = LFG.form
	kindButton:SetText(KindLabel(f.kind))
	activityButton:SetText(LFG.ACTIVITIES[f.activity])
	durationButton:SetText(LFG.DURATIONS[f.duration] .. " min")
	local mine = LFG.Mine()
	postButton:SetText(mine and "Update" or "Post")
	if mine then clearButton:Enable() else clearButton:Disable() end
	local posts = LFG.Posts()
	local now = ns.Now()
	list:SetRows(posts, function(p, key)
		if key == "name" then return ns.Roster.DisplayName(p.who), ns.UI.ClassColor(p.member.classFile) end
		if key == "level" then return tostring(p.member.level or "") end
		if key == "what" then return KindLabel(p.kind) .. ": " .. p.activity, p.kind == "lfm" and 0.5 or 1, 1, p.kind == "lfm" and 0.5 or 1 end
		if key == "note" then return p.note end
		if key == "left" then return ns.UI.Ago(p.expires - now) end
	end)
	status:SetText(#posts == 0 and "Nobody online is looking right now." or
		(#posts .. " posts. Right-click to whisper, Shift-click to invite."))
end

local function Cycle(n, max) return n % max + 1 end

local function Build(panel)
	LFG.panel = panel
	local f = LFG.form
	kindButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	kindButton:SetSize(150, 22)
	kindButton:SetPoint("TOPLEFT", 0, 0)
	kindButton:SetScript("OnClick", function()
		f.kind = f.kind == "need" and "lfm" or "need"
		LFG.Refresh()
	end)
	activityButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	activityButton:SetSize(90, 22)
	activityButton:SetPoint("LEFT", kindButton, "RIGHT", 4, 0)
	activityButton:SetScript("OnClick", function() f.activity = Cycle(f.activity, #LFG.ACTIVITIES); LFG.Refresh() end)
	durationButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	durationButton:SetSize(70, 22)
	durationButton:SetPoint("LEFT", activityButton, "RIGHT", 4, 0)
	durationButton:SetScript("OnClick", function() f.duration = Cycle(f.duration, #LFG.DURATIONS); LFG.Refresh() end)

	noteBox = ns.UI.CreateInput(panel, 380, "Note: which dungeon, role, level...")
	noteBox:SetPoint("TOPLEFT", 8, -30)
	noteBox.onChange = function(text) f.note = text end
	local function DoPost()
		LFG.Post(f.kind, LFG.ACTIVITIES[f.activity], LFG.DURATIONS[f.duration], f.note)
		LFG.Refresh()
	end
	noteBox.onEnter = DoPost
	postButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	postButton:SetSize(90, 22)
	postButton:SetPoint("LEFT", noteBox, "RIGHT", 8, 0)
	postButton:SetScript("OnClick", DoPost)
	clearButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	clearButton:SetSize(110, 22)
	clearButton:SetPoint("LEFT", postButton, "RIGHT", 4, 0)
	clearButton:SetText("Take mine down")
	clearButton:SetScript("OnClick", function() LFG.Clear(); LFG.Refresh() end)

	list = ns.UI.CreateList(panel, {
		top = -62, rows = 15, columns = COLUMNS,
		onClick = function(p, button)
			if button == "RightButton" then ns.UI.Whisper(p.who)
			elseif IsShiftKeyDown and IsShiftKeyDown() then ns.UI.Invite(p.who) end
		end,
		onEnter = function(_, p)
			GameTooltip:AddLine(ns.Roster.DisplayName(p.who), ns.UI.ClassColor(p.member.classFile))
			GameTooltip:AddLine(string.format("Level %s %s, %s", tostring(p.member.level), p.member.class or "", p.member.zone or ""), 1, 1, 1)
			GameTooltip:AddLine(KindLabel(p.kind) .. ": " .. p.activity, 1, 0.82, 0)
			if p.note ~= "" then GameTooltip:AddLine(p.note, 1, 1, 1, true) end
			GameTooltip:AddLine("Right-click to whisper, Shift-click to invite", 0.5, 0.5, 0.5)
		end,
	})
	status = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	status:SetPoint("BOTTOMLEFT", 4, 2)
	panel:SetScript("OnShow", LFG.Refresh)
	LFG.Refresh()
end

ns.UI.AddTabBeforeSettings("Groups", Build)
ns.Settings.AddToggle("lfgAlerts", "Tell me when a guildmate posts on the Groups board")
ns.Listen("ROSTER_UPDATED", function() LFG.Refresh() end)
-- Refresh the time left once a minute while the tab is open.
if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(60, function() LFG.Refresh() end) end

ns.RegisterCommand("lfg", "post on the Groups board: /iwt lfg note, or /iwt lfg off", function(rest)
	rest = rest or ""
	if rest:lower() == "off" then
		return LFG.Clear() and ns.Print("Your post is down.") or ns.Print("You have no post up.")
	end
	if rest == "" then return ns.UI.Open("Groups") end
	LFG.Post("need", "Dungeon", 60, rest)
end)
