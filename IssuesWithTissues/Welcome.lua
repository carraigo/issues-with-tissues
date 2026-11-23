-- A welcome card on first install, and a "What's new" card the first time a new version loads.
-- Both are shown once, a few seconds after logging in, and never in combat.
--
-- Keep Welcome.NOTES up to date with each release: the newest version first, a few short lines
-- each (a test checks that the current version has an entry).

local _, ns = ...

local Welcome = ns.RegisterModule("Welcome", {})
ns.Welcome = Welcome

Welcome.NOTES = {
	{ version = "1.3.0", lines = {
		"New themes: Solarized Dark and Solarized Light, picked from a drop-down in Settings.",
		"Kawaii Day has its own class colours, easy to read and easy to tell apart.",
		"Chat says \"5 min ago\" for recent lines; hover a time for the full date.",
		"Officers: a new Officers page under Members lists who's been away 30+ days and who needs to update.",
		"Lighter syncing: recipes are shared as item ids, and old votes are tidied away.",
	} },
	{ version = "1.2.3", lines = {
		"Behind the scenes: new versions now reach CurseForge automatically.",
	} },
	{ version = "1.2.2", lines = {
		"New installs catch up with the guild much faster.",
		"Home shows sync progress, and Settings has a Sync now button.",
	} },
	{ version = "1.2.1", lines = {
		"Kawaii Day: guild chat is easy to read again.",
		"Your guild key can open this window instead of the game's guild window: press the button below.",
	} },
	{ version = "1.2.0", lines = {
		"Item tooltips say \"Guild craftable\" in green when someone in the guild can make it.",
		"Promote and Demote on the roster now fill in the game's command in chat: press Enter to do it.",
		"Guild news on Home: who joined, left, hit 60 or was promoted this week.",
		"Hover over someone on the roster to see their guild note.",
		"Unread guild chat shows on the Chat tab and the minimap button.",
		"The addon stays quiet in combat and raids.",
		"Settings: choose whether the window opens on Home, Chat or the last tab you used.",
	} },
	{ version = "1.1.0", lines = {
		"Crafters has its own Crafting tab.",
		"The roster shows rank and when people were last on. Right-click someone to whisper or invite them.",
		"Officers can promote and demote from the roster's right-click menu.",
	} },
	{ version = "1.0.2", lines = {
		"New versions now reach CurseForge automatically, so the CurseForge app keeps the addon up to date.",
	} },
	{ version = "1.0.1", lines = {
		"Fixed the key bindings: they have their own Issues with Tissues section in Key Bindings, with no stray row.",
	} },
	{ version = "1.0.0", lines = {
		"Version 1.0: Issues with Tissues is now on CurseForge as well as GitHub.",
		"Recipes and professions of characters who left the guild are cleared after three days.",
		"/iwt bug shows how much each part of the addon's saved data takes.",
	} },
	{ version = "0.9.0", lines = {
		"Layer hopping is gone: Blizzard turns it off after 25 November.",
		"Settings: window size, window sounds, hide the window in combat, and 12 or 24-hour chat times.",
		"Ctrl+F jumps to the search on Roster, Crafters and Loot notes. Enter picks the first result.",
		"Scrolled up in chat? A Newest button shows how many lines came in and takes you back down.",
		"Professions list only the crafting ones, and the addon is quicker to log in and search.",
	} },
	{ version = "0.8.2", lines = {
		"This card now fits its text, so the buttons no longer cover the last lines.",
	} },
	{ version = "0.8.1", lines = {
		"A welcome card for new installs, and this card after each update.",
		"You're told once when a guildmate has a newer version, with the download link (/iwt update).",
		"Issues with Tissues has its own page in the game's Options, under AddOns.",
	} },
	{ version = "0.8.0", lines = {
		"Guild and officer chat in the window, with earlier chat from the game's server.",
		"A list of who's online by rank, beside the chat.",
		"Themes in Settings: Default, Kawaii Night, Kawaii Day, Midnight and High contrast.",
		"Key bindings: bind \"Open guild chat\" to J to use the addon as your guild window.",
	} },
}

