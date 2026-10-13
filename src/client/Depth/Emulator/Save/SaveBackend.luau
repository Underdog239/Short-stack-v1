--!strict
--[[ Emulator/Save/SaveBackend.luau

 Battery-backed save hardware:

   SRAM         direct 8-bit access, 32 KiB mirrored
   Flash        command state machine (ID / erase / program / bank switch)
   EEPROM       serial protocol driven through DMA3 to 0x0D000000

 All three persist through the same readBytes()/loadBytes() pair, so the rest of
 the emulator never needs to know which chip is present.

 NOTE: Flash is modelled closely to the Sanyo/Macronix command set. EEPROM
 serial timing is modelled from the documented bit counts; it is covered by an
 internal round-trip test but has not been compared against real hardware.
 ]]

local SaveBackend = {}
SaveBackend.__index = SaveBackend

SaveBackend.NONE = "NONE"
SaveBackend.SRAM = "SRAM"
SaveBackend.FLASH512 = "FLASH512"
SaveBackend.FLASH1024 = "FLASH1024"
SaveBackend.EEPROM = "EEPROM"

local SIZE_OF = {
	SRAM = 0x8000,
	FLASH512 = 0x10000,
	FLASH1024 = 0x20000,
	EEPROM = 0x200, -- refined by romSize below
	NONE = 0,
}

--- EEPROM density follows ROM size: small carts use 512 B, larger use 8 KiB.
local function eepromSize(romSizeBytes: number): number
	return romSizeBytes <= 0x100000 and 0x200 or 0x2000
end

function SaveBackend.new(saveType: string, romSizeBytes: number)
	saveType = saveType or SaveBackend.NONE
	local size = SIZE_OF[saveType] or 0
	if saveType == SaveBackend.EEPROM then
		size = eepromSize(romSizeBytes or 0x800000)
	end
	local self = setmetatable({
		type = saveType,
		size = size,
		data = table.create(math.max(size, 1), 0xFF),
		-- flash state
		flashState = 0,
		flashBank = 0,
		flashIdMode = false,
		-- eeprom state
		eeBits = {},
		eeAddrBits = (size == 0x200) and 6 or 14,
		eeReadActive = false,
		eeOut = {},
		eeByte = 0,
		eeAddr = 0,
		eeCmd = 0,
		-- diagnostics
		writes = 0,
		readComplete = false,
	}, SaveBackend) :: any
	return self
end

-- Common --------------------------------------------------------------------

function SaveBackend:readBytes(): { number }
	local out = table.create(self.size, 0xFF)
	for i = 1, self.size do out[i] = self.data[i] or 0xFF end
	return out
end

