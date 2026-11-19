-- Guild comms: hidden addon messages between guildmates' addons.
--
-- Wire format (prefix "IWT"):
--   S<type>\t<payload>                 a whole message that fits in one packet
--   M<id>:<index>:<total>:<data>       one piece of a longer message ("<type>\t<payload>" split)
-- Only GUILD and WHISPER are used. Every handler declares who may send it:
--   "member"  the sender is in our guild roster (the default)
--   "officer" the sender's rank in OUR roster is GM or Officer (ns.Roster.IsOfficer)
--   "any"     anyone (whispers from outside the guild, e.g. a version check)
-- Outgoing packets are queued and sent a few per second so the game never drops them.

local _, ns = ...

local Comm = ns.RegisterModule("Comm", {})
ns.Comm = Comm

Comm.PREFIX = "IWT"
Comm.MAX_PACKET = 250          -- the game allows 255 bytes
Comm.SEND_INTERVAL = 0.1       -- seconds between queued packets
Comm.PARTIAL_TIMEOUT = 30      -- seconds to wait for the rest of a split message
Comm.MAX_PIECES = 64

Comm.handlers = {}
Comm.queue = {}
Comm.partial = {}              -- sender .. "\1" .. id -> { total, got, parts, started }
Comm.sendHook = nil            -- tests replace the real send with this
local nextId = 0

local function RawSend(packet, distribution, target)
	if Comm.sendHook then return Comm.sendHook(Comm.PREFIX, packet, distribution, target) end
	if C_ChatInfo and C_ChatInfo.SendAddonMessage then
		return C_ChatInfo.SendAddonMessage(Comm.PREFIX, packet, distribution, target)
	elseif SendAddonMessage then
		return SendAddonMessage(Comm.PREFIX, packet, distribution, target)
	end
end

-- Split "<type>\t<payload>" into packets.
function Comm.Encode(msgType, payload)
	local body = msgType .. "\t" .. (payload or "")
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

function Comm.Pump()
	local item = table.remove(Comm.queue, 1)
	if item then RawSend(item.packet, item.distribution, item.target) end
	if #Comm.queue > 0 then
		ns.After(Comm.SEND_INTERVAL, Comm.Pump)
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

function Comm.Allowed(who, sender, distribution)
	if who == "any" then return true end
	if who == "officer" then return ns.Roster.IsOfficer(sender) end
	return ns.Roster.IsMember(sender)
end

local function Dispatch(sender, body, distribution)
	local msgType, payload = body:match("^([^\t]+)\t(.*)$")
	if not msgType then return end
	local h = Comm.handlers[msgType]
	if not h then return end
	if not Comm.Allowed(h.who, sender, distribution) then
		ns.Log("comm: dropped %s from %s (not allowed)", msgType, tostring(sender))
		return
	end
	ns.Measure("comm " .. msgType, h.fn, sender, payload, distribution)
end

function Comm.Receive(prefix, packet, distribution, sender)
	if prefix ~= Comm.PREFIX or type(packet) ~= "string" then return end
	sender = ns.FullName(sender)
	if not sender or (sender == ns.PlayerName() and not Comm.hearSelf) then return end
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
end

function Comm:OnLoad()
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		C_ChatInfo.RegisterAddonMessagePrefix(Comm.PREFIX)
	elseif RegisterAddonMessagePrefix then
		RegisterAddonMessagePrefix(Comm.PREFIX)
	end
	if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(60, Comm.Sweep) end
end

ns.On("CHAT_MSG_ADDON", function(_, prefix, packet, distribution, sender)
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
Comm.versions = {}
Comm.Register("HELLO", function(sender, payload)
	Comm.versions[sender] = payload
	ns.Send("VERSION_SEEN", sender, payload)
end)
function Comm:OnLogin()
	ns.After(5, function() Comm.Send("HELLO", ns.VERSION) end)
end
