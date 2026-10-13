--!strict
--[[ Emulator/GBA.luau

 Top-level console: owns the bus, CPU, PPU, DMA, timers, keypad and cartridge,
 and exposes the small surface the Roblox client actually needs.

   local gba = GBA.new({ rom = bytes })
   gba:setKeys(mask)
   local frame = gba:runFrame()   -- advances exactly one video frame
   local rgba = gba:framebuffer() -- 240*160*4 bytes
 ]]

local projectRoot = script:FindFirstAncestor("ShortStack")
assert(projectRoot, "Depth must be mounted under ShortStack")
local shared = projectRoot:WaitForChild("Shared")
local Config = require(shared:WaitForChild("Config") :: ModuleScript)

local MemoryBus = require(script.Parent.Bus.MemoryBus)
local Regions = require(script.Parent.Bus.Regions)
local Arm7tdmi = require(script.Parent.CPU.Arm7tdmi)
local IdleLoop = require(script.Parent.CPU.IdleLoop)
local Cartridge = require(script.Parent.Cart.Cartridge)
local HLEBIOS = require(script.Parent.Cart.HLEBIOS)
local Interrupts = require(script.Parent.Hardware.Interrupts)
local Timers = require(script.Parent.Hardware.Timers)
local Dma = require(script.Parent.Hardware.Dma)
local Keypad = require(script.Parent.Hardware.Keypad)
local Ppu = require(script.Parent.Hardware.Ppu)
local Apu = require(script.Parent.Hardware.Apu)

local GBA = {}
GBA.__index = GBA

