-- Wishlists (1.4.0): items each character would like. They travel in the character sheet
-- (Sheet.lua, fourth field, as item ids), so crafters and officers can see who wants what:
-- on item tooltips ("Wanted by 3 guildmates"), and on Crafting > Wishlists with who can make it.
-- Add an item by shift-clicking it while the page's box has focus, or with /iwt wish <item>.

local _, ns = ...

local W = ns.RegisterModule("Wishlist", {})
ns.Wishlist = W

W.MAX = 30 -- items per character

local function List()
	ns.char.wish = ns.char.wish or {}
	return ns.char.wish
end

-- This character's wishlist: item ids, oldest first.
function W.Mine()
	local out = {}
	for i, id in ipairs(List()) do out[i] = id end
	return out
end

function W.Has(id)
	for _, x in ipairs(List()) do if x == id then return true end end
	return false
end

-- An item id from a link, an id, or the name of an item the game has seen.
function W.ItemId(text)
	if type(text) == "number" then return text end
	text = ns.Readable(text)
	if not text then return nil end
	local id = tonumber(text:match("item:(%d+)")) or tonumber(text:match("^%s*(%d+)%s*$"))
	if id then return id end
	local name = text:match("^%s*(.-)%s*$")
	if name == "" or not GetItemInfo then return nil end
	local ok, _, link = pcall(GetItemInfo, name)
	return ok and link and tonumber(link:match("item:(%d+)")) or nil
end

local function Changed()
	ns.Send("WISHLIST_CHANGED")
	if ns.Sheet then ns.Sheet.ShareSoon() end
end

