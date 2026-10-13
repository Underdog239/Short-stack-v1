--!strict
-- Client-only adapter between the Short Stack UI and Depth's GBA machine.
-- The emulator is budgeted per RenderStepped callback; the GUI is never asked
-- to draw one Instance per GBA pixel on the primary EditableImage path.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local projectRoot = script:FindFirstAncestor("ShortStack")
assert(projectRoot, "GBAHost must be mounted under ShortStack")

local depth = projectRoot:WaitForChild("Depth")
local emulatorFolder = depth:WaitForChild("Emulator")
local inputFolder = depth:WaitForChild("Input")
local renderFolder = depth:WaitForChild("Render")
local optimizeFolder = depth:WaitForChild("Optimize")
local shared = projectRoot:WaitForChild("Shared")

local GBA = require(emulatorFolder:WaitForChild("GBA") :: ModuleScript)
local DemoROM = require(emulatorFolder:WaitForChild("DemoROM") :: ModuleScript)
local ROMLoader = require(emulatorFolder:WaitForChild("ROMLoader") :: ModuleScript)
local SaveState = require(emulatorFolder:WaitForChild("Save"):WaitForChild("SaveState") :: ModuleScript)
local Input = require(inputFolder :: ModuleScript)
local Renderer = require(renderFolder :: ModuleScript)
local Adaptive = require(optimizeFolder:WaitForChild("Adaptive") :: ModuleScript)
local Config = require(shared:WaitForChild("Config") :: ModuleScript)

local Host = {}
Host.__index = Host

function Host.new()
	return setmetatable({
		_running = false,
		_paused = false,
		_connections = {},
		_debt = 0,
		_emulatedFrames = 0,
		_metricClock = 0,
		_savedState = nil,
	}, Host)
end

function Host:_status(message: string)
	if self._callbacks and self._callbacks.onStatus then
		self._callbacks.onStatus(message)
	end
end

function Host:_stopConnections()
	if self._renderConnection then
		self._renderConnection:Disconnect()
		self._renderConnection = nil
	end
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	table.clear(self._connections)
end

function Host:_fail(message: string)
	self._running = false
	self._paused = true
	self:_stopConnections()
	if self.input then
		self.input:destroy()
		self.input = nil
	end
	self:_status(message)
end

function Host:_onFrame(dt: number)
	if not self._running or self._paused then
		return
	end

	local frameStart = os.clock()
	self._debt = math.min(self._debt + dt, 2 / Config.FPS)
	if self._debt >= 1 / Config.FPS then
		self.gba:setKeys(self.input.mask)
		self.gba.ppu.renderEvery = self.adaptive.renderEvery
		local deadline = os.clock() + self.adaptive.sliceMs / 1000
		local completedFrames = 0

		while self._debt >= 1 / Config.FPS and completedFrames < 2 do
			local remainingMs = (deadline - os.clock()) * 1000
			if remainingMs <= 0 then
				break
			end

			local ok, failure = pcall(function()
				self.gba:runFrame(remainingMs)
			end)
			if not ok then
				self:_fail("Emulation stopped safely: " .. tostring(failure))
				return
			end
			if not self.gba.ppu.frameComplete then
				break
			end

			self._emulatedFrames += 1
			completedFrames += 1
			self._debt = math.max(0, self._debt - 1 / Config.FPS)
			if self.gba.ppu.frameRendered then
				local presentOk, presentFailure = pcall(function()
					self.renderer:present(self.gba:framebuffer())
				end)
				if not presentOk then
					self:_fail("Display stopped safely: " .. tostring(presentFailure))
					return
				end
			end
		end
	end

	local workMs = (os.clock() - frameStart) * 1000
	local hostFrameMs = math.max(dt * 1000, workMs)
	self.adaptive:sample(hostFrameMs, workMs)
	self._metricClock += dt
	if self._metricClock >= 0.5 then
		self._metricClock = 0
		local fps = dt > 0 and (1 / dt) or 0
		local metrics = string.format(
			"DEPTH  ·  %s  ·  host %.0f FPS  ·  %d GBA frames  ·  %.1f ms budget",
			self.renderer.backend,
			fps,
			self._emulatedFrames,
			self.adaptive.sliceMs
		)
		if self._callbacks and self._callbacks.onMetrics then
			self._callbacks.onMetrics(metrics)
		end
	end
end

