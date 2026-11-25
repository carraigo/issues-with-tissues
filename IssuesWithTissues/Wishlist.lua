-- Wishlists (1.4.0): items each character would like. They travel in the character sheet
-- (Sheet.lua, fourth field, as item ids), so crafters and officers can see who wants what:
-- on item tooltips ("Wanted by 3 guildmates"), and on Crafting > Wishlists with who can make it.
-- Add an item by shift-clicking it while the page's box has focus, alt-clicking it anywhere, or
-- with /iwt wish <item>. When a wished item reaches your bags it comes off the list by itself,
-- and the guild news says so (the sheet's fifth field lists the week's wishes that came true).

local _, ns = ...

local W = ns.RegisterModule("Wishlist", {})
ns.Wishlist = W

W.MAX = 30 -- items per character
W.GOT_KEEP = 7 * 86400 -- a wish that came true stays in the sheet (and so the news) this long

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
	-- How many we have now: it comes off the list once we have more than this.
	ns.char.wishHave = ns.char.wishHave or {}
	ns.char.wishHave[id] = W.Count(id)
	Changed()
	return true
end

-- How many of an item are in the bags or worn.
function W.Count(id)
	if not GetItemCount then return 0 end
	local ok, n = pcall(GetItemCount, id)
	return ok and tonumber(n) or 0
end

function W.Remove(id)
	local list = List()
	for i, x in ipairs(list) do
		if x == id then
			table.remove(list, i)
			if ns.char.wishHave then ns.char.wishHave[id] = nil end
			Changed()
			return true
		end
	end
	return false
end

---------------------------------------------------------------------------
-- Wishes that came true
---------------------------------------------------------------------------
-- Wished items now in the bags come off the list: { id, ... } of those that did.
function W.CheckBags()
	local have, got = ns.char.wishHave or {}, {}
	for _, id in ipairs(W.Mine()) do
		if W.Count(id) > (have[id] or 0) then got[#got + 1] = id end
	end
	if #got == 0 then return got end
	ns.char.wishGot = ns.char.wishGot or {}
	local now = ns.Now()
	for _, id in ipairs(got) do
		W.Remove(id)
		table.insert(ns.char.wishGot, { id = id, t = now })
		if ns.News then ns.News.Add("got", ns.PlayerName(), nil, { item = id }) end
		ns.Print("%s came off your wishlist. Enjoy!", W.Name(id) or ("Item " .. id))
	end
	return got
end

-- Item ids of this character's wishes that came true in the last week (for the sheet).
function W.GotRecently()
	local list, now, out = ns.char.wishGot or {}, ns.Now(), {}
	for i = #list, 1, -1 do
		if now - list[i].t > W.GOT_KEEP then table.remove(list, i) end
	end
	for _, g in ipairs(list) do out[#out + 1] = g.id end
	table.sort(out)
	return out
end

-- Guildmates' wishes that came true go in this PC's guild news, once each.
function W.NewsFromSheets()
	local db, me, added = ns.db, ns.PlayerName(), 0
	db.wishGotSeen = db.wishGotSeen or {}
	for who, s in pairs(ns.Sheet.All()) do
		if who ~= me and s.got and ns.Roster.IsMember(who) then
			local seen, now = db.wishGotSeen[who] or {}, {}
			for _, id in ipairs(s.got) do
				now[id] = true
				if not seen[id] and ns.News and ns.News.Add("got", who, nil, { item = id }) then added = added + 1 end
			end
			db.wishGotSeen[who] = next(now) and now or nil
		end
	end
	return added
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
	list:SetEmpty("No wishes yet. Alt-click any item you'd like (in your bags, chat or loot), or shift-click one into the box above. It comes off by itself once it reaches your bags. Crafters and officers see who wants what.")
	panel:SetScript("OnShow", W.Refresh)
	W.list = list
	W.Refresh()
end
ns.UI.AddPage("Crafting", "Wishlists", Build, { order = 20 })

local Soon = ns.Coalesce(function() W.Refresh() end, 0.5)
ns.Listen("ROSTER_UPDATED", Soon)
ns.Listen("WISHLIST_CHANGED", Soon)
local NewsSoon = ns.Coalesce(function() W.NewsFromSheets() end, 2)
ns.Listen("SYNC_CHANGED", function(set)
	if set == "sheet" or set == "recipes" then Soon() end
	if set == "sheet" then NewsSoon() end
end)
local BagsSoon = ns.Coalesce(function() W.CheckBags() end, 1)
pcall(ns.On, "BAG_UPDATE_DELAYED", function() if ns.char.wish and #ns.char.wish > 0 then BagsSoon() end end)
pcall(ns.On, "GET_ITEM_INFO_RECEIVED", function(_, id) if asked[tonumber(id)] then Soon() end end)

-- Items wished for before 1.4.0-beta.2 start counting from what's in the bags now.
function W:OnLogin()
	ns.char.wishHave = ns.char.wishHave or {}
	for _, id in ipairs(W.Mine()) do
		if not ns.char.wishHave[id] then ns.char.wishHave[id] = W.Count(id) end
	end
end

-- Alt-click (on its own) an item anywhere, in bags, chat links or loot: on or off the wishlist.
function W.Toggle(item)
	local id = W.ItemId(item)
	if not id then return false end
	local name = W.Name(id) or ("Item " .. id)
	if W.Has(id) then
		W.Remove(id)
		ns.Print("%s taken off your wishlist.", name)
		return true
	end
	local ok, why = W.Add(id)
	ns.Print(ok and "%s added to your wishlist (alt-click it again to take it off)." or why, name)
	return ok
end

function W.OnModifiedClick(link)
	if ns.db.settings.altClickWish == false then return false end
	if not (IsAltKeyDown and IsAltKeyDown()) or (IsShiftKeyDown and IsShiftKeyDown()) or (IsControlKeyDown and IsControlKeyDown()) then
		return false
	end
	link = ns.Readable(link)
	if not link or not link:find("item:%d+") then return false end
	return W.Toggle(link)
end
if hooksecurefunc and HandleModifiedItemClick then
	hooksecurefunc("HandleModifiedItemClick", function(link) pcall(W.OnModifiedClick, link) end)
end

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
