-- A welcome card on first install, and a "What's new" card the first time a new version loads.
-- Both are shown once, a few seconds after logging in, and never in combat.
--
-- Keep Welcome.NOTES up to date with each release: the newest version first, a few short lines
-- each (a test checks that the current version has an entry).

local _, ns = ...

local Welcome = ns.RegisterModule("Welcome", {})
ns.Welcome = Welcome

Welcome.NOTES = {
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
	"Members: the roster and who can craft what.",
	"Hop: layers, and asking a guildmate for an invite.",
	"Guild life: polls, donations and loot notes.",
	"The cog opens Settings, with themes. Everything is shared only with guildmates who run the addon.",
}

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
	for _, n in ipairs(Welcome.NOTES) do
		local current = not Welcome.Newer(n.version, ns.VERSION)
		if current and (not since or Welcome.Newer(n.version, since)) then out[#out + 1] = n end
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
	open:SetScript("OnClick", function() card:Hide(); UI.Open("Home") end)
	card.open = open
	return card
end

local function Show(title, text)
	local c = Card()
	c.title:SetText(title)
	c.body:SetText(text)
	-- Fit the card to the text: title bar and padding above, a gap and the buttons below.
	local function Fit()
		local h = c.body.GetStringHeight and c.body:GetStringHeight()
		if type(h) == "number" and h > 0 then c:SetHeight(math.max(200, math.ceil(48 + h + 20 + 24 + 16))) end
	end
	Fit()
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
	return Show("Welcome to Issues with Tissues", table.concat(lines, "\n"))
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
-- When to show it
---------------------------------------------------------------------------
function Welcome:OnLoad()
	-- Data from an earlier version: this is an update, not a first install.
	local db = ns.db
	Welcome.updating = db.seenVersion ~= nil or type(db.usage) == "table" or next(db.sync or {}) ~= nil
end

function Welcome.Check()
	if InCombatLockdown and InCombatLockdown() then return ns.After(10, Welcome.Check) end
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
	ns.After(6, Welcome.Check)
end

ns.RegisterCommand("new", "what's new in this version", function()
	Welcome.ShowWhatsNew(nil)
end)
ns.RegisterCommand("welcome", "show the welcome card again", function() Welcome.ShowWelcome() end)
