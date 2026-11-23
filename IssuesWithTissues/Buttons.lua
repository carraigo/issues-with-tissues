-- The minimap button, the button on the game's guild window, and the key bindings.

local _, ns = ...

local UI = ns.UI

---------------------------------------------------------------------------
-- Minimap button (no library: a round button that can be dragged around the edge).
---------------------------------------------------------------------------
local mini
-- On the rim, however big the minimap is: other addons (and some UI packs) make it larger or
-- square, so the distance comes from its size (80 on the default 140-wide map).
function UI.MinimapOffset(angleDeg, width, height, shape)
	local a = math.rad(angleDeg or 220)
	local x, y = math.cos(a), math.sin(a)
	local rx, ry = (width or 140) / 2 + 10, (height or width or 140) / 2 + 10
	if shape == "SQUARE" then
		-- Out to the square's edge rather than a circle inside it.
		local m = math.max(math.abs(x), math.abs(y))
		if m > 0 then x, y = x / m, y / m end
	end
	return x * rx, y * ry
end

local function PlaceMini()
	local shape = type(GetMinimapShape) == "function" and GetMinimapShape() or "ROUND"
	local x, y = UI.MinimapOffset(ns.db.minimapAngle, Minimap:GetWidth(), Minimap:GetHeight(), shape)
	mini:ClearAllPoints()
	mini:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function UI.CreateMinimapButton()
	if mini or not Minimap then return end
	mini = CreateFrame("Button", "IwTMinimapButton", Minimap)
	mini:SetSize(31, 31)
	mini:SetFrameStrata("MEDIUM")
	mini:SetFrameLevel(8)
	mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local icon = mini:CreateTexture(nil, "BACKGROUND")
	icon:SetTexture("Interface\\Icons\\INV_Misc_Bandage_15")
	icon:SetSize(20, 20)
	icon:SetPoint("CENTER", 0, 1)
	local border = mini:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	mini:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	mini:RegisterForDrag("LeftButton")
	mini:SetScript("OnClick", function(_, button)
		if button == "RightButton" then UI.Open("Settings") else UI.Toggle() end
	end)
	mini:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			ns.db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
			PlaceMini()
		end)
	end)
	mini:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	mini:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Issues with Tissues")
		GameTooltip:AddLine("Left-click: open", 1, 1, 1)
		GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
		GameTooltip:Show()
	end)
	mini:SetScript("OnLeave", function() GameTooltip:Hide() end)
	if Minimap.HookScript then Minimap:HookScript("OnSizeChanged", PlaceMini) end
	PlaceMini()
end

function UI.UpdateMinimapButton()
	if ns.db.settings.minimap then
		UI.CreateMinimapButton()
		if mini then mini:Show() end
	elseif mini then
		mini:Hide()
	end
end

---------------------------------------------------------------------------
-- Guild-frame button: whichever guild window this client has (GuildFrame or
-- CommunitiesFrame), loaded on demand by the game.
---------------------------------------------------------------------------
local guildButton
function UI.AttachGuildButton()
	if guildButton then return end
	local host = _G.CommunitiesFrame or _G.GuildFrame
	if not host then return end
	guildButton = UI.Button(host, "Tissues", 70, 22)
	guildButton:SetPoint("TOPRIGHT", host, "TOPRIGHT", -30, -28)
	guildButton:SetScript("OnClick", function() UI.Toggle() end)
	UI.UpdateGuildButton()
end

-- Open the game's own guild window, whichever this client has.
function UI.OpenGameGuildWindow()
	if ToggleGuildFrame then return pcall(ToggleGuildFrame) end
	if ToggleFriendsFrame then return pcall(ToggleFriendsFrame, 3) end
end

-- Key bindings (Bindings.xml): Esc menu > Options > Key Bindings > Issues with Tissues.
-- Binding "Open or close the window" to the guild key (J) opens this window instead of the
-- game's. The bindings use a category (its own expandable section in the list); the old
-- header attribute showed up on this client as a stray bindable row.
BINDING_HEADER_ISSUESWITHTISSUES = "Issues with Tissues"
BINDING_NAME_IWT_TOGGLE = "Open or close the window"
BINDING_NAME_IWT_CHAT = "Open guild chat"
function IssuesWithTissues_Toggle() UI.Toggle() end
function IssuesWithTissues_Chat()
	local f = UI.Create()
	if f:IsShown() and ns.Chat and ns.Chat.Visible() then f:Hide() else UI.Open("Chat") end
end

function UI.UpdateGuildButton()
	if guildButton then guildButton:SetShown(ns.db.settings.guildButton) end
end

ns.On("ADDON_LOADED", function(_, name)
	if name == "Blizzard_Communities" or name == "Blizzard_GuildUI" then UI.AttachGuildButton() end
end)

function UI:OnLogin()
	UI.UpdateMinimapButton()
	UI.AttachGuildButton()
end
