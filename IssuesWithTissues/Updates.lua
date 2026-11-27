-- "A newer version is out": the addon already hears guildmates' versions (Comm HELLO). When one
-- is newer than ours, say so once per version, with the download link a command away.
-- Pre-releases only count for people already on a pre-release.
-- A version counts as out once two different players run it (alts of one player count once):
-- a build being tried before its release is usually on one player's characters only (1.4.2).

local _, ns = ...

local Updates = ns.RegisterModule("Updates", {})
ns.Updates = Updates

Updates.URL = "https://www.curseforge.com/projects/1825695"
Updates.newest = nil -- { version, who }
Updates.PLAYERS = 2 -- players running a version before it counts as out
Updates.seen = {}   -- version -> { [player's main] = true }

-- How many different players run a version (counting each player's alts once).
function Updates.Players(who, version)
	local list = Updates.seen[version] or {}
	Updates.seen[version] = list
	local player = (ns.Alts and ns.Alts.MainOf(who)) or who
	list[player] = true
	local n = 0
	for _ in pairs(list) do n = n + 1 end
	return n
end

function Updates.Consider(who, version)
	local W = ns.Welcome
	if type(version) ~= "string" or not W.Newer(version, ns.VERSION) then return false end
	local _, _, _, pre = W.ParseVersion(version)
	local _, _, _, minePre = W.ParseVersion(ns.VERSION)
	if pre and not minePre then return false end
	if Updates.Players(who, version) < Updates.PLAYERS then return false end
	if Updates.newest and not W.Newer(version, Updates.newest.version) then return false end
	Updates.newest = { version = version, who = who }
	if ns.db.updateNotified ~= version then
		ns.db.updateNotified = version
		ns.Print("Version %s is out (%s has it). You're on %s. Update it in the CurseForge app, or type |cffffd100/iwt update|r for the link.",
			version, ns.Roster.DisplayName(who) ~= "" and ns.Roster.DisplayName(who) or tostring(who), ns.VERSION)
		ns.Log("update: %s seen from %s", version, tostring(who))
	end
	return true
end

ns.Listen("VERSION_SEEN", function(who, version) Updates.Consider(who, version) end)

ns.RegisterCommand("update", "where to download the newest version", function()
	local n = Updates.newest
	local title = n and ("Version " .. n.version .. " is out") or ("You're on " .. ns.VERSION)
	ns.UI.ShowCopyBox(title .. ": copy the link (Ctrl+C) into your browser", Updates.URL)
end)
