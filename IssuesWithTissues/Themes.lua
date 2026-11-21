-- Themes (0.8.0 beta): the window's colours, picked in Settings and applied at the next /reload.
-- A theme is a full set of UI.COLORS, copied into that table before any frame is made, so every
-- part of the addon picks it up without knowing about themes.
--
-- Readability: in any theme but Default, text that would be too faint against the panels (a
-- Rogue's yellow name on a light theme, say) is moved toward the theme's ink colour until it
-- reaches a 4.5:1 contrast. That covers class colours, coloured words inside text, and the
-- game's own font colours. Default keeps every colour exactly as before.

local _, ns = ...

local UI = ns.UI
local C = UI.COLORS

local function Hex(s)
	return { tonumber(s:sub(1, 2), 16) / 255, tonumber(s:sub(3, 4), 16) / 255, tonumber(s:sub(5, 6), 16) / 255 }
end
local function A(s, a) local c = Hex(s); c[4] = a; return c end

-- Keys as in UI.COLORS, plus:
--   ink      text is moved toward this colour when it's too faint
--   ref      the background text is checked against (the lightest panel on a light theme)
--   chat     guild/officer chat colours, instead of the game's chat settings
--   light    a light theme (game font shadows are lightened)
UI.THEMES = {
	{ id = "default", name = "Default" },
	{ id = "kawaiiNight", name = "Kawaii Night", colors = {
		bg = A("2a1830", 0.97), bar = Hex("3a2140"), card = A("3a2242", 0.92), edge = Hex("ff9ecb"), dim = Hex("6b4470"),
		button = Hex("45284d"), primary = Hex("ff7fb6"), close = Hex("c2477f"), selected = Hex("6a3a66"),
		hover = A("ffc2df", 0.12), stripe = A("ffffff", 0.03), input = Hex("1e1124"),
		gold = Hex("ffc2df"), text = Hex("fbeaf3"), tabtext = Hex("d9b8e0"), subtext = Hex("cdb0d6"),
		stamp = Hex("c9a3d6"), sys = Hex("cdb8d6"), primarytext = Hex("2a1830"),
	}, ink = Hex("fbeaf3"), ref = Hex("45284d"), chat = { guild = Hex("9ff0c8"), officer = Hex("7fe0b0") } },
	{ id = "kawaiiDay", name = "Kawaii Day", light = true, colors = {
		bg = A("fff4f8", 0.98), bar = Hex("ffd9e8"), card = A("ffe9f2", 0.95), edge = Hex("e889b5"), dim = Hex("f2bcd4"),
		button = Hex("ffe6f0"), primary = Hex("ff8fc0"), close = Hex("f07aa8"), selected = Hex("ffc7de"),
		hover = A("e889b5", 0.15), stripe = A("e889b5", 0.06), input = Hex("fffaf2"),
		gold = Hex("b03a74"), text = Hex("5a3349"), tabtext = Hex("8a5a74"), subtext = Hex("8a5a74"),
		stamp = Hex("a07a90"), sys = Hex("8a7684"), primarytext = Hex("4a2038"),
	}, ink = Hex("4a2038"), ref = Hex("fffaf2"), chat = { guild = Hex("2f8f6a"), officer = Hex("1f7a55") } },
	{ id = "midnight", name = "Midnight", colors = {
		bg = A("0c1220", 0.97), bar = Hex("131c30"), card = A("16213a", 0.9), edge = Hex("6f8fbf"), dim = Hex("2c3a58"),
		button = Hex("18233b"), primary = Hex("2f5ea8"), close = Hex("3a4a6e"), selected = Hex("24365a"),
		hover = A("9fc0ff", 0.10), stripe = A("ffffff", 0.025), input = Hex("080d18"),
		gold = Hex("c9d8f2"), text = Hex("e2e8f3"), tabtext = Hex("a9b6cc"), subtext = Hex("a0adc4"),
		stamp = Hex("7484a3"), sys = Hex("a3acbd"), primarytext = Hex("ffffff"),
	}, ink = Hex("e2e8f3"), ref = Hex("18233b") },
	{ id = "contrast", name = "High contrast", colors = {
		bg = A("000000", 1), bar = Hex("0d0d0d"), card = A("111111", 1), edge = Hex("ffd200"), dim = Hex("8c8c8c"),
		button = Hex("1a1a1a"), primary = Hex("ffd200"), close = Hex("b30000"), selected = Hex("3a3000"),
		hover = A("ffffff", 0.15), stripe = A("ffffff", 0.05), input = Hex("000000"),
		gold = Hex("ffd200"), text = Hex("ffffff"), tabtext = Hex("e0e0e0"), subtext = Hex("e0e0e0"),
		stamp = Hex("d0d0d0"), sys = Hex("e0e0e0"), primarytext = Hex("000000"),
	}, ink = Hex("ffffff"), ref = Hex("1a1a1a") },
}

UI.theme = UI.THEMES[1]

function UI.Theme(id)
	for _, t in ipairs(UI.THEMES) do if t.id == id then return t end end
	return UI.THEMES[1]
end

-- Copy a theme's colours into UI.COLORS (in place: code holding UI.COLORS sees them).
function UI.ApplyTheme(id)
	local t = UI.Theme(id)
	UI.theme = t
	for k, v in pairs(t.colors or {}) do C[k] = v end
	return t
end

---------------------------------------------------------------------------
-- Readability
---------------------------------------------------------------------------
local function Lum(r, g, b)
	local function ch(x) return x <= 0.03928 and x / 12.92 or ((x + 0.055) / 1.055) ^ 2.4 end
	return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
end

function UI.Contrast(a, b)
	local la, lb = Lum(a[1], a[2], a[3]), Lum(b[1], b[2], b[3])
	if la < lb then la, lb = lb, la end
	return (la + 0.05) / (lb + 0.05)
end

UI.MIN_CONTRAST = 4.5

-- r, g, b moved toward the theme's ink until readable on its panels. Default: unchanged.
function UI.Readable(r, g, b)
	local t = UI.theme
	if not (t and t.ink and t.ref) or type(r) ~= "number" then return r, g, b end
	local c = { r, g or r, b or r }
	if UI.Contrast(c, t.ref) >= UI.MIN_CONTRAST then return r, g, b end
	local ink = t.ink
	for step = 1, 10 do
		local f = step / 10
		local m = { r + (ink[1] - r) * f, (g or r) + (ink[2] - (g or r)) * f, (b or r) + (ink[3] - (b or r)) * f }
		if UI.Contrast(m, t.ref) >= UI.MIN_CONTRAST or step == 10 then return m[1], m[2], m[3] end
	end
end

-- The same for colour codes inside text ("|cffffd100Elite|r").
function UI.Recolor(text)
	local t = UI.theme
	if type(text) ~= "string" or not (t and t.ink) or not text:find("|c", 1, true) then return text end
	return (text:gsub("|c(%x%x)(%x%x)(%x%x)(%x%x)", function(a, r, g, b)
		local nr, ng, nb = UI.Readable(tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255)
		return string.format("|c%s%02x%02x%02x", a, math.floor(nr * 255 + 0.5), math.floor(ng * 255 + 0.5), math.floor(nb * 255 + 0.5))
	end))
end

local classColor = UI.ClassColor
function UI.ClassColor(token)
	return UI.Readable(classColor(token))
end

-- Fix a text object of ours so whatever colour it's given stays readable.
local themed = setmetatable({}, { __mode = "k" })
function UI.ThemeText(obj)
	local t = UI.theme
	if not (t and t.ink) or themed[obj] or obj.noTheme then return end
	themed[obj] = true
	if obj.SetTextColor then
		local set = obj.SetTextColor
		obj.SetTextColor = function(self, r, g, b, a)
			local nr, ng, nb = UI.Readable(r, g, b)
			return set(self, nr, ng, nb, a)
		end
		if obj.GetTextColor then
			local r, g, b, a = obj:GetTextColor()
			if r then obj:SetTextColor(r, g, b, a) end
		end
	end
	if obj.SetText and obj.GetObjectType and obj:GetObjectType() == "FontString" then
		local set = obj.SetText
		obj.SetText = function(self, s, ...) return set(self, UI.Recolor(s), ...) end
		if obj.GetText then
			local s = obj:GetText()
			if s then set(obj, UI.Recolor(s)) end
		end
	end
	if obj.AddMessage then
		local add = obj.AddMessage
		obj.AddMessage = function(self, s, ...) return add(self, UI.Recolor(s), ...) end
	end
	if t.light and obj.SetShadowColor then obj:SetShadowColor(1, 1, 1, 0.35) end
end

-- Everything under a frame of ours. Cheap to repeat: objects already done are skipped.
function UI.ThemeTree(frame)
	local t = UI.theme
	if not (t and t.ink) or not frame then return end
	local kind = frame.GetObjectType and frame:GetObjectType()
	if kind == "EditBox" or kind == "ScrollingMessageFrame" then UI.ThemeText(frame) end
	if frame.GetRegions then
		for _, r in ipairs({ frame:GetRegions() }) do
			if r and r.GetObjectType and r:GetObjectType() == "FontString" then UI.ThemeText(r) end
		end
	end
	if frame.GetChildren then
		for _, ch in ipairs({ frame:GetChildren() }) do UI.ThemeTree(ch) end
	end
end

-- Before any frame is made: the saved theme.
function UI:OnLoad()
	UI.ApplyTheme(ns.db.settings.theme)
end

function UI.ChatColor(channel)
	local t = UI.theme
	return t and t.chat and t.chat[channel]
end
