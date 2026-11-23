-- Raid readiness: each character shares one small "sheet" record with the attunements and keys
-- it has and the raids it is saved to (with their reset times). It is read at login and when a
-- quest is handed in, the bags change or the game's raid info updates, and it is sent only
-- when something in it changed, so it costs a packet now and then.
--
-- Record data: "<codes>;<lockouts>"
--   codes     attunement codes joined by "."            mc.ony.ubrs
--   lockouts  name:resetAt:done:total joined by "/"     Molten Core:1795000000:7:10
-- resetAt is server time, rounded to 5 minutes so the same lockout always reads the same.

local _, ns = ...

local Sheet = ns.RegisterModule("Sheet", {})
ns.Sheet = Sheet

ns.Sync.Define("sheet", { writer = "owner" })

-- What counts: a quest flagged completed (any listed), or a key item in the bags, keyring or bank.
-- raid = true: shown under "Raids"; the rest are dungeon keys and the like.
Sheet.ATTUNEMENTS = {
	{ code = "mc", short = "MC", name = "Molten Core", raid = true, quests = { 7848 } },
	{ code = "ony", short = "Ony", name = "Onyxia's Lair (Drakefire Amulet)", raid = true,
		quests = { 6502, 6602 }, items = { 16309 } },
	{ code = "bwl", short = "BWL", name = "Blackwing Lair", raid = true, quests = { 7761 } },
	{ code = "naxx", short = "Naxx", name = "Naxxramas", raid = true, quests = { 9121, 9122, 9123 } },
	{ code = "ubrs", short = "UBRS", name = "Upper Blackrock Spire (Seal of Ascension)", quests = { 4743 }, items = { 12344 } },
	{ code = "scholo", short = "Scholo", name = "Scholomance (Skeleton Key)", quests = { 5505, 5511 }, items = { 13704 } },
	{ code = "strat", short = "Strat", name = "Stratholme (Key to the City)", items = { 12382 } },
	{ code = "dm", short = "DM", name = "Dire Maul (Crescent Key)", items = { 18249 } },
	{ code = "brd", short = "BRD", name = "Blackrock Depths (Shadowforge Key)", quests = { 3802 }, items = { 11000 } },
	{ code = "douse", short = "Douse", name = "Molten Core runes (Aqual or Eternal Quintessence)", items = { 17333, 22754 } },
}
Sheet.BY_CODE = {}
for _, a in ipairs(Sheet.ATTUNEMENTS) do Sheet.BY_CODE[a.code] = a end

Sheet.RESET_ROUND = 300

---------------------------------------------------------------------------
-- Reading this character
---------------------------------------------------------------------------
local function QuestDone(id)
	local q = C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted or IsQuestFlaggedCompleted
	if not q then return false end
	local ok, done = pcall(q, id)
	return ok and done and true or false
end

local function HasItem(id)
	local count = C_Item and C_Item.GetItemCount or GetItemCount
	if not count then return false end
	local ok, n = pcall(count, id, true) -- true: the bank counts too
	return ok and (tonumber(n) or 0) > 0
end

function Sheet.Has(a)
	for _, q in ipairs(a.quests or {}) do if QuestDone(q) then return true end end
	for _, i in ipairs(a.items or {}) do if HasItem(i) then return true end end
	return false
end

local function Clean(s) return (tostring(s or ""):gsub("[%c:/;%.|]", ""):sub(1, 40)) end

