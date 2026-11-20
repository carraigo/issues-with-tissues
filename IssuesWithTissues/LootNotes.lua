-- Guild life > Loot notes: officers note who received which item (and why), so the guild has a
-- shared record. Notes only: there are no points or priorities. Everyone can read and search.
--
-- "loot" (officers): key = id, data = "time;player;itemID;item name;note"
-- Officers can shift-click an item into the item box, or type its name.

local _, ns = ...

local Loot = ns.RegisterModule("LootNotes", {})
ns.LootNotes = Loot

ns.Sync.Define("loot", { writer = "officer", max = 800 })

local Clean = ns.CleanText

-- "|cffa335ee|Hitem:19019::...|h[Thunderfury]|h|r" -> 19019, "Thunderfury"; plain text -> nil, text
function Loot.ParseItem(text)
	text = tostring(text or "")
	local id, name = text:match("|Hitem:(%d+)[^|]*|h%[([^%]]+)%]|h")
	if id then return tonumber(id), name end
	return nil, Clean(text:gsub("^%[", ""):gsub("%]$", ""), 60)
end

function Loot.Decode(data)
	local t, player, id, item, note = tostring(data or ""):match("^(%d+);([^;]*);(%d*);([^;]*);(.*)$")
	if not t then return nil end
	return { time = tonumber(t), player = player, itemID = tonumber(id), item = item, note = note }
end

-- Officers: note that player got item. player: a guildmate's name (first name is enough when
-- only one guildmate has it).
function Loot.Add(player, itemText, note)
	local who = ns.FullName(Clean(player, 40))
	if not who or not ns.Roster.IsMember(who) then return false, "Give the name of a guildmate." end
	local id, name = Loot.ParseItem(itemText)
	if not name or name == "" then return false, "Give the item (shift-click it into the box, or type its name)." end
	local key = tostring(ns.Now())
	while ns.Sync.Get("loot", key) do key = tostring(tonumber(key) + 1) end
	return ns.Sync.Set("loot", key, string.format("%d;%s;%s;%s;%s", ns.Now(), who, id or "", Clean(name, 60), Clean(note, 100)))
end

function Loot.Remove(key) return ns.Sync.Delete("loot", key) end

