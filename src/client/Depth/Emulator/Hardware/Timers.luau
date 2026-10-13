--!strict
--[[ Emulator/Hardware/Timers.luau

 Four cascadable 16-bit timers. Each preserves its cycle remainder across ticks
 so timing stays accurate regardless of how many cycles the CPU hands us at once.

   REG_TMxCNT (16-bit): bit7 enable, bit6 irq, bits4-5 cascade, bits0-1 prescaler
 ]]

local PRESCALE = { 1, 64, 256, 1024 }

local Timers = {}
Timers.__index = Timers

function Timers.new(interrupts: any)
	local timers = { interrupts = interrupts, list = {} }
	for i = 1, 4 do
		timers.list[i] = {
			counter = 0, reload = 0, control = 0,
			enabled = false, irq = false, cascade = false, prescale = 1,
			prescaleCounter = 0,
		}
	end
	return setmetatable(timers, Timers) :: any
end

local function decodeControl(t): nil
	local c = t.control
	t.prescale = PRESCALE[bit32.band(c, 3) + 1]
	t.cascade = bit32.band(c, 0x4) ~= 0
	t.irq = bit32.band(c, 0x40) ~= 0
	t.enabled = bit32.band(c, 0x80) ~= 0
end

function Timers:read16(addr: number): number
	local index = (addr - 0x100) // 4 + 1
	local t = self.list[index]
	if not t then return 0 end
	local reg = (addr - 0x100) % 4
	if reg == 0 then return t.counter end
	if reg == 2 then return t.control end
	return 0
end

function Timers:write16(addr: number, value: number)
	local index = (addr - 0x100) // 4 + 1
	local t = self.list[index]
	if not t then return end
	local reg = (addr - 0x100) % 4
	if reg == 0 then
		t.reload = bit32.band(value, 0xFFFF)
		if not t.enabled then t.counter = t.reload end
	elseif reg == 2 then
		local wasEnabled = t.enabled
		t.control = bit32.band(value, 0xFF)
		decodeControl(t)
		if t.enabled and not wasEnabled then
			t.counter = t.reload
			t.prescaleCounter = 0
		end
	end
end

--- Advance all timers by `cycles` CPU cycles.
function Timers:tick(cycles: number)
	for i = 1, 4 do
		local t = self.list[i]
		if not t.enabled then continue end
		if t.cascade then
			-- cascaded timers are clocked by the overflow of the previous one,
			-- handled inline below; skip here.
			continue
		end
		local inc = 0
		if t.prescale == 1 then
			inc = cycles
		else
			t.prescaleCounter += cycles
			inc = t.prescaleCounter // t.prescale
			t.prescaleCounter -= inc * t.prescale
		end
		Timers._advance(self, i, inc)
	end
end

--- Add `delta` ticks to timer `i`, cascading overflows to the next timer.
function Timers._advance(self, i: number, delta: number)
	if delta <= 0 then return end
	local t = self.list[i]
	local remaining = 0x10000 - t.counter
	if delta >= remaining then
		local period = 0x10000 - t.reload
		local overflows = 1 + (delta - remaining) // period
		t.counter = t.reload + (delta - remaining) % period
		if t.irq then self.interrupts:raise(2 + i) end
		if self.onOverflow then self.onOverflow(i - 1, overflows) end
		local nextT = self.list[i + 1]
		if nextT and nextT.enabled and nextT.cascade then Timers._advance(self, i + 1, overflows) end
	else
		t.counter += delta
	end
end

function Timers:reset()
	for i = 1, 4 do
		self.list[i] = { counter = 0, reload = 0, control = 0, enabled = false, irq = false, cascade = false, prescale = 1, prescaleCounter = 0 }
	end
end

return Timers
