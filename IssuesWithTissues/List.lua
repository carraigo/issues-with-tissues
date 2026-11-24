-- The list page builder (UI.CreateList), shared by every board. Moved out of Widgets.lua,
-- which holds the smaller building blocks it uses (buttons, rows, inputs).

local _, ns = ...

local UI = ns.UI
local C = UI.COLORS

---------------------------------------------------------------------------
-- The list page builder, shared by every board (Roster, Officers, Raid, Crafters, Loot notes,
-- Polls, Donations): column titles, rows, scrolling, an empty message, and optionally sorting,
-- filter buttons, a search box, a count line and a remembered choice of sort and filter.
--   local list = UI.CreateList(panel, {
--       top = -60, rows = 15,
--       columns = { { key, label, width, sort = true | fn(row), desc = true }, ... },
--       filters = { { key, label, test = fn(row) }, ... },  -- buttons along the top
--       search = { width, hint, text = fn(row), onEnter = fn(firstRow) },
--       state = {}, save = "raid",           -- the choices; saved per PC under db.lists[save]
--       source = fn(state),                  -- rows already filtered and sorted (else the list does it)
--       count = fn(shown, all),              -- the line along the bottom
--       cell = fn(row, key),                 -- or given to SetRows
--       onClick = fn(row, button), onEnter = fn(line, row), onChange = fn(list) })
--   list:SetRows(rows, function(row, key) return text, r, g, b end)
--   list:Refresh()  (take the source again)  /  list:Draw()  (repaint only)
-- Sorting: click a column title; again to reverse. A column's sort value is row[key] unless
-- `sort` is a function; ties go by row.name.
---------------------------------------------------------------------------
local function SortValue(col, row)
	if type(col.sort) == "function" then return col.sort(row) end
	return row[col.key]
end

function UI.SortRows(rows, columns, key, desc)
	local col
	for _, c in ipairs(columns) do if c.key == key and c.sort then col = c end end
	if not col then return rows end
	local values = {}
	for _, r in ipairs(rows) do
		local v = SortValue(col, r)
		if type(v) == "boolean" then v = v and 1 or 0 end
		values[r] = v == nil and "" or v
	end
	table.sort(rows, function(a, b)
		local x, y = values[a], values[b]
		if type(x) ~= type(y) then x, y = tostring(x), tostring(y) end
		if x ~= y then
			if desc then return x > y end
			return x < y
		end
		return tostring(a.name or "") < tostring(b.name or "")
	end)
	return rows
end

