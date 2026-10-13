--!strict
--[[
	Avalon R1 — a high-performance software 3D renderer for Roblox.

	Everything renders into an EditableImage shown in a GUI, so a scene costs
	nothing in the 3D workspace. Pull in the pieces you need:

		local Avalon = require(ReplicatedStorage.Avalon)

		local renderer = Avalon.new(parent, { width = 480, height = 360 })
		renderer:setCamera(Avalon.Camera.new({ position = Vector3.new(0, 2, 8) }))

		local cube = Avalon.Mesh.cube(Vector3.new(2, 2, 2))
		local tex  = Avalon.Texture.checker(64, 64, 8, Vector3.new(1, 1, 1), Vector3.new(0.2, 0.2, 0.2))

		RunService.RenderStepped:Connect(function()
			renderer:beginFrame()
			renderer:drawMesh(cube, { shading = "textured", texture = tex })
			renderer:present()
		end)

	See README.md for the full guide and docs/ARCHITECTURE.md for how the
	pipeline is put together.
]]

local Avalon = {}

Avalon.VERSION = "1.0.0"

Avalon.Mat4 = require(script.Mat4)
Avalon.Camera = require(script.Camera)
Avalon.Mesh = require(script.Mesh)
Avalon.Texture = require(script.Texture)
Avalon.Framebuffer = require(script.Framebuffer)
Avalon.Rasterizer = require(script.Rasterizer)
Avalon.Renderer = require(script.Renderer)

--- Create a Renderer (shortcut for Avalon.Renderer.new).
function Avalon.new(parent: Instance, options: any?)
	return Avalon.Renderer.new(parent, options)
end

return Avalon
