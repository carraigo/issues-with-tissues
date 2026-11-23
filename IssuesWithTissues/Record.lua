-- Record formats: how each shared set writes its data as text, in one place.
--
-- A set's data travels inside addon messages, so it must never hold the message separators
-- (\30, \31) or "|" (the chat escape character). Each set registers a codec:
--   ns.Record.Define("kills", { encode = fn(value) -> text, decode = fn(text) -> value or nil,
--       sample = value })
-- and the tests round-trip every set's sample (encode, decode, encode again: the same text), so
-- a set without a codec, or one that loses data, fails the build.
--
-- Helpers for writing one:
--   Record.Clean(text, max, extra)   text with the separators (and any `extra` characters) removed
--   Record.Fields(text, n)           the first n ";" fields (the last one takes the rest), or nil
--   Record.Split(text, sep)          every field between sep (empty ones too)
--   Record.B36(n, width) / Record.Num36(text)   base 36 numbers
--   Record.Gaps(ids) / Record.Ungaps(text)      a sorted id list as base 36 gaps: "1zz.1.4.a"

local _, ns = ...

local Record = {}
ns.Record = Record
Record.codecs = {}

function Record.Define(set, codec)
	assert(type(codec.encode) == "function" and type(codec.decode) == "function", "codec needs encode and decode")
	Record.codecs[set] = codec
end

function Record.Encode(set, value) return Record.codecs[set].encode(value) end
function Record.Decode(set, text) return Record.codecs[set].decode(text) end

function Record.Clean(text, max, extra)
	return ns.CleanText(text, max, extra)
end

-- Split on a single plain character, keeping empty fields: Split("a;;b", ";") = { "a", "", "b" }.
function Record.Split(text, sep)
	local out, from = {}, 1
	text = tostring(text or "")
	while true do
		local at = text:find(sep, from, true)
		if not at then out[#out + 1] = text:sub(from) break end
		out[#out + 1] = text:sub(from, at - 1)
		from = at + 1
	end
	return out
end

-- The first n ";" fields, the last taking the rest of the text (it may hold ";"). nil when
-- there are fewer than n.
function Record.Fields(text, n)
	local parts = Record.Split(text, ";")
	if #parts < n then return nil end
	if #parts > n then
		local rest = {}
		for i = n, #parts do rest[#rest + 1] = parts[i] end
		for i = #parts, n + 1, -1 do parts[i] = nil end
		parts[n] = table.concat(rest, ";")
	end
	return unpack(parts, 1, n)
end

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
-- n in base 36; with width, padded (and cut) to exactly that many digits.
function Record.B36(n, width)
	n = math.floor(tonumber(n) or 0)
	if width then
		local out = {}
		for i = width, 1, -1 do
			local d = n % 36
			out[i] = DIGITS:sub(d + 1, d + 1)
			n = math.floor(n / 36)
		end
		return table.concat(out)
	end
	if n <= 0 then return "0" end
	local out = ""
	while n > 0 do
		local d = n % 36
		out = DIGITS:sub(d + 1, d + 1) .. out
		n = math.floor(n / 36)
	end
	return out
end

function Record.Num36(text)
	return tonumber(text, 36)
end

-- Ids sorted, each written as the gap from the one before (the first as itself), in base 36:
-- { 2996, 2997, 3001 } -> "2b8.1.4". Duplicates and non-positive ids are dropped.
function Record.Gaps(ids)
	local sorted, seen = {}, {}
	for _, id in ipairs(ids) do
		id = math.floor(tonumber(id) or 0)
		if id > 0 and not seen[id] then seen[id] = true; sorted[#sorted + 1] = id end
	end
	table.sort(sorted)
	local out, last = {}, 0
	for i, id in ipairs(sorted) do
		out[i] = Record.B36(id - last)
		last = id
	end
	return table.concat(out, ".")
end

function Record.Ungaps(text)
	local ids, last = {}, 0
	for part in tostring(text or ""):gmatch("[^%.]+") do
		local gap = Record.Num36(part)
		if not gap then return ids end
		last = last + gap
		ids[#ids + 1] = last
	end
	return ids
end
