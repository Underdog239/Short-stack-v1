--!strict
--!native
--[[
	Framebuffer — the render target's colour and depth planes.

	colour : width*height*4 bytes, RGBA8 in (R,G,B,A) byte order. Written one
	         32-bit word at a time so a pixel costs a single buffer op.
	depth  : width*height*4 bytes, f32. Stores 1/w (reciprocal view depth), so
	         a *larger* value is nearer. Cleared to 0 so any visible fragment
	         (1/w > 0) passes the test.

	`packRGBA`/`unpackRGBA` use bit32 so the hot path never allocates a Color3.
]]

local Framebuffer = {}
Framebuffer.__index = Framebuffer

export type Class = typeof(setmetatable(
	{} :: {
		width: number,
		height: number,
		size: number,
		color: buffer,
		depth: buffer,
	},
	Framebuffer
))

function Framebuffer.new(width: number, height: number): Class
	local self = setmetatable({}, Framebuffer) :: any
	self.width = width
	self.height = height
	self.size = width * height
	self.color = buffer.create(self.size * 4)
	self.depth = buffer.create(self.size * 4)
	return self
end

--- Pack 0-255 channels into one little-endian RGBA word.
function Framebuffer.packRGBA(r: number, g: number, b: number, a: number): number
	return r + g * 256 + b * 65536 + a * 16777216
end

--- Clear colour + depth. Channels are 0-255. Also resets the depth plane.
function Framebuffer.clear(self: Class, r: number, g: number, b: number, a: number)
	buffer.fill(self.color, 0, Framebuffer.packRGBA(r, g, b, a), self.size * 4)
	buffer.fill(self.depth, 0, 0, self.size * 4)
end

function Framebuffer.resize(self: Class, width: number, height: number)
	self.width = width
	self.height = height
	self.size = width * height
	self.color = buffer.create(self.size * 4)
	self.depth = buffer.create(self.size * 4)
end

return Framebuffer
