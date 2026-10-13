--!strict
--[[ Emulator/Cart/HLEBIOS.luau

 High-level emulation of the GBA BIOS SWI interface. This lets commercial ROMs
 boot and run *without* shipping Nintendo's copyrighted 16 KiB BIOS image: each
 SWI is intercepted and reimplemented in Luau.

 If the user supplies a real bios.bin, GBA.luau will not install this module and
 SWIs vector through 0x08 instead (max accuracy).

 Register conventions follow the official BIOS: R0..R3 arguments, results in
 R0/R1, R4-R11/R12 preserved, flags undefined unless stated.
 ]]

local Interrupts = require(script.Parent.Parent.Hardware.Interrupts)

local HLEBIOS = {}
HLEBIOS.__index = HLEBIOS

function HLEBIOS.new(bus: any)
	-- Original IRQ trampoline: preserve caller registers, call the handler at
	-- IWRAM 0x7FFC, then restore CPSR and return from IRQ.
	local words = { [0x18] = 0xEA000038, [0x100] = 0xE92D500F,
		[0x104] = 0xE3A00301, [0x108] = 0xE1A0E00F, [0x10C] = 0xE510F004,
		[0x110] = 0xE8BD500F, [0x114] = 0xE25EF004 }
	for addr, word in words do
		for i = 0, 3 do bus.bios[addr + i + 1] = bit32.band(bit32.rshift(word, i * 8), 0xFF) end
	end
	return setmetatable({ bus = bus }, HLEBIOS) :: any
end

-- Helpers -------------------------------------------------------------------

local function signed(v: number): number
	v %= 0x100000000
	if v >= 0x80000000 then return v - 0x100000000 end
	return v
end

local function divArm(cpu, arm: boolean)
	local n = cpu.regs[1]
	local d = cpu.regs[2]
	if arm then n, d = d, n end
	if d == 0 then
		cpu.regs[1] = 0
		cpu.regs[2] = 0
		cpu.regs[4] = 0
		return
	end
	local sn, sd = signed(n), signed(d)
	local q = math.floor(math.abs(sn) / math.abs(sd))
	local r = math.abs(sn) % math.abs(sd)
	if (sn < 0) ~= (sd < 0) then q = -q end
	if sn < 0 then r = -r end
	cpu.regs[1] = q % 0x100000000
	cpu.regs[2] = r % 0x100000000
	cpu.regs[4] = math.abs(q) % 0x100000000
end

local function sqrt(cpu)
	local v = cpu.regs[1]
	cpu.regs[1] = math.floor(math.sqrt(v)) % 0x100000000
end

local function arcTan(cpu)
	local v = signed(cpu.regs[1])
	local a = math.atan(v / 16384)
	cpu.regs[1] = math.floor(a / (math.pi / 2) * 16384 + 0.5) % 0x10000
end

local function arcTan2(cpu)
	local x = signed(cpu.regs[1])
	local y = signed(cpu.regs[2])
	local a = math.atan2(y, x)
	cpu.regs[1] = math.floor(a / (2 * math.pi) * 65536 + 0.5) % 0x10000
end

local function cpuSet(cpu, fast: boolean)
	local src = cpu.regs[1]
	local dst = cpu.regs[2]
	local ctrl = cpu.regs[3]
	local count = bit32.band(ctrl, 0x1FFFFF)
	local word = fast or bit32.band(ctrl, 0x4000000) ~= 0
	if fast then count = math.ceil(count / 8) * 8 end
	assert(count <= 0x40000, "BIOS copy exceeds supported transfer size")
	src = bit32.band(src, word and 0xFFFFFFFC or 0xFFFFFFFE)
	dst = bit32.band(dst, word and 0xFFFFFFFC or 0xFFFFFFFE)
	local fill = bit32.band(ctrl, 0x1000000) ~= 0
	local bus = cpu.bus
	if word then
		local value = bus:read32(src)
		for i = 1, count do
			bus:write32(dst + (i - 1) * 4, value)
			if not fill then value = bus:read32(src + i * 4) end
		end
	else
		local value = bus:read16(src)
		for i = 1, count do
			bus:write16(dst + (i - 1) * 2, value)
			if not fill then value = bus:read16(src + i * 2) end
		end
	end
