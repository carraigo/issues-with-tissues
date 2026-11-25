-- Professions, part two: reading the profession window and the "Scan my recipes" button.
-- The recipe data itself (encoding, names, who can make what) lives in Professions.lua.
-- Every profession tab the player opens is read a moment after it appears and shared through
-- Prof.ReadOpenWindow; the scan only counts which tabs are still to be opened.

local _, ns = ...

local Prof = ns.Professions
local Clean = Prof.Clean

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
