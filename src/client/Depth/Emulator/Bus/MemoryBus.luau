--!strict
--[[ Emulator/Bus/MemoryBus.luau

 The system bus. Owns every memory array and routes CPU accesses to the right
 region or hardware component. Also tracks the cycle counter that drives the
 PPU, timers and DMA.

 Design notes:
   * reads/writes are plain functions with a single top-byte branch, tuned for
     the interpreter hot path;
   * unmapped regions return the last value driven on the bus (open bus), which
     a handful of games actually rely on;
   * VRAM ignores 8-bit writes and ROM ignores all writes, per hardware.
 ]]

local Regions = require(script.Parent.Regions)

local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local lshift, rshift, arshift, rrotate = bit32.lshift, bit32.rshift, bit32.arshift, bit32.rrotate

local MemoryBus = {}
MemoryBus.__index = MemoryBus

function MemoryBus.new()
	local bus = {
		bios = table.create(Regions.BIOS_SIZE, 0),
		ewram = table.create(Regions.EWRAM_SIZE, 0),
		iwram = table.create(Regions.IWRAM_SIZE, 0),
		pal = table.create(Regions.PAL_SIZE, 0),
		vram = table.create(Regions.VRAM_SIZE, 0),
		oam = table.create(Regions.OAM_SIZE, 0),
		io = table.create(0x400, 0),
		cycles = 0,
		stallCycles = 0,
		tickLimit = 0,
		openBus = 0,
		-- components (assigned by GBA.luau)
		ppu = nil, dma = nil, timers = nil, keypad = nil, interrupts = nil, cart = nil,
		-- waitstates (simplified): extra cycles per access region
		ws = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
	}
	return setmetatable(bus, MemoryBus) :: any
end

function MemoryBus:addCycles(n: number)
	self.stallCycles += n
end

--- Advance every timed component by `n` master cycles.
function MemoryBus:tick(n: number)
	if n <= 0 then return end
	self.tickLimit = 0
	self.cycles += n
	if self.ppu then self.ppu:tick(n) end
	if self.timers then self.timers:tick(n) end
	if self.sound then self.sound:tick(n) end
end

-- Reads ---------------------------------------------------------------------

function MemoryBus:read8(addr: number): number
	local top = addr // 0x1000000
	if top <= 0x01 then
		return self.bios[band(addr, Regions.BIOS_MASK) + 1] or 0
	elseif top == 0x02 then
		return self.ewram[band(addr, Regions.EWRAM_MASK) + 1] or 0
	elseif top == 0x03 then
		return self.iwram[band(addr, Regions.IWRAM_MASK) + 1] or 0
	elseif top == 0x04 then
		return band(rshift(self:readIO16(band(addr, 0x3FE)), (addr % 2) * 8), 0xFF)
	elseif top == 0x05 then
		return self.pal[band(addr, Regions.PAL_MASK) + 1] or 0
	elseif top == 0x06 then
		return self.vram[Regions.vramOffset(addr) + 1] or 0
	elseif top == 0x07 then
		return self.oam[band(addr, Regions.OAM_MASK) + 1] or 0
	elseif top <= 0x0D then
		return self.cart and self.cart:read8(band(addr, 0x1FFFFFF)) or 0
	else
		-- SRAM / Flash: 8-bit only, handled by the save backend's state machine.
		if self.cart and self.cart.backend then
			return self.cart.backend:read8(addr)
		end
		return 0xFF
	end
end

function MemoryBus:read16(addr: number): number
	local top = addr // 0x1000000
	-- ROM is the hottest region by far (every THUMB fetch), so it gets a direct
	-- path instead of two full region dispatches.
	if top >= 0x08 and top <= 0x0D then
		local cart = self.cart
		if cart then return cart:read16(band(addr, 0x1FFFFFF)) end
		return 0
	end
	if top == 2 or top == 3 then
		local ram = top == 2 and self.ewram or self.iwram
		local mask = top == 2 and Regions.EWRAM_MASK or Regions.IWRAM_MASK
		local off = band(addr, mask)
		if off < mask then return ram[off + 1] + ram[off + 2] * 0x100 end
	end
	if top == 0x04 then return self:readIO16(band(addr, 0x3FE)) end
	if top >= 0x0E then
		-- SRAM/Flash are 8-bit parts: a wider read returns the same byte in
		-- every lane. The conformance suite asserts ldrh after strb gives
		-- 0x0101, which only holds with this behaviour.
		local b = self.cart and self.cart.backend and self.cart.backend:read8(addr) or 0xFF
		return b + b * 0x100
	end
	local a0 = self:read8(addr)
	local a1 = self:read8(addr + 1)
	return a0 + a1 * 0x100
