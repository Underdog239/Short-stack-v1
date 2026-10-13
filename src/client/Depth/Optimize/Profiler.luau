--!strict
--[[ Optimize/Profiler.luau

 Named stopwatch sections with rolling averages. The emulator loop wraps the
 hot stages (cpu, ppu, present) so the diagnostics dashboard can show where the
 frame budget actually goes, and the adaptive optimizer can act on it.
 ]]

local Profiler = {}
Profiler.__index = Profiler

function Profiler.new(samples: number?)
	return setmetatable({ _sections = {}, _max = samples or 60 }, Profiler) :: any
end

function Profiler:beginSection(name: string)
	self._sections[name] = self._sections[name] or { total = 0, count = 0, samples = {}, open = 0 }
	self._sections[name].open = os.clock()
end

function Profiler:endSection(name: string)
	local s = self._sections[name]
	if not s or s.open == 0 then return end
	local dt = (os.clock() - s.open) * 1000
	s.open = 0
	s.total += dt
	s.count += 1
	table.insert(s.samples, dt)
	if #s.samples > self._max then table.remove(s.samples, 1) end
end

function Profiler:avg(name: string): number
	local s = self._sections[name]
	if not s or #s.samples == 0 then return 0 end
	local sum = 0
	for _, v in s.samples do sum += v end
	return sum / #s.samples
end

function Profiler:report(): { [string]: number }
	local out = {}
	for name in self._sections do
		out[name] = self:avg(name)
	end
	return out
end

function Profiler:reset()
	table.clear(self._sections)
end

return Profiler
