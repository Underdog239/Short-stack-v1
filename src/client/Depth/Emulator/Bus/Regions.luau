--!strict
--[[ Emulator/Bus/Regions.luau

 GBA memory map constants + address decoding helpers.

   0x00000000  BIOS            16 KiB
   0x02000000  EWRAM          256 KiB
   0x03000000  IWRAM           32 KiB
   0x04000000  I/O registers
   0x05000000  Palette RAM      1 KiB
   0x06000000  VRAM            96 KiB
   0x07000000  OAM              1 KiB
   0x08000000  Game Pak ROM   up to 32 MiB (waitstates)
   0x0E000000  SRAM / Flash    64 KiB (mirrored)
 ]]

local Regions = {}

Regions.BIOS_BASE = 0x00000000
Regions.BIOS_SIZE = 0x4000
Regions.BIOS_MASK = Regions.BIOS_SIZE - 1

Regions.EWRAM_BASE = 0x02000000
Regions.EWRAM_SIZE = 0x40000
Regions.EWRAM_MASK = Regions.EWRAM_SIZE - 1

Regions.IWRAM_BASE = 0x03000000
Regions.IWRAM_SIZE = 0x8000
Regions.IWRAM_MASK = Regions.IWRAM_SIZE - 1

Regions.IO_BASE = 0x04000000
Regions.IO_MASK = 0x3FF

Regions.PAL_BASE = 0x05000000
Regions.PAL_SIZE = 0x400
Regions.PAL_MASK = Regions.PAL_SIZE - 1

Regions.VRAM_BASE = 0x06000000
Regions.VRAM_SIZE = 0x18000
Regions.VRAM_MASK = Regions.VRAM_SIZE - 1

Regions.OAM_BASE = 0x07000000
Regions.OAM_SIZE = 0x400
Regions.OAM_MASK = Regions.OAM_SIZE - 1

Regions.ROM_BASE = 0x08000000
Regions.ROM_END = 0x0E000000
Regions.SRAM_BASE = 0x0E000000
Regions.SRAM_SIZE = 0x10000
Regions.SRAM_MASK = Regions.SRAM_SIZE - 1

--- VRAM is 96 KiB (0x18000), which is *not* a power of two, so it cannot be
-- masked with size-1. The 32 KiB at 0x06018000-0x0601FFFF mirror the first
-- 32 KiB of VRAM; everything else addresses VRAM directly.
function Regions.vramOffset(addr: number): number
	local off = bit32.band(addr, 0x1FFFF)
	if off >= Regions.VRAM_SIZE then
		off -= 0x8000
	end
	return off
end

--- Return the memory region index for an address (fast top-byte branch).
function Regions.regionOf(addr: number): number
	local top = addr // 0x1000000
	if top <= 0x01 then return 1 end  -- BIOS
	if top == 0x02 then return 2 end  -- EWRAM
	if top == 0x03 then return 3 end  -- IWRAM
	if top == 0x04 then return 4 end  -- IO
	if top == 0x05 then return 5 end  -- Palette
	if top == 0x06 then return 6 end  -- VRAM
	if top == 0x07 then return 7 end  -- OAM
	if top <= 0x0D then return 8 end  -- ROM
	if top <= 0x0F then return 9 end  -- SRAM/Flash
	return 0
end

return Regions