function Host:Start(parent: GuiObject, source: string, callbacks: { [string]: any }?): (boolean, string)
	self:Stop()
	self._callbacks = callbacks or {}

	local romBytes
	local romSource
	if source == "demo" then
		local ok, result = pcall(DemoROM.create)
		if not ok then
			return false, "Could not build the original demo ROM: " .. tostring(result)
		end
		romBytes = result
		romSource = "Original Depth homebrew demo"
	elseif source == "installed" then
		local ok, bytes, label = pcall(ROMLoader.find)
		if not ok then
			return false, "Local ROM data could not be read: " .. tostring(bytes)
		end
		if not bytes then
			return false, tostring(label)
		end
		romBytes = bytes
		romSource = label or "Local ROM"
	else
		return false, "Unknown GBA launch source."
	end

	local core = GBA.new()
	-- Keep hardware state/timers accurate, but skip PCM table churn when no
	-- authorized client audio output is configured.
	core.apu.outputEnabled = false
	local loadOk, gameInfo = pcall(function()
		return core:loadROM(romBytes)
	end)
	if not loadOk then
		return false, "ROM validation failed: " .. tostring(gameInfo)
	end

	local rendererOk, renderer = pcall(function()
		return Renderer.new(parent, { scale = Config.RENDER.scale })
	end)
	if not rendererOk then
		return false, "Display could not be created: " .. tostring(renderer)
	end
	local inputOk, input = pcall(Input.new)
	if not inputOk then
		renderer:destroy()
		return false, "Input could not be initialized: " .. tostring(input)
	end

	self.gba = core
	self.renderer = renderer
	self.input = input
	self.adaptive = Adaptive.new(UserInputService.TouchEnabled)
	self._debt = 0
	self._emulatedFrames = 0
	self._metricClock = 0
	self._savedState = nil
	self._running = true
	self._paused = false
	self.input:setEnabled(true)

	local initialFrameOk, initialFrameFailure = pcall(function()
		self.renderer:present(self.gba:framebuffer(), true)
	end)
	if not initialFrameOk then
		self:Stop()
		return false, "Initial display upload failed: " .. tostring(initialFrameFailure)
	end

	table.insert(self._connections, UserInputService.WindowFocusReleased:Connect(function()
		if self._running and not self._paused then
			self._resumeOnFocus = true
			self:SetPaused(true)
		end
	end))
	table.insert(self._connections, UserInputService.WindowFocused:Connect(function()
		if self._resumeOnFocus then
			self._resumeOnFocus = false
			self:SetPaused(false)
		end
	end))

	self._renderConnection = RunService.RenderStepped:Connect(function(dt)
		self:_onFrame(dt)
	end)
	self:_status(string.format("%s · %s", gameInfo.title, romSource))
	return true, gameInfo.title
end

function Host:SetPaused(paused: boolean)
	if not self._running then
		return
	end
	self._paused = paused
	self.input:setEnabled(not paused)
	if paused then
		self:_status("Paused · input released")
	else
		self:_status("Running · " .. (self.gba.cart and self.gba.cart.info.title or "Game Boy Advance"))
	end
end

function Host:IsPaused(): boolean
	return self._paused
end

function Host:IsRunning(): boolean
	return self._running
end

function Host:Touch(source: any, buttonBit: number, down: boolean)
	if self.input and self._running then
		self.input:touch(source, buttonBit, down)
	end
end

function Host:SaveState(): boolean
	if not self._running or not self.gba.cart then
		return false
	end
	local ok, state = pcall(SaveState.save, self.gba)
	if not ok then
		self:_status("Save state failed: " .. tostring(state))
		return false
	end
	self._savedState = state
	self:_status("State snapshot saved in this client session")
	return true
end

function Host:LoadState(): boolean
	if not self._running or not self._savedState then
		self:_status("No state snapshot is saved for this session")
		return false
	end
	local ok, restored = pcall(SaveState.load, self.gba, self._savedState)
	if not ok or not restored then
		self:_status("State could not be restored for this cartridge")
		return false
	end
	self._debt = 0
	local presentOk, presentFailure = pcall(function()
		self.renderer:present(self.gba:framebuffer(), true)
	end)
	if not presentOk then
		self:_fail("Display stopped safely: " .. tostring(presentFailure))
		return false
	end
	self:_status("State snapshot restored")
	return true
end

function Host:Stop()
	self._running = false
	self._paused = true
	self:_stopConnections()
	if self.input then
		self.input:destroy()
		self.input = nil
	end
	if self.renderer then
		self.renderer:destroy()
		self.renderer = nil
	end
	self.gba = nil
	self.adaptive = nil
	self._callbacks = nil
	self._resumeOnFocus = false
	self._savedState = nil
	self._debt = 0
end

local GBAHost = {
	apiVersion = 1,
	id = "gba",
}

function GBAHost.Create(_configuration: { [string]: any }): any
	return Host.new()
end

return GBAHost
