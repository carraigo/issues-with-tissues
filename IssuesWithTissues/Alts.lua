-- Alt links: a player links the characters of one account so lists show one person.
--
-- On the main:  /iwt alt add Name   (Name is another character on this account)
-- Log on to that alt: a popup asks "Link this character as an alt of Main?" Yes publishes
-- the link. The record's key is the alt itself, so only the alt can make or remove it
-- (Sync "owner" set): nobody can claim someone else's character as their alt.
-- The request waits in IwTDB.altPending, which is account-wide, so it proves both
-- characters belong to the same account.
--
-- Quicker: /iwt alt main on your main (or the Settings button). Every other character of the
-- account that logs on in the guild then offers to link itself to it, once ("No" is remembered
-- for that character; /iwt alt ask offers again).
--
--   /iwt alt               list your links
--   /iwt alt remove Name   on the alt: removes at once; on the main: removed at the alt's next login

local _, ns = ...

local Alts = ns.RegisterModule("Alts", {})
ns.Alts = Alts

ns.Sync.Define("alts", { writer = "owner" })
-- Record: the main's name ("Large Joseph").
ns.Record.Define("alts", { encode = function(main) return ns.Record.Clean(main, 60) end,
	decode = function(data) return data ~= "" and data or nil end, sample = "Large Joseph" })

local function Me() return ns.PlayerName() end

-- The main of a character (itself when it has no link).
function Alts.MainOf(name)
	local full = ns.FullName(name)
	if not full then return nil end
	local main = ns.Sync.Get("alts", full)
	if main and main ~= "" then return main end
	return full
end

function Alts.IsAlt(name)
	return Alts.MainOf(name) ~= ns.FullName(name)
end

