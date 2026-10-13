--!strict
-- Four DMA channels. Programmer-visible addresses are latched on enable;
-- repeating transfers advance the internal source and optionally reload dest.
local Interrupts = require(script.Parent.Interrupts)
local band = bit32.band
local Dma = {}
Dma.__index = Dma

local function channel()
	return { sad = 0, dad = 0, cnt = 0, cntHigh = 0, src = 0, dst = 0, active = false }
end

function Dma.new(bus: any, interrupts: any)
	return setmetatable({ bus = bus, interrupts = interrupts, ch = { channel(), channel(), channel(), channel() } }, Dma)
end

local function channelOf(addr: number): (number, number)
	return (addr - 0xB0) // 12 + 1, (addr - 0xB0) % 12
end

function Dma:read16(addr: number): number
	local i, off = channelOf(addr)
	local c = self.ch[i]
	if not c then return 0 end
	-- Source/destination/count registers are write-only.
	return off == 10 and c.cntHigh or 0
end

function Dma:write16(addr: number, value: number)
	local i, off = channelOf(addr)
	local c = self.ch[i]
	if not c then return end
	value = band(value, 0xFFFF)
	if off == 0 then c.sad = band(c.sad, 0xFFFF0000) + value
	elseif off == 2 then c.sad = band(c.sad, 0xFFFF) + band(value, i == 1 and 0x7FF or 0xFFF) * 0x10000
	elseif off == 4 then c.dad = band(c.dad, 0xFFFF0000) + value
	elseif off == 6 then c.dad = band(c.dad, 0xFFFF) + band(value, i == 4 and 0xFFF or 0x7FF) * 0x10000
	elseif off == 8 then c.cnt = band(value, i == 4 and 0xFFFF or 0x3FFF)
	elseif off == 10 then
		local wasEnabled = band(c.cntHigh, 0x8000) ~= 0
		c.cntHigh = band(value, 0xFFE0)
		if band(value, 0x8000) ~= 0 and not wasEnabled then
			local mask = band(value, 0x400) ~= 0 and 0xFFFFFFFC or 0xFFFFFFFE
			c.src, c.dst = band(c.sad, mask), band(c.dad, mask)
			if band(value, 0x3000) == 0 then self:_transfer(i) end
		end
	end
end

local function step(ctl: number, unit: number): number
	if ctl == 0 or ctl == 3 then return unit end
	return ctl == 1 and -unit or 0
end

function Dma:_transfer(i: number, fifo: boolean?)
	local c = self.ch[i]
	local control = c.cntHigh
	if c.active or band(control, 0x8000) == 0 then return end
	c.active = true
	local unit = (fifo or band(control, 0x400) ~= 0) and 4 or 2
	local count = fifo and 4 or c.cnt
	if count == 0 then count = i == 4 and 0x10000 or 0x4000 end
	local srcStep = step(band(control // 0x80, 3), unit)
	local dstCtl = band(control // 0x20, 3)
	local dstStep = fifo and 0 or step(dstCtl, unit)
	local src, dst = c.src, c.dst
	local bus = self.bus
	local backend = bus.cart and bus.cart.backend
	local function isEEPROM(addr)
		if not backend or backend.type ~= "EEPROM" then return false end
		return addr >= 0x0D000000 and addr < 0x0E000000
			and (bus.cart.size <= 0x1000000 or addr >= 0x0DFFFF00)
	end
	local srcEE, dstEE = i == 4 and isEEPROM(src), i == 4 and isEEPROM(dst)
	if dstEE and backend.beginEEPROM then backend:beginEEPROM(count) end
	for _ = 1, count do
		if srcEE then bus:write16(dst, backend:eepromReadHalf())
		elseif dstEE then backend:eepromWriteHalf(bus:read16(src))
		elseif unit == 4 then bus:write32(dst, bus:read32(src))
		else bus:write16(dst, bus:read16(src)) end
		src = (src + srcStep) % 0x10000000
		dst = (dst + dstStep) % 0x10000000
	end
	c.src, c.dst = src, dst
	if band(control, 0x4000) ~= 0 then self.interrupts:raise(Interrupts.DMA0 + i - 1) end
	local repeatTransfer = band(control, 0x200) ~= 0 and band(control, 0x3000) ~= 0
	if fifo or repeatTransfer then
		if dstCtl == 3 then c.dst = band(c.dad, unit == 4 and 0xFFFFFFFC or 0xFFFFFFFE) end
	else
		c.cntHigh = band(control, 0x7FFF)
	end
	c.active = false
	bus:addCycles(2 + count * (unit == 4 and 4 or 2))
end

function Dma:trigger(timing: number)
	for i = 1, 4 do
		local c = self.ch[i]
		if band(c.cntHigh, 0x8000) ~= 0 and band(c.cntHigh // 0x1000, 3) == timing then
			self:_transfer(i)
		end
	end
end

function Dma:requestFIFO(addr: number)
	for i = 2, 3 do
		local c = self.ch[i]
		if band(c.cntHigh, 0xB000) == 0xB000 and band(c.dad, 0xFFFFFFFC) == addr then
			self:_transfer(i, true)
		end
	end
end

function Dma:reset()
	for i = 1, 4 do self.ch[i] = channel() end
end

return Dma