end

local function signed16(v: number): number
	v %= 0x10000
	return v >= 0x8000 and v - 0x10000 or v
end

-- Affine SWIs use the upper angle byte and signed 8.8 scale factors.
-- Quantize a quarter wave to 1.14, then mirror it to avoid floating point
-- residues at the cardinal angles. This remains HLE, not a BIOS image.
local sineQuarter = table.create(65)
for i = 0, 64 do sineQuarter[i + 1] = math.floor(math.sin(i * math.pi / 128) * 16384) end
local function sine(angle: number): number
	angle %= 256
	local quadrant, offset = angle // 64, angle % 64
	local value = sineQuarter[(quadrant % 2 == 0 and offset or 64 - offset) + 1]
	return quadrant < 2 and value or -value
end

local function affineMatrix(sx: number, sy: number, angle: number)
	local sin, cos = sine(angle), sine(angle + 64)
	local a = signed16(math.floor(sx * cos / 16384))
	local b = -signed16(math.floor(sx * sin / 16384))
	local c = signed16(math.floor(sy * sin / 16384))
	local d = signed16(math.floor(sy * cos / 16384))
	return a, b, c, d
end

local function affineSet(cpu, background: boolean)
	local bus, src, dst, count = cpu.bus, cpu.regs[1], cpu.regs[2], cpu.regs[3]
	assert(count <= 0x4000, "BIOS affine transfer exceeds supported size")
	local stride = background and 2 or cpu.regs[4]
	for _ = 1, count do
		local scaleOffset = background and 12 or 0
		local a, b, c, d = affineMatrix(signed16(bus:read16(src + scaleOffset)),
			signed16(bus:read16(src + scaleOffset + 2)), bit32.rshift(bus:read16(src + scaleOffset + 4), 8))
		local originX, originY = 0, 0
		if background then
			local x, y = signed16(bus:read16(src + 8)), signed16(bus:read16(src + 10))
			originX = (signed(bus:read32(src)) - a * x - b * y) % 0x100000000
			originY = (signed(bus:read32(src + 4)) - c * x - d * y) % 0x100000000
		end
		bus:write16(dst, a % 0x10000)
		bus:write16(dst + stride, b % 0x10000)
		bus:write16(dst + stride * 2, c % 0x10000)
		bus:write16(dst + stride * 3, d % 0x10000)
		if background then
			bus:write32(dst + 8, originX)
			bus:write32(dst + 12, originY)
		end
		src += background and 20 or 8
		dst += background and 16 or stride * 4
	end
end

