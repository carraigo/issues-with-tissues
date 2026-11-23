-- Professions: each character's professions and skill, and the recipes it knows.
--
-- Skills are read at login and whenever they change. Recipes are read when the player opens a
-- profession window (the game only lists them then). Both are shared with the guild:
--   Sync "profs"   key = character, data = "Tailoring:225:300,Alchemy:150:150"
--   Sync "recipes" key = character .. "#" .. profession, data = "i2b8.1.4;s5p9.2;nRecipe name"
--     (version 3, 1.3.0): "i" then the item ids of recipes that make an item, "s" then the
--     spell ids of ones that don't (enchants), each sorted and written as base 36 gaps from the
--     one before (Record.Gaps); "n" .. name as a last resort. Names are looked up in game and
--     remembered on this PC (db.recipeNames), so each name is stored once instead of once per
--     crafter. Version 2 (a 1.3.0 beta) was "12345;s7421;nName", version 1 "itemID:Name;...";
--     both are upgraded as they arrive.
-- Only the crafting professions are tracked (0.9.0): gathering ones, First Aid and Fishing are
-- left out, and guildmates' older records that still list them are filtered when read.
-- Cooking was dropped in 1.3.0 (nearly everyone has it, so it swamped the Crafting list): it is
-- no longer read or shown, and each character deletes its own old Cooking recipes at login.
-- Forever has the modern C_TradeSkillUI API; the classic GetTradeSkill* functions are a fallback.

local _, ns = ...

local Prof = ns.RegisterModule("Professions", {})
ns.Professions = Prof

ns.Sync.Define("profs", { writer = "owner" })
-- Recipes are the one set that grows with the guild: a safety cap on top of the clean-up below.
ns.Sync.Define("recipes", { writer = "member", max = 1500, version = 3,
	upgrade = function(data, v) return Prof.UpgradeRecipes(data, v) end })

-- The professions tracked, by name and by skill line (the name may be in another language).
Prof.CRAFTING = {
	Alchemy = 171, Blacksmithing = 164, Enchanting = 333, Engineering = 202,
	Leatherworking = 165, Tailoring = 197,
}
local craftingLine = {}
for _, id in pairs(Prof.CRAFTING) do craftingLine[id] = true end

function Prof.IsCrafting(name, skillLine)
	return (skillLine ~= nil and craftingLine[skillLine]) or Prof.CRAFTING[name] ~= nil
end

local function Clean(s, max)
	s = tostring(s or ""):gsub("[%c\30\31:;,|#]", "")
	return s:sub(1, max or 40)
end