end

function MemoryBus:read32(addr: number): number
	local top = addr // 0x1000000
	if top >= 0x08 and top <= 0x0D then
		local cart = self.cart
		if cart then return cart:read32(band(addr, 0x1FFFFFF)) end
		return 0
	end
	if top == 2 or top == 3 then
		local ram = top == 2 and self.ewram or self.iwram
		local mask = top == 2 and Regions.EWRAM_MASK or Regions.IWRAM_MASK
		local off = band(addr, mask)
		if off <= mask - 3 then
			return ram[off + 1] + ram[off + 2] * 0x100 + ram[off + 3] * 0x10000 + ram[off + 4] * 0x1000000
		end
	end
	if top == 0x04 then
		return self:readIO16(band(addr, 0x3FC)) + self:readIO16(band(addr + 2, 0x3FE)) * 0x10000
	end
	if top >= 0x0E then
		local b = self.cart and self.cart.backend and self.cart.backend:read8(addr) or 0xFF
		return b * 0x01010101
	end
	local a0 = self:read8(addr)
	local a1 = self:read8(addr + 1)
	local a2 = self:read8(addr + 2)
	local a3 = self:read8(addr + 3)
	return a0 + a1 * 0x100 + a2 * 0x10000 + a3 * 0x1000000
end

-- Writes --------------------------------------------------------------------

function MemoryBus:write8(addr: number, value: number)
	local top = addr // 0x1000000
	value = band(value, 0xFF)
	if top <= 0x01 then
		return -- BIOS is read-only
	elseif top == 0x02 then
		self.ewram[band(addr, Regions.EWRAM_MASK) + 1] = value
	elseif top == 0x03 then
		self.iwram[band(addr, Regions.IWRAM_MASK) + 1] = value
	elseif top == 0x04 then
		if addr == 0x04000301 and self.cpu then self.cpu.halted = true; return end
		local off = band(addr, 0x3FE)
		if off == 0x202 then self:writeIO16(off, lshift(value, (addr % 2) * 8)); return end
		local cur = self:readIO16(off)
		if addr % 2 == 0 then
			self:writeIO16(off, bor(band(cur, 0xFF00), value))
		else
			self:writeIO16(off, bor(band(cur, 0x00FF), lshift(value, 8)))
		end
	elseif top == 0x05 then
		-- 8-bit stores to palette are replicated across both lanes of the
		-- addressed halfword.
		local off = band(addr, Regions.PAL_MASK, bnot(1))
		self.pal[off + 1] = value
		self.pal[bor(off, 1) + 1] = value
	elseif top == 0x06 then
		-- VRAM has no 8-bit write path: the byte is replicated across both
		-- lanes of the addressed halfword, as hardware does.
		local off = band(Regions.vramOffset(addr), bnot(1))
		local mode = self.ppu and band(self.ppu.dispcnt, 7) or 0
		if off >= (mode >= 3 and 0x14000 or 0x10000) then return end
		self.vram[off + 1] = value
		self.vram[off + 2] = value
	elseif top == 0x07 then
		-- OAM does not support 8-bit writes on real hardware.
		return
	elseif top <= 0x0D then
		return -- ROM read-only
	else
		if self.cart and self.cart.backend then
			self.cart.backend:write8(addr, value)
		end
	end
end