Welcome.WELCOME = {
	"Everything for the guild in one window. Open it with /iwt, the minimap button, or a key (Key Bindings, Issues with Tissues).",
	"Home: the guild at a glance and your professions.",
	"Chat: guild and officer chat, and who's online.",
	"Members: the roster. Officers can promote and demote from it.",
	"Crafting: who can craft what.",
	"Guild life: polls, donations and loot notes.",
	"The cog opens Settings, with themes. Everything is shared only with guildmates who run the addon.",
}
-- The first-run tour: the welcome card's "Take the tour" opens each page with a short tip.
Welcome.TOUR = {
	{ page = "Home", text = "Home: the guild at a glance, this character and its main, and your professions. Press \"Scan my recipes\" once so guildmates can find what you craft." },
	{ page = "Chat", text = "Chat: guild and officer chat with earlier messages, and who's online by rank on the right. Type below and press Enter to send." },
	{ page = "Crafters", text = "Crafting: search for an item to see who in the guild can make it. Item tooltips also say \"Guild craftable\" in green." },
}

-- Shown under the welcome (and in What's new) while the guild key still opens the game's window.
Welcome.KEY_TIP = "Tip: let your guild key (%s) open this window instead of the game's Guild & Communities. Press the button below, or set it in Key Bindings."

-- "0.8.0-beta.3" -> 0, 8, 0, "beta.3"
function Welcome.ParseVersion(v)
	local a, b, c, pre = tostring(v or ""):match("^(%d+)%.(%d+)%.(%d+)%-?(.*)$")
	if not a then return nil end
	return tonumber(a), tonumber(b), tonumber(c), pre ~= "" and pre or nil
end

-- true when version a is newer than b. A release beats its own pre-releases.
function Welcome.Newer(a, b)
	local a1, a2, a3, ap = Welcome.ParseVersion(a)
	local b1, b2, b3, bp = Welcome.ParseVersion(b)
	if not a1 or not b1 then return false end
	if a1 ~= b1 then return a1 > b1 end
	if a2 ~= b2 then return a2 > b2 end
	if a3 ~= b3 then return a3 > b3 end
	if ap == bp then return false end
	if not ap then return true end
	if not bp then return false end
	local an, bn = tonumber(ap:match("(%d+)$")), tonumber(bp:match("(%d+)$"))
	if an and bn and ap:gsub("%d+$", "") == bp:gsub("%d+$", "") then return an > bn end
	return ap > bp
end

-- The notes for versions newer than `since`, up to this one (newest first, at most two).
function Welcome.NotesSince(since)
	local out = {}
	-- A beta counts as its release here: it shows that release's notes, once.
	local release = tostring(ns.VERSION):match("^%d+%.%d+%.%d+") or ns.VERSION
	local sinceRelease = since and (tostring(since):match("^%d+%.%d+%.%d+") or since)
	for _, n in ipairs(Welcome.NOTES) do
		local current = not Welcome.Newer(n.version, release)
		if current and (not since or Welcome.Newer(n.version, sinceRelease)) then out[#out + 1] = n end
		if #out == 2 then break end
	end
	return out
end

---------------------------------------------------------------------------
-- The card
---------------------------------------------------------------------------
local card

local function Card()
	if card then return card end
	local UI = ns.UI
	card = UI.Window("IwTWelcomeCard", 500, 330, "", "DIALOG")
	local body = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	body:SetPoint("TOPLEFT", 22, -48)
	body:SetWidth(500 - 44) -- a fixed width, so its height can be measured before it's shown
	body:SetJustifyH("LEFT")
	body:SetJustifyV("TOP")
	if body.SetSpacing then body:SetSpacing(3) end
	card.body = body
	local ok = UI.Button(card, "Got it", 110, 24, "primary")
	ok:SetPoint("BOTTOMRIGHT", -16, 14)
	ok:SetScript("OnClick", function() card:Hide() end)
	card.ok = ok
	local open = UI.Button(card, "Open the window", 140, 24)
	open:SetPoint("RIGHT", ok, "LEFT", -8, 0)
	open:SetScript("OnClick", function()
		card:Hide()
		if card.tour then Welcome.StartTour() else UI.Open("Home") end
	end)
	card.open = open
	local key = UI.Button(card, "", 180, 24)
	key:SetPoint("RIGHT", open, "LEFT", -8, 0)
	key:SetScript("OnClick", function()
		if Welcome.UseGuildKey() then key:Hide() end
	end)
	card.key = key
	return card
end

---------------------------------------------------------------------------
-- The guild key: the game's "Guild & Communities" key (J unless changed) can open this
-- window instead. Only ever on the player's click, and never in combat.
---------------------------------------------------------------------------
Welcome.GAME_GUILD = "TOGGLEGUILDTAB"
Welcome.OURS = "IWT_TOGGLE"

-- The key the game's guild window uses now (or J, its default, when it has none).
function Welcome.GuildKey()
	local key = GetBindingKey and GetBindingKey(Welcome.GAME_GUILD)
	return key or "J"
end

-- True when the guild key already opens our window.
function Welcome.KeyIsOurs()
	local key = Welcome.GuildKey()
	if GetBindingAction and GetBindingAction(key) == Welcome.OURS then return true end
	local ours = GetBindingKey and GetBindingKey(Welcome.OURS)
	return ours ~= nil and ours == key
end

function Welcome.UseGuildKey()
	if not SetBinding or (InCombatLockdown and InCombatLockdown()) then
		ns.Print("Change it out of combat, or in the game's Key Bindings (Issues with Tissues).")
		return false
	end
	local key = Welcome.GuildKey()
	if not SetBinding(key, Welcome.OURS) then return false end
	if SaveBindings then SaveBindings(GetCurrentBindingSet and GetCurrentBindingSet() or 1) end
	ns.Print("%s now opens Issues with Tissues. You can change it back in Key Bindings.", key)
	return key
end

-- The card's key button, when the guild key isn't ours yet.
function Welcome.UpdateKeyButton(c)
	if Welcome.KeyIsOurs() then c.key:Hide() return end
	c.key:SetText("Use " .. Welcome.GuildKey() .. " for this window")
	c.key:Show()
end

local function Show(title, text, tour)
	local c = Card()
	c.tour = tour and true or false
	c.open:SetText(tour and "Take the tour" or "Open the window")
	c.title:SetText(title)
	c.body:SetText(text)
	-- Fit the card to the text: title bar and padding above, a gap and the buttons below.
	local function Fit()
		local h = c.body.GetStringHeight and c.body:GetStringHeight()
		if type(h) == "number" and h > 0 then c:SetHeight(math.max(200, math.ceil(48 + h + 20 + 24 + 16))) end
	end
	Fit()
	Welcome.UpdateKeyButton(c)
	c:Show()
	ns.After(0, Fit) -- once more after the game has laid the text out
	if ns.UI.ThemeTree then ns.UI.ThemeTree(c) end
	Welcome.shown = title
	return c
end

local function Gold(s)
	local g = ns.UI.COLORS.gold
	return string.format("|cff%02x%02x%02x%s|r", math.floor(g[1] * 255 + 0.5), math.floor(g[2] * 255 + 0.5), math.floor(g[3] * 255 + 0.5), s)
end

function Welcome.ShowWelcome()
	local lines = { Welcome.WELCOME[1], "" }
	for i = 2, #Welcome.WELCOME - 1 do lines[#lines + 1] = "- " .. Welcome.WELCOME[i] end
	lines[#lines + 1] = ""
	lines[#lines + 1] = Welcome.WELCOME[#Welcome.WELCOME]
	if not Welcome.KeyIsOurs() then
		lines[#lines + 1] = ""
		lines[#lines + 1] = Gold(Welcome.KEY_TIP:format(Welcome.GuildKey()))
	end
	return Show("Welcome to Issues with Tissues", table.concat(lines, "\n"), true)
end

function Welcome.ShowWhatsNew(since)
	local notes = Welcome.NotesSince(since)
	if #notes == 0 then return end
	local lines = {}
	for i, n in ipairs(notes) do
		if i > 1 then lines[#lines + 1] = "" end
		lines[#lines + 1] = Gold("Version " .. n.version)
		for _, l in ipairs(n.lines) do lines[#lines + 1] = "- " .. l end
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "The full list is in the changelog on the addon's GitHub page."
	return Show("What's new in Issues with Tissues", table.concat(lines, "\n"))
end

---------------------------------------------------------------------------
-- The tour: a tip under the window for each page, with Next and Done.
---------------------------------------------------------------------------
local tip
local function Tip()
	if tip then return tip end
	local UI = ns.UI
	tip = CreateFrame("Frame", "IwTTourTip", UIParent)
	tip:SetSize(420, 96)
	tip:SetFrameStrata("DIALOG")
	tip:EnableMouse(true)
	UI.Skin(tip)
	tip.step = tip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	tip.step:SetPoint("TOPLEFT", 12, -10)
	tip.text = tip:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	tip.text:SetPoint("TOPLEFT", 12, -26)
	tip.text:SetWidth(396)
	tip.text:SetJustifyH("LEFT")
	tip.next = UI.Button(tip, "Next", 80, 22, "primary")
	tip.next:SetPoint("BOTTOMRIGHT", -10, 8)
	tip.next:SetScript("OnClick", function() Welcome.TourStep((Welcome.tourAt or 0) + 1) end)
	tip.close = UI.Button(tip, "End tour", 80, 22)
	tip.close:SetPoint("RIGHT", tip.next, "LEFT", -6, 0)
	tip.close:SetScript("OnClick", function() Welcome.EndTour() end)
	return tip
end

function Welcome.StartTour() return Welcome.TourStep(1) end

-- Show step i (past the last one ends the tour). Returns the step shown.
function Welcome.TourStep(i)
	local step = Welcome.TOUR[i]
	if not step then return Welcome.EndTour() end
	Welcome.tourAt = i
	ns.UI.Open(step.page)
	local t = Tip()
	t.step:SetText(string.format("Tour %d of %d", i, #Welcome.TOUR))
	t.text:SetText(step.text)
	t.next:SetText(i == #Welcome.TOUR and "Done" or "Next")
	t:ClearAllPoints()
	local w = _G.IwTMainWindow
	if w then t:SetPoint("TOP", w, "BOTTOM", 0, -6) else t:SetPoint("CENTER") end
	t:Show()
	if ns.UI.ThemeTree then ns.UI.ThemeTree(t) end
	return step
end

function Welcome.EndTour()
	Welcome.tourAt = nil
	if tip then tip:Hide() end
end

ns.RegisterCommand("tour", "a short tour of the window", function() Welcome.StartTour() end)

---------------------------------------------------------------------------
-- When to show it
---------------------------------------------------------------------------
function Welcome:OnLoad()
	-- Data from an earlier version: this is an update, not a first install.
	local db = ns.db
	Welcome.updating = db.seenVersion ~= nil or type(db.usage) == "table" or next(db.sync or {}) ~= nil
end

function Welcome.Check()
	if InCombatLockdown and InCombatLockdown() then return ns.Later("welcomeRetry", Welcome.Check) end
	local db = ns.db
	local seen = db.seenVersion
	db.seenVersion = ns.VERSION
	if not seen and not Welcome.updating then
		return Welcome.ShowWelcome()
	end
	if seen ~= ns.VERSION and (not seen or Welcome.Newer(ns.VERSION, seen)) then
		return Welcome.ShowWhatsNew(seen)
	end
end

function Welcome:OnLogin()
	ns.Later("welcome", Welcome.Check)
end

ns.RegisterCommand("new", "what's new in this version", function()
	Welcome.ShowWhatsNew(nil)
end)
ns.RegisterCommand("welcome", "show the welcome card again", function() Welcome.ShowWelcome() end)
