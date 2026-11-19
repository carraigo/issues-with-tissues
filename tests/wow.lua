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
			deliver = c.fullName == target or c.name == target
		end
		if deliver and c.registered[prefix] then
			c.env.__fire("CHAT_MSG_ADDON", prefix, msg, distribution, fromClient.fullName)
		end
	end
end

-- guild = { name = "Issues with Tissues", members = { {name, rankIndex, online}, ... } }
function W.NewClient(baseDir, name, guild)
	local c = { name = name, fullName = name .. "-Realm", guild = guild, registered = {} }
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
	env.UnitName = function(unit) if unit == "player" then return name end end
	env.GetNormalizedRealmName = function() return "Realm" end
	env.IsInGuild = function() return guild ~= nil end
	env.GetNumGuildMembers = function() return guild and #guild.members or 0 end
	env.GetGuildRosterInfo = function(i)
		local m = guild.members[i]
		return m[1] .. "-Realm", "Rank" .. m[2], m[2], 60, "Warrior", "Stormwind City", "", "", m[3], 0, "WARRIOR"
	end
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
	c.env = env

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