-- This character's saved raids: { name, resetAt, done, total }, by name.
function Sheet.ReadLockouts(now)
	local out = {}
	if not (GetNumSavedInstances and GetSavedInstanceInfo) then return out end
	now = now or ns.Now()
	local ok, n = pcall(GetNumSavedInstances)
	for i = 1, ok and tonumber(n) or 0 do
		local okInfo, name, _, reset, _, locked, _, _, _, _, _, total, done = pcall(GetSavedInstanceInfo, i)
		reset = okInfo and tonumber(reset) or 0
		if okInfo and name and locked and reset > 0 then
			local at = math.floor((now + reset) / Sheet.RESET_ROUND + 0.5) * Sheet.RESET_ROUND
			out[#out + 1] = { name = Clean(name), resetAt = at, done = tonumber(done) or 0, total = tonumber(total) or 0 }
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

function Sheet.Encode(has, locks)
	local codes = {}
	for _, a in ipairs(Sheet.ATTUNEMENTS) do if has[a.code] then codes[#codes + 1] = a.code end end
	local l = {}
	for i, lock in ipairs(locks or {}) do
		l[i] = string.format("%s:%d:%d:%d", Clean(lock.name), lock.resetAt, lock.done or 0, lock.total or 0)
	end
	return table.concat(codes, ".") .. ";" .. table.concat(l, "/")
end

-- { has = { code = true }, locks = { {name, resetAt, done, total} } }; lockouts that have
-- reset are left out. Codes this version doesn't know are kept (a newer addon may add some).
function Sheet.Decode(data, now)
	local codes, locks = tostring(data or ""):match("^([^;]*);?(.*)$")
	if not codes then return nil end
	now = now or ns.Now()
	local s = { has = {}, locks = {} }
	for c in codes:gmatch("[^%.]+") do s.has[c] = true end
	for name, at, done, total in locks:gmatch("([^:/]+):(%d+):(%d+):(%d+)") do
		at = tonumber(at)
		if at > now then
			s.locks[#s.locks + 1] = { name = name, resetAt = at, done = tonumber(done), total = tonumber(total) }
		end
	end
	return s
end

function Sheet.Read()
	local has = {}
	for _, a in ipairs(Sheet.ATTUNEMENTS) do has[a.code] = Sheet.Has(a) or nil end
	return Sheet.Encode(has, Sheet.ReadLockouts())
end

-- Share this character's sheet (only when it changed).
function Sheet.Share()
	local me = ns.PlayerName()
	if not me or not ns.Roster.me then return false end
	local data = Sheet.Read()
	if data == ns.Sync.Get("sheet", me) then return false end
	return ns.Sync.Set("sheet", me, data)
end

function Sheet.Of(name)
	local data = ns.Sync.Get("sheet", ns.FullName(name) or name)
	return data and Sheet.Decode(data)
end

---------------------------------------------------------------------------
-- The guild's sheets
---------------------------------------------------------------------------
-- One row per guildmate who shares a sheet: online first, then highest level, then by name.
-- opts.online: only those online now.
function Sheet.Rows(opts)
	opts = opts or {}
	local rows, now = {}, ns.Now()
	for who, data in ns.Sync.Each("sheet") do
		local m = ns.Roster.Get(who)
		local s = m and Sheet.Decode(data, now)
		if s and (not opts.online or m.online) then
			rows[#rows + 1] = { full = who, name = ns.Roster.DisplayName(who), classFile = m.classFile,
				level = m.level or 0, online = m.online, has = s.has, locks = s.locks }
		end
	end
	table.sort(rows, function(a, b)
		if a.online ~= b.online then return a.online end
		if a.level ~= b.level then return a.level > b.level end
		return a.name < b.name
	end)
	return rows
end

-- How many rows have each attunement, and how many are saved to each raid.
function Sheet.Counts(rows)
	local has, saved = {}, {}
	for _, r in ipairs(rows) do
		for code in pairs(r.has) do has[code] = (has[code] or 0) + 1 end
		for _, l in ipairs(r.locks) do saved[l.name] = (saved[l.name] or 0) + 1 end
	end
	return has, saved
end

---------------------------------------------------------------------------
-- When to read
---------------------------------------------------------------------------
local shareSoon = ns.Coalesce(function() Sheet.Share() end, ns.TIMERS.sheetChanged)
local bagsSoon = ns.Coalesce(function() Sheet.Share() end, ns.TIMERS.sheetBags)
Sheet.ShareSoon = shareSoon

-- Ask the game for this character's saved raids; UPDATE_INSTANCE_INFO follows.
function Sheet.AskRaidInfo()
	if RequestRaidInfo then pcall(RequestRaidInfo) else shareSoon() end
end

pcall(ns.On, "UPDATE_INSTANCE_INFO", shareSoon)
pcall(ns.On, "QUEST_TURNED_IN", shareSoon)
pcall(ns.On, "BAG_UPDATE_DELAYED", bagsSoon)
-- A boss kill saves the raid: look again a moment later.
for _, ev in ipairs({ "BOSS_KILL", "ENCOUNTER_END" }) do
	pcall(ns.On, ev, function() ns.Later("sheetBoss", Sheet.AskRaidInfo) end)
end

function Sheet:OnLogin()
	ns.Later("sheet", Sheet.AskRaidInfo)
end
-- The roster can arrive after the login read, and until it has, sharing is refused.
ns.Listen("ROSTER_UPDATED", ns.Coalesce(function()
	if ns.Roster.me and not ns.Sync.Get("sheet", ns.PlayerName()) then shareSoon() end
end, 1))

ns.RegisterCommand("raid", "your attunements and saved raids, as the guild sees them", function()
	local s = Sheet.Decode(Sheet.Read())
	local got, missing = {}, {}
	for _, a in ipairs(Sheet.ATTUNEMENTS) do
		if s.has[a.code] then got[#got + 1] = a.short else missing[#missing + 1] = a.short end
	end
	ns.Print("Attuned or keyed: %s", #got > 0 and table.concat(got, ", ") or "none yet")
	if #missing > 0 then ns.Print("Not yet: %s", table.concat(missing, ", ")) end
	if #s.locks == 0 then return ns.Print("Not saved to any raid.") end
	for _, l in ipairs(s.locks) do
		ns.Print("Saved: %s %d/%d, resets %s", l.name, l.done, l.total, date("%a %d %b %H:%M", l.resetAt))
	end
end)
