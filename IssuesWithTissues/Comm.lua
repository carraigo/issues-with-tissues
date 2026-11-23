-- Guild comms: hidden addon messages between guildmates' addons.
--
-- Wire format (prefix "IWT"). A message body is "<sender>\t<type>\t<payload>", where sender is
-- the sender's own "First Surname": the game only stamps the first name, and guildmates can
-- share one. The claim is only taken when its first name matches the game's.
--   S<body>                            a whole message that fits in one packet
--   M<id>:<index>:<total>:<data>       one piece of a longer body
-- Only GUILD and WHISPER are used. Every handler declares who may send it:
--   "member"  the sender is in our guild roster (the default)
--   "officer" the sender's rank in OUR roster is GM or Officer (ns.Roster.IsOfficer)
--   "any"     anyone (whispers from outside the guild, e.g. a version check)
-- Outgoing packets are queued and sent a few per second so the game never drops them. In
-- combat they wait until it ends; in a raid they go out slowly (one a second), so the addon
-- never competes with the fight.

local _, ns = ...

local Comm = ns.RegisterModule("Comm", {})
ns.Comm = Comm

Comm.PREFIX = "IWT"
Comm.MAX_PACKET = 250          -- the game allows 255 bytes
Comm.SEND_INTERVAL = 0.1       -- seconds between queued packets
Comm.RAID_INTERVAL = 1         -- in a raid
Comm.HOLD_CHECK = 2            -- in combat: how often to look again
Comm.THROTTLE_WAIT = 1.5       -- the game said "too fast": wait this long, then send it again
Comm.MAX_TRIES = 4             -- give up on a packet the game keeps refusing
Comm.PARTIAL_TIMEOUT = 30      -- seconds to wait for the rest of a split message
Comm.MAX_PIECES = 64

Comm.handlers = {}
Comm.queue = {}
Comm.partial = {}              -- sender .. "\1" .. id -> { total, got, parts, started }
Comm.sendHook = nil            -- tests replace the real send with this
local nextId = math.random(0, 9998) -- two guildmates with one first name rarely pick the same ids
Comm.sent = {}                 -- body -> time, to tell our own echo from someone posing as us
Comm.echoes = {}               -- message type -> when our own copy last came back

local function RawSend(packet, distribution, target)
	if Comm.sendHook then return Comm.sendHook(Comm.PREFIX, packet, distribution, target) end
	if C_ChatInfo and C_ChatInfo.SendAddonMessage then
		return C_ChatInfo.SendAddonMessage(Comm.PREFIX, packet, distribution, target)
	elseif SendAddonMessage then
		return SendAddonMessage(Comm.PREFIX, packet, distribution, target)
	end
end

