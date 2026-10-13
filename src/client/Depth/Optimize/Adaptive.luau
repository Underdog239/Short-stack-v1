--!strict
-- Bound work in wall-clock milliseconds. Screen scaling does not reduce CPU work.
local Adaptive = {}
Adaptive.__index = Adaptive
function Adaptive.new(touch: boolean?)
	local initial, maximum = touch and 4 or 8, touch and 6 or 10
	return setmetatable({ mode = "balanced", initial = initial, maximum = maximum, sliceMs = initial,
		slowFrames = 0, fastFrames = 0, averageMs = 16.7, averageWorkMs = initial,
		targetWorkMs = touch and 16 or 18, presentEvery = 1,
		renderEvery = 1, recoverySeconds = 0 }, Adaptive)
end
function Adaptive:setLowPower(enabled: boolean)
	self.mode = enabled and "battery" or "balanced"
	self.sliceMs = enabled and math.min(self.sliceMs, 3) or self.initial
	self.presentEvery = enabled and 2 or 1
	self.renderEvery = enabled and 2 or 1
	self.recoverySeconds = 0
end
-- Drop drawing work when emulation falls behind. Game logic, interrupts and
-- input keep their normal clock; this differs from merely hiding uploaded frames.
function Adaptive:sampleGameSpeed(fps: number)
	if fps < 45 then
		self.renderEvery = math.min(3, self.renderEvery + 1)
		self.recoverySeconds = 0
	elseif fps >= 57 then
		self.recoverySeconds += 1
		if self.recoverySeconds >= 3 then
			self.renderEvery = math.max(self.mode == "battery" and 2 or 1, self.renderEvery - 1)
			self.recoverySeconds = 0
		end
	else self.recoverySeconds = 0 end
end
function Adaptive:sample(frameMs: number, workMs: number)
	self.averageMs += (math.clamp(frameMs, 1, 250) - self.averageMs) * 0.05
	self.averageWorkMs += (math.clamp(workMs, 0, 250) - self.averageWorkMs) * 0.05
	-- A host capped at 20/30 FPS must not starve emulation. Judge the time
	-- Depth consumed in this callback, independently of Roblox's frame interval.
	if self.averageWorkMs > self.targetWorkMs + 2 then
		self.slowFrames += 1; self.fastFrames = 0
	elseif self.averageWorkMs < self.targetWorkMs then
		self.fastFrames += 1; self.slowFrames = 0
	else self.slowFrames, self.fastFrames = 0, 0 end
	if self.slowFrames >= 20 then
		self.sliceMs = math.max(self.mode == "battery" and 2 or 6, self.sliceMs - 1)
		self.presentEvery = 2
		self.slowFrames = 0
	elseif self.fastFrames >= 60 then
		self.sliceMs = math.min(self.mode == "battery" and 3 or self.maximum, self.sliceMs + 1)
		self.presentEvery = self.mode == "battery" and 2 or 1
		self.fastFrames = 0
	end
end
function Adaptive:shouldPresent(frameIndex: number): boolean
	return frameIndex % self.presentEvery == 0
end
return Adaptive
