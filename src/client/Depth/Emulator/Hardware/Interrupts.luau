--!strict
--[[ Emulator/Hardware/Interrupts.luau

 GBA interrupt controller.
   REG_IE  0x200  (enabled)
   REG_IF  0x202  (requested / write-1-to-acknowledge)
   REG_IME 0x208  (master enable)

 Bit map: 0 VBlank 1 HBlank 2 VCounter 3 Timer0 4 Timer1 5 Timer2 6 Timer3
          7 Serial 8 DMA0 9 DMA1 10 DMA2 11 DMA3 12 Keypad 13 GamePak
 ]]

local Interrupts = {}
Interrupts.__index = Interrupts

Interrupts.VBLANK = 0
Interrupts.HBLANK = 1
Interrupts.VCOUNT = 2
Interrupts.TIMER0 = 3
Interrupts.TIMER1 = 4
Interrupts.TIMER2 = 5
Interrupts.TIMER3 = 6
Interrupts.SERIAL = 7
Interrupts.DMA0 = 8
Interrupts.DMA1 = 9
Interrupts.DMA2 = 10
Interrupts.DMA3 = 11
Interrupts.KEYPAD = 12
Interrupts.GAMEPAK = 13

function Interrupts.new()
	return setmetatable({ ie = 0, if_ = 0, ime = 0 }, Interrupts) :: any
end

function Interrupts:raise(bit: number)
	self.if_ = bit32.bor(self.if_, bit32.lshift(1, bit))
end

function Interrupts:pending(): boolean
	return self.ime ~= 0 and bit32.band(self.ie, self.if_) ~= 0
end

--- Return the highest-priority pending interrupt bit (0..13), or nil.
function Interrupts:pendingBit(): number?
	local active = bit32.band(self.ie, self.if_)
	if active == 0 then return nil end
	for bit = 0, 13 do
		if bit32.band(active, bit32.lshift(1, bit)) ~= 0 then return bit end
	end
	return nil
end

function Interrupts:read16(addr: number): number
	if addr == 0x200 then return self.ie end
	if addr == 0x202 then return self.if_ end
	if addr == 0x208 then return self.ime end
	return 0
end

function Interrupts:write16(addr: number, value: number)
	if addr == 0x200 then self.ie = bit32.band(value, 0x3FFF)
	elseif addr == 0x202 then self.if_ = bit32.band(self.if_, bit32.bnot(value)) -- write-1-to-clear
	elseif addr == 0x208 then self.ime = bit32.band(value, 1) end
end

function Interrupts:reset()
	self.ie = 0; self.if_ = 0; self.ime = 0
end

return Interrupts