-- Split "<sender>\t<type>\t<payload>" into packets.
function Comm.Encode(msgType, payload)
	local body = (ns.PlayerName() or "") .. "\t" .. msgType .. "\t" .. (payload or "")
	Comm.sent[body] = ns.Now()
	if #body + 1 <= Comm.MAX_PACKET then return { "S" .. body } end
	nextId = (nextId % 9999) + 1
	local id = tostring(nextId)
	-- header "M<id>:<i>:<n>:" is at most 1 + 4 + 1 + 2 + 1 + 2 + 1 = 12 bytes
	local size = Comm.MAX_PACKET - 12
	local total = math.ceil(#body / size)
	if total > Comm.MAX_PIECES then return nil, "message too long" end
	local packets = {}
	for i = 1, total do
		packets[i] = string.format("M%s:%d:%d:%s", id, i, total, body:sub((i - 1) * size + 1, i * size))
	end
	return packets
end

-- Did the game refuse a packet? Older clients answer true/false, newer ones a result code
-- (0 = sent; the throttle codes mean "too many messages, try again shortly").
function Comm.Refused(result)
	if result == nil or result == true or result == 0 then return false end
	if result == false then return true end
	local E = Enum and Enum.SendAddonMessageResult
	if E and result == E.Success then return false end
	return type(result) == "number"
end

-- "combat" (hold everything), "raid" (go slowly) or nil.
function Comm.Held()
	if InCombatLockdown and InCombatLockdown() then return "combat" end
	if IsInInstance then
		local inside, kind = IsInInstance()
		if inside and kind == "raid" then return "raid" end
	end
end

function Comm.Pump()
	local held = Comm.Held()
	if held == "combat" then
		ns.After(Comm.HOLD_CHECK, Comm.Pump)
		return
	end
	local item = table.remove(Comm.queue, 1)
	local wait = held == "raid" and Comm.RAID_INTERVAL or Comm.SEND_INTERVAL
	if item and Comm.Refused(RawSend(item.packet, item.distribution, item.target)) then
		item.tries = (item.tries or 0) + 1
		Comm.throttled = (Comm.throttled or 0) + 1
		if item.tries < Comm.MAX_TRIES then
			table.insert(Comm.queue, 1, item) -- keep the order: a split message needs every piece
			wait = Comm.THROTTLE_WAIT
		else
			Comm.dropped = (Comm.dropped or 0) + 1
		end
	end
	if #Comm.queue > 0 then
		ns.After(wait, Comm.Pump)
	else
		Comm.pumping = false
	end
end

-- Send to the guild (distribution "GUILD") or to one player ("WHISPER", target).
function Comm.Send(msgType, payload, distribution, target)
	distribution = distribution or "GUILD"
	if distribution == "GUILD" and IsInGuild and not IsInGuild() then return false end
	local packets, err = Comm.Encode(msgType, payload)
	if not packets then
		ns.ReportError("Comm.Send " .. msgType .. ": " .. err)
		return false
	end
	for _, p in ipairs(packets) do
		Comm.queue[#Comm.queue + 1] = { packet = p, distribution = distribution, target = target }
	end
	if Comm.immediate then -- tests: deliver at once
		while #Comm.queue > 0 do
			local item = table.remove(Comm.queue, 1)
			RawSend(item.packet, item.distribution, item.target)
		end
	elseif not Comm.pumping then
		Comm.pumping = true
		Comm.Pump()
	end
	return true
end

-- Comm.Register("POLL", fn(sender, payload, distribution), "officer")
function Comm.Register(msgType, fn, who)
	assert(not msgType:find("[\t:]"), "message types cannot contain tab or colon")
	Comm.handlers[msgType] = { fn = fn, who = who or "member" }
end

function Comm.Allowed(who, sender, distribution, verified)
	if who == "any" then return true end
	if who == "officer" then return ns.Roster.IsOfficer(sender, not verified) end
	return ns.Roster.IsMember(sender)
end

-- Who sent it. The Forever client stamps "First Surname" (seen in game, 1.60.1): then that is
-- the sender, whatever the message claims (verified). If the game only gave a first name, the
-- claimed "First Surname" is taken when its first name matches (not verified).
function Comm.Identify(rawSender, claimed)
	local stamped = ns.Roster.ParseName(rawSender)
	if stamped and stamped:find(" ", 1, true) then return stamped, true end
	local first = ns.Roster.FirstName(rawSender)
	local who = ns.Roster.ParseName(claimed)
	if not who or ns.Roster.FirstName(who) ~= first then who = ns.FullName(rawSender) end
	return who, false
end

local function Dispatch(rawSender, body, distribution)
	local claimed, msgType, payload = body:match("^([^\t]*)\t([^\t]+)\t(.*)$")
	if not msgType then return end
	local sender, verified = Comm.Identify(rawSender, claimed)
	if not sender then return end
	local forged = false
	if sender == ns.PlayerName() then
		if Comm.sent[body] then Comm.echoes[msgType] = ns.Now() end -- the self-test looks for these
		if Comm.sent[body] and not Comm.hearSelf then return end -- our own message coming back
		if not Comm.sent[body] then
			forged = true
			ns.ReportError(string.format("comm: a %s message arrived in your name that this addon did not send", msgType))
		end
	end
	local h = Comm.handlers[msgType]
	if not h then return end
	if not Comm.Allowed(h.who, sender, distribution, verified) then
		ns.Log("comm: dropped %s from %s (not allowed)", msgType, tostring(sender))
		return
	end
	ns.Measure("comm " .. msgType, h.fn, sender, payload, distribution, forged, verified)
end

function Comm.Receive(prefix, packet, distribution, sender)
	if prefix ~= Comm.PREFIX or type(packet) ~= "string" then return end
	if type(sender) ~= "string" or sender == "" then return end
	local kind = packet:sub(1, 1)
	if kind == "S" then
		Dispatch(sender, packet:sub(2), distribution)
	elseif kind == "M" then
		local id, i, n, data = packet:match("^M(%d+):(%d+):(%d+):(.*)$")
		i, n = tonumber(i), tonumber(n)
		if not id or not i or not n or n < 1 or n > Comm.MAX_PIECES or i < 1 or i > n then return end
		local key = sender .. "\1" .. id
		local now = ns.Now()
		local p = Comm.partial[key]
		if not p or p.total ~= n or now - p.started > Comm.PARTIAL_TIMEOUT then
			p = { total = n, got = 0, parts = {}, started = now }
			Comm.partial[key] = p
		end
		if not p.parts[i] then
			p.parts[i] = data
			p.got = p.got + 1
		end
		if p.got == p.total then
			Comm.partial[key] = nil
			Dispatch(sender, table.concat(p.parts), distribution)
		end
	end
end

-- Drop half-received messages that will never finish.
function Comm.Sweep()
	local now = ns.Now()
	for key, p in pairs(Comm.partial) do
		if now - p.started > Comm.PARTIAL_TIMEOUT then Comm.partial[key] = nil end
	end
	for body, t in pairs(Comm.sent) do
		if now - t > 120 then Comm.sent[body] = nil end
	end
end

function Comm:OnLoad()
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		C_ChatInfo.RegisterAddonMessagePrefix(Comm.PREFIX)
	elseif RegisterAddonMessagePrefix then
		RegisterAddonMessagePrefix(Comm.PREFIX)
	end
	if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(60, Comm.Sweep) end
end

ns.On("CHAT_MSG_ADDON", function(_, prefix, packet, distribution, sender, ...)
	if prefix == Comm.PREFIX then
		-- For the bug report: everything the game says about a sender (does Forever give more
		-- than the first name anywhere?)
		local extra = {}
		for i = 1, select("#", ...) do extra[i] = tostring((select(i, ...))) end
		Comm.lastSender = tostring(sender) .. " | " .. table.concat(extra, ", ")
	end
	Comm.Receive(prefix, packet, distribution, sender)
end)

-- Fields inside a payload are separated by "\31" (unit separator); helpers keep it consistent.
local SEP = "\31"
Comm.SEP = SEP
function Comm.Pack(...)
	local t = { ... }
	for i = 1, select("#", ...) do
		local v = t[i]
		v = v == nil and "" or tostring(v)
		t[i] = v:gsub(SEP, "")
	end
	return table.concat(t, SEP, 1, select("#", ...))
end
function Comm.Unpack(payload)
	local out = {}
	for field in ((payload or "") .. SEP):gmatch("(.-)" .. SEP) do out[#out + 1] = field end
	return unpack(out)
end

-- Version check: who in the guild runs which version.
-- A HELLO goes to the guild at login. Whoever hears one from someone new whispers theirs back
-- ("<version>;r"), so a guildmate who logs in later still learns who was already online.
Comm.versions = {}
Comm.Register("HELLO", function(sender, payload, distribution)
	local version, reply = tostring(payload or ""):match("^([^;]*);?(r?)$")
	version = version or ""
	local new = Comm.versions[sender] == nil
	Comm.versions[sender] = version
	ns.Send("VERSION_SEEN", sender, version)
	ns.Send("ADDON_HELLO", sender, reply == "r")
	if new and reply ~= "r" and sender ~= ns.PlayerName() then
		Comm.Send("HELLO", ns.VERSION .. ";r", "WHISPER", sender)
	end
end)
function Comm:OnLogin()
	ns.Later("hello", function() Comm.Send("HELLO", ns.VERSION) end)
end