-- Add an item; false and why when it can't be.
function W.Add(item)
	local id = W.ItemId(item)
	if not id or id <= 0 then return false, "That isn't an item. Shift-click one, or type its exact name." end
	if W.Has(id) then return false, "Already on your wishlist." end
	local list = List()
	if #list >= W.MAX then return false, "Your wishlist is full (" .. W.MAX .. " items). Remove one first." end
	list[#list + 1] = id
	Changed()
	return true
end

function W.Remove(id)
	local list = List()
	for i, x in ipairs(list) do
		if x == id then
			table.remove(list, i)
			Changed()
			return true
		end
	end
	return false
end

---------------------------------------------------------------------------
-- The guild's wishes
---------------------------------------------------------------------------
-- item id -> { character, ... } for everyone sharing a sheet (us included); rebuilt on change.
local index, indexGen
function W.Index()
	if index and indexGen == ns.Sync.gen then return index end
	index, indexGen = {}, ns.Sync.gen
	for who, s in pairs(ns.Sheet.All()) do
		if ns.Roster.IsMember(who) then
			for _, id in ipairs(s.wish or {}) do
				index[id] = index[id] or {}
				table.insert(index[id], who)
			end
		end
	end
	for _, list in pairs(index) do table.sort(list) end
	return index
end

-- Who wants an item, us left out (our own wish shows as "On your wishlist").
function W.WantedBy(id)
	local me, out = ns.PlayerName(), {}
	for _, who in ipairs(W.Index()[id] or {}) do
		if who ~= me then out[#out + 1] = who end
	end
	return out
end

function W.AddTooltipLines(tooltip, id)
	local mine = W.Has(id)
	local others = W.WantedBy(id)
	if not mine and #others == 0 then return false end
	if mine then tooltip:AddLine("On your wishlist", 1, 0.82, 0) end
	if #others > 0 then
		local names = {}
		for i, who in ipairs(others) do
			if i > 4 then names[#names + 1] = "+" .. (#others - 4) break end
			names[#names + 1] = ns.Roster.DisplayName(who)
		end
		tooltip:AddLine(string.format("Wanted by %d %s: %s", #others, #others == 1 and "guildmate" or "guildmates",
			table.concat(names, ", ")), 1, 0.82, 0, true)
	end
	return true
end

-- Crafters in the guild who can make an item: { character, ... }. Indexed by item once per
-- change of the recipe list (the page asks for every wished item).
local makers, makersFrom
local NONE = {}
function W.Crafters(id)
	local all = ns.Professions.AllRecipes()
	if makersFrom ~= all then
		makers, makersFrom = {}, all
		local seen = {}
		for _, r in ipairs(all) do
			local item = r.item
			if item and item > 0 then
				local key = item .. "#" .. r.crafter
				if not seen[key] then
					seen[key] = true
					makers[item] = makers[item] or {}
					table.insert(makers[item], r.crafter)
				end
			end
		end
		for _, list in pairs(makers) do table.sort(list) end
	end
	return makers[id] or NONE
end

-- The item's name, or nil while the game loads it (GET_ITEM_INFO_RECEIVED follows).
local asked = {}
function W.Name(id)
	local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local name = fn and fn(id)
	if name then return name end
	if not asked[id] then
		asked[id] = true
		local request = C_Item and C_Item.RequestLoadItemDataByID
		if request then pcall(request, id) end
	end
	return nil
end

-- One row per wished item: { id, name, wanters = { ... }, mine, crafters = { ... } }
function W.Rows()
	local rows = {}
	local me = ns.PlayerName()
	local idx = W.Index()
	local ids = {}
	for id in pairs(idx) do ids[id] = true end
	for _, id in ipairs(List()) do ids[id] = true end -- ours, before the sheet has gone out
	for id in pairs(ids) do
		local wanters = {}
		local mine = W.Has(id)
		for _, who in ipairs(idx[id] or {}) do if who ~= me then wanters[#wanters + 1] = who end end
		local crafters = W.Crafters(id)
		rows[#rows + 1] = { id = id, name = W.Name(id) or ("item " .. id), wanters = wanters, wanted = #wanters + (mine and 1 or 0),
			mine = mine, crafters = crafters, craftable = #crafters > 0 }
	end
	return rows
end

---------------------------------------------------------------------------
-- Crafting > Wishlists
---------------------------------------------------------------------------
local list, input

W.FILTERS = {
	{ key = "all", label = "All" },
	{ key = "mine", label = "Mine", test = function(r) return r.mine end },
	{ key = "craft", label = "Craftable", test = function(r) return r.craftable end },
}

local function Who(names, max)
	local out = {}
	for i, who in ipairs(names) do
		if i > max then out[#out + 1] = "+" .. (#names - max) break end
		local m = ns.Roster.Get(who)
		out[#out + 1] = ((m and m.online) and "|cff40d070" or "|cffb8b0a1") .. ns.Roster.DisplayName(who) .. "|r"
	end
	return table.concat(out, ", ")
end

function W.Refresh()
	if not W.panel or not W.panel:IsShown() then return end
	list:SetRows(W.Rows(), function(row, key)
		if key == "name" then return row.name, 1, 1, 1 end
		if key == "wanted" then
			local who = Who(row.wanters, 2)
			if row.mine then who = (who ~= "" and ("You, " .. who) or "You") end
			return who
		end
		if key == "crafters" then
			if not row.craftable then return "nobody yet", 0.5, 0.5, 0.5 end
			return Who(row.crafters, 2)
		end
	end)
end

local function AddFromBox()
	local ok, why = W.Add(input:GetText())
	if ok then
		input:SetText("")
		W.Refresh()
	else
		ns.Print(why)
	end
end

local function Build(panel)
	W.panel = panel
	input = ns.UI.CreateInput(panel, 220, "Shift-click an item to add it")
	input:SetPoint("TOPRIGHT", -60, 0)
	input.onEnter = AddFromBox
	local add = ns.UI.Button(panel, "Add", 54, 22, "primary")
	add:SetPoint("TOPRIGHT", 0, 0)
	add:SetScript("OnClick", AddFromBox)
	W.input = input
	list = ns.UI.CreateList(panel, {
		top = -34, rows = 18, filters = W.FILTERS, save = "wishlist",
		state = { sort = "wanted", desc = true },
		columns = {
			{ key = "name", label = "Item", width = 220, sort = true },
			{ key = "wanted", label = "Wanted by", width = 200, sort = true, desc = true },
			{ key = "crafters", label = "Can make it", width = 186, sort = function(r) return #r.crafters end, desc = true },
		},
		count = function(shown, all)
			return string.format("%d of %d items. Hover for the item; click to whisper; right-click your own to remove it.", #shown, #all)
		end,
		onClick = function(row, button)
			if button == "RightButton" and row.mine then
				W.Remove(row.id)
				W.Refresh()
			elseif row.craftable and not row.mine then
				ns.UI.Whisper(row.wanters[1])
			elseif row.craftable then
				ns.UI.Whisper(row.crafters[1])
			elseif row.wanters[1] then
				ns.UI.Whisper(row.wanters[1])
			end
		end,
		onEnter = function(line, row)
			GameTooltip:SetOwner(line, "ANCHOR_RIGHT")
			if GameTooltip.SetItemByID then
				pcall(GameTooltip.SetItemByID, GameTooltip, row.id)
			else
				pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. row.id)
			end
		end,
	})
	list:SetEmpty("No wishes yet. Shift-click an item you'd like into the box above (or type /iwt wish and shift-click it). Crafters and officers see who wants what.")
	panel:SetScript("OnShow", W.Refresh)
	W.list = list
	W.Refresh()
end
ns.UI.AddPage("Crafting", "Wishlists", Build, { order = 20 })

local Soon = ns.Coalesce(function() W.Refresh() end, 0.5)
ns.Listen("ROSTER_UPDATED", Soon)
ns.Listen("WISHLIST_CHANGED", Soon)
ns.Listen("SYNC_CHANGED", function(set) if set == "sheet" or set == "recipes" then Soon() end end)
pcall(ns.On, "GET_ITEM_INFO_RECEIVED", function(_, id) if asked[tonumber(id)] then Soon() end end)

-- Shift-clicking an item while the box has focus puts the link in it, as in chat.
if hooksecurefunc and ChatEdit_InsertLink then
	hooksecurefunc("ChatEdit_InsertLink", function(link)
		if input and input.HasFocus and input:HasFocus() and link then input:SetText(link) end
	end)
end

ns.RegisterCommand("wish", "add or remove an item on your wishlist: /iwt wish <shift-click an item>", function(rest)
	rest = rest or ""
	if rest:match("^%s*$") then
		local mine = W.Mine()
		if #mine == 0 then return ns.Print("Your wishlist is empty. /iwt wish then shift-click an item to add it.") end
		local names = {}
		for _, id in ipairs(mine) do names[#names + 1] = W.Name(id) or ("item " .. id) end
		return ns.Print("Your wishlist: %s", table.concat(names, ", "))
	end
	local id = W.ItemId(rest)
	if id and W.Has(id) then
		W.Remove(id)
		return ns.Print("Removed from your wishlist.")
	end
	local ok, why = W.Add(rest)
	ns.Print(ok and "Added to your wishlist. Guildmates see it once your sheet goes out (a few seconds)." or why)
end)