-- Decode to a byte array so VRAM output uses halfword stores and overlapping
-- backreferences always see the bytes already produced.
local function decompress(cpu, vram: boolean, runLength: boolean)
	local bus, src, dst = cpu.bus, cpu.regs[1], cpu.regs[2]
	local header = bus:read32(src)
	local size = bit32.rshift(header, 8)
	assert(size <= 0x40000, "BIOS decompression exceeds 256 KiB")
	local out = table.create(size)
	src += 4
	while #out < size do
		local flag = bus:read8(src); src += 1
		if runLength then
			local repeatRun = bit32.band(flag, 0x80) ~= 0
			local count = bit32.band(flag, 0x7F) + (repeatRun and 3 or 1)
			local value = repeatRun and bus:read8(src) or 0
			if repeatRun then src += 1 end
			for _ = 1, math.min(count, size - #out) do
				if not repeatRun then value = bus:read8(src); src += 1 end
				table.insert(out, value)
			end
		else
			for bit = 7, 0, -1 do
				if #out >= size then break end
				if bit32.band(flag, bit32.lshift(1, bit)) == 0 then
					table.insert(out, bus:read8(src)); src += 1
				else
					local b1, b2 = bus:read8(src), bus:read8(src + 1); src += 2
					local length, distance = b1 // 16 + 3, (b1 % 16) * 256 + b2 + 1
					assert(distance <= #out, "Invalid LZ77 backreference")
					for _ = 1, math.min(length, size - #out) do table.insert(out, out[#out - distance + 1]) end
				end
			end
		end
	end
	if vram then
		for i = 1, size, 2 do bus:write16(dst + i - 1, out[i] + (out[i + 1] or 0) * 256) end
	else
		for i = 1, size do bus:write8(dst + i - 1, out[i]) end
	end
end

local function halt(cpu)
	cpu.halted = true
end

local function intrWait(cpu, vblank: boolean)
	local discard = vblank or cpu.regs[1] ~= 0
	local flags = vblank and 1 or bit32.band(cpu.regs[2], 0x3FFF)
	local bus = cpu.bus
	local checked = bus:read16(0x03007FF8)
	if discard then
		bus:write16(0x03007FF8, bit32.band(checked, bit32.bnot(flags)))
	elseif bit32.band(checked, flags) ~= 0 then
		bus:write16(0x03007FF8, bit32.band(checked, bit32.bnot(flags)))
		return
	end
	cpu.bus.interrupts.ime = 1
	cpu._intrWaitFlags = flags
	cpu.halted = true
end

local function registerRamReset(cpu)
	local flags, bus = cpu.regs[1], cpu.bus
	local regions = { {1, bus.ewram, 0x40000}, {2, bus.iwram, 0x7E00},
		{4, bus.pal, 0x400}, {8, bus.vram, 0x18000}, {16, bus.oam, 0x400} }
	for _, region in regions do
		if bit32.band(flags, region[1]) ~= 0 then
			for i = 1, region[3] do region[2][i] = 0 end
		end
	end
	bus.ppu.dispcnt = 0x80
	if bit32.band(flags, 0x40) ~= 0 then bus.sound:reset() end
	if bit32.band(flags, 0x80) ~= 0 then bus.dma:reset(); bus.timers:reset(); bus.interrupts:reset() end
end

local function softReset(cpu)
	local fromRAM = cpu.bus:read8(0x03007FFA) ~= 0
	for i = 0x7E01, 0x8000 do cpu.bus.iwram[i] = 0 end
	cpu:reset(fromRAM and 0x02000000 or 0x08000000)
	cpu:setCPSR(0x1F)
end

-- Dispatch ------------------------------------------------------------------

HLEBIOS.TABLE = {
	[0x00] = softReset,                 -- SoftReset
	[0x01] = registerRamReset,
	[0x02] = halt,
	[0x03] = halt,                                                 -- Stop
	[0x04] = function(cpu) intrWait(cpu, false) end,               -- IntrWait
	[0x05] = function(cpu) intrWait(cpu, true) end,                -- VBlankIntrWait
	[0x06] = function(cpu) divArm(cpu, false) end,
	[0x07] = function(cpu) divArm(cpu, true) end,
	[0x08] = sqrt,
	[0x09] = arcTan,
	[0x0A] = arcTan2,
	[0x0B] = function(cpu) cpuSet(cpu, false) end,
	[0x0C] = function(cpu) cpuSet(cpu, true) end,
	[0x0D] = function(cpu) cpu.regs[1] = 0xBAAE187F end,           -- GetBiosChecksum
	[0x0E] = function(cpu) affineSet(cpu, true) end,              -- BgAffineSet
	[0x0F] = function(cpu) affineSet(cpu, false) end,             -- ObjAffineSet
	[0x11] = function(cpu) decompress(cpu, false, false) end,
	[0x12] = function(cpu) decompress(cpu, true, false) end,
	[0x14] = function(cpu) decompress(cpu, false, true) end,
	[0x15] = function(cpu) decompress(cpu, true, true) end,
}

--- Handle a SWI. Returns true when handled in HLE.
function HLEBIOS:call(comment: number, cpu: any): boolean
	local fn = HLEBIOS.TABLE[comment]
	if fn then
		fn(cpu)
		return true
	end
	error(string.format("Unsupported BIOS SWI 0x%02X at PC 0x%08X", comment, cpu.regs[16]))
end

return HLEBIOS
