-- "A newer version is out": the addon already hears guildmates' versions (Comm HELLO). When one
-- is newer than ours, say so once per version, with the download link a command away.
-- Pre-releases only count for people already on a pre-release.

local _, ns = ...

local Updates = ns.RegisterModule("Updates", {})
ns.Updates = Updates

Updates.URL = "https://github.com/carraigo/issues-with-tissues/releases/latest"
Updates.newest = nil -- { version, who }

function Updates.Consider(who, version)
	local W = ns.Welcome
	if type(version) ~= "string" or not W.Newer(version, ns.VERSION) then return false end
	local _, _, _, pre = W.ParseVersion(version)
	local _, _, _, minePre = W.ParseVersion(ns.VERSION)
	if pre and not minePre then return false end
	if Updates.newest and not W.Newer(version, Updates.newest.version) then return false end
	Updates.newest = { version = version, who = who }
	if ns.db.updateNotified ~= version then
		ns.db.updateNotified = version
		ns.Print("Version %s is out (%s has it). You're on %s. Type |cffffd100/iwt update|r for the download link.",
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
