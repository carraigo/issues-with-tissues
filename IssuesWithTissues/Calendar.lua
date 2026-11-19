-- Guild life > Calendar: guild events added by officers, and sign-ups from everyone.
--
-- "events" (officers): key = id, data = "time;title;note"
-- "signups" (owner):   key = character, data = "id=T,id=H" (T tank, H healer, D damage,
--                      M maybe, N can't come), upcoming events only

local _, ns = ...

local Cal = ns.RegisterModule("Calendar", {})
ns.Calendar = Cal

ns.Sync.Define("events", { writer = "officer", max = 60 })
ns.Sync.Define("signups", { writer = "owner" })

Cal.ROLES = {
	{ key = "T", label = "Tank" },
	{ key = "H", label = "Healer" },
	{ key = "D", label = "Damage" },
	{ key = "M", label = "Maybe" },
	{ key = "N", label = "Can't come" },
}
Cal.KEEP_PAST = 3 * 3600 -- an event stays listed this long after it starts
Cal.DAYS_AHEAD = 28

local function RoleLabel(key)
	for _, r in ipairs(Cal.ROLES) do if r.key == key then return r.label end end
end

local function Clean(text, max)
	return (tostring(text or ""):gsub("[|;=,\30\31]", ""):gsub("^%s+", ""):gsub("%s+$", "")):sub(1, max)
end

function Cal.Decode(data)
	local t, title, note = tostring(data or ""):match("^(%d+);([^;]*);(.*)$")
	if not t then return nil end
	return { time = tonumber(t), title = title, note = note }
end

-- The time of day `dayOffset` days from today at "HH:MM" (local clock).
function Cal.TimeOf(dayOffset, hhmm)
	local h, m = tostring(hhmm or ""):match("^%s*(%d%d?)[:.]?(%d?%d?)%s*$")
	h, m = tonumber(h), tonumber(m) or 0
	if not h or h > 23 or m > 59 then return nil end
	local d = date("*t", ns.Now() + (dayOffset or 0) * 86400)
	return time({ year = d.year, month = d.month, day = d.day, hour = h, min = m, sec = 0 })
end

-- Officers: add an event (or change one, with id).
function Cal.Add(title, when, note, id)
	title = Clean(title, 40)
	if title == "" then return false, "Give the event a name." end
	if not when then return false, "Give a time like 20:00." end
	if not id then
		id = tostring(ns.Now())
		while ns.Sync.Get("events", id) do id = tostring(tonumber(id) + 1) end
	end
	return ns.Sync.Set("events", id, string.format("%d;%s;%s", when, title, Clean(note, 80)))
end
function Cal.Remove(id) return ns.Sync.Delete("events", id) end

local function SignupsOf(who)
	local out = {}
	for id, r in tostring(ns.Sync.Get("signups", who) or ""):gmatch("(%d+)=(%a)") do out[id] = r end
	return out
end
Cal.SignupsOf = SignupsOf

-- Sign this character up as role (a key from Cal.ROLES), or nil to take the sign-up back.
function Cal.SignUp(id, role)
	local e = Cal.Decode(ns.Sync.Get("events", id))
	if not e or e.time < ns.Now() - Cal.KEEP_PAST then return false end
	if role and not RoleLabel(role) then return false end
	local mine, parts = SignupsOf(ns.PlayerName()), {}
	mine[id] = role
	for eid, r in pairs(mine) do
		local ev = Cal.Decode(ns.Sync.Get("events", eid))
		if ev and ev.time >= ns.Now() - Cal.KEEP_PAST then parts[#parts + 1] = eid .. "=" .. r end
	end
	table.sort(parts)
	return ns.Sync.Set("signups", ns.PlayerName(), table.concat(parts, ","))
end

-- Who signed up for event id: { T = { names }, H = ..., count = coming (not M or N) }.
function Cal.Signups(id)
	local out = { count = 0 }
	for _, r in ipairs(Cal.ROLES) do out[r.key] = {} end
	for who, data in ns.Sync.Each("signups") do
		local r = tostring(data):match("%f[%d]" .. id .. "=(%a)")
		if r and out[r] and ns.Roster.IsMember(who) then
			table.insert(out[r], ns.Roster.DisplayName(who))
			if r ~= "M" and r ~= "N" then out.count = out.count + 1 end
		end
	end
	for _, r in ipairs(Cal.ROLES) do table.sort(out[r.key]) end
	return out
end

-- Upcoming events, soonest first.
function Cal.Upcoming()
	local now, out = ns.Now(), {}
	for id, data in ns.Sync.Each("events") do
		local e = Cal.Decode(data)
		if e and e.time >= now - Cal.KEEP_PAST then
			e.id = id
			e.signups = Cal.Signups(id)
			e.mine = SignupsOf(ns.PlayerName())[id]
			out[#out + 1] = e
		end
	end
	table.sort(out, function(a, b) return a.time < b.time end)
	return out
end

function Cal.When(t)
	local now = ns.Now()
	local today = date("%Y%m%d", now)
	local day = date("%Y%m%d", t)
	local label
	if day == today then label = "Today"
	elseif day == date("%Y%m%d", now + 86400) then label = "Tomorrow"
	else label = date("%a %d %b", t) end
	return label .. " " .. date("%H:%M", t)
end

function Cal.RoleSummary(s)
	local parts = {}
	for _, r in ipairs(Cal.ROLES) do
		if #s[r.key] > 0 and r.key ~= "N" then parts[#parts + 1] = #s[r.key] .. " " .. r.label:lower() end
	end
	return #parts > 0 and table.concat(parts, ", ") or "nobody yet"
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------
local list, officerRow, titleBox, dayButton, timeBox, noteBox, roleButtons, detail, removeButton, leaveButton
Cal.form = { day = 0 }

local function DayLabel(offset)
	if offset == 0 then return "Today" end
	if offset == 1 then return "Tomorrow" end
	return date("%a %d %b", ns.Now() + offset * 86400)
end

function Cal.Refresh()
	if not Cal.panel or not Cal.panel:IsShown() then return end
	local officer = ns.Roster.IsOfficer(ns.PlayerName())
	officerRow:SetShown(officer)
	dayButton:SetText(DayLabel(Cal.form.day))
	local events = Cal.Upcoming()
	local sel
	for _, e in ipairs(events) do if e.id == Cal.selected then sel = e end end
	sel = sel or events[1]
	Cal.selected = sel and sel.id
	list:SetRows(events, function(e, key)
		local r, g, b = 1, 1, 1
		if e == sel then r, g, b = 0.96, 0.82, 0.48 end
		if key == "when" then return Cal.When(e.time), r, g, b end
		if key == "title" then return e.title, r, g, b end
		if key == "coming" then return e.signups.count .. " coming", r, g, b end
		if key == "mine" then return e.mine and RoleLabel(e.mine) or "", r, g, b end
	end)
	for _, b in ipairs(roleButtons) do
		b:SetShown(sel ~= nil)
		if sel then ns.UI.SetSelected(b, sel.mine == b.role) end
	end
	leaveButton:SetShown(sel ~= nil and sel.mine ~= nil)
	removeButton:SetShown(officer and sel ~= nil)
	if not sel then
		detail:SetText("No events coming up." .. (officer and "" or " Officers add guild events here."))
	else
		local lines = { sel.title .. "  |cff999999" .. Cal.When(sel.time) .. "|r" }
		if sel.note ~= "" then lines[#lines + 1] = sel.note end
		for _, r in ipairs(Cal.ROLES) do
			local names = sel.signups[r.key]
			if #names > 0 then lines[#lines + 1] = "|cffffd100" .. r.label .. ":|r " .. table.concat(names, ", ") end
		end
		detail:SetText(table.concat(lines, "\n"))
	end
end

local function Build(panel)
	Cal.panel = panel
	officerRow = CreateFrame("Frame", nil, panel)
	officerRow:SetPoint("TOPLEFT", 0, 0)
	officerRow:SetSize(616, 24)
	titleBox = ns.UI.CreateInput(officerRow, 160, "Event, e.g. Deadmines run")
	titleBox:SetPoint("TOPLEFT", 4, 0)
	dayButton = ns.UI.Button(officerRow, nil, 100, 22)
	dayButton:SetPoint("LEFT", titleBox, "RIGHT", 6, 0)
	dayButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	dayButton:SetScript("OnClick", function(_, button)
		local step = button == "RightButton" and -1 or 1
		Cal.form.day = (Cal.form.day + step) % Cal.DAYS_AHEAD
		Cal.Refresh()
	end)
	timeBox = ns.UI.CreateInput(officerRow, 60, "20:00")
	timeBox:SetPoint("LEFT", dayButton, "RIGHT", 6, 0)
	noteBox = ns.UI.CreateInput(officerRow, 150, "Note (optional)")
	noteBox:SetPoint("LEFT", timeBox, "RIGHT", 6, 0)
	local add = ns.UI.Button(officerRow, "Add event", 100, 22, "primary")
	add:SetPoint("LEFT", noteBox, "RIGHT", 6, 0)
	add:SetScript("OnClick", function()
		local ok, why = Cal.Add(titleBox:GetText(), Cal.TimeOf(Cal.form.day, timeBox:GetText()), noteBox:GetText())
		if ok then
			titleBox:SetText(""); noteBox:SetText("")
		elseif why then
			ns.Print(why)
		end
		Cal.Refresh()
	end)

	list = ns.UI.CreateList(panel, {
		top = -34, rows = 8,
		columns = {
			{ key = "when", label = "When", width = 150 },
			{ key = "title", label = "Event", width = 260 },
			{ key = "coming", label = "Signed up", width = 90 },
			{ key = "mine", label = "You", width = 100 },
		},
		onClick = function(e) Cal.selected = e.id; Cal.Refresh() end,
	})

	roleButtons = {}
	local prev
	for _, r in ipairs(Cal.ROLES) do
		local b = ns.UI.Button(panel, r.label, 92, 24)
		if prev then b:SetPoint("LEFT", prev, "RIGHT", 6, 0) else b:SetPoint("TOPLEFT", 4, -210) end
		b.role = r.key
		b:SetScript("OnClick", function() if Cal.selected then Cal.SignUp(Cal.selected, r.key) end Cal.Refresh() end)
		roleButtons[#roleButtons + 1] = b
		prev = b
	end
	leaveButton = ns.UI.Button(panel, "Take back", 90, 24)
	leaveButton:SetPoint("LEFT", prev, "RIGHT", 6, 0)
	leaveButton:SetScript("OnClick", function() if Cal.selected then Cal.SignUp(Cal.selected, nil) end Cal.Refresh() end)

	detail = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	detail:SetPoint("TOPLEFT", 4, -246)
	detail:SetWidth(600)
	detail:SetJustifyH("LEFT")
	detail:SetJustifyV("TOP")
	removeButton = ns.UI.Button(panel, "Remove event", 110, 22)
	removeButton:SetPoint("BOTTOMLEFT", 4, 4)
	removeButton:SetScript("OnClick", function()
		if Cal.selected then Cal.Remove(Cal.selected); Cal.selected = nil end
		Cal.Refresh()
	end)
	panel:SetScript("OnShow", Cal.Refresh)
	Cal.Refresh()
end

ns.UI.AddPage("Guild life", "Calendar", Build, { order = 10 })

ns.Listen("SYNC_CHANGED", function(set)
	if set == "events" or set == "signups" then Cal.Refresh(); ns.Send("GUILD_LIFE_CHANGED") end
end)