-- Every alt linked to a main, sorted.
function Alts.AltsOf(main)
	main = ns.FullName(main)
	local list = {}
	for alt, m in ns.Sync.Each("alts") do
		if m == main and alt ~= main then list[#list + 1] = alt end
	end
	table.sort(list)
	return list
end

function Alts.Pending()
	ns.db.altPending = ns.db.altPending or {}
	return ns.db.altPending
end

function Alts.Request(altName)
	local alt = ns.FullName(altName) -- "Clane" -> "Clane Stocious" when only one guildmate is Clane
	local me = Me()
	if not alt or alt == me then
		ns.Print("Usage: /iwt alt add Name (another character on this account)")
		return false
	end
	if Alts.IsAlt(me) then
		ns.Print("This character is itself an alt of %s. Link alts from your main.", Alts.MainOf(me))
		return false
	end
	Alts.Pending()[alt] = { main = me, at = ns.Now() }
	ns.Print("Now log on to %s and say yes to link it to %s.", alt, me)
	return true
end

function Alts.Confirm()
	local me = Me()
	local p = Alts.Pending()[me]
	if not p then return false end
	Alts.Pending()[me] = nil
	if p.remove then
		ns.Sync.Delete("alts", me)
		ns.Print("This character is no longer linked to %s.", p.main or "your main")
		return true
	end
	ns.Sync.Set("alts", me, p.main)
	ns.Print("Linked as an alt of %s.", p.main)
	return true
end

function Alts.Decline()
	local me = Me()
	local p = Alts.Pending()[me]
	Alts.Pending()[me] = nil
	if p and p.auto then
		ns.db.altDeclined = ns.db.altDeclined or {}
		ns.db.altDeclined[me] = true
	end
end

-- This character is the account's main: the others offer to link to it.
function Alts.SetMain()
	local me = Me()
	if ns.Sync.Get("alts", me) then ns.Sync.Delete("alts", me) end -- a main is no one's alt
	ns.db.accountMain = me
	if ns.db.altDeclined then ns.db.altDeclined[me] = nil end
	ns.Print("%s is now your main. Log on to your other guild characters and say yes to link them.",
		ns.Roster.DisplayName(me))
	return true
end

function Alts.AccountMain()
	return ns.db.accountMain
end

-- At login on another character of the account: offer the link to the account's main.
function Alts.OfferAuto()
	local me, main = Me(), ns.db.accountMain
	if not main or main == me then return false end
	if Alts.MainOf(me) == main then return false end
	if ns.db.altDeclined and ns.db.altDeclined[me] then return false end
	if not ns.Roster.IsMember(me) then return false end -- only characters in the guild
	Alts.Pending()[me] = { main = main, at = ns.Now(), auto = true }
	if StaticPopup_Show then StaticPopup_Show("IWT_ALT_CONFIRM", ns.Roster.DisplayName(main)) end
	return true
end

function Alts.Remove(name)
	local full = ns.FullName(name)
	local me = Me()
	if full == me or not full then
		if ns.Sync.Get("alts", me) then
			ns.Sync.Delete("alts", me)
			ns.Print("This character is no longer an alt.")
			return true
		end
		ns.Print("This character has no link to remove.")
		return false
	end
	-- From the main: the alt removes its own record at its next login.
	if Alts.MainOf(full) == me then
		Alts.Pending()[full] = { main = me, remove = true, at = ns.Now() }
		ns.Print("%s will be unlinked the next time you log on to it.", full)
		return true
	end
	ns.Print("%s is not linked to this character.", full)
	return false
end

-- At login: a waiting link or removal for this character.
function Alts.CheckPending()
	local p = Alts.Pending()[Me()]
	if not p then return Alts.OfferAuto() end
	if p.remove then return Alts.Confirm() end
	if Alts.MainOf(Me()) == p.main then -- already linked (e.g. said yes to the automatic offer)
		Alts.Pending()[Me()] = nil
		return false
	end
	if StaticPopup_Show then
		StaticPopup_Show("IWT_ALT_CONFIRM", ns.Roster.DisplayName(p.main))
	end
end

if StaticPopupDialogs then
	StaticPopupDialogs.IWT_ALT_CONFIRM = {
		text = "Issues with Tissues: link this character as an alt of %s?",
		button1 = YES or "Yes",
		button2 = NO or "No",
		OnAccept = function() Alts.Confirm() end,
		OnCancel = function() Alts.Decline() end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
	}
end

-- Older builds kept names as "First Surname-Realm" or the first name alone; once the roster
-- is in, use the one key spelling ("First Surname").
function Alts.MigrateNames()
	local fixed = {}
	for alt, p in pairs(Alts.Pending()) do
		local key = ns.FullName(alt)
		if key then
			p.main = ns.FullName(p.main)
			fixed[key] = p
		end
	end
	ns.db.altPending = fixed
	if ns.db.accountMain then ns.db.accountMain = ns.FullName(ns.db.accountMain) end
	if ns.db.altDeclined then
		local d = {}
		for k, v in pairs(ns.db.altDeclined) do d[ns.FullName(k) or k] = v end
		ns.db.altDeclined = d
	end
end

-- Ask once per login, as soon as the guild roster lists this character (usually a second or
-- two after login), with a 10-second fallback.
local checked = false
local function CheckOnce()
	if checked then return end
	if not ns.Roster.IsMember(Me()) and ns.Roster.count == 0 then return end -- roster not in yet
	checked = true
	Alts.MigrateNames()
	Alts.CheckPending()
end
ns.Listen("ROSTER_UPDATED", CheckOnce)

function Alts:OnLogin()
	ns.Later("alts", function() checked = false; CheckOnce() end)
end

ns.RegisterCommand("alt", "alt links: main, add Name, remove Name, ask, or list", function(rest)
	local verb, name = (rest or ""):match("^(%S*)%s*(.-)%s*$")
	verb = (verb or ""):lower()
	if verb == "add" then return Alts.Request(name) end
	if verb == "remove" then return Alts.Remove(name ~= "" and name or nil) end
	if verb == "main" then return Alts.SetMain() end
	if verb == "ask" then
		if ns.db.altDeclined then ns.db.altDeclined[Me()] = nil end
		return Alts.OfferAuto() or ns.Print("Nothing to offer: set a main first with /iwt alt main on it.")
	end
	local me = Me()
	local main = Alts.MainOf(me)
	if ns.db.accountMain then ns.Print("Account main: %s", ns.db.accountMain) end
	if main ~= me then
		ns.Print("%s is an alt of %s.", me, main)
	else
		local list = Alts.AltsOf(me)
		ns.Print(#list > 0 and ("Your alts: " .. table.concat(list, ", ")) or "No alts linked. /iwt alt add Name")
	end
	for alt, p in pairs(Alts.Pending()) do
		ns.Print("Waiting for %s to log on (%s).", alt, p.remove and "remove" or "link")
	end
end)
