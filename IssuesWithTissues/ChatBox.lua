-- Chat (4 of 4): the Chat page: channel buttons, the lines, unread counts and the box to type in.

local _, ns = ...

local Chat = ns.Chat

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------
function Chat.CanOfficer()
	if ns.Roster.IsOfficer(ns.PlayerName()) then return true end
	return #Chat.View("officer") > 0
end

function Chat.Visible()
	return Chat.panel ~= nil and Chat.panel.IsVisible ~= nil and Chat.panel:IsVisible() and true or false
end

-- Online/offline lines are always kept; Settings can leave them out of the page.
function Chat.Shown(e)
	return e.k ~= "sys" or ns.db.settings.chatOnlineLines ~= false
end

-- Unread: what guildmates said. Not online/offline lines, the message of the day or your own.
function Chat.CountsAsUnread(kind, author)
	if kind ~= "msg" then return false end
	local who = author and ns.Roster.ParseName(author)
	return not (who and ns.FullName(who) == ns.PlayerName())
end

-- On the Chat tab ("Chat (3)") and the minimap button.
function Chat.UpdateBadge()
	for _, g in ipairs(ns.UI.tabs or {}) do
		if g.title == "Chat" and g.button then
			g.button:SetText(Chat.unread > 0 and ("Chat (" .. math.min(Chat.unread, 99) .. ")") or "Chat")
		end
	end
	if ns.UI.SetMinimapBadge then ns.UI.SetMinimapBadge(Chat.unread) end
end

