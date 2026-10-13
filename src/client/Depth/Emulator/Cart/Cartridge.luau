--!strict
--[[ Emulator/Cart/Cartridge.luau

 Parses a real GBA ROM header and exposes the ROM as a native Luau `buffer`.

 Why a buffer and not a Lua table: a byte table costs roughly 16 bytes per
 entry in TValue overhead, so a 16 MiB ROM would occupy ~250 MiB and generate
 heavy GC pressure. A buffer is exactly 16 MiB and lives outside the GC-managed
 table graph.

 IMPORTANT: buffer reads are bounds checked by the runtime and *throw* when out
 of range, where the old table form returned nil. The CPU can legitimately run
 off the end of a ROM (bad branch, PC past the image), so every accessor here
 clamps and returns 0 instead of raising.
 ]]

local projectRoot = script:FindFirstAncestor("ShortStack")
assert(projectRoot, "Depth must be mounted under ShortStack")
local shared = projectRoot:WaitForChild("Shared")
local Util = require(shared:WaitForChild("Util") :: ModuleScript)
local SaveBackend = require(script.Parent.Parent.Save.SaveBackend)

export type Cartridge = {
	rom: buffer,
	size: number,
	info: any,
	read8: (self: Cartridge, offset: number) -> number,
	read16: (self: Cartridge, offset: number) -> number,
	read32: (self: Cartridge, offset: number) -> number,
	saveBytes: (self: Cartridge) -> { number },
	loadSaveBytes: (self: Cartridge, bytes: { number }) -> (),
}

local Cartridge = {}
Cartridge.__index = Cartridge

local SAVE_EEPROM = "EEPROM"
local SAVE_SRAM = "SRAM"
local SAVE_FLASH512 = "FLASH512"
local SAVE_FLASH1024 = "FLASH1024"
local SAVE_NONE = "NONE"

-- (gameCode) -> save type. Kept short here; extend freely.
local SAVE_TABLE: { [string]: string } = {
	["A9PJ"] = SAVE_EEPROM,
	["AA4J"] = SAVE_EEPROM,
	["ABPP"] = SAVE_FLASH512,
	["AF4J"] = SAVE_EEPROM,
	["AGBJ"] = SAVE_EEPROM,
	["AIDJ"] = SAVE_EEPROM,
	["AR8J"] = SAVE_EEPROM,
	["AXVJ"] = SAVE_EEPROM,
}

-- Save hardware is identified the way real emulators do it: by scanning the ROM
-- for the marker string the linker leaves behind. Falls back to the game-code
-- table, then to SRAM.
local SAVE_MARKERS = {
	{ "FLASH1M_V", SAVE_FLASH1024 },
	{ "FLASH512_V", SAVE_FLASH512 },
	{ "FLASH_V", SAVE_FLASH512 },
	{ "SRAM_V", SAVE_SRAM },
	{ "EEPROM_V", SAVE_EEPROM },
}

local function detectSaveType(rom: buffer, gameCode: string): string
	-- Search fixed-size slices instead of buffer.tostring(rom), which would
	-- temporarily duplicate an entire 32 MiB cartridge string on mobile.
	local found: { [number]: boolean } = {}
	local ok = pcall(function()
		local length = buffer.len(rom)
		local chunkSize = 64 * 1024
		local overlap = 16
		local offset = 0
		while offset < length do
			local count = math.min(chunkSize + overlap, length - offset)
			local chunk = buffer.readstring(rom, offset, count)
			for index, marker in ipairs(SAVE_MARKERS) do
				if not found[index] and string.find(chunk, marker[1], 1, true) then
					found[index] = true
				end
			end
			if found[1] then return end
			offset += chunkSize
		end
	end)
	if ok then
		for index, marker in ipairs(SAVE_MARKERS) do
			if found[index] then
				return marker[2]
			end
		end
	end
	return SAVE_TABLE[gameCode] or SAVE_SRAM
end

--- Parse the 0x00..0xBF header from a ROM buffer. Never raises.
function Cartridge.parseHeader(rom: buffer): any
	local len = buffer.len(rom)

	local function u8(off: number): number
		if off < 0 or off >= len then return 0 end
		return buffer.readu8(rom, off)
	end

	local function str(off: number, count: number): string
		local bytes = table.create(count)
		for i = 1, count do bytes[i] = u8(off + i - 1) end
		return (Util.bytesToString(bytes)):gsub("[%z%s]+$", "")
	end

	local entry = u8(0) + u8(1) * 0x100 + u8(2) * 0x10000 + u8(3) * 0x1000000
	local checksum = -0x19
	for i = 0xA0, 0xBC do
		checksum = (checksum - u8(i)) % 256
	end
	local hdrChecksum = u8(0xBD)
	local sizeIndex = u8(0xBE)
	local gameCode = str(0xAC, 4)

	return {
		title = str(0xA0, 12),
		gameCode = gameCode,
		makerCode = str(0xB0, 2),
		version = u8(0xBC),
		entryPoint = entry,
		headerChecksum = hdrChecksum,
		headerChecksumOk = checksum == hdrChecksum,
		firmwareFlag = u8(0xB2),
		romSizeBytes = len,
		sizeIndex = sizeIndex,
		saveType = detectSaveType(rom, gameCode),
	}
end

--- Create a cartridge. Accepts a byte array (legacy paths / tests) or a buffer.
function Cartridge.new(romBytes: any): Cartridge
	local rom: buffer
	if Util.isBuffer(romBytes) then
		rom = romBytes
	else
		rom = Util.bytesToBuffer(romBytes)
	end
	assert(buffer.len(rom) >= 0xC0 and buffer.len(rom) <= 32 * 1024 * 1024, "ROM must be between 192 bytes and 32 MiB")
	local info = Cartridge.parseHeader(rom)
	return setmetatable({
		rom = rom,
		size = buffer.len(rom),
		info = info,
		-- Battery-backed save chip: SRAM, Flash or EEPROM (or a null backend).
		backend = SaveBackend.new(info.saveType, buffer.len(rom)),
	}, Cartridge) :: any
end

-- Accessors ----------------------------------------------------------------
-- All three clamp to the ROM and return 0 past the end. Unaligned reads are
-- natively supported by buffers, so no byte shifting is required in the common
-- case; the byte assembly path only exists for the final partial word.

function Cartridge:read8(offset: number): number
	if offset < 0 or offset >= self.size then return 0 end
	return buffer.readu8(self.rom, offset)
end

function Cartridge:read16(offset: number): number
	if offset >= 0 and offset + 2 <= self.size then
		return buffer.readu16(self.rom, offset)
	end
	return self:read8(offset) + self:read8(offset + 1) * 0x100
end

function Cartridge:read32(offset: number): number
	if offset >= 0 and offset + 4 <= self.size then
		return buffer.readu32(self.rom, offset)
	end
	return self:read8(offset)
		+ self:read8(offset + 1) * 0x100
		+ self:read8(offset + 2) * 0x10000
		+ self:read8(offset + 3) * 0x1000000
end

function Cartridge:saveBytes(): { number }
	return self.backend:readBytes()
end

function Cartridge:loadSaveBytes(bytes: { number })
	self.backend:loadBytes(bytes)
end

Cartridge.SAVE_EEPROM = SAVE_EEPROM
Cartridge.SAVE_SRAM = SAVE_SRAM
Cartridge.SAVE_FLASH512 = SAVE_FLASH512
Cartridge.SAVE_FLASH1024 = SAVE_FLASH1024
Cartridge.SAVE_NONE = SAVE_NONE

return Cartridge
