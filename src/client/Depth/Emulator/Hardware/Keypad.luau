--!strict
--[[ Emulator/Hardware/Keypad.luau

 REG_KEYINPUT (0x130) is active-low: a 0 bit means the button is held.
 REG_KEYCNT  (0x132) selects IRQ-on-key combinations.

 Bit order: 0 A, 1 B, 2 Select, 3 Start, 4 Right, 5 Left, 6 Up, 7 Down, 8 R, 9 L
 ]]

local Interrupts = require(script.Parent.Interrupts)

local Keypad = {}
Keypad.__index = Keypad

Keypad.A = 0
Keypad.B = 1
Keypad.SELECT = 2
Keypad.START = 3
Keypad.RIGHT = 4
Keypad.LEFT = 5
Keypad.UP = 6
Keypad.DOWN = 7
Keypad.R = 8
Keypad.L = 9

function Keypad.new(interrupts: any)
	return setmetatable({
		interrupts = interrupts,
		held = 0,       -- bit set = pressed (logical)
		keycnt = 0,
	}, Keypad) :: any
end

function Keypad:setKey(bit: number, down: boolean)
	local before = self.held
	if down then
		self.held = bit32.bor(self.held, bit32.lshift(1, bit))
	else
		self.held = bit32.band(self.held, bit32.bnot(bit32.lshift(1, bit)))
	end
	if before ~= self.held then
		self:_maybeIrq()
	end
end

function Keypad:setMask(mask: number)
	self.held = bit32.band(mask, 0x3FF)
	self:_maybeIrq()
end

function Keypad:_maybeIrq()
	local irqBit = bit32.band(self.keycnt, 0x4000) ~= 0
	if not irqBit then return end
	local keys = bit32.band(self.keycnt, 0x3FF)
	local logic = bit32.band(self.keycnt, 0x8000) ~= 0
	local pressed = self.held
	if logic then
		if keys ~= 0 and bit32.band(pressed, keys) == keys then self.interrupts:raise(Interrupts.KEYPAD) end
	else
		if bit32.band(pressed, keys) ~= 0 then self.interrupts:raise(Interrupts.KEYPAD) end
	end
end

function Keypad:read16(addr: number): number
	if addr == 0x130 then
		-- active-low: invert held bits within the 10-key mask
		return bit32.band(bit32.bnot(self.held), 0x3FF)
	elseif addr == 0x132 then
		return self.keycnt
	end
	return 0
end

function Keypad:write16(addr: number, value: number)
	if addr == 0x132 then
		self.keycnt = bit32.band(value, 0xC3FF)
	end
end

function Keypad:reset()
	self.held = 0
	self.keycnt = 0
end

return Keypad