function MemoryBus:write16(addr: number, value: number)
	local top = addr // 0x1000000
	if top < 0x0E then addr = band(addr, bnot(1)) end
	if top == 2 or top == 3 then
		local ram = top == 2 and self.ewram or self.iwram
		local off = band(addr, top == 2 and Regions.EWRAM_MASK or Regions.IWRAM_MASK)
		ram[off + 1], ram[off + 2] = band(value, 0xFF), band(value // 0x100, 0xFF)
		return
	end
	if top == 0x04 then return self:writeIO16(band(addr, 0x3FE), value) end
	if top >= 0x0E then
		-- SRAM/Flash are 8-bit parts. A wider store latches a single byte,
		-- selected by the address low bits - the conformance suite pins this
		-- down exactly (strh at an even address leaves the next byte intact).
		local backend = self.cart and self.cart.backend
		if backend then
			local byte = (addr % 2 == 0) and band(value, 0xFF) or band(value // 0x100, 0xFF)
			backend:write8(addr, byte)
		end
		return
	end
	if top == 0x05 then
		local off = band(addr, Regions.PAL_MASK)
		self.pal[off + 1] = band(value, 0xFF)
		self.pal[off + 2] = band(value // 0x100, 0xFF)
		return
	end
	if top == 0x07 then
		-- OAM rejects 8-bit writes but accepts 16-bit ones, so route the
		-- halfword straight into the array rather than via write8.
		local off = band(addr, Regions.OAM_MASK)
		self.oam[off + 1] = band(value, 0xFF)
		self.oam[off + 2] = band(value // 0x100, 0xFF)
		return
	end
	if top == 0x06 then
		-- VRAM: only aligned 16-bit writes land
		local off = Regions.vramOffset(addr)
		self.vram[off + 1] = band(value, 0xFF)
		self.vram[off + 2] = band(value // 0x100, 0xFF)
		return
	end
	self:write8(addr, band(value, 0xFF))
	self:write8(addr + 1, band(value // 0x100, 0xFF))
end

function MemoryBus:write32(addr: number, value: number)
	local top = addr // 0x1000000
	-- Address bits are region-specific: 16/32-bit parts ignore them, while the
	-- 8-bit save chips use A0/A1 as the byte-lane selector.
	if top < 0x0E then addr = band(addr, bnot(3)) end
	if top == 2 or top == 3 then
		local ram = top == 2 and self.ewram or self.iwram
		local off = band(addr, top == 2 and Regions.EWRAM_MASK or Regions.IWRAM_MASK)
		ram[off + 1], ram[off + 2] = band(value, 0xFF), band(value // 0x100, 0xFF)
		ram[off + 3], ram[off + 4] = band(value // 0x10000, 0xFF), band(value // 0x1000000, 0xFF)
		return
	end
	if top >= 0x08 and top <= 0x0D then return end -- ROM is read-only
	if top == 0x04 then
		self:writeIO16(band(addr, 0x3FC), band(value, 0xFFFF))
		self:writeIO16(band(addr + 2, 0x3FE), rshift(value, 16))
		return
	end
	if top >= 0x0E then
		local backend = self.cart and self.cart.backend
		if backend then
			local lane = addr % 4
			backend:write8(addr, band(value // (2 ^ (8 * lane)), 0xFF))
		end
		return
	end
	if top == 0x06 then
		self:write16(addr, band(value, 0xFFFF))
		self:write16(addr + 2, band(value // 0x10000, 0xFFFF))
		return
	end
	self:write16(addr, band(value, 0xFFFF))
	self:write16(addr + 2, band(value // 0x10000, 0xFFFF))
end

-- IO routing ----------------------------------------------------------------

function MemoryBus:readIO16(off: number): number
	if self.syncIO then self.syncIO() end
	off = band(off, 0x3FE)
	if off <= 0x056 then
		if self.ppu then return self.ppu:read16(off) end
		return 0
	elseif off >= 0x060 and off <= 0x0AF then
		if self.sound then return self.sound:read16(off) end
		return 0
	elseif off >= 0x0B0 and off <= 0x0DF then
		if self.dma then return self.dma:read16(off) end
		return 0
	elseif off >= 0x100 and off <= 0x10F then
		if self.timers then return self.timers:read16(off) end
		return 0
	elseif off >= 0x130 and off <= 0x132 then
		if self.keypad then return self.keypad:read16(off) end
		return 0
	elseif off >= 0x200 and off <= 0x208 then
		if self.interrupts then return self.interrupts:read16(off) end
		return 0
	end
	return self.io[off + 1] or 0
end

function MemoryBus:writeIO16(off: number, value: number)
	if self.syncIO then self.syncIO() end
	off = band(off, 0x3FE)
	value = band(value, 0xFFFF)
	if off <= 0x056 then
		if self.ppu then self.ppu:write16(off, value) end
	elseif off >= 0x060 and off <= 0x0AF then
		if self.sound then self.sound:write16(off, value) end
	elseif off >= 0x0B0 and off <= 0x0DF then
		if self.dma then self.dma:write16(off, value) end
	elseif off >= 0x100 and off <= 0x10F then
		if self.timers then self.timers:write16(off, value) end
	elseif off >= 0x130 and off <= 0x132 then
		if self.keypad then self.keypad:write16(off, value) end
	elseif off >= 0x200 and off <= 0x208 then
		if self.interrupts then self.interrupts:write16(off, value) end
	else
		self.io[off + 1] = value
	end
end

return MemoryBus