-- Notes, newest first, matching search (player, item or note; any case).
function Loot.List(search)
	local out = {}
	search = tostring(search or ""):lower()
	for key, data in ns.Sync.Each("loot") do
		local n = Loot.Decode(data)
		if n then
			local hay = (ns.Roster.DisplayName(n.player) .. " " .. n.item .. " " .. n.note):lower()
			if search == "" or hay:find(search, 1, true) then
				n.key = key
				out[#out + 1] = n
			end
		end
	end
	table.sort(out, function(a, b) return a.time > b.time end)
	return out
end

-- How many items a player has been noted for (alts counted with their main).
function Loot.CountFor(player)
	local main, n = ns.Alts.MainOf(ns.FullName(player) or player), 0
	for _, note in ipairs(Loot.List()) do
		if ns.Alts.MainOf(note.player) == main then n = n + 1 end
	end
	return n
end

local function ItemColor(id)
	if id and GetItemInfo then
		local _, _, quality = GetItemInfo(id)
		local c = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
		if c then return c.r, c.g, c.b end
	end
	return 1, 1, 1
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------
local list, officerRow, playerBox, itemBox, noteBox, searchBox, removeButton, status
Loot.search = ""

function Loot.Refresh()
	if not Loot.panel or not Loot.panel:IsShown() then return end
	local officer = ns.Roster.IsOfficer(ns.PlayerName())
	officerRow:SetShown(officer)
	local notes = Loot.List(Loot.search)
	local sel
	for _, n in ipairs(notes) do if n.key == Loot.selected then sel = n end end
	Loot.selected = sel and sel.key
	list:SetRows(notes, function(n, key)
		if key == "when" then return date("%d %b %Y", n.time), 0.7, 0.7, 0.7 end
		if key == "player" then
			local m = ns.Roster.Get(n.player)
			return ns.Roster.DisplayName(n.player), ns.UI.ClassColor(m and m.classFile)
		end
		if key == "item" then return n.item, ItemColor(n.itemID) end
		if key == "note" then return n.note end
	end)
	removeButton:SetShown(officer and sel ~= nil)
	status:SetText(#notes .. (Loot.search ~= "" and " matching notes." or " notes.")
		.. (officer and " Click a note to select it." or "") .. " Hover an item to see it.")
end

local function Build(panel)
	Loot.panel = panel
	officerRow = CreateFrame("Frame", nil, panel)
	officerRow:SetPoint("TOPLEFT", 0, 0)
	officerRow:SetSize(616, 24)
	playerBox = ns.UI.CreateInput(officerRow, 140, "Guildmate")
	playerBox:SetPoint("TOPLEFT", 4, 0)
	ns.UI.AttachNameSuggest(playerBox) -- type part of a name, pick the guildmate
	playerBox.onPick = function() itemBox:SetFocus() end
	itemBox = ns.UI.CreateInput(officerRow, 170, "Item (shift-click it here)")
	itemBox:SetMaxLetters(255)
	itemBox:SetPoint("LEFT", playerBox, "RIGHT", 6, 0)
	noteBox = ns.UI.CreateInput(officerRow, 180, "Note, e.g. main spec, MC")
	noteBox:SetPoint("LEFT", itemBox, "RIGHT", 6, 0)
	local add = ns.UI.Button(officerRow, "Add note", 90, 22, "primary")
	add:SetPoint("LEFT", noteBox, "RIGHT", 6, 0)
	add:SetScript("OnClick", function()
		local ok, why = Loot.Add(playerBox:GetText(), itemBox:GetText(), noteBox:GetText())
		if ok then
			itemBox:SetText(""); noteBox:SetText("")
		elseif why then
			ns.Print(why)
		end
		Loot.Refresh()
	end)
	Loot.itemBox, Loot.playerBox = itemBox, playerBox

	searchBox = ns.UI.CreateInput(panel, 250, "Search player, item or note")
	searchBox:SetPoint("TOPLEFT", 4, -30)
	searchBox.onChange = function(text) Loot.search = text; Loot.Refresh() end
	status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("LEFT", searchBox, "RIGHT", 10, 0)

	list = ns.UI.CreateList(panel, {
		top = -62, rows = 16,
		columns = {
			{ key = "when", label = "Date", width = 90 },
			{ key = "player", label = "Given to", width = 150 },
			{ key = "item", label = "Item", width = 190 },
			{ key = "note", label = "Note", width = 176 },
		},
		onClick = function(n) Loot.selected = n.key; Loot.Refresh() end,
		onEnter = function(_, n)
			if n.itemID then
				GameTooltip:SetHyperlink("item:" .. n.itemID)
			else
				GameTooltip:AddLine(n.item)
			end
			if n.note ~= "" then GameTooltip:AddLine(n.note, 1, 1, 1, true) end
			GameTooltip:AddLine(ns.Roster.DisplayName(n.player) .. ", " .. date("%d %b %Y", n.time), 0.7, 0.7, 0.7)
		end,
	})
	removeButton = ns.UI.Button(panel, "Remove note", 110, 22)
	removeButton:SetPoint("BOTTOMLEFT", 4, 0)
	removeButton:SetScript("OnClick", function()
		if Loot.selected then Loot.Remove(Loot.selected); Loot.selected = nil end
		Loot.Refresh()
	end)
	panel:SetScript("OnShow", Loot.Refresh)
	Loot.Refresh()
end

ns.UI.AddPage("Guild life", "Loot notes", Build, { order = 40 })

-- Shift-clicking an item while the item box has (or just had) focus puts its link there.
-- Clients differ in which function a shift-click goes through, so several are watched.
Loot.hooks = {}
function Loot.TakeLink(link)
	local box = Loot.itemBox
	if type(link) ~= "string" or not link:find("|Hitem:") or not box or not box:IsVisible() then return end
	local recently = box.focusLostAt and GetTime and (GetTime() - box.focusLostAt) < 1.5
	if box:HasFocus() or recently then
		box:SetText(link)
		box:SetFocus()
		return true
	end
end
if hooksecurefunc then
	local function Watch(owner, name)
		local ok = owner and type(owner[name]) == "function" and pcall(hooksecurefunc, owner, name, function(...)
			for i = 1, select("#", ...) do
				local v = select(i, ...)
				if type(v) == "string" and v:find("|Hitem:") then return Loot.TakeLink(v) end
			end
		end)
		if ok then Loot.hooks[#Loot.hooks + 1] = name end
	end
	Watch(_G, "ChatEdit_InsertLink")
	Watch(_G, "HandleModifiedItemClick")
	Watch(_G.ChatFrameUtil, "InsertLink")
end

local Soon = ns.Coalesce(function() Loot.Refresh() end)
ns.Listen("SYNC_CHANGED", function(set) if set == "loot" then Soon() end end)
ns.Listen("ROSTER_UPDATED", Soon)