function Chat.Redraw()
	local box = Chat.messages
	if not box then return end
	box:Clear()
	if Chat.channel == "guild" then
		local motd = Chat.MOTD()
		if motd then
			local r, g, b = Chat.ChannelColor("guild")
			box:AddMessage("|cff" .. Chat.Hex(r, g, b) .. "Message of the day: " .. motd .. "|r")
		end
	end
	local lines = {}
	for _, e in ipairs(Chat.View(Chat.channel)) do
		if Chat.Shown(e) then lines[#lines + 1] = e end
	end
	for _, e in ipairs(lines) do
		local line = Chat.Display(Chat.channel, e)
		if line then box:AddMessage(line) end
	end
	box:ScrollToBottom()
	Chat.stampsChangeAt = Chat.NextStampChange(lines)
	Chat.unseen = 0
	Chat.UpdateJump()
	if Chat.hint then Chat.hint:SetShown(#lines == 0) end
end

-- Scrolled up: a "Newest" button, with how many lines came in since, takes you back down.
Chat.unseen = 0
function Chat.ScrolledUp()
	local box = Chat.messages
	local offset = box and box.GetScrollOffset and box:GetScrollOffset()
	return type(offset) == "number" and offset > 0
end

function Chat.UpdateJump()
	local b = Chat.jump
	if not b then return end
	if Chat.ScrolledUp() then
		b:SetText(Chat.unseen > 0 and string.format("Newest (%d new)", math.min(Chat.unseen, 999)) or "Newest")
		b:Show()
	else
		Chat.unseen = 0
		b:Hide()
	end
end

function Chat.JumpToNewest()
	if Chat.messages then Chat.messages:ScrollToBottom() end
	Chat.unseen = 0
	Chat.UpdateJump()
end

function Chat.SetChannel(channel)
	if channel == "officer" and not Chat.CanOfficer() then channel = "guild" end
	Chat.channel = channel
	for ch, b in pairs(Chat.channelButtons or {}) do ns.UI.SetSelected(b, ch == channel) end
	if Chat.input and Chat.input.hint then
		Chat.input.hint:SetText(channel == "officer" and "Type to officers, Enter to send" or "Type to the guild, Enter to send")
	end
	Chat.Redraw()
end

local function Build(panel)
	Chat.panel = panel
	local UI = ns.UI
	local guild = UI.Button(panel, "Guild", 80, 22)
	guild:SetPoint("TOPLEFT", 0, 0)
	guild:SetScript("OnClick", function() Chat.SetChannel("guild") end)
	local officer = UI.Button(panel, "Officer", 80, 22)
	officer:SetPoint("LEFT", guild, "RIGHT", 4, 0)
	officer:SetScript("OnClick", function() Chat.SetChannel("officer") end)
	Chat.channelButtons = { guild = guild, officer = officer }

	local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("RIGHT", panel, "TOPRIGHT", -4, -11)
	note:SetText("Shift-click items to link them")

	local frame = CreateFrame("Frame", nil, panel)
	frame:SetPoint("TOPLEFT", 0, -30)
	frame:SetPoint("BOTTOMRIGHT", -(Chat.ONLINE_WIDTH + 6), 34)
	UI.Skin(frame, UI.COLORS.input, UI.COLORS.dim)
	Chat.BuildOnline(panel)

	local box = CreateFrame("ScrollingMessageFrame", nil, frame)
	box:SetPoint("TOPLEFT", 8, -6)
	box:SetPoint("BOTTOMRIGHT", -8, 6)
	box:SetFontObject(_G.ChatFontNormal or "ChatFontNormal")
	UI.PlainFont(box)
	box:SetJustifyH("LEFT")
	box:SetMaxLines(Chat.MAX_LINES + 20)
	box:SetFading(false)
	if box.SetIndentedWordWrap then box:SetIndentedWordWrap(true) end
	if box.SetHyperlinksEnabled then box:SetHyperlinksEnabled(true) end
	box:EnableMouseWheel(true)
	box:SetScript("OnMouseWheel", function(self, delta)
		if IsShiftKeyDown and IsShiftKeyDown() then
			if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
		elseif delta > 0 then self:ScrollUp() else self:ScrollDown() end
		Chat.UpdateJump()
	end)
	-- Item, spell and player links work as in the game's chat (player: left-click whispers,
	-- right-click opens the usual menu).
	box:SetScript("OnHyperlinkClick", function(self, link, text, button)
		if tostring(link):match("^iwttime:") then return end -- our timestamps: hover only
		if SetItemRef then SetItemRef(link, text, button, self) end
	end)
	box:SetScript("OnHyperlinkEnter", function(self, link)
		local kind = tostring(link):match("^(%a+):")
		if kind == "iwttime" then
			GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
			GameTooltip:AddLine(Chat.FullTime(tonumber(link:match(":(%d+)")) or 0), 1, 1, 1)
			GameTooltip:Show()
			return
		end
		if kind == "item" or kind == "spell" or kind == "enchant" then
			GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
			pcall(GameTooltip.SetHyperlink, GameTooltip, link)
			GameTooltip:Show()
		end
	end)
	box:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
	Chat.messages = box
	-- "5 min ago" moves on: while the chat is open at the newest lines, look every half minute
	-- and redraw only when a time label shown would now read differently.
	ns.Every("chatStamps", function()
		local at = Chat.stampsChangeAt
		if at and ns.Now() >= at and Chat.Visible() and not Chat.ScrolledUp() then Chat.Redraw() end
	end)

	local jump = UI.Button(frame, "Newest", 130, 20, "primary")
	jump:SetPoint("BOTTOMRIGHT", -10, 8)
	jump:SetFrameLevel((box.GetFrameLevel and box:GetFrameLevel() or 1) + 5)
	jump:SetScript("OnClick", Chat.JumpToNewest)
	jump:Hide()
	Chat.jump = jump

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	hint:SetPoint("CENTER")
	hint:SetText("No messages yet. New guild chat shows up here.")
	Chat.hint = hint

	local input = UI.CreateInput(panel, 300, "Type to the guild, Enter to send")
	input:ClearAllPoints()
	input:SetPoint("BOTTOMLEFT", 0, 0)
	input:SetPoint("BOTTOMRIGHT", -84, 0)
	input:SetHeight(26)
	input:SetMaxLetters(255)
	if input.SetAltArrowKeyMode then input:SetAltArrowKeyMode(false) end
	-- Enter sends and keeps the box open for the next line, like the game's chat.
	input:SetScript("OnEnterPressed", function(self)
		local text = self:GetText() or ""
		if text ~= "" then
			Chat.Send(text)
			self:SetText("")
		end
		Chat.recall = nil
	end)
	input:SetScript("OnArrowPressed", function(self, key)
		local n = #Chat.sent
		if n == 0 then return end
		if key == "UP" then Chat.recall = math.max(1, (Chat.recall or n + 1) - 1)
		elseif key == "DOWN" then Chat.recall = Chat.recall and Chat.recall + 1 or nil
		else return end
		if Chat.recall and Chat.recall > n then Chat.recall = nil end
		self:SetText(Chat.recall and Chat.sent[Chat.recall] or "")
		if self.SetCursorPosition then self:SetCursorPosition(#(self:GetText() or "")) end
	end)
	Chat.input = input

	local send = UI.Button(panel, "Send", 80, 26, "primary")
	send:SetPoint("BOTTOMRIGHT", 0, 0)
	send:SetScript("OnClick", function()
		local text = input:GetText() or ""
		if text ~= "" and Chat.Send(text) then input:SetText("") end
	end)

	panel:SetScript("OnShow", function()
		Chat.RequestServer()
		ns.Roster.Request()
		Chat.DrawOnline()
		officer:SetShown(Chat.CanOfficer())
		Chat.unread = 0
		Chat.UpdateBadge()
		Chat.SetChannel(Chat.channel)
	end)
	Chat.RequestServer()
	officer:SetShown(Chat.CanOfficer())
	Chat.unread = 0
	Chat.UpdateBadge()
	Chat.SetChannel(Chat.channel)
end

ns.UI.AddPage("Chat", "Chat", Build)

-- New lines go straight into the open page.
ns.Listen("CHAT_LINE", function(channel, entry)
	if Chat.messages and channel == Chat.channel and Chat.Shown(entry) then
		local line = Chat.Display(channel, entry)
		if line then Chat.messages:AddMessage(line) end
		if Chat.hint then Chat.hint:Hide() end
		if Chat.ScrolledUp() then Chat.unseen = Chat.unseen + 1 end
		Chat.UpdateJump()
	end
end)

-- Shift-clicking an item (bags, loot, the auction house...) while our box has focus puts the
-- link in it. A hook after the game's own function: nothing of Blizzard's is replaced.
if hooksecurefunc and ChatEdit_InsertLink then
	hooksecurefunc("ChatEdit_InsertLink", function(link)
		local box = Chat.input
		if box and box.HasFocus and box:HasFocus() and link then box:Insert(link) end
	end)
end

ns.Settings.OnChange("chatHistory", function(on) Chat.SetHistory(on) end)
ns.Settings.OnChange("clock24", function() Chat.Redraw() end)
ns.Settings.OnChange("relativeTimes", function() Chat.Redraw() end)
ns.Settings.OnChange("chatOnlineLines", function() Chat.Redraw() end)

ns.RegisterCommand("chat", "open guild chat", function() ns.UI.Open("Chat") end)
