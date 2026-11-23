-- Speed test: a 500-member guild with shared professions, recipes and chat. Fails when a
-- redraw, a search or a sync catch-up takes longer than its limit. Run from the repository
-- root:  luajit tests/speed.lua
-- The limits are several times what these take on a GitHub runner, so only a real slowdown
-- (something that would make the game hitch) fails the run.
local base = arg and arg[1] or "."
package.path = base .. "/tests/?.lua;" .. package.path
local W = dofile(base .. "/tests/wow.lua")
W.ReadToc(base)

local MEMBERS, CRAFTERS, RECIPES = 500, 200, 60

local LIMITS = { -- ms per run, on LuaJIT (about 4 times what a GitHub runner takes; the game's Lua is slower)
	["roster rows (500 members)"] = 20,
	["roster redraw"] = 25,
	["crafters search"] = 40,
	["crafters by profession"] = 20,
	["chat view (300 + 300 lines)"] = 10,
	["sync digest (all sets)"] = 10,
	["sync catch-up (whole guild)"] = 1000,
}

local clock = os.clock
local function Time(runs, fn)
	fn() -- warm up
	local start = clock()
	for _ = 1, runs do fn() end
	return (clock() - start) * 1000 / runs
end

local PROFS = { "Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Leatherworking", "Tailoring", "Cooking" }
local function Guild()
	local members = { { "Gm", 0, true, 0, 60 } }
	for i = 2, MEMBERS do
		members[i] = { "Member" .. string.char(97 + i % 26) .. i, i % 5, i % 4 == 0, i % 60, 10 + i % 51 }
	end
	return { members = members }
end

local g = Guild()
local gm = W.NewClient(base, "Gm", g)
local now = W.now

-- What a 500-member guild has shared: professions for everyone, recipes for 200 crafters.
local store = gm.env.IwTDB.sync
store.profs = { records = {} }
store.recipes = { records = {} }
for i = 2, MEMBERS do
	local who = g.members[i][1]
	local a, b = PROFS[i % 7 + 1], PROFS[(i + 3) % 7 + 1]
	store.profs.records[who] = { rev = now - i, by = who, data = a .. ":" .. (i % 300) .. ":300," .. b .. ":75:150" }
	if i <= CRAFTERS + 1 then
		local parts = {}
		for r = 1, RECIPES do parts[r] = (2000 + r) .. ":" .. a .. " recipe " .. r end
		store.recipes.records[who .. "#" .. a] = { rev = now - i, by = who, data = table.concat(parts, ";") }
	end
end
local Chat = gm.ns.Chat
for i = 1, Chat.MAX_LINES do gm.env.__fire("CHAT_MSG_GUILD", "message number " .. i, g.members[i % MEMBERS + 1][1] .. "-Realm") end

-- The server's copy of the same chat (as at login), half of it not matching what we saved.
local server = {}
for i, e in ipairs(Chat.Lines("guild")) do
	server[i] = { t = e.t + (i % 2) * 400, k = "msg", a = e.a, m = (i % 2 == 0) and e.m or ("other " .. i), srv = true }
end
Chat.server.guild = server

local results = {}
results["roster rows (500 members)"] = Time(20, function() gm.ns.RosterTab.Rows() end)
gm.ns.UI.Open("Roster")
results["roster redraw"] = Time(20, function() gm.ns.RosterTab.Refresh(true) end)
results["crafters search"] = Time(20, function() gm.ns.CraftersTab.Search("recipe 1", false) end)
results["crafters by profession"] = Time(20, function() gm.ns.CraftersTab.ByProfession(false) end)
results["chat view (300 + 300 lines)"] = Time(20, function() Chat.View("guild") end)
results["sync digest (all sets)"] = Time(20, function()
	for name in pairs(gm.ns.Sync.sets) do gm.ns.Sync.Digest(name) end
end)
-- A guildmate whose saved data was wiped logs in and asks for everything.
results["sync catch-up (whole guild)"] = Time(1, function()
	W.clients = { gm }
	local fresh = W.NewClient(base, g.members[2][1], g)
	fresh.ns.Sync.Ask()
	local n = 0
	for _ in fresh.ns.Sync.Each("recipes") do n = n + 1 end
	assert(n == CRAFTERS, "catch-up got " .. n .. " recipe lists, wanted " .. CRAFTERS)
end)

local failed = 0
local names = {}
for name in pairs(LIMITS) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
	local ms, limit = results[name], LIMITS[name]
	local ok = ms <= limit
	if not ok then failed = failed + 1 end
	print(string.format("%-4s %-30s %8.2f ms  (limit %d)", ok and "ok" or "SLOW", name, ms, limit))
end
if failed > 0 then
	print(failed .. " too slow")
	os.exit(1)
end
print("all within limits")
