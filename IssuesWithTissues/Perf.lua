-- Profiler: /iwt perf on|off|reset, /iwt perf shows the report.
-- While on, every ns.On listener and every comm handler is timed through ns.Measure.
-- Off (the default) the wrapper is a plain call, so it costs nothing.

local _, ns = ...

local Perf = ns.RegisterModule("Perf", {})
ns.Perf = Perf

Perf.stats = {} -- label -> { calls, total ms, max ms }

local clock = debugprofilestop or function() return os.clock() * 1000 end

function Perf.IsOn()
	return ns.db and ns.db.perf and ns.db.perf.on
end

-- Run fn(...) and charge its time to label when the profiler is on.
function ns.Measure(label, fn, ...)
	if not Perf.IsOn() then return fn(...) end
	local start = clock()
	local results = { pcall(fn, ...) }
	local spent = clock() - start
	local s = Perf.stats[label]
	if not s then
		s = { calls = 0, total = 0, max = 0 }
		Perf.stats[label] = s
	end
	s.calls = s.calls + 1
	s.total = s.total + spent
	if spent > s.max then s.max = spent end
	if not results[1] then error(results[2], 0) end
	return unpack(results, 2)
end

-- Time the shared event dispatcher too.
local fire = ns.Fire
ns.Fire = function(event, ...)
	return ns.Measure("event " .. tostring(event), fire, event, ...)
end

function Perf.Report()
	local rows = {}
	for label, s in pairs(Perf.stats) do rows[#rows + 1] = { label = label, s = s } end
	table.sort(rows, function(a, b) return a.s.total > b.s.total end)
	local lines = { "Issues with Tissues profiler (" .. (Perf.IsOn() and "on" or "off") .. ")",
		"total ms | calls | max ms | what" }
	for _, r in ipairs(rows) do
		lines[#lines + 1] = string.format("%8.2f | %5d | %6.2f | %s", r.s.total, r.s.calls, r.s.max, r.label)
	end
	if #rows == 0 then lines[#lines + 1] = "(nothing measured yet: /iwt perf on)" end
	lines[#lines + 1] = ""
	local kb = ns.MemoryKB()
	lines[#lines + 1] = "Memory: " .. (kb and string.format("%.0f KB", kb) or "unknown")
	lines[#lines + 1] = "Startup: " .. ns.StartupText()
	return table.concat(lines, "\n")
end

ns.RegisterCommand("perf", "profiler: on, off, reset, or show the report", function(rest)
	rest = (rest or ""):lower()
	if rest == "on" or rest == "off" then
		ns.db.perf.on = (rest == "on")
		ns.Print("Profiler %s.", rest)
	elseif rest == "reset" then
		wipe(Perf.stats)
		ns.Print("Profiler reset.")
	elseif ns.UI and ns.UI.ShowCopyBox then
		ns.UI.ShowCopyBox("Profiler report", Perf.Report())
	else
		ns.Print(Perf.Report())
	end
end)
