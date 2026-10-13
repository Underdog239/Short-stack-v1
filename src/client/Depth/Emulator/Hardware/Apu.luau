--!strict
--[[ Emulator/Hardware/Apu.luau

 GBA sound hardware: two square channels, a wave channel, a noise channel and
 the two DMA sound FIFOs, plus the master mixer (SOUNDCNT_L/H/X, SOUNDBIAS).

 The mixer produces
 signed 8-bit samples into a ring buffer that any sink can consume.

 This build exposes samples for inspection without audible Roblox playback.
 Sound accuracy remains experimental; see docs/AUDIO.md.
 ]]

local projectRoot = script:FindFirstAncestor("ShortStack")
assert(projectRoot, "Depth must be mounted under ShortStack")
local shared = projectRoot:WaitForChild("Shared")
local Config = require(shared:WaitForChild("Config") :: ModuleScript)

local Apu = {}
Apu.__index = Apu

-- Duty cycle waveforms (8 steps each).
local DUTY = {
	{ 0, 0, 0, 0, 0, 0, 0, 1 },
	{ 1, 0, 0, 0, 0, 0, 0, 1 },
	{ 1, 0, 0, 0, 0, 1, 1, 1 },
	{ 0, 1, 1, 1, 1, 1, 1, 0 },
}

local function newChannel()
	return {
		enabled = false, dac = false,
		freq = 0, timer = 0, duty = 0, dutyPos = 0,
		length = 0, lengthEnable = false,
		envVol = 0, envDir = 0, envPeriod = 0, envTimer = 0,
		sweepShift = 0, sweepDir = 0, sweepPeriod = 0, sweepTimer = 0,
		lfsr = 0x7FFF, width7 = false, divisor = 0, prescaler = 0,
		wavePos = 0, waveVol = 0, out = 0,
	}
end

function Apu.new(interrupts: any?)
	local self = setmetatable({
		interrupts = interrupts,
		regs = table.create(0x50, 0),
		waveRam = table.create(16, 0),
		fifoA = {}, fifoB = {}, fifoSampleA = 0, fifoSampleB = 0, frameAcc = 0, frameStep = 0,
		ch = { newChannel(), newChannel(), newChannel(), newChannel() },
		sampleAcc = 0,
		cyclesPerSample = Config.CPU_HZ / math.max(Config.AUDIO.sampleRate, 1),
		buffer = {},
		bufferLimit = 4096,
		sink = nil :: ((samples: { number }) -> ())?,
		masterEnable = false,
		outputEnabled = Config.AUDIO.enabled,
		samplesProduced = 0,
	}, Apu) :: any
	return self
end

-- Registers -----------------------------------------------------------------

