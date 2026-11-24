-- A small stand-in for the WoW API, enough to load the addon offline and simulate
-- several guildmates' clients talking over guild addon messages.
-- Each client gets its own environment (globals), so two loaded copies never share state.

local W = {}

local function Frame()
	local f = { shown = false, scripts = {}, events = {} }
	local mt = {}
	mt.__index = function(t, k)
		if k == "SetScript" then return function(self, name, fn) self.scripts[name] = fn end end
		if k == "GetScript" then return function(self, name) return self.scripts[name] end end
		if k == "RegisterEvent" then return function(self, e) self.events[e] = true end end
		if k == "Show" then return function(self) self.shown = true end end
		if k == "Hide" then return function(self) self.shown = false end end
		if k == "SetShown" then return function(self, v) self.shown = v and true or false end end
		if k == "IsShown" then return function(self) return self.shown end end
		if k == "GetChecked" then return function(self) return self.checked end end
		if k == "SetChecked" then return function(self, v) self.checked = v end end
		if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
		if k == "CreateFontString" or k == "CreateTexture" then return function() return Frame() end end
		return function() end -- every other widget method is a no-op
	end
	return setmetatable(f, mt)
end
W.Frame = Frame

W.TOC_FILES = nil
W.MISSING_TEMPLATES = { CharacterFrameTabButtonTemplate = true }

-- The "server": delivers addon messages to every client in the same guild.
W.clients = {}
W.now = 1800000000

