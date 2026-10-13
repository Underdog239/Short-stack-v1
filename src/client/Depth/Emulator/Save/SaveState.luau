--!strict
-- Session snapshots include every mutable hardware field. Object references
-- and callbacks stay attached to the live machine; ROM data is never copied.
local SaveState = {}
local REFERENCES = { bus = true, interrupts = true, ppu = true, dma = true,
	timers = true, keypad = true, cart = true, sound = true, hleBios = true,
	cpu = true, sink = true, onOverflow = true }
local COMPONENTS = { "cpu", "bus", "ppu", "dma", "timers", "interrupts", "keypad", "apu" }

local function copy(value: any): any
	if type(value) == "buffer" then
		local out = buffer.create(buffer.len(value))
		buffer.copy(out, 0, value)
		return out
	elseif type(value) == "table" then
		local out = {}
		for k, v in value do out[k] = copy(v) end
		return out
	end
	return value
end

local function capture(component: any): any
	local state = {}
	for k, v in component do
		if not REFERENCES[k] and type(v) ~= "function" then state[k] = copy(v) end
	end
	return state
end

local function restore(component: any, state: any)
	for k, v in component do
		if not REFERENCES[k] and type(v) ~= "function" then component[k] = nil end
	end
	for k, v in state do component[k] = copy(v) end
end

function SaveState.save(gba: any)
	assert(gba.cart, "Load a ROM before saving a state")
	local state = { version = 2, rom = gba.cart.rom, frames = gba.frames,
		pendingCycles = gba.pendingCycles, backend = capture(gba.cart.backend) }
	for _, name in COMPONENTS do state[name] = capture(gba[name]) end
	return state
end

function SaveState.load(gba: any, state: any): boolean
	-- Only snapshots created in this session for this exact cartridge qualify.
	if type(state) ~= "table" or state.version ~= 2 or not gba.cart or state.rom ~= gba.cart.rom then return false end
	for _, name in COMPONENTS do
		if type(state[name]) ~= "table" then return false end
	end
	if type(state.backend) ~= "table" then return false end
	for _, name in COMPONENTS do restore(gba[name], state[name]) end
	restore(gba.cart.backend, state.backend)
	gba.frames, gba.pendingCycles = state.frames, state.pendingCycles
	return true
end

return SaveState
