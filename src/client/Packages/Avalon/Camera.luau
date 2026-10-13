--!strict
--[[
	Camera — position, orientation and projection for one viewpoint.

	Orientation can be driven either by a look-at target or by yaw/pitch. The
	projection is a right-handed perspective matrix; `near` is also the clip
	plane the rasterizer culls against.
]]

local Mat4 = require(script.Parent.Mat4)

local Camera = {}
Camera.__index = Camera

export type Class = typeof(setmetatable(
	{} :: {
		position: Vector3,
		target: Vector3,
		up: Vector3,
		fov: number,
		near: number,
		far: number,
	},
	Camera
))

function Camera.new(options: { [string]: any }?): Class
	options = options or {}
	local self = setmetatable({}, Camera) :: any
	self.position = options.position or Vector3.new(0, 0, 8)
	self.target = options.target or Vector3.new(0, 0, 0)
	self.up = options.up or Vector3.new(0, 1, 0)
	self.fov = options.fov or math.rad(70)
	self.near = options.near or 0.1
	self.far = options.far or 500
	return self
end

function Camera.viewMatrix(self: Class): Mat4.Mat
	return Mat4.lookAt(self.position, self.target, self.up)
end

function Camera.projMatrix(self: Class, aspect: number): Mat4.Mat
	return Mat4.perspective(self.fov, aspect, self.near, self.far)
end

--- Combined view * projection, ready to multiply by a model matrix.
function Camera.viewProjection(self: Class, aspect: number): Mat4.Mat
	return Mat4.mul(Camera.projMatrix(self, aspect), Camera.viewMatrix(self))
end

return Camera