function GBA.new(options: any)
	options = options or {}
	local self = setmetatable({}, GBA)

	self.bus = MemoryBus.new()
	self.interrupts = Interrupts.new()
	self.keypad = Keypad.new(self.interrupts)
	self.timers = Timers.new(self.interrupts)
	self.ppu = Ppu.new(self.bus, self.interrupts)
	self.dma = Dma.new(self.bus, self.interrupts)
	self.apu = Apu.new(self.interrupts)

	self.bus.interrupts = self.interrupts
	self.bus.keypad = self.keypad
	self.bus.timers = self.timers
	self.bus.ppu = self.ppu
	self.bus.dma = self.dma
	self.bus.sound = self.apu
	self.ppu.dma = self.dma

	self.cpu = Arm7tdmi.new(self.bus)
	self.bus.cpu = self.cpu
	self.apu.dma = self.dma
	self.timers.onOverflow = function(index, count) self.apu:timerOverflow(index, count) end
	self.cart = nil
	self.frames = 0
	self.pendingCycles = 0
	self.diag = options.diag
	self.bus.syncIO = function()
		self:flushCycles()
		self.bus.tickLimit = 0 -- register writes can schedule an earlier event
	end

	if options.bios then
		for i = 1, math.min(#options.bios, Regions.BIOS_SIZE) do
			self.bus.bios[i] = options.bios[i]
		end
	else
		self.bus.hleBios = HLEBIOS.new(self.bus)
	end

	if options.rom then
		self:loadROM(options.rom)
	end
	return self
end

--- Load a ROM image (byte array). Resets the machine to the entry point.
function GBA:loadROM(bytes: buffer | { number })
	self.cart = Cartridge.new(bytes)
	self.bus.cart = self.cart
	self:reset()
	return self.cart.info
end

function GBA:reset()
	if self.cart then self.cart.backend:reset() end
	for _, name in { "ewram", "iwram", "pal", "vram", "oam", "io" } do
		for i = 1, #self.bus[name] do self.bus[name][i] = 0 end
	end
	self.bus.cycles, self.bus.stallCycles, self.bus.openBus = 0, 0, 0
	self.bus.tickLimit = 0
	self.interrupts:reset()
	self.timers:reset()
	self.dma:reset()
	self.keypad:reset()
	self.ppu:reset()
	self.apu:reset()
	-- Hardware always begins execution at the ROM base; the 4 bytes at ROM
	-- offset 0 are the entry-point branch instruction itself.
	self.cpu:reset(self.bus.hleBios and 0x08000000 or 0)
	if self.bus.hleBios then self.cpu:setCPSR(0x1F) end
	self.frames = 0
	self.pendingCycles = 0
end

function GBA:setKeys(mask: number)
	self.keypad:setMask(mask)
end

function GBA:framebuffer(): buffer
	return self.ppu.framebuffer
end

function GBA:saveBytes(): { number }
	return self.cart and self.cart:saveBytes() or {}
end

function GBA:loadSaveBytes(bytes: { number })
	if self.cart then self.cart:loadSaveBytes(bytes) end
end

-- Accumulate ordinary CPU work between hardware events. Register accesses
-- synchronize immediately, and the cached limit never exceeds the next event.

-- A skipped wait must stop before anything can change its inputs: scanline
-- transitions/DMA/IRQs, timer overflow/FIFO refill, or an audio clock edge.
function GBA:nextEventCycles(): number
	local ppu = self.ppu
	local nextEvent = (ppu.dot < 1006 and 1006 or 1232) - ppu.dot
	for _, timer in self.timers.list do
		if timer.enabled and not timer.cascade then
			nextEvent = math.min(nextEvent, (0x10000 - timer.counter) * timer.prescale - timer.prescaleCounter)
		end
	end
	local apu = self.apu
	if apu.masterEnable then
		nextEvent = math.min(nextEvent, 32768 - apu.frameAcc)
		if apu.outputEnabled and Config.AUDIO.mode ~= "off" then
			nextEvent = math.min(nextEvent, apu.cyclesPerSample - apu.sampleAcc)
		end
		for _, ch in apu.ch do if ch.enabled then nextEvent = math.min(nextEvent, ch.timer) end end
	end
	return math.max(1, math.ceil(nextEvent))
end

function GBA:skipIdle(info: any): boolean
	self:flushCycles()
	if not self.cpu.irqDisable and self.interrupts:pending() then return false end
	local loops = math.floor((self:nextEventCycles() - 1) / info.cycles)
	if loops <= 0 then return false end
	local cycles = loops * info.cycles
	self.cpu.instructions += loops * info.instructions
	self.cpu.lastPc = info.finish
	self.cpu.idleCycles = (self.cpu.idleCycles or 0) + cycles
	self.bus:tick(cycles)
	return true
end

--- Run a single CPU instruction with proper cycle accounting.
function GBA:stepInstruction(fastHalt: boolean?)
	if self.cpu.halted then
		if fastHalt then self:flushCycles() end
		local pending = bit32.band(self.interrupts.ie, self.interrupts.if_)
		if pending ~= 0 then
			if self.cpu._intrWaitFlags and bit32.band(pending, self.cpu._intrWaitFlags) == 0 then
				self.bus:tick(fastHalt and self:nextEventCycles() or 4)
				return
			end
			self.cpu._intrWaitFlags = nil
			self.cpu.halted = false
		else
			self.bus:tick(fastHalt and self:nextEventCycles() or 4)
			return
		end
	end
	local cycles = self.cpu:step() + self.bus.stallCycles
	self.bus.stallCycles = 0
	local pending = self.pendingCycles + cycles
	self.pendingCycles = pending
	local limit = self.bus.tickLimit
	if limit == 0 then
		limit = math.min(Config.CORE.tickBatchCycles, self:nextEventCycles())
		self.bus.tickLimit = limit
	end
	if pending >= limit then self:flushCycles() end
end

--- Flush cycles still held back by batching.
function GBA:flushCycles()
	local pending = self.pendingCycles
	-- Clear before dispatch: timer/DMA callbacks may access IO recursively.
	self.pendingCycles = 0
	while pending > 0 do
		local step = math.min(pending, self:nextEventCycles())
		self.bus:tick(step)
		pending -= step
	end
end

--- Total emulated cycles including any not yet flushed to the components.
function GBA:cycles(): number
	return self.bus.cycles + self.pendingCycles
end

--- Run until the PPU completes one frame (or the safety budget is exhausted).
function GBA:runFrame(maxMilliseconds: number?): number
	self.ppu.frameComplete = false
	local guard = 0
	local maxIterations = Config.CORE.maxCyclesPerFrame
	local deadline = maxMilliseconds and os.clock() + maxMilliseconds / 1000 or nil
	local idle = nil
	local skipWaits = Config.CORE.idleLoopSkip and not Config.CORE.traceInstructions

	-- Optional fixed-budget mode: ignore VBlank pacing and run a set number of
	-- cycles. Used for benchmarking and for titles that need a speed nudge.
	if Config.CORE.skipFrameCap then
		local target = Config.CORE.fixedCyclesPerFrame
		local start = self:cycles()
		while self:cycles() - start < target and guard < maxIterations do
			self:stepInstruction()
			guard += 1
			if deadline and guard % 256 == 0 and os.clock() >= deadline then break end
		end
		self:flushCycles()
		self.frames += 1
		return self.ppu.frame
	end

	while not self.ppu.frameComplete do
		local skipped = false
		if skipWaits then
			local pc = self.cpu.regs[16]
			if idle and (pc < idle.start or pc > idle.finish or self.cpu.thumb ~= idle.thumb) then idle = nil end
			if (idle and pc == idle.start) or (not idle and guard % 127 == 126) then
				idle = IdleLoop.probe(self.cpu)
				if idle then skipped = self:skipIdle(idle) end
			end
		end
		if not skipped then self:stepInstruction(skipWaits) end
		guard += 1
		if deadline and guard % 32 == 0 and os.clock() >= deadline then break end
		if guard >= maxIterations then
			if self.diag then
				self.diag.report("frame budget exhausted before VBlank", {
					source = "GBA.runFrame", kind = "bug", severity = "warn",
					pc = self.cpu.regs[16],
				})
			end
			break
		end
	end
	self:flushCycles()
	if self.ppu.frameComplete then self.frames += 1 end
	return self.ppu.frame
end

--- Run for a fixed number of master cycles (used by benchmarks/tests).
function GBA:runCycles(cycles: number)
	local start = self:cycles()
	while self:cycles() - start < cycles do
		self:stepInstruction()
	end
	self:flushCycles()
end

function GBA:info()
	return {
		rom = self.cart and self.cart.info or nil,
		frames = self.frames,
		instructions = self.cpu.instructions,
		cycles = self.bus.cycles,
		hleBios = self.bus.hleBios ~= nil,
	}
end

return GBA
