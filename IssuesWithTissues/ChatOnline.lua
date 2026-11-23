-- Chat (3 of 4): who's online, by rank, beside the chat.

local _, ns = ...

local Chat = ns.Chat

---------------------------------------------------------------------------
-- Who's online, by rank, beside the chat (offline members are left out)
---------------------------------------------------------------------------
Chat.ONLINE_WIDTH = 150
Chat.ONLINE_ROW = 14

-- { {rank = "Guild Master", count = 1}, {key = "Large Joseph", m = member}, ... } with ranks in
-- guild order (Guild Master first) and names A to Z within each rank.
function Chat.OnlineRows()
	local byRank, order = {}, {}
	local total = 0
	for key, m in pairs(ns.Roster.members or {}) do
		if m.online then
			local r = m.rankIndex or 99
			if not byRank[r] then
				byRank[r] = { name = m.rank or ("Rank " .. (r + 1)), list = {} }
				order[#order + 1] = r
			end
			table.insert(byRank[r].list, key)
			total = total + 1
		end
	end
	table.sort(order)
	local rows = {}
	for _, r in ipairs(order) do
		local g = byRank[r]
		table.sort(g.list, function(a, b) return ns.Roster.DisplayName(a) < ns.Roster.DisplayName(b) end)
		rows[#rows + 1] = { rank = g.name, count = #g.list }
		for _, key in ipairs(g.list) do rows[#rows + 1] = { key = key, m = ns.Roster.members[key] } end
	end
	return rows, total
end

function Chat.BuildOnline(panel)
	local UI = ns.UI
	local f = CreateFrame("Frame", nil, panel)
	f:SetPoint("TOPRIGHT", 0, -30)
	f:SetPoint("BOTTOMRIGHT", 0, 34)
	f:SetWidth(Chat.ONLINE_WIDTH)
	UI.Skin(f, UI.COLORS.input, UI.COLORS.dim)
	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	title:SetPoint("TOPLEFT", 8, -6)
	title:SetText("Online")
	f.title = title
	f.rows, f.offset = {}, 0
	f:EnableMouseWheel(true)
	f:SetScript("OnMouseWheel", function(self, delta)
		self.offset = math.max(0, self.offset - delta * 3)
		Chat.DrawOnline()
	end)
	f:SetScript("OnSizeChanged", function() Chat.DrawOnline() end)
	Chat.online = f
end

local function OnlineRow(f, i)
	local row = f.rows[i]
	if row then return row end
	row = CreateFrame("Button", nil, f)
	row:SetHeight(Chat.ONLINE_ROW)
	row:SetPoint("TOPLEFT", 4, -22 - (i - 1) * Chat.ONLINE_ROW)
	row:SetPoint("TOPRIGHT", -4, -22 - (i - 1) * Chat.ONLINE_ROW)
	local hl = ns.UI.Fill(row:CreateTexture(nil, "HIGHLIGHT"), ns.UI.COLORS.hover)
	hl:SetAllPoints()
	row.hl = hl
	local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("LEFT", 4, 0)
	text:SetPoint("RIGHT", -2, 0)
	text:SetJustifyH("LEFT")
	text:SetWordWrap(false)
	row.text = text
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	-- Left-click whispers, right-click invites, like the roster page.
	row:SetScript("OnClick", function(self, button)
		if not self.key then return end
		if button == "RightButton" then ns.UI.Invite(self.key) else ns.UI.Whisper(self.key) end
	end)
	row:SetScript("OnEnter", function(self)
		local m = self.key and ns.Roster.members[self.key]
		if not m then return end
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(ns.Roster.DisplayName(self.key), ns.UI.ClassColor(m.classFile))
		GameTooltip:AddLine(string.format("Level %s %s", tostring(m.level or "?"), m.class or ""), 1, 1, 1)
		if m.zone and m.zone ~= "" then GameTooltip:AddLine(m.zone, 0.8, 0.8, 0.8) end
		GameTooltip:AddLine("Click to whisper, right-click to invite", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.rows[i] = row
	return row
end

function Chat.DrawOnline()
	local f = Chat.online
	if not f then return end
	local rows, total = Chat.OnlineRows()
	f.title:SetText("Online (" .. total .. ")")
	local h = f.GetHeight and f:GetHeight() or 0
	local fit = (h and h > 40) and math.floor((h - 26) / Chat.ONLINE_ROW) or 24
	f.offset = math.min(f.offset, math.max(0, #rows - fit))
	for i = 1, math.max(fit, #f.rows) do
		local data = i <= fit and rows[i + f.offset] or nil
		local row = (data or f.rows[i]) and OnlineRow(f, i)
		if row then
			row.key = data and data.key or nil
			if not data then
				row:Hide()
			elseif data.rank then
				row.text:SetText(data.rank .. " (" .. data.count .. ")")
				row.text:SetTextColor(ns.UI.COLORS.gold[1], ns.UI.COLORS.gold[2], ns.UI.COLORS.gold[3])
				row.text:SetPoint("LEFT", 4, 0)
				row.hl:Hide()
				row:Show()
			else
				row.text:SetText(ns.Roster.DisplayName(data.key))
				row.text:SetTextColor(ns.UI.ClassColor(data.m and data.m.classFile))
				row.text:SetPoint("LEFT", 12, 0)
				row.hl:Show()
				row:Show()
			end
		end
	end
	if ns.UI.ThemeTree then ns.UI.ThemeTree(f) end
	return rows
end

local drawOnlineSoon = ns.Coalesce(function() if Chat.Visible() then Chat.DrawOnline() end end)
function Chat.DrawOnlineSoon() drawOnlineSoon() end
ns.Listen("ROSTER_UPDATED", Chat.DrawOnlineSoon)
