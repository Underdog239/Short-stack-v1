--!strict
-- One-shot decorative 3D console render. It is intentionally not connected to
-- RenderStepped: only the emulated 2D framebuffer runs in the gameplay hot path.

local projectRoot = script:FindFirstAncestor("ShortStack")
assert(projectRoot, "AvalonPreview must be mounted under ShortStack")
local packages = projectRoot:FindFirstChild("Packages")

local Preview = {}

function Preview.Render(parent: GuiObject, accent: Color3): any?
	local renderer
	local ok, failure = pcall(function()
		local avalonModule = packages and packages:FindFirstChild("Avalon")
		assert(avalonModule and avalonModule:IsA("ModuleScript"), "Avalon package is not mounted")
		local Avalon = require(avalonModule :: ModuleScript)
		renderer = Avalon.new(parent, {
			width = 96,
			height = 64,
			adaptive = false,
			background = Color3.fromRGB(8, 15, 18),
			ambient = 0.42,
			light = Vector3.new(-0.5, -1, -0.7),
			camera = Avalon.Camera.new({
				position = Vector3.new(2.7, 2.0, 6.4),
				target = Vector3.new(0, 0, 0),
				fov = math.rad(48),
				near = 0.1,
				far = 100,
			}),
		})

		local Mat4 = Avalon.Mat4
		local Mesh = Avalon.Mesh
		local rotation = Mat4.mul(Mat4.rotationY(-0.24), Mat4.rotationX(0.08))
		local body = Mesh.cube(Vector3.new(2.8, 1.38, 0.42))
		local screen = Mesh.cube(Vector3.new(1.9, 0.83, 0.035))
		local padVertical = Mesh.cube(Vector3.new(0.14, 0.52, 0.07))
		local padHorizontal = Mesh.cube(Vector3.new(0.48, 0.14, 0.07))
		local actionButton = Mesh.sphere(0.13, 4, 6)

		renderer:beginFrame()
		renderer:drawMesh(body, {
			transform = rotation,
			shading = "gouraud",
			color = Color3.fromRGB(73, 91, 108),
		})
		renderer:drawMesh(screen, {
			transform = Mat4.mul(rotation, Mat4.translation(Vector3.new(0, 0.14, 0.23))),
			shading = "flat",
			color = Color3.fromRGB(13, 24, 28),
		})
		renderer:drawMesh(padVertical, {
			transform = Mat4.mul(rotation, Mat4.translation(Vector3.new(-0.76, -0.38, 0.24))),
			shading = "flat",
			color = Color3.fromRGB(132, 151, 161),
		})
		renderer:drawMesh(padHorizontal, {
			transform = Mat4.mul(rotation, Mat4.translation(Vector3.new(-0.76, -0.38, 0.24))),
			shading = "flat",
			color = Color3.fromRGB(132, 151, 161),
		})
		renderer:drawMesh(actionButton, {
			transform = Mat4.mul(rotation, Mat4.translation(Vector3.new(0.72, -0.28, 0.25))),
			shading = "gouraud",
			color = accent,
		})
		renderer:drawMesh(actionButton, {
			transform = Mat4.mul(rotation, Mat4.translation(Vector3.new(1.02, -0.08, 0.25))),
			shading = "gouraud",
			color = Color3.fromRGB(255, 131, 131),
		})
		renderer:present()
	end)

	if not ok then
		if renderer then
			pcall(function()
				renderer:destroy()
			end)
		end
		for _, child in ipairs(parent:GetChildren()) do
			if child.Name == "AvalonR1" then
				child:Destroy()
			end
		end
		warn("Avalon R1 preview unavailable: " .. tostring(failure))
		return nil
	end
	return renderer
end

return Preview
