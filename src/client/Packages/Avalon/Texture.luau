--!strict
--!native
--[[
	Texture — a sampled RGBA image backed by a u32 buffer.

	Pixels live in a `buffer` of width*height 32-bit words (packed RGBA) so the
	rasterizer samples with a single buffer.readu32 and no table indexing.

	Sources:
		Texture.new(w, h, buffer)      -- you supply the words
		Texture.checker(w, h, cell, c1, c2)   -- procedural, zero I/O
		Texture.fromEditableImage(img) -- copy an existing EditableImage
		Texture.load(assetId)          -- async, decodes any image asset

	Wrap modes: "repeat" (default) and "clamp".
]]

local Framebuffer = require(script.Parent.Framebuffer)
local pack = Framebuffer.packRGBA

local Texture = {}
Texture.__index = Texture

export type Class = typeof(setmetatable(
	{} :: {
		width: number,
		height: number,
		pixels: buffer,
		wrap: string,
	},
	Texture
))

function Texture.new(width: number, height: number, pixels: buffer?): Class
	local self = setmetatable({}, Texture) :: any
	self.width = width
	self.height = height
	self.pixels = pixels or buffer.create(width * height * 4)
	self.wrap = "repeat"
	return self
end

function Texture.checker(width: number, height: number, cell: number, c1: Vector3, c2: Vector3): Class
	local self = Texture.new(width, height)
	local px = self.pixels
	local a = pack(c1.X * 255, c1.Y * 255, c1.Z * 255, 255)
	local b = pack(c2.X * 255, c2.Y * 255, c2.Z * 255, 255)
	for y = 0, height - 1 do
		local row = y * width
		local cy = (y // cell) % 2
		for x = 0, width - 1 do
			local on = ((x // cell) % 2) == cy
			buffer.writeu32(px, (row + x) * 4, if on then a else b)
		end
	end
	return self
end

--- Copy the pixels of an existing EditableImage into a Texture.
function Texture.fromEditableImage(img: EditableImage): Class
	local size = img.Size
	local width, height = size.X, size.Y
	local raw = img:ReadPixelsBuffer(Vector2.zero, size) -- RGBA8 bytes
	local self = Texture.new(width, height)
	local px = self.pixels
	for i = 0, width * height - 1 do
		local o = i * 4
		buffer.writeu32(
			px,
			o,
			buffer.readu8(raw, o)
				+ buffer.readu8(raw, o + 1) * 256
				+ buffer.readu8(raw, o + 2) * 65536
				+ buffer.readu8(raw, o + 3) * 16777216
		)
	end
	return self
end

--- Load any image asset (rbxassetid) into a Texture. Yields.
function Texture.load(assetId: string): Class
	local editable = game:GetService("AssetService"):CreateEditableImageAsync(assetId)
	local tex = Texture.fromEditableImage(editable)
	editable:Destroy()
	return tex
end

--- Sample by normalised UV (0..1) with the configured wrap mode. Returns packed RGBA.
function Texture.sample(self: Class, u: number, v: number): number
	local w, h = self.width, self.height
	local x = u * w
	local y = v * h
	local ix, iy = math.floor(x), math.floor(y)
	if self.wrap == "repeat" then
		ix = ix % w
		iy = iy % h
	else
		ix = math.clamp(ix, 0, w - 1)
		iy = math.clamp(iy, 0, h - 1)
	end
	return buffer.readu32(self.pixels, (iy * w + ix) * 4)
end

return Texture
