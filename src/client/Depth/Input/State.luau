--!strict
-- Independent input sources prevent one finger/key release from releasing another.
local State = {}
State.__index = State
function State.new()
	return setmetatable({ held = {}, x = 0, y = 0 }, State)
end
function State:set(source: any, bit: number?, down: boolean)
	if down then
		assert(type(bit) == "number" and bit % 1 == 0 and bit >= 0 and bit <= 9, "Invalid GBA button")
		self.held[source] = bit
	else
		self.held[source] = nil
	end
end
function State:clear()
	table.clear(self.held)
	self.x, self.y = 0, 0
end
function State:mask(deadzone: number): number
	local mask = 0
	for _, bit in self.held do mask = bit32.bor(mask, bit32.lshift(1, bit)) end
	if self.x > deadzone then mask = bit32.bor(mask, 0x10) end
	if self.x < -deadzone then mask = bit32.bor(mask, 0x20) end
	if self.y > deadzone then mask = bit32.bor(mask, 0x40) end
	if self.y < -deadzone then mask = bit32.bor(mask, 0x80) end
	return mask
end
return State