-- { { name, rank, max }, ... } for this character, from whichever API the client has.
function Prof.ReadSkills()
	local list = {}
	if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
		local ids = { GetProfessions() }
		for i = 1, 6 do
			local id = ids[i]
			if id then
				local name, _, rank, max, _, _, skillLine = GetProfessionInfo(id)
				if name and Prof.IsCrafting(name, skillLine) then
					list[#list + 1] = { name = name, rank = rank or 0, max = max or 0, skillLine = skillLine }
				end
			end
		end
		if #list > 0 then return list end
	end
	if type(GetNumSkillLines) == "function" and type(GetSkillLineInfo) == "function" then
		for i = 1, GetNumSkillLines() do
			local name, isHeader, _, rank, _, _, max = GetSkillLineInfo(i)
			if not isHeader and name and Prof.IsCrafting(name) then
				list[#list + 1] = { name = name, rank = rank or 0, max = max or 0 }
			end
		end
	end
	return list
end

-- Skills record: "Alchemy:150:225,Tailoring:225:300" (sorted)
function Prof.Encode(list)
	local parts = {}
	for _, p in ipairs(list) do parts[#parts + 1] = Clean(p.name, 24) .. ":" .. (p.rank or 0) .. ":" .. (p.max or 0) end
	table.sort(parts)
	return table.concat(parts, ",")
end

function Prof.Decode(data)
	local list = {}
	for _, part in ipairs(ns.Record.Split(data or "", ",")) do
		local name, rank, max = part:match("^([^:]+):(%d+):(%d+)$")
		if name then list[#list + 1] = { name = name, rank = tonumber(rank), max = tonumber(max) } end
	end
	return list
end
ns.Record.Define("profs", { encode = Prof.Encode, decode = Prof.Decode,
	sample = { { name = "Alchemy", rank = 150, max = 225 }, { name = "Tailoring", rank = 225, max = 300 } } })

-- Publish our skills when they changed.
function Prof.UpdateSkills()
	local data = Prof.Encode(Prof.ReadSkills())
	local me = ns.PlayerName()
	if data == "" or data == ns.Sync.Get("profs", me) then return false end
	return ns.Sync.Set("profs", me, data)
end

-- A character's crafting professions: { { name, rank, max }, ... }
-- Remembered until shared data changes (lists and searches ask for the same people often).
-- Callers must not change the list.
local ofCache, ofGen = {}, nil
function Prof.Of(name)
	if ofGen ~= ns.Sync.gen then ofCache, ofGen = {}, ns.Sync.gen end
	local data = ns.Sync.Get("profs", ns.FullName(name))
	local hit = ofCache[name]
	if hit and hit.data == data then return hit.list end
	local out = {}
	for _, p in ipairs(Prof.Decode(data)) do
		if Prof.IsCrafting(p.name) then out[#out + 1] = p end
	end
	ofCache[name] = { data = data, list = out }
	return out
end

---------------------------------------------------------------------------
-- Recipes (read when a profession window is open)
---------------------------------------------------------------------------
local function ItemId(link)
	return link and tonumber(link:match("item:(%d+)"))
end

local function ReadModern()
	local T = C_TradeSkillUI
	if not T or type(T.GetBaseProfessionInfo) ~= "function" or type(T.GetRecipeInfo) ~= "function" then return nil end
	if type(T.IsTradeSkillLinked) == "function" and T.IsTradeSkillLinked() then return nil end
	if type(T.IsTradeSkillGuild) == "function" and T.IsTradeSkillGuild() then return nil end
	local ok, base = pcall(T.GetBaseProfessionInfo)
	if not ok or type(base) ~= "table" or not base.professionName then return nil end
	local ids
	for _, f in ipairs({ "GetAllRecipeIDs", "GetFilteredRecipeIDs" }) do
		if not ids and type(T[f]) == "function" then
			local okr, r = pcall(T[f])
			if okr and type(r) == "table" then ids = r end
		end
	end
	local recipes = {}
	for _, id in ipairs(ids or {}) do
		local okr, info = pcall(T.GetRecipeInfo, id)
		if okr and type(info) == "table" and info.learned and info.name then
			local item
			if type(T.GetRecipeOutputItemData) == "function" then
				local oko, out = pcall(T.GetRecipeOutputItemData, id)
				if oko and type(out) == "table" then item = out.itemID end
			end
			recipes[#recipes + 1] = { item = item or 0, spell = id, name = info.name }
		end
	end
	return base.professionName, recipes
end

local function ReadClassic(craft)
	local lineFn = craft and GetCraftDisplaySkillLine or GetTradeSkillLine
	if type(lineFn) ~= "function" then return nil end
	if type(IsTradeSkillLinked) == "function" and IsTradeSkillLinked() then return nil end
	local profName = lineFn()
	if type(profName) ~= "string" or profName == "" or profName == "UNKNOWN" then return nil end
	local count = craft and GetNumCrafts or GetNumTradeSkills
	local info = craft and GetCraftInfo or GetTradeSkillInfo
	local itemLink = craft and GetCraftItemLink or GetTradeSkillItemLink
	local recipes = {}
	for i = 1, (type(count) == "function" and count() or 0) do
		local name, kind, _
		if craft then name, _, kind = info(i) else name, kind = info(i) end
		if name and kind ~= "header" and kind ~= "subheader" then
			recipes[#recipes + 1] = { item = ItemId(type(itemLink) == "function" and itemLink(i)) or 0, name = name }
		end
	end
	return profName, recipes
end

---------------------------------------------------------------------------
-- Recipe names: looked up in game, remembered on this PC.
---------------------------------------------------------------------------
Prof.namesGen = 0 -- goes up when names arrive (the recipe list is decoded again)
Prof.NAME_BATCH = 100 -- item names asked of the game per step
local missing, waiting = {}, 0 -- item id -> true while the game loads its name; how many

local function Names()
	ns.db.recipeNames = ns.db.recipeNames or {}
	return ns.db.recipeNames
end

function Prof.Remember(kind, id, name)
	if not id or id == 0 or type(name) ~= "string" or name == "" then return end
	Names()[kind .. id] = Clean(name, 50)
end

local function ItemName(id)
	local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	return type(fn) == "function" and fn(id) or nil
end

local function SpellName(id)
	if C_Spell and type(C_Spell.GetSpellName) == "function" then return C_Spell.GetSpellName(id) end
	if type(GetSpellInfo) == "function" then return (GetSpellInfo(id)) end
end

-- A recipe's name: remembered, else asked from the game (nil while an item still loads).
function Prof.NameOf(kind, id)
	local names = Names()
	local name = names[kind .. id]
	if name then return name end
	name = kind == "i" and ItemName(id) or kind == "s" and SpellName(id) or nil
	if name then Prof.Remember(kind, id, name) end
	return name
end

-- Names arrive one item at a time: the Crafting list is rebuilt once they're all in, or every
-- few seconds while a big batch is still loading, not once per item.
local function NamesIn()
	Prof.namesGen = Prof.namesGen + 1
	ns.Send("SYNC_CHANGED", "recipes")
end
local namesArrived = ns.Coalesce(NamesIn, 3)
pcall(ns.On, "GET_ITEM_INFO_RECEIVED", function(_, id, ok)
	id = tonumber(id)
	if not id or not missing[id] then return end
	missing[id] = nil
	waiting = waiting - 1
	if ok ~= false then Prof.NameOf("i", id) end
	if waiting <= 0 then waiting = 0; NamesIn() else namesArrived() end
end)

-- Every recipe item in the guild's data whose name this PC doesn't know yet: asked of the game
-- in batches (after the catch-up, and when new recipes come in). Returns how many were asked.
function Prof.PrefetchNames()
	local names, want = Names(), {}
	for _, data in ns.Sync.Each("recipes") do
		for _, id in ipairs((Prof.RecipeIds(data))) do
			if not names["i" .. id] and not missing[id] then
				local name = ItemName(id)
				if name then Prof.Remember("i", id, name) else want[#want + 1] = id end
			end
		end
	end
	if #want == 0 then return 0 end
	for _, id in ipairs(want) do missing[id] = true end -- all counted now, asked in batches
	waiting = waiting + #want
	local request = C_Item and C_Item.RequestLoadItemDataByID
	local function Step(from)
		for i = from, math.min(#want, from + Prof.NAME_BATCH - 1) do
			if type(request) == "function" then pcall(request, want[i]) else ItemName(want[i]) end
		end
		if from + Prof.NAME_BATCH <= #want then ns.After(0.2, function() Step(from + Prof.NAME_BATCH) end) end
	end
	Step(1)
	return #want
end
local prefetchSoon = ns.Coalesce(Prof.PrefetchNames, 5)
ns.Listen("SYNC_CHANGED", function(set) if set == "recipes" then prefetchSoon() end end)

-- A recipe list -> "i<item gaps>;s<spell gaps>;n<name>;n<name>" (empty groups left out).
-- Names given with the ids are remembered on this PC.
function Prof.EncodeRecipes(recipes)
	local items, spells, names, seen = {}, {}, {}, {}
	for _, r in ipairs(recipes) do
		if r.item and r.item > 0 then
			Prof.Remember("i", r.item, r.name)
			items[#items + 1] = r.item
		elseif r.spell and r.spell > 0 then
			Prof.Remember("s", r.spell, r.name)
			spells[#spells + 1] = r.spell
		else
			local n = Clean(r.name, 50)
			if n ~= "" and not seen[n] then seen[n] = true; names[#names + 1] = n end
		end
	end
	table.sort(names)
	local parts = {}
	if #items > 0 then parts[#parts + 1] = "i" .. ns.Record.Gaps(items) end
	if #spells > 0 then parts[#parts + 1] = "s" .. ns.Record.Gaps(spells) end
	for _, n in ipairs(names) do parts[#parts + 1] = "n" .. n end
	return table.concat(parts, ";")
end

-- The ids in a recipe record, without looking names up: items, spells, names.
function Prof.RecipeIds(data)
	local items, spells, names = {}, {}, {}
	for _, token in ipairs(ns.Record.Split(data or "", ";")) do
		local kind, rest = token:sub(1, 1), token:sub(2)
		if kind == "i" then items = ns.Record.Ungaps(rest)
		elseif kind == "s" then spells = ns.Record.Ungaps(rest)
		elseif kind == "n" and rest ~= "" then names[#names + 1] = rest end
	end
	return items, spells, names
end

-- { { item, spell, name }, ... }; name is "" while the game hasn't loaded it yet.
function Prof.DecodeRecipes(data)
	local list = {}
	local items, spells, names = Prof.RecipeIds(data)
	for _, id in ipairs(items) do list[#list + 1] = { item = id, name = Prof.NameOf("i", id) or "" } end
	for _, id in ipairs(spells) do list[#list + 1] = { item = 0, spell = id, name = Prof.NameOf("s", id) or "" } end
	for _, n in ipairs(names) do list[#list + 1] = { item = 0, name = n } end
	return list
end
ns.Record.Define("recipes", { encode = Prof.EncodeRecipes, decode = Prof.DecodeRecipes,
	sample = { { item = 2996 }, { item = 2997 }, { item = 4305 }, { spell = 7418 }, { spell = 7420 }, { item = 0, name = "Secret Stew" } } })

-- Older records -> version 3. Version 1: "itemID:Name;..." (names move to this PC's name list).
-- Version 2: "12345;s7421;nName".
function Prof.UpgradeRecipes(data, v)
	local list = {}
	if (v or 1) == 1 then
		for item, name in (data or ""):gmatch("(%d+):([^;]*)") do
			item = tonumber(item)
			if item > 0 then list[#list + 1] = { item = item, name = name }
			elseif name ~= "" then list[#list + 1] = { item = 0, name = name } end
		end
	else
		for token in (data or ""):gmatch("[^;]+") do
			if token:match("^%d+$") then list[#list + 1] = { item = tonumber(token) }
			elseif token:sub(1, 1) == "s" and tonumber(token:sub(2)) then list[#list + 1] = { spell = tonumber(token:sub(2)) }
			elseif token:sub(1, 1) == "n" then list[#list + 1] = { item = 0, name = token:sub(2) } end
		end
	end
	return Prof.EncodeRecipes(list)
end

-- The skill line of one of this character's professions, by name.
function Prof.SkillLineOf(profName)
	for _, p in ipairs(Prof.ReadSkills()) do if p.name == profName then return p.skillLine end end
end

-- Read the open profession window and publish it when it changed.
function Prof.ReadOpenWindow(craft)
	if InCombatLockdown and InCombatLockdown() then return false end
	local profName, recipes = nil, nil
	if not craft then profName, recipes = ReadModern() end
	if not profName then profName, recipes = ReadClassic(craft) end
	if not profName or not recipes or #recipes == 0 then return false end
	if not Prof.IsCrafting(profName) and not Prof.IsCrafting(nil, Prof.SkillLineOf(profName)) then return false end -- Smelting and the like
	Prof.lastRead = profName
	local me = ns.PlayerName()
	local key = me .. "#" .. Clean(profName, 24)
	local data = Prof.EncodeRecipes(recipes)
	if data == ns.Sync.Get("recipes", key) then return false end
	return ns.Sync.Set("recipes", key, data)
end

-- Recipes are a "member" set, but each record must be its writer's own character.
local canWrite = ns.Sync.CanWrite
ns.Sync.CanWrite = function(name, key, by)
	if name == "recipes" then
		local owner = key:match("^(.-)#")
		return owner ~= nil and ns.FullName(owner) == ns.FullName(by) and ns.Roster.IsMember(by)
	end
	return canWrite(name, key, by)
end

-- Every recipe in the guild: { { crafter, profession, item, name }, ... }
-- Decoded once per change: the Crafters search runs on every key typed, and decoding thousands
-- of recipes each time made typing stutter in a big guild. Callers must not change the list.
local cache, cacheGen, cacheStore, cacheNames
function Prof.AllRecipes()
	local store = ns.db.sync.recipes
	if cache and cacheGen == ns.Sync.gen and cacheNames == Prof.namesGen and cacheStore == (store and store.records) then return cache end
	local out = {}
	for key, data in ns.Sync.Each("recipes") do
		local crafter, profession = key:match("^(.-)#(.*)$")
		if crafter and Prof.IsCrafting(profession) then
			for _, r in ipairs(Prof.DecodeRecipes(data)) do
				out[#out + 1] = { crafter = crafter, profession = profession, item = r.item, name = r.name, lower = r.name:lower() }
			end
		end
	end
	cache, cacheGen, cacheStore, cacheNames = out, ns.Sync.gen, store and store.records, Prof.namesGen
	return out
end

-- Who can make something whose name contains `text`.
function Prof.WhoCanMake(text)
	text = (text or ""):lower()
	local out = {}
	if text == "" then return out end
	for _, r in ipairs(Prof.AllRecipes()) do
		if r.lower:find(text, 1, true) then out[#out + 1] = r end
	end
	table.sort(out, function(a, b) if a.name ~= b.name then return a.name < b.name end return a.crafter < b.crafter end)
	return out
end

---------------------------------------------------------------------------
-- Scan: Forever shows every profession in one window, with a tab per profession on its right.
-- The game does not let addons open that window (it is protected), so the button opens the
-- profession book where it can, and the player clicks through the tabs. Every tab shown is
-- read a moment after it appears, scan or no scan; the scan only tracks what is left.
---------------------------------------------------------------------------
-- Gathering professions have no recipe list worth sharing.
Prof.NO_RECIPES = { Herbalism = true, Skinning = true, Fishing = true, Mining = true }
Prof.scan = nil -- { left = { name, ... }, done = n, total = n }

-- How many recipes this character has shared for a profession (nil: never scanned).
function Prof.SharedCount(profName, who)
	local data = ns.Sync.Get("recipes", (who or ns.PlayerName()) .. "#" .. Clean(profName, 24))
	if not data then return nil end
	return #Prof.DecodeRecipes(data)
end

-- Professions on this character with recipes to share.
function Prof.Scannable()
	local out = {}
	for _, p in ipairs(Prof.ReadSkills()) do
		if not Prof.NO_RECIPES[p.name] then out[#out + 1] = p end
	end
	return out
end

-- Professions this character still has to show once.
function Prof.Unscanned()
	local out = {}
	for _, p in ipairs(Prof.Scannable()) do
		if not Prof.SharedCount(p.name) then out[#out + 1] = p.name end
	end
	return out
end

-- The profession book key ("Toggle profession book"). Opening a panel is allowed; the
-- profession window itself is not.
local function OpenBook()
	for _, fn in ipairs({ "ToggleProfessionsBook", "ToggleProfessionBook" }) do
		if type(_G[fn]) == "function" then
			local ok = pcall(_G[fn])
			if ok then return true end
		end
	end
	return false
end

-- The button.
function Prof.Scan()
	if InCombatLockdown and InCombatLockdown() then
		ns.Print("Recipe scan waits until you leave combat.")
		return false
	end
	local total = #Prof.Scannable()
	if total == 0 then
		ns.Print("No crafting professions to scan on this character.")
		return false
	end
	-- Every profession is read again (recipes learned since), not only the unscanned ones.
	Prof.scan = { total = total, done = 0, left = {} }
	for _, p in ipairs(Prof.Scannable()) do table.insert(Prof.scan.left, p.name) end
	OpenBook()
	ns.Print("Open a profession (your profession book or its key), then click each profession tab on the right of that window: %s.",
		table.concat(Prof.scan.left, ", "))
	ns.Send("SCAN_CHANGED")
	return true
end

-- A profession window was read: tick it off.
function Prof.ScanRead(profName)
	local s = Prof.scan
	if not s or not profName then return end
	for i, name in ipairs(s.left) do
		if name == profName then table.remove(s.left, i) break end
	end
	s.done = s.total - #s.left
	if #s.left == 0 then
		Prof.scan = nil
		ns.Print("Recipe scan finished: all %d professions shared.", s.total)
	end
	ns.Send("SCAN_CHANGED")
end

-- Read a moment after the last window event, so a quick click through the tabs still reads
-- the tab that ends up shown. Each new event cancels the read before it.
local token = 0
local function Soon(craft)
	token = token + 1
	local mine = token
	ns.Later("recipeRead", function()
		if mine ~= token then return end
		Prof.lastRead = nil
		local ok, err = pcall(Prof.ReadOpenWindow, craft)
		if not ok then ns.ReportError("recipe read: " .. tostring(err)) return end
		Prof.ScanRead(Prof.lastRead)
	end)
end
Prof.Soon = Soon

for _, ev in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED" }) do
	pcall(ns.On, ev, function() Soon(false) end)
end
pcall(ns.On, "CRAFT_SHOW", function() Soon(true) end)
pcall(ns.On, "SKILL_LINES_CHANGED", function() ns.Later("skillsChanged", Prof.UpdateSkills) end)

-- Delete this character's shared recipes for professions no longer tracked (Cooking, 1.3.0).
-- A deletion travels like any change, so guildmates on older versions drop them too.
function Prof.DropUntracked()
	local me = ns.PlayerName()
	if not me or not ns.Roster.me then return 0 end
	local n = 0
	local keys = {}
	for key in ns.Sync.Each("recipes") do keys[#keys + 1] = key end
	for _, key in ipairs(keys) do
		local who, profession = key:match("^(.-)#(.+)$")
		if who == me and not Prof.IsCrafting(profession) and ns.Sync.Delete("recipes", key) then n = n + 1 end
	end
	return n
end

function Prof:OnLogin()
	ns.Later("profs", function() Prof.UpdateSkills(); Prof.DropUntracked() end)
	ns.Later("recipeNames", Prof.PrefetchNames)
end
-- At login the roster can arrive after those 12 seconds, and until it has, sharing is refused
-- (we are not known to be in the guild yet). Try again whenever the roster is read; it only
-- sends when the skills differ from what is shared.
ns.Listen("ROSTER_UPDATED", ns.Coalesce(function()
	if ns.Roster.me then Prof.UpdateSkills() end
	Prof.ForgetLeavers()
end, 1))

---------------------------------------------------------------------------
-- Characters who left the guild: their professions and recipes are dropped from this PC once
-- they've been missing from the roster for LEAVER_DAYS (guildmates can't send them back: only
-- members' records are accepted). A roster much smaller than usual is not trusted.
---------------------------------------------------------------------------
Prof.LEAVER_DAYS = 3
-- Sets keyed by character (recipes: character#profession) that are dropped for leavers.
Prof.LEAVER_SETS = { "profs", "recipes", "kills", "votes", "sheet" }
Prof.rosterPeak = 0

local function Owner(set, key)
	if set == "recipes" then return key:match("^(.-)#") end
	return key
end

function Prof.ForgetLeavers()
	local R = ns.Roster
	if (R.count or 0) == 0 then return 0 end
	Prof.rosterPeak = math.max(Prof.rosterPeak, R.count)
	if R.count < Prof.rosterPeak * 0.75 then return 0 end
	local db = ns.db
	db.leftAt = db.leftAt or {}
	local now, dropped = ns.Now(), 0
	local seen = {}
	for _, set in ipairs(Prof.LEAVER_SETS) do
		local store = db.sync[set] and db.sync[set].records or {}
		for key in pairs(store) do
			local who = Owner(set, key)
			if who and R.IsMember(who) then
				db.leftAt[who] = nil
			elseif who then
				db.leftAt[who] = db.leftAt[who] or now
				if now - db.leftAt[who] >= Prof.LEAVER_DAYS * 86400 then
					store[key] = nil
					dropped = dropped + 1
				else
					seen[who] = true -- still has records waiting
				end
			end
		end
	end
	for who in pairs(db.leftAt) do if not seen[who] then db.leftAt[who] = nil end end
	if dropped > 0 then
		ns.Sync.gen = ns.Sync.gen + 1
		ns.Log("leavers: dropped %d records of characters who left the guild", dropped)
		for _, set in ipairs(Prof.LEAVER_SETS) do ns.Send("SYNC_CHANGED", set) end
	end
	return dropped
end

ns.RegisterCommand("craft", "who in the guild can make an item: /iwt craft name", function(rest)
	local found = Prof.WhoCanMake(rest)
	if rest == "" then return ns.Print("Usage: /iwt craft <part of an item name>") end
	if #found == 0 then return ns.Print("Nobody has shared a recipe matching \"%s\" yet.", rest) end
	for i = 1, math.min(#found, 15) do
		local r = found[i]
		ns.Print("%s - %s (%s)", r.name, r.crafter, r.profession)
	end
	if #found > 15 then ns.Print("...and %d more.", #found - 15) end
end)
