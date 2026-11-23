-- "Guild craftable" on item tooltips: a green line when someone in the guild has shared the
-- recipe for the item. Recipe items (Pattern:, Plans:, Formula:...) count when someone already
-- knows the recipe they teach. Nothing is shown otherwise: no line can mean the crafter hasn't
-- installed the addon or scanned yet, so "no" would mislead.

local _, ns = ...

local Tip = ns.RegisterModule("Tooltip", {})
ns.Tooltip = Tip

Tip.TEXT = "Guild craftable"
Tip.COLOR = { 0.25, 1, 0.25 }

-- Words in front of a recipe item's name: "Pattern: Linen Bag" teaches "Linen Bag".
Tip.PREFIXES = { "Recipe", "Pattern", "Plans", "Formula", "Schematic", "Manual" }

-- Item ids and lower-case recipe names in the guild. Rebuilt when the shared recipes change.
local items, names, builtFrom
function Tip.Index()
	local all = ns.Professions.AllRecipes()
	if builtFrom ~= all then
		items, names = {}, {}
		for _, r in ipairs(all) do
			if r.item and r.item > 0 then items[r.item] = true end
			if r.lower ~= "" then names[r.lower] = true end
		end
		builtFrom = all
	end
	return items, names
end

-- The recipe an item teaches, from its name ("Plans: Arcanite Reaper" -> "arcanite reaper").
function Tip.Teaches(itemName)
	if type(itemName) ~= "string" then return nil end
	for _, p in ipairs(Tip.PREFIXES) do
		local rest = itemName:match("^" .. p .. ":%s*(.+)$")
		if rest then return rest:lower() end
	end
end

function Tip.IsCraftable(itemID, itemName)
	local byItem, byName = Tip.Index()
	if itemID and byItem[itemID] then return true end
	local taught = Tip.Teaches(itemName)
	return taught ~= nil and byName[taught] == true
end

-- Adds the line to a tooltip showing an item, once per item shown.
function Tip.Add(tooltip)
	if not ns.db or ns.db.settings.tooltipCraftable == false or not tooltip or not tooltip.GetItem then return end
	local name, link = tooltip:GetItem()
	local id = link and tonumber(link:match("item:(%d+)"))
	if not id and not name then return end
	if tooltip.iwtShown == (link or name) then return end
	if Tip.IsCraftable(id, name) then
		tooltip.iwtShown = link or name
		tooltip:AddLine(Tip.TEXT, Tip.COLOR[1], Tip.COLOR[2], Tip.COLOR[3])
		if tooltip.Show then tooltip:Show() end -- resize to fit the new line
	end
end

local function Clear(tooltip) tooltip.iwtShown = nil end

-- Newer clients run post-calls for every item tooltip; older ones fire OnTooltipSetItem.
function Tip.Hook()
	if Tip.hooked then return end
	Tip.hooked = true
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip) pcall(Tip.Add, tooltip) end)
		for _, t in ipairs({ GameTooltip, ItemRefTooltip }) do
			if t and t.HookScript then pcall(t.HookScript, t, "OnTooltipCleared", Clear) end
		end
		return
	end
	for _, t in ipairs({ GameTooltip, ItemRefTooltip, ShoppingTooltip1, ShoppingTooltip2 }) do
		if t and t.HookScript then
			pcall(t.HookScript, t, "OnTooltipSetItem", function(self) pcall(Tip.Add, self) end)
			pcall(t.HookScript, t, "OnTooltipCleared", Clear)
		end
	end
end

function Tip:OnLogin()
	Tip.Hook()
end

