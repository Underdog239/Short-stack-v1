--!strict
-- Prove one short THUMB iteration leaves registers/flags unchanged and has
-- no writes or volatile reads. Only then may the runner skip whole iterations
-- up to the next hardware event. Re-probe after each event; never cache RAM
-- contents or assume a particular game's addresses.
local IdleLoop = {}
local band = bit32.band

local function stableMemory(addr: number, width: number): boolean
	local top = addr // 0x1000000
	return (top == 0 or top == 2 or top == 3 or (top >= 8 and top <= 12))
		and (addr + width - 1) // 0x1000000 == top
end

function IdleLoop.probe(cpu: any): any?
	if cpu.halted then return nil end
	local start = cpu.regs[16]
	if not stableMemory(start, 16) then return nil end
	if not cpu.thumb then
		local op = cpu.bus:read32(start)
		local cond = op // 0x10000000
		if band(op, 0x0FFFFFFF) == 0x0AFFFFFE and cond < 15 and cpu:condition(cond) then
			return { start = start, finish = start, cycles = 3, instructions = 1, thumb = false }
		end
		return nil
	end
	local shadow = setmetatable({ regs = table.clone(cpu.regs), n = cpu.n,
		z = cpu.z, c = cpu.c, v = cpu.v }, { __index = cpu })
	local cycles = 0
	for i = 1, 8 do
		local pc = start + (i - 1) * 2
		local op = cpu.bus:read16(pc)
		local top, allowed = op // 0x1000, false
		if top <= 3 or (op >= 0x4000 and op < 0x4400) then
			allowed = true -- low-register arithmetic; no PC/mode/stack effects
		elseif op >= 0x4800 and op < 0x5000 then
			allowed = stableMemory(band(pc + 4, 0xFFFFFFFC) + (op % 256) * 4, 4)
		elseif (top == 6 or top == 7 or top == 8) and band(op, 0x800) ~= 0 then
			local width = top == 8 and 2 or (top == 7 and 1 or 4)
			local addr = shadow.regs[(op // 8) % 8 + 1] + ((op // 64) % 32) * width
			allowed = stableMemory(addr, width)
		elseif top == 5 and (op // 512) % 8 >= 3 then
			local addr = shadow.regs[(op // 8) % 8 + 1] + shadow.regs[(op // 64) % 8 + 1]
			allowed = stableMemory(addr, 4) -- all these encodings are loads
		elseif (top == 13 and (op // 256) % 16 < 14) or op // 0x800 == 0x1C then
			shadow.regs[16] = pc + 2
			cycles += shadow:executeTHUMB(op)
			if shadow.regs[16] ~= start then return nil end
			for reg = 1, 16 do if shadow.regs[reg] ~= cpu.regs[reg] then return nil end end
			if shadow.n ~= cpu.n or shadow.z ~= cpu.z or shadow.c ~= cpu.c or shadow.v ~= cpu.v then return nil end
			return { start = start, finish = pc, cycles = cycles, instructions = i, thumb = true }
		end
		if not allowed then return nil end
		shadow.regs[16] = pc + 2
		cycles += shadow:executeTHUMB(op)
	end
	return nil
end

return IdleLoop
