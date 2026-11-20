-- Professions: each character's professions and skill, and the recipes it knows.
--
-- Skills are read at login and whenever they change. Recipes are read when the player opens a
-- profession window (the game only lists them then). Both are shared with the guild:
--   Sync "profs"   key = character, data = "Tailoring:225:300,Herbalism:150:150"
--   Sync "recipes" key = character .. "#" .. profession, data = "itemID:Recipe name;..."
-- Forever has the modern C_TradeSkillUI API; the classic GetTradeSkill* functions are a fallback.

local _, ns = ...

local Prof = ns.RegisterModule("Professions", {})
ns.Professions = Prof

ns.Sync.Define("profs", { writer = "owner" })
ns.Sync.Define("recipes", { writer = "member" })

-- Names the classic skill list uses for professions (enUS; other locales use headers below).
Prof.KNOWN = {
	Alchemy = true, Blacksmithing = true, Enchanting = true, Engineering = true, Herbalism = true,
	Leatherworking = true, Mining = true, Skinning = true, Tailoring = true, Jewelcrafting = true,
	Inscription = true, Cooking = true, ["First Aid"] = true, Fishing = true,
}

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
				if name then list[#list + 1] = { name = name, rank = rank or 0, max = max or 0, skillLine = skillLine } end
			end
		end
		if #list > 0 then return list end
	end
	if type(GetNumSkillLines) == "function" and type(GetSkillLineInfo) == "function" then
		local section
		for i = 1, GetNumSkillLines() do
			local name, isHeader, _, rank, _, _, max = GetSkillLineInfo(i)
			if isHeader then
				section = name
			elseif name and (Prof.KNOWN[name] or section == (TRADE_SKILLS or "Professions")
				or section == (SECONDARY_SKILLS or "Secondary Skills")) then
				list[#list + 1] = { name = name, rank = rank or 0, max = max or 0 }
			end
		end
	end
	return list
end

function Prof.Encode(list)
	local parts = {}
	for _, p in ipairs(list) do parts[#parts + 1] = Clean(p.name, 24) .. ":" .. (p.rank or 0) .. ":" .. (p.max or 0) end
	table.sort(parts)
	return table.concat(parts, ",")
end

function Prof.Decode(data)
	local list = {}
	for name, rank, max in (data or ""):gmatch("([^:,]+):(%d+):(%d+)") do
		list[#list + 1] = { name = name, rank = tonumber(rank), max = tonumber(max) }
	end
	return list
end

-- Publish our skills when they changed.
function Prof.UpdateSkills()
	local data = Prof.Encode(Prof.ReadSkills())
	local me = ns.PlayerName()
	if data == "" or data == ns.Sync.Get("profs", me) then return false end
	return ns.Sync.Set("profs", me, data)
end

-- A character's professions: { { name, rank, max }, ... }
function Prof.Of(name)
	return Prof.Decode(ns.Sync.Get("profs", ns.FullName(name)))
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
			recipes[#recipes + 1] = { item = item or 0, name = info.name }
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

function Prof.EncodeRecipes(recipes)
	local parts = {}
	for _, r in ipairs(recipes) do parts[#parts + 1] = (r.item or 0) .. ":" .. Clean(r.name, 50) end
	table.sort(parts)
	return table.concat(parts, ";")
end

function Prof.DecodeRecipes(data)
	local list = {}
	for item, name in (data or ""):gmatch("(%d+):([^;]*)") do
		list[#list + 1] = { item = tonumber(item), name = name }
	end
	return list
end

-- Read the open profession window and publish it when it changed.
function Prof.ReadOpenWindow(craft)
	if InCombatLockdown and InCombatLockdown() then return false end
	local profName, recipes = nil, nil
	if not craft then profName, recipes = ReadModern() end
	if not profName then profName, recipes = ReadClassic(craft) end
	if not profName or not recipes or #recipes == 0 then return false end
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
function Prof.AllRecipes()
	local out = {}
	for key, data in ns.Sync.Each("recipes") do
		local crafter, profession = key:match("^(.-)#(.*)$")
		if crafter then
			for _, r in ipairs(Prof.DecodeRecipes(data)) do
				out[#out + 1] = { crafter = crafter, profession = profession, item = r.item, name = r.name }
			end
		end
	end
	return out
end

-- Who can make something whose name contains `text`.
function Prof.WhoCanMake(text)
	text = (text or ""):lower()
	local out = {}
	if text == "" then return out end
	for _, r in ipairs(Prof.AllRecipes()) do
		if r.name:lower():find(text, 1, true) then out[#out + 1] = r end
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

-- Crafting professions on this character (Mining keeps Smelting, but it is not worth a tab).
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
	ns.After(0.6, function()
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
pcall(ns.On, "SKILL_LINES_CHANGED", function() ns.After(2, Prof.UpdateSkills) end)

function Prof:OnLogin()
	ns.After(12, Prof.UpdateSkills)
end
-- At login the roster can arrive after those 12 seconds, and until it has, sharing is refused
-- (we are not known to be in the guild yet). Try again whenever the roster is read; it only
-- sends when the skills differ from what is shared.
ns.Listen("ROSTER_UPDATED", ns.Coalesce(function()
	if ns.Roster.me then Prof.UpdateSkills() end
end, 1))

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