function SaveBackend:loadBytes(bytes: { number })
	for i = 1, math.min(#bytes, self.size) do self.data[i] = bytes[i] end
end

function SaveBackend:sizeBytes(): number
	return self.size
end

-- SRAM / Flash memory-mapped access -----------------------------------------

function SaveBackend:_flashOffset(addr: number): number
	if self.type == SaveBackend.FLASH1024 then
		local bank = self.flashBank
		return bank * 0x10000 + bit32.band(addr, 0xFFFF)
	end
	return bit32.band(addr, 0xFFFF)
end

function SaveBackend:read8(addr: number): number
	if self.type == SaveBackend.SRAM then
		return self.data[bit32.band(addr, 0x7FFF) + 1] or 0
	elseif self.type == SaveBackend.FLASH512 or self.type == SaveBackend.FLASH1024 then
		local off = self:_flashOffset(addr)
		if self.flashIdMode then
			if off == 0 then return 0x62 end -- manufacturer (Sanyo)
			if off == 1 then
				return self.type == SaveBackend.FLASH512 and 0x13 or 0x1B
			end
			return 0
		end
		return self.data[off + 1] or 0xFF
	end
	return 0xFF
end

function SaveBackend:write8(addr: number, value: number)
	if self.type == SaveBackend.SRAM then
		self.data[bit32.band(addr, 0x7FFF) + 1] = bit32.band(value, 0xFF)
		self.writes += 1
	elseif self.type == SaveBackend.FLASH512 or self.type == SaveBackend.FLASH1024 then
		self:_flashWrite(addr, bit32.band(value, 0xFF))
		self.writes += 1
	end
end

--- Flash command state machine.
function SaveBackend:_flashWrite(addr: number, value: number)
	local low = bit32.band(addr, 0xFFFF)
	local off = self:_flashOffset(addr)
	local s = self.flashState

	if self.flashIdMode then
		if value == 0xF0 then self.flashIdMode = false end
		self.flashState = 0
		return
	end

	if value == 0xF0 and s ~= 6 then
		self.flashState = 0
		return
	end

	if s == 0 then
		if low == 0x5555 and value == 0xAA then self.flashState = 1 end
	elseif s == 1 then
		self.flashState = (low == 0x2AAA and value == 0x55) and 2 or 0
	elseif s == 2 then
		if low == 0x5555 then
			if value == 0x90 then self.flashIdMode = true; self.flashState = 0
			elseif value == 0x80 then self.flashState = 3
			elseif value == 0xA0 then self.flashState = 6
			elseif value == 0xB0 then self.flashState = 7
			else self.flashState = 0 end
		else
			self.flashState = 0
		end
	elseif s == 3 then
		self.flashState = (low == 0x5555 and value == 0xAA) and 4 or 0
	elseif s == 4 then
		self.flashState = (low == 0x2AAA and value == 0x55) and 5 or 0
	elseif s == 5 then
		if value == 0x30 then
			local base = bit32.band(off, bit32.bnot(0xFFF))
			for i = base, base + 0xFFF do
				if i < self.size then self.data[i + 1] = 0xFF end
			end
		elseif value == 0x10 then
			for i = 1, self.size do self.data[i] = 0xFF end
		end
		self.flashState = 0
	elseif s == 6 then
		self.data[off + 1] = value
		self.flashState = 0
	elseif s == 7 then
		self.flashBank = bit32.band(value, 1)
		self.flashState = 0
	end
end

-- EEPROM serial protocol (driven by DMA3) -----------------------------------

--- DMA3 request length identifies the EEPROM address width (6 or 14 bits).
function SaveBackend:beginEEPROM(count: number)
	local bits = (count == 9 or count == 73) and 6 or ((count == 17 or count == 81) and 14 or nil)
	assert(bits, "Invalid EEPROM DMA request length")
	self.eeAddrBits = bits
	self.size = bits == 6 and 512 or 8192
	for i = #self.data + 1, self.size do self.data[i] = 0xFF end
	for i = #self.data, self.size + 1, -1 do self.data[i] = nil end
	table.clear(self.eeBits)
end

function SaveBackend:eepromWriteHalf(value: number)
	table.insert(self.eeBits, bit32.band(value, 1))
	if #self.eeBits < 2 then return end
	local read = self.eeBits[2] == 1
	local length = 2 + self.eeAddrBits + (read and 0 or 64) + 1
	if #self.eeBits ~= length then return end
	local bits = self.eeBits
	assert(bits[1] == 1 and bits[length] == 0, "Invalid EEPROM serial frame")
	local block = 0
	for i = 3, 2 + self.eeAddrBits do block = block * 2 + bits[i] end
	local addr = (block * 8) % self.size
	if read then
		self.eeOut = {0, 0, 0, 0}
		for i = 1, 8 do
			local byte = self.data[addr + i]
			for bit = 7, 0, -1 do table.insert(self.eeOut, bit32.band(bit32.rshift(byte, bit), 1)) end
		end
		self.eeReadActive = true
	else
		for i = 0, 7 do
			local byte = 0
			for bit = 1, 8 do byte = byte * 2 + bits[2 + self.eeAddrBits + i * 8 + bit] end
			self.data[addr + i + 1] = byte
		end
		self.writes += 1
	end
	table.clear(self.eeBits)
end

function SaveBackend:eepromReadHalf(): number
	if #self.eeOut == 0 then self.eeReadActive = false; return 1 end
	return table.remove(self.eeOut, 1)
end

function SaveBackend:reset()
	self.flashState = 0
	self.flashBank = 0
	self.flashIdMode = false
	table.clear(self.eeBits)
	self.eeCmd = 0
	self.eeReadActive = false
	table.clear(self.eeOut)
end

return SaveBackend