function UI.CreateList(panel, opts)
	local list = { rows = {}, all = {}, offset = 0, lines = {}, titles = {}, filterButtons = {} }
	local ROW_H = opts.rowHeight or 18
	local state = opts.state or {}
	list.state, list.cell = state, opts.cell
	if opts.save and ns.db then
		ns.db.lists = ns.db.lists or {}
		local saved = ns.db.lists[opts.save]
		if saved then
			for _, k in ipairs({ "sort", "desc", "filter" }) do
				if saved[k] ~= nil then state[k] = saved[k] end
			end
		end
	end
	if opts.filters and not state.filter then state.filter = opts.filters[1].key end
	state.search = state.search or ""

	local function Save()
		if not opts.save or not ns.db then return end
		ns.db.lists = ns.db.lists or {}
		ns.db.lists[opts.save] = { sort = state.sort, desc = state.desc, filter = state.filter }
	end

	-- Filter buttons and the search box, along the top.
	local x = 0
	for _, f in ipairs(opts.filters or {}) do
		local b = UI.Button(panel)
		b:SetSize(opts.filterWidth or 72, 22)
		b:SetPoint("TOPLEFT", x, 0)
		b:SetText(f.label)
		b.key = f.key
		b:SetScript("OnClick", function()
			state.filter, list.offset = f.key, 0
			Save()
			list:Refresh()
		end)
		list.filterButtons[#list.filterButtons + 1] = b
		x = x + (opts.filterWidth or 72) + 4
	end
	list.toolbarX = x -- where a page can add its own controls
	if opts.search then
		local box = UI.CreateInput(panel, opts.search.width or 136, opts.search.hint or "Search")
		box:SetPoint("TOPRIGHT", -4, 0)
		box.onChange = function(text)
			state.search, list.offset = text:match("^%s*(.-)%s*$"), 0
			list:Refresh()
		end
		box.onEnter = function()
			if state.search ~= "" and list.rows[1] and opts.search.onEnter then return opts.search.onEnter(list.rows[1]) end
		end
		UI.SetSearch(panel, box)
		list.searchBox = box
	end

	-- Column titles: buttons when the column sorts.
	x = 4
	for c, col in ipairs(opts.columns) do
		local holder = panel
		if col.sort then
			holder = CreateFrame("Button", nil, panel)
			holder:SetSize(col.width, 18)
			holder:SetPoint("TOPLEFT", x, opts.top + 3)
			holder:SetScript("OnClick", function() list:SortBy(col.key) end)
		end
		local t = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		if col.sort then t:SetPoint("LEFT") else t:SetPoint("TOPLEFT", x, opts.top) end
		t:SetText(col.label)
		list.titles[c] = t
		x = x + col.width
	end
	local rule = UI.Fill(panel:CreateTexture(nil, "BORDER"), C.dim)
	rule:SetPoint("TOPLEFT", 0, opts.top - 15)
	rule:SetPoint("TOPRIGHT", 0, opts.top - 15)
	rule:SetHeight(1)
	for i = 1, opts.rows do
		local line = CreateFrame("Button", nil, panel)
		line:SetSize(606, ROW_H)
		UI.StyleRow(line, i)
		line:SetPoint("TOPLEFT", 4, opts.top - 18 - (i - 1) * ROW_H)
		line.cells = {}
		local cx = 0
		for c, col in ipairs(opts.columns) do
			local fs = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			fs:SetPoint("LEFT", cx, 0)
			fs:SetWidth(col.width - 4)
			fs:SetJustifyH("LEFT")
			fs:SetWordWrap(false)
			line.cells[c] = fs
			cx = cx + col.width
		end
		line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		line:SetScript("OnClick", function(self, button)
			if self.row and opts.onClick then opts.onClick(self.row, button, self) end
		end)
		line:SetScript("OnEnter", function(self)
			if not self.row or not opts.onEnter then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			opts.onEnter(self, self.row)
			GameTooltip:Show()
		end)
		line:SetScript("OnLeave", function() GameTooltip:Hide() end)
		line:Hide()
		list.lines[i] = line
	end
	-- Shown in place of the rows when there are none (list:SetEmpty("Nobody's ...")).
	local empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	empty:SetPoint("TOPLEFT", 12, opts.top - 30)
	empty:SetWidth(580)
	empty:SetJustifyH("LEFT")
	list.emptyText = empty
	if opts.count then
		local count = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		count:SetPoint("BOTTOMLEFT", 4, 2)
		list.countText = count
	end
	function list:SetEmpty(text) self.empty = text end
	panel:EnableMouseWheel(true)
	panel:SetScript("OnMouseWheel", function(_, delta)
		list.offset = math.max(0, list.offset - delta * 3)
		list:Draw()
	end)

	function list:SortBy(key)
		local col
		for _, c in ipairs(opts.columns) do if c.key == key then col = c end end
		if not col or not col.sort then return end
		if state.sort == key then state.desc = not state.desc
		else state.sort, state.desc = key, col.desc and true or false end
		Save()
		self:Refresh()
	end

	-- The rows to show from all of them: the filter, the search, then the sort.
	function list:Pick(all)
		local filter
		for _, f in ipairs(opts.filters or {}) do if f.key == state.filter then filter = f end end
		local search = opts.search and opts.search.text and (state.search or ""):lower() or ""
		local out = {}
		for _, r in ipairs(all) do
			local keep = not filter or not filter.test or filter.test(r)
			if keep and search ~= "" then keep = opts.search.text(r):lower():find(search, 1, true) ~= nil end
			if keep then out[#out + 1] = r end
		end
		if state.sort then UI.SortRows(out, opts.columns, state.sort, state.desc) end
		return out
	end

	function list:SetRows(rows, cell)
		self.all, self.cell = rows, cell or self.cell
		self.rows = opts.source and rows or self:Pick(rows)
		self:Draw()
	end

	-- Take the rows again: from the source, or from the last rows given.
	function list:Refresh()
		if opts.source then
			self.all = opts.source(state)
			self.rows = self.all
		else
			self.rows = self:Pick(self.all)
		end
		self:Draw()
	end

	function list:Draw()
		self.emptyText:SetText(#self.rows == 0 and self.empty or "")
		local maxOffset = math.max(0, #self.rows - opts.rows)
		if self.offset > maxOffset then self.offset = maxOffset end
		for i, line in ipairs(self.lines) do
			local row = self.rows[i + self.offset]
			line.row = row
			if row and self.cell then
				for c, col in ipairs(opts.columns) do
					local text, r, g, b = self.cell(row, col.key)
					line.cells[c]:SetText(text or "")
					line.cells[c]:SetTextColor(r or 1, g or 1, b or 1)
				end
				line:Show()
			else
				line:Hide()
			end
		end
		for _, b in ipairs(self.filterButtons) do UI.SetSelected(b, b.key == state.filter) end
		if self.countText then self.countText:SetText(opts.count(self.rows, self.all) or "") end
		if opts.onChange then opts.onChange(self) end
	end
	return list
end
