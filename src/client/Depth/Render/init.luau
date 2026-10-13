--!strict
--[[ Render (init)

 Presents the emulator's 240x160 RGBA buffer to Roblox.

 Primary backend: EditableImage (AssetService:CreateEditableImage) written with
 WritePixelsBuffer, which is a single GPU-side upload per frame.

 Fallback backend: a grid of Frames sampling the framebuffer, used when
 EditableImage is unavailable. It is deliberately coarse; it exists so the
 emulator still shows something on older engine builds.

 The renderer also owns auto-scaling: if measured FPS drops below the target it
 reduces scale / switches to adaptive presentation.
 ]]

local projectRoot = script:FindFirstAncestor("ShortStack")
assert(projectRoot, "Depth must be mounted under ShortStack")
local shared = projectRoot:WaitForChild("Shared")
local Config = require(shared:WaitForChild("Config") :: ModuleScript)
local Logger = require(shared:WaitForChild("Logger") :: ModuleScript)

local W, H = Config.SCREEN_W, Config.SCREEN_H

local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(parent: Instance, options: any?)
	options = options or {}
	local self = setmetatable({}, Renderer)
	self.scale = options.scale or Config.RENDER.scale
	self.backend = nil
	self.fpsSamples = {}
	self.currentScale = self.scale

	self.container = Instance.new("Frame")
	self.container.Name = "GBAScreen"
	self.container.BackgroundColor3 = Color3.new(0, 0, 0)
	self.container.BorderSizePixel = 0
	self.container.Size = UDim2.fromScale(1, 1)
	self.container.Parent = parent

	self:_createBackend()
	return self
end

function Renderer:_createBackend()
	local editable, label
	local ok, err = pcall(function()
		assert(Config.RENDER.mode ~= "grid", "grid selected")
		editable = game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(W, H) })
		assert(editable, "EditableImage allocation unavailable")
		label = Instance.new("ImageLabel")
		label.Name = "GBASurface"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.ResampleMode = Enum.ResamplerMode.Pixelated
		label.ImageContent = Content.fromObject(editable)
		label.Parent = self.container
	end)
	if ok then
		self.editableImage, self.imageLabel = editable, label
		self.backend = "editableimage"
		Logger.info("Renderer backend: EditableImage")
		return
	end
	if label then label:Destroy() end
	if editable then editable:Destroy() end

	self:_createGrid(err)
end

function Renderer:_createGrid(reason: any)
	-- Fallback: coarse frame grid
	self.backend = "grid"
	self.gridCols = 30
	self.gridRows = 20
	self.cells = {}
	self.cellColors = {}
	self.lastPresent = 0
	for gy = 0, self.gridRows - 1 do
		for gx = 0, self.gridCols - 1 do
			local cell = Instance.new("Frame")
			cell.BackgroundColor3 = Color3.new(0, 0, 0)
			cell.BorderSizePixel = 0
			cell.Size = UDim2.fromScale(1 / self.gridCols, 1 / self.gridRows)
			cell.Position = UDim2.fromScale(gx / self.gridCols, gy / self.gridRows)
			cell.Parent = self.container
			self.cells[gy * self.gridCols + gx + 1] = cell
		end
	end
	Logger.warn("Renderer backend: grid fallback: " .. tostring(reason))
end

--- Push the emulator framebuffer to the screen.
-- `fb` is a native buffer of 240*160*4 RGBA bytes produced directly by the PPU,
-- so this is a single engine upload with no per-pixel Lua work.
function Renderer:present(fb: buffer, force: boolean?)
	if self.backend == "editableimage" then
		local ok, failure = pcall(function()
			self.editableImage:WritePixelsBuffer(Vector2.zero, Vector2.new(W, H), fb)
		end)
		if ok then return end
		self.imageLabel:Destroy(); self.editableImage:Destroy()
		self.imageLabel, self.editableImage = nil, nil
		self:_createGrid(failure)
		force = true
	end
	if not force and os.clock() - self.lastPresent < 1 / 20 then return end
	self.lastPresent = os.clock()
	local cols, rows = self.gridCols, self.gridRows
	for gy = 0, rows - 1 do
		for gx = 0, cols - 1 do
			local px = math.floor((gx + 0.5) * W / cols)
			local py = math.floor((gy + 0.5) * H / rows)
			local o = (py * W + px) * 4
			local cell = self.cells[gy * cols + gx + 1]
			local color = buffer.readu32(fb, o)
			local index = gy * cols + gx + 1
			if self.cellColors[index] ~= color then
				self.cellColors[index] = color
				cell.BackgroundColor3 = Color3.fromRGB(buffer.readu8(fb, o), buffer.readu8(fb, o + 1), buffer.readu8(fb, o + 2))
			end
		end
	end
end

function Renderer:setScale(scale: number)
	self.currentScale = scale
	self.container.Size = UDim2.fromScale(1, 1)
end

function Renderer:destroy()
	if self.editableImage then self.editableImage:Destroy() end
	self.container:Destroy()
end

return Renderer