function W.Deliver(fromClient, prefix, msg, distribution, target)
	assert(#msg <= 255, "packet over 255 bytes: " .. #msg)
	for _, c in ipairs(W.clients) do
		local deliver = false
		if distribution == "GUILD" then
			deliver = c.guild == fromClient.guild
		elseif distribution == "WHISPER" then
			deliver = c.name == target -- a whisper needs the whole "First Surname"
		end
		if deliver and c.registered[prefix] then
			c.env.__fire("CHAT_MSG_ADDON", prefix, msg, distribution, fromClient.fullName)
		end
	end
end

-- guild = { name = "Issues with Tissues", members = { {name, rankIndex, online}, ... } }
function W.NewClient(baseDir, name, guild, opts)
	-- Forever: the game stamps addon messages and UnitName with the first name only.
	local first = name:match("^(%S+)")
	-- opts.fullSender: stamp "First Surname" instead, as the 1.60.1 client was seen to do.
	local c = { name = name, first = first, fullName = first .. "-Realm", guild = guild, registered = {} }
	if opts and opts.fullSender then c.fullName = name end
	local env = {}
	setmetatable(env, { __index = _G })
	env._G = env
	local frames = {}
	env.CreateFrame = function(kind, frameName, parent, template)
		-- Templates the Forever client (1.60.1, interface 16001) does not have.
		for t in tostring(template or ""):gmatch("[^,%s]+") do
			if W.MISSING_TEMPLATES[t] then
				error("CreateFrame(): Couldn't find inherited node '" .. t .. "'", 2)
			end
		end
		local f = Frame()
		frames[#frames + 1] = f
		return f
	end
	env.__fire = function(event, ...)
		for _, f in ipairs(frames) do
			if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
		end
	end
	env.UIParent = Frame()
	env.Minimap = Frame()
	env.UISpecialFrames = {}
	env.tinsert = table.insert
	env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	env.unpack = unpack
	env.date = os.date
	env.time = function() return W.now end
	env.GetServerTime = function() return W.now end
	env.debugprofilestop = function() return os.clock() * 1000 end
	env.GetBuildInfo = function() return "1.60.1", "70000", "Nov 2026", 16010 end
	env.GetLocale = function() return "enGB" end
	env.UnitName = function(unit) if unit == "player" then return first end end
	env.UnitGUID = function(unit) if unit == "player" then return "Player-" .. name end end
	env.GetNormalizedRealmName = function() return "Realm" end
	env.IsInGuild = function() return guild ~= nil end
	env.GetNumGuildMembers = function() return guild and #guild.members or 0 end
	env.GetGuildRosterInfo = function(i)
		local m = guild.members[i]
		return m[1] .. "-Realm", "Rank" .. m[2], m[2], m[5] or 60, "Warrior", "Stormwind City", m[6] or "", m[7] or "", m[3], 0, "WARRIOR",
			0, 0, false, false, 0, "Player-" .. m[1]
	end
	env.GetGuildRosterLastOnline = function(i)
		local m = guild.members[i]
		if m[3] then return nil end
		return 0, 0, m[4] or 0, 0
	end
	-- Skills: c.skills = { {name, rank, max}, ... } (modern GetProfessions API)
	c.skills = {}
	env.GetProfessions = function()
		local ids = {}
		for i = 1, #c.skills do ids[i] = i end
		return unpack(ids)
	end
	env.GetProfessionInfo = function(id)
		local s = c.skills[id]
		return s[1], 0, s[2], s[3], 0, 0, s[4] -- 7th: skillLine
	end
	env.GetGuildInfo = function() if guild then return guild.name or "Issues with Tissues", "Member", 3 end end
	-- An open profession window: c.tradeSkill = { name = "Tailoring", recipes = { {id, name, itemID, learned} } }
	-- Opening by skill line: c.tradeSkills[skillLine] = { name, recipes }; c.blockOpen refuses.
	c.tradeSkills = {}
	env.C_TradeSkillUI = {
		OpenTradeSkill = function(line)
			if c.blockOpen then error("blocked: needs a hardware click") end
			c.tradeSkill = c.tradeSkills[line]
			c.opened = (c.opened or 0) + 1
		end,
		CloseTradeSkill = function() c.tradeSkill = nil end,
		GetBaseProfessionInfo = function()
			return c.tradeSkill and { professionID = 197, professionName = c.tradeSkill.name } or {}
		end,
		GetAllRecipeIDs = function()
			local ids = {}
			for i, r in ipairs(c.tradeSkill and c.tradeSkill.recipes or {}) do ids[i] = r[1] end
			return ids
		end,
		GetRecipeInfo = function(id)
			for _, r in ipairs(c.tradeSkill.recipes) do
				if r[1] == id then return { name = r[2], learned = r[4] ~= false } end
			end
		end,
		GetRecipeOutputItemData = function(id)
			for _, r in ipairs(c.tradeSkill.recipes) do
				if r[1] == id then
					if r[3] then W.itemNames[r[3]] = W.itemNames[r[3]] or r[2] end -- the game knows its items
					return { itemID = r[3] }
				end
			end
		end,
	}
	-- Item names the game has loaded (shared by every client); c.unknownItems hides some.
	env.GetItemInfo = function(id)
		if c.unknownItems and c.unknownItems[id] then return nil end
		return W.itemNames[id]
	end
	c.popups = {}
	env.StaticPopupDialogs = {}
	env.StaticPopup_Show = function(which, a, b, data) table.insert(c.popups, { which = which, arg = a, arg2 = b, data = data }) end
	env.GuildControlGetNumRanks = function() return 5 end
	env.GuildControlGetRankName = function(i)
		return ({ "Guild Master", "Officer", "Veteran", "Member", "Initiate" })[i]
	end
	env.GuildRoster = function() end
	env.C_ChatInfo = {
		RegisterAddonMessagePrefix = function(p) c.registered[p] = true return true end,
		SendAddonMessage = function(p, msg, dist, target) W.Deliver(c, p, msg, dist, target) return true end,
	}
	env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) c.printed = c.printed or {}; table.insert(c.printed, m) end }
	env.SlashCmdList = {}
	-- Timers wait until the test calls c.flush(), which runs the short ones (1s or less) once.
	c.timers = {}
	W.seq = (W.seq or 0) + 1
	env.C_Timer = { After = function(sec, fn)
		W.seq = W.seq + 1
		table.insert(c.timers, { sec = sec, fn = fn, at = W.now + sec, seq = W.seq })
	end }
	function c.flush()
		local due = c.timers
		c.timers = {}
		for _, t in ipairs(due) do
			if t.sec <= 1 then t.fn() else table.insert(c.timers, t) end
		end
	end
	c.env = env
	if opts and opts.account then env.IwTDB = opts.account.env.IwTDB end

	local ns = {}
	for _, file in ipairs(W.TOC_FILES) do
		local chunk = assert(loadfile(baseDir .. "/IssuesWithTissues/" .. file))
		setfenv(chunk, env)
		chunk("IssuesWithTissues", ns)
	end
	c.ns = ns
	env.__fire("ADDON_LOADED", "IssuesWithTissues")
	env.__fire("PLAYER_LOGIN")
	env.__fire("GUILD_ROSTER_UPDATE")
	ns.Comm.immediate = true
	W.clients[#W.clients + 1] = c
	return c
end

-- A clock for timing tests: runs every timer of the given clients that falls due in the next
-- `seconds`, earliest first (ties in the order they were set), moving W.now along, and leaves
-- W.now at the end. Timers a timer sets run too, if they fall due in time. Set
-- c.ns.Comm.immediate = false first so messages go through the paced queue.
function W.Run(seconds, clients)
	local stop = W.now + seconds
	while true do
		local bestC, bestI, best
		for _, c in ipairs(clients) do
			for i, t in ipairs(c.timers) do
				if t.at <= stop and (not best or t.at < best.at or (t.at == best.at and t.seq < best.seq)) then
					bestC, bestI, best = c, i, t
				end
			end
		end
		if not best then break end
		table.remove(bestC.timers, bestI)
		W.now = math.max(W.now, best.at)
		best.fn()
	end
	W.now = stop
end

W.itemNames = {}
function W.Reset()
	W.clients = {}
end

function W.ReadToc(baseDir)
	local files = {}
	for line in io.lines(baseDir .. "/IssuesWithTissues/IssuesWithTissues.toc") do
		line = line:gsub("\r", "")
		if line ~= "" and not line:find("^##") then files[#files + 1] = line end
	end
	W.TOC_FILES = files
	return files
end

return W
