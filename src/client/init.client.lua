--!strict
-- The only runtime entry point is a LocalScript under StarterPlayerScripts.
-- Short Stack intentionally ships no server scripts or remote calls.

local modules = script:WaitForChild("Modules")
local AppController = require(modules:WaitForChild("AppController"))

local app = AppController.new()
app:Start()

script.Destroying:Connect(function()
	app:Destroy()
end)