function Apu:read16(off: number): number
	off = bit32.band(off, 0x3FE)
	if off >= 0x090 and off <= 0x09F then
		return self.waveRam[(off - 0x090) // 2 + 1] or 0
	end
	if off >= 0x0A0 and off <= 0x0A3 then return 0 end -- FIFO A write-only
	if off >= 0x0A4 and off <= 0x0A7 then return 0 end -- FIFO B write-only
	local idx = (off - 0x060) // 2 + 1
	return self.regs[idx] or 0
end

function Apu:write16(off: number, value: number)
	off = bit32.band(off, 0x3FE)
	value = bit32.band(value, 0xFFFF)
	if off >= 0x090 and off <= 0x09F then
		self.waveRam[(off - 0x090) // 2 + 1] = value
		return
	end
	if off >= 0x0A0 and off <= 0x0A3 then
		if #self.fifoA >= 32 then return end
		table.insert(self.fifoA, bit32.band(value, 0xFF))
		table.insert(self.fifoA, value // 0x100)
		return
	end
	if off >= 0x0A4 and off <= 0x0A7 then
		if #self.fifoB >= 32 then return end
		table.insert(self.fifoB, bit32.band(value, 0xFF))
		table.insert(self.fifoB, value // 0x100)
		return
	end
	local idx = (off - 0x060) // 2 + 1
	self.regs[idx] = value
	self:_applyRegister(off, value)
end

function Apu:_applyRegister(off: number, value: number)
	if off == 0x082 then
		if bit32.band(value, 0x0800) ~= 0 then table.clear(self.fifoA); self.fifoSampleA = 0 end
		if bit32.band(value, 0x8000) ~= 0 then table.clear(self.fifoB); self.fifoSampleB = 0 end
	end
	if off == 0x084 then
		self.masterEnable = bit32.band(value, 0x80) ~= 0
		if not self.masterEnable then
			for i = 1, 4 do self.ch[i].enabled = false end
		end
		return
	end
	if off == 0x064 then -- SOUND1CNT_X
		self:_trigger(1, value, 0x062)
	elseif off == 0x06C then -- SOUND2CNT_H
		self:_trigger(2, value, 0x068)
	elseif off == 0x074 then -- SOUND3CNT_X
		self:_trigger(3, value, 0x072)
	elseif off == 0x07C then -- SOUND4CNT_H
		self:_trigger(4, value, 0x078)
	end
end

local function regValue(self: any, off: number): number
	return self.regs[(off - 0x060) // 2 + 1] or 0
end

function Apu:_trigger(i: number, value: number, _envReg: number)
	local ch = self.ch[i]
	ch.freq = bit32.band(value, 0x7FF)
	ch.timer = self:_period(i)
	ch.lengthEnable = bit32.band(value, 0x4000) ~= 0
	local trigger = bit32.band(value, 0x8000) ~= 0
	if not trigger then return end

	ch.enabled = self.masterEnable
	ch.dac = true
	ch.dutyPos = 0
	ch.wavePos = 0

	if i == 1 or i == 2 or i == 4 then
		local envReg = (i == 1) and 0x062 or (i == 2 and 0x068 or 0x078)
		local env = regValue(self, envReg)
		ch.envPeriod = bit32.band(env // 0x100, 7)
		ch.envDir = bit32.band(env // 0x800, 1)
		ch.envVol = bit32.band(env // 0x1000, 0xF)
		ch.envTimer = ch.envPeriod
		ch.duty = bit32.band(env // 0x40, 3)
	end
	if i == 1 then
		local sweep = regValue(self, 0x060)
		ch.sweepShift = bit32.band(sweep, 7)
		ch.sweepDir = bit32.band(sweep // 0x8, 1)
		ch.sweepPeriod = bit32.band(sweep // 0x10, 7)
		ch.sweepTimer = ch.sweepPeriod
	end
	if i == 3 then
		local cnt = regValue(self, 0x072)
		ch.waveVol = bit32.band(cnt // 0x2000, 3)
	end
	if i == 4 then
		local cnt = value
		ch.divisor = bit32.band(cnt, 7)
		ch.width7 = bit32.band(cnt, 8) ~= 0
		ch.prescaler = bit32.band(cnt // 0x10, 0xF)
		ch.lfsr = 0x7FFF
	end
	-- length load
	local lenReg = (i == 1) and 0x062 or (i == 2 and 0x068 or (i == 3 and 0x072 or 0x078))
	local lenBits = bit32.band(regValue(self, lenReg), i == 3 and 0xFF or 0x3F)
	ch.length = (i == 3 and 256 or 64) - lenBits
end

function Apu:_period(i: number): number
	local ch = self.ch[i]
	local base = 2048 - ch.freq
	if i == 3 then return base * 8 end
	if i == 4 then
		local r = ch.divisor == 0 and 8 or ch.divisor * 16
		return r * 2 ^ ch.prescaler * 4
	end
	return base * 16
end

-- Clocking ------------------------------------------------------------------

function Apu:tick(cycles: number)
	if not self.masterEnable then return end
	self.frameAcc += cycles
	while self.frameAcc >= 32768 do
		self.frameAcc -= 32768
		self.frameStep = (self.frameStep + 1) % 8
		self:_tickEnvelopes()
	end
	for i = 1, 4 do self:_tickChannel(i, cycles) end
	if not self.outputEnabled or Config.AUDIO.mode == "off" then
		self.sampleAcc = 0
		return
	end
	self.sampleAcc += cycles
	local cps = self.cyclesPerSample
	local guard = 0
	while self.sampleAcc >= cps and guard < 512 do
		self.sampleAcc -= cps
		guard += 1
		self:_mixSample()
	end
	if guard >= 512 then self.sampleAcc = 0 end
end

function Apu:_tickChannel(i: number, cycles: number)
	local ch = self.ch[i]
	if not ch.enabled then return end
	ch.timer -= cycles
	local guard = 0
	while ch.timer <= 0 and guard < 64 do
		guard += 1
		ch.timer += math.max(self:_period(i), 1)
		if i == 1 or i == 2 then
			ch.dutyPos = (ch.dutyPos + 1) % 8
			ch.out = DUTY[ch.duty + 1][ch.dutyPos + 1] == 1 and ch.envVol or 0
		elseif i == 3 then
			ch.wavePos = (ch.wavePos + 1) % 32
			local word = self.waveRam[ch.wavePos // 4 + 1] or 0
			local byte = bit32.band(bit32.rshift(word, (ch.wavePos // 2 % 2) * 8), 0xFF)
			local nib = (ch.wavePos % 2 == 0) and (byte // 0x10) or bit32.band(byte, 0xF)
			local shift = (ch.waveVol == 0) and 4 or (ch.waveVol == 1 and 0 or (ch.waveVol == 2 and 1 or 2))
			ch.out = ch.waveVol == 0 and 0 or (nib // 2 ^ shift)
		else
			local bit = bit32.band(ch.lfsr, 1)
			local newBit = bit32.bxor(bit, bit32.band(ch.lfsr // 2, 1))
			ch.lfsr = bit32.bor(bit32.rshift(ch.lfsr, 1), bit32.lshift(newBit, 14))
			if ch.width7 then
				ch.lfsr = bit32.bor(bit32.band(ch.lfsr, bit32.bnot(0x40)), bit32.lshift(newBit, 6))
			end
			ch.out = (bit32.band(ch.lfsr, 1) == 0) and ch.envVol or 0
		end
	end
	if guard >= 64 then ch.timer = self:_period(i) end
end

--- Envelope + length tickers run at 64 Hz / 256 Hz on real hardware; we fold
-- them into the sample loop, which is equivalent for register-visible state.
function Apu:_tickEnvelopes()
	for i = 1, 4 do
		local ch = self.ch[i]
		if not ch.enabled then continue end
		if i ~= 3 and self.frameStep == 7 then
			if ch.envPeriod > 0 then
				ch.envTimer -= 1
				if ch.envTimer <= 0 then
					ch.envTimer = ch.envPeriod
					local v = ch.envVol + (ch.envDir == 1 and 1 or -1)
					if v >= 0 and v <= 15 then ch.envVol = v end
				end
			end
		end
		if self.frameStep % 2 == 0 and ch.lengthEnable and ch.length > 0 then
			ch.length -= 1
			if ch.length == 0 then ch.enabled = false end
		end
	end
end

-- Mixing --------------------------------------------------------------------

function Apu:_mixSample()

	local cntL = regValue(self, 0x080)
	local volL = bit32.band(cntL, 7)
	local volR = bit32.band(cntL // 0x100, 7)
	local enable = bit32.band(cntL // 0x1000, 0xF)

	local sum = 0
	local channels = 0
	for i = 1, 4 do
		if bit32.band(enable, bit32.lshift(1, i - 1)) ~= 0 then
			sum += self.ch[i].out
			channels += 1
		end
	end
	-- DMA sound FIFOs
	local cntH = regValue(self, 0x082)
	if bit32.band(cntH, 0x300) ~= 0 then sum += self.fifoSampleA / 16; channels += 1 end
	if bit32.band(cntH, 0x3000) ~= 0 then sum += self.fifoSampleB / 16; channels += 1 end

	local volume = math.max(volL, volR) / 7
	local sample = 0
	if channels > 0 then
		sample = math.floor((sum / channels) * 15 * volume * Config.AUDIO.master)
	end
	sample = math.clamp(sample, -128, 127)

	table.insert(self.buffer, sample)
	self.samplesProduced += 1
	if #self.buffer > self.bufferLimit then table.remove(self.buffer, 1) end
end

-- Direct sound advances on the selected hardware timer, independently of
-- the host sample rate. DMA1/2 refill a FIFO in four-word bursts.
function Apu:timerOverflow(index: number, count: number)
	if not self.masterEnable then return end
	local control = regValue(self, 0x082)
	for _, spec in { {"fifoA", "fifoSampleA", 0x400, 0x040000A0}, {"fifoB", "fifoSampleB", 0x4000, 0x040000A4} } do
		local timer = bit32.band(control, spec[3]) ~= 0 and 1 or 0
		if index ~= timer then continue end
		for _ = 1, count do
			local fifo = self[spec[1]]
			local byte = table.remove(fifo, 1)
			if byte then self[spec[2]] = byte >= 128 and byte - 256 or byte end
			if #fifo <= 16 and self.dma then self.dma:requestFIFO(spec[4]) end
		end
	end
end

--- Drain up to `n` samples (default: all).
function Apu:readSamples(n: number?): { number }
	n = math.clamp(math.floor(n or #self.buffer), 0, #self.buffer)
	local out = table.create(n)
	table.move(self.buffer, 1, n, 1, out)
	local remaining = #self.buffer - n
	table.move(self.buffer, n + 1, #self.buffer, 1, self.buffer)
	for i = #self.buffer, remaining + 1, -1 do self.buffer[i] = nil end
	return out
end

--- Attach a sink; it receives batches of samples as they are produced.
function Apu:setSink(fn: ((samples: { number }) -> ())?)
	self.sink = fn
end

function Apu:flush()
	if self.sink and #self.buffer > 0 then
		local batch = self:readSamples()
		pcall(self.sink, batch)
	end
end

function Apu:reset()
	for i = 1, 0x50 do self.regs[i] = 0 end
	for i = 1, 16 do self.waveRam[i] = 0 end
	table.clear(self.fifoA)
	table.clear(self.fifoB)
	table.clear(self.buffer)
	for i = 1, 4 do self.ch[i] = newChannel() end
	self.masterEnable = false
	self.sampleAcc = 0
	self.frameAcc, self.frameStep = 0, 0
	self.fifoSampleA, self.fifoSampleB = 0, 0
	self.samplesProduced = 0
end

return Apu
