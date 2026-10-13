--!strict
local projectRoot = script:FindFirstAncestor("ShortStack")
assert(projectRoot, "Depth must be mounted under ShortStack")
local Config = require(projectRoot:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)
local State = require(script.State)
local UIS = game:GetService("UserInputService")
local Input = {}
Input.__index = Input
local function isGamepad(kind)
	return string.find(kind.Name, "Gamepad", 1, true) ~= nil
end
function Input.new()
	local self = setmetatable({ keyboard = table.clone(Config.INPUT.defaultKeyboard),
		gamepad = table.clone(Config.INPUT.defaultGamepad), state = State.new(),
		mask = 0, enabled = true, connections = {}, capture = nil }, Input)
	local function connect(signal, fn) table.insert(self.connections, signal:Connect(fn)) end
	connect(UIS.InputBegan, function(event, processed)
		if UIS:GetFocusedTextBox() then return end
		if self.capture and event.KeyCode ~= Enum.KeyCode.Unknown then
			local capture = self.capture
			self.capture = nil
			if event.KeyCode == Enum.KeyCode.Escape or event.KeyCode == Enum.KeyCode.ButtonY then
				capture.done("Mapping cancelled")
			else
				local map = isGamepad(event.UserInputType) and self.gamepad or self.keyboard
				-- One binding per GBA action per device; assigning an occupied key swaps it out.
				for key, bit in map do if bit == capture.bit then map[key] = nil end end
				map[event.KeyCode] = capture.bit
				capture.done("Mapped to " .. event.KeyCode.Name .. " (this session)")
			end
			self:clearAll()
			return
		end
		if event.KeyCode == Enum.KeyCode.ButtonY and self.onMenu then self.onMenu(); return end
		if processed or not self.enabled then return end
		local map = isGamepad(event.UserInputType) and self.gamepad or self.keyboard
		local bit = map[event.KeyCode]
		if bit ~= nil then self.state:set(event, bit, true); self:recompute() end
	end)
	connect(UIS.InputEnded, function(event)
		self.state:set(event, nil, false)
		-- InputObjects can differ for keyboard events between begin/end.
		for source in self.state.held do
			if typeof(source) == "InputObject" and source.KeyCode == event.KeyCode
				and source.UserInputType == event.UserInputType and event.KeyCode ~= Enum.KeyCode.Unknown then
				self.state:set(source, nil, false)
			end
		end
		self:recompute()
	end)
	connect(UIS.InputChanged, function(event)
		if event.KeyCode == Enum.KeyCode.Thumbstick1 and event.UserInputType == Enum.UserInputType.Gamepad1 then
			if self.enabled and not UIS:GetFocusedTextBox() then
				self.state.x, self.state.y = event.Position.X, event.Position.Y
			else self.state.x, self.state.y = 0, 0 end
			self:recompute()
		end
	end)
	connect(UIS.WindowFocusReleased, function() self:clearAll() end)
	connect(UIS.TextBoxFocused, function() self:clearAll() end)
	connect(UIS.GamepadDisconnected, function() self:clearAll() end)
	return self
end
function Input:recompute() self.mask = self.enabled and self.state:mask(Config.INPUT.stickDeadzone) or 0 end
function Input:clearAll() self.state:clear(); self:recompute() end
function Input:setEnabled(enabled) self.enabled = enabled; self:clearAll() end
function Input:touch(source, bit, down)
	if down and not self.enabled then return end
	self.state:set(source, bit, down); self:recompute()
end
function Input:beginMapping(bit, done)
	self:clearAll()
	local capture = { bit = bit, done = done }
	self.capture = capture
	task.delay(10, function()
		if self.capture == capture then self.capture = nil; done("Mapping timed out; try again") end
	end)
end
function Input:resetBindings()
	self.capture = nil
	self.keyboard = table.clone(Config.INPUT.defaultKeyboard)
	self.gamepad = table.clone(Config.INPUT.defaultGamepad)
	self:clearAll()
end
function Input:describe(bit)
	local labels = {}
	for _, map in {self.keyboard, self.gamepad} do
		for key, value in map do if value == bit then table.insert(labels, key.Name) end end
	end
	table.sort(labels)
	return table.concat(labels, " / ")
end
function Input:destroy()
	self.capture = nil
	self:clearAll()
	for _, conn in self.connections do conn:Disconnect() end
end
return Input
