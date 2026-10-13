--!strict
--!native
--[[
	Mat4 — row-major 4x4 matrix for the Avalon R1 software pipeline.

	Stored flat (16 numbers) so a transform touches one contiguous array instead
	of nested tables. Row-major layout:

		[  1   2   3   4 ]
		[  5   6   7   8 ]
		[  9  10  11  12 ]
		[ 13  14  15  16 ]

	Column-vector convention (point on the right):
		x' = m1*x + m2*y + m3*z + m4
		y' = m5*x + m6*y + m7*z + m8
		z' = m9*x + m10*y + m11*z + m12
		w' = m13*x + m14*y + m15*z + m16
]]

local Mat4 = {}

export type Mat = { number }

local function blank(): Mat
	return table.create(16, 0)
end

function Mat4.identity(): Mat
	local m = blank()
	m[1], m[6], m[11], m[16] = 1, 1, 1, 1
	return m
end

function Mat4.mul(a: Mat, b: Mat): Mat
	local m = blank()
	local b1, b2, b3, b4 = b[1], b[2], b[3], b[4]
	local b5, b6, b7, b8 = b[5], b[6], b[7], b[8]
	local b9, b10, b11, b12 = b[9], b[10], b[11], b[12]
	local b13, b14, b15, b16 = b[13], b[14], b[15], b[16]
	for row = 0, 3 do
		local r = row * 4
		local a1, a2, a3, a4 = a[r + 1], a[r + 2], a[r + 3], a[r + 4]
		m[r + 1] = a1 * b1 + a2 * b5 + a3 * b9 + a4 * b13
		m[r + 2] = a1 * b2 + a2 * b6 + a3 * b10 + a4 * b14
		m[r + 3] = a1 * b3 + a2 * b7 + a3 * b11 + a4 * b15
		m[r + 4] = a1 * b4 + a2 * b8 + a3 * b12 + a4 * b16
	end
	return m
end

function Mat4.translation(v: Vector3): Mat
	local m = Mat4.identity()
	m[4], m[8], m[12] = v.X, v.Y, v.Z
	return m
end

function Mat4.scale(v: Vector3): Mat
	local m = blank()
	m[1], m[6], m[11], m[16] = v.X, v.Y, v.Z, 1
	return m
end

function Mat4.rotationX(a: number): Mat
	local m = Mat4.identity()
	local c, s = math.cos(a), math.sin(a)
	m[6], m[7], m[10], m[11] = c, -s, s, c
	return m
end

function Mat4.rotationY(a: number): Mat
	local m = Mat4.identity()
	local c, s = math.cos(a), math.sin(a)
	m[1], m[3], m[9], m[11] = c, s, -s, c
	return m
end

function Mat4.rotationZ(a: number): Mat
	local m = Mat4.identity()
	local c, s = math.cos(a), math.sin(a)
	m[1], m[2], m[5], m[6] = c, -s, s, c
	return m
end

--- Right-handed perspective projection (OpenGL style). Clip w == -viewZ, so a
--- point in front of the camera has w > 0.
function Mat4.perspective(fovY: number, aspect: number, near: number, far: number): Mat
	local f = 1 / math.tan(fovY * 0.5)
	local m = blank()
	m[1] = f / aspect
	m[6] = f
	m[11] = (far + near) / (near - far)
	m[12] = (2 * far * near) / (near - far)
	m[15] = -1
	return m
end

function Mat4.lookAt(eye: Vector3, target: Vector3, up: Vector3): Mat
	local zAxis = (eye - target)
	if zAxis.Magnitude < 1e-6 then zAxis = Vector3.new(0, 0, 1) end
	zAxis = zAxis.Unit
	local xAxis = up:Cross(zAxis)
	if xAxis.Magnitude < 1e-6 then xAxis = Vector3.new(1, 0, 0) end
	xAxis = xAxis.Unit
	local yAxis = zAxis:Cross(xAxis)
	local m = Mat4.identity()
	m[1], m[2], m[3] = xAxis.X, xAxis.Y, xAxis.Z
	m[5], m[6], m[7] = yAxis.X, yAxis.Y, yAxis.Z
	m[9], m[10], m[11] = zAxis.X, zAxis.Y, zAxis.Z
	m[4] = -xAxis:Dot(eye)
	m[8] = -yAxis:Dot(eye)
	m[12] = -zAxis:Dot(eye)
	return m
end

--- Build a model matrix from a Roblox CFrame (handy for driving meshes from parts).
function Mat4.fromCFrame(cf: CFrame): Mat
	local c = table.pack(cf:GetComponents())
	local m = Mat4.identity()
	m[1], m[2], m[3] = c[4], c[5], c[6]
	m[5], m[6], m[7] = c[7], c[8], c[9]
	m[9], m[10], m[11] = c[10], c[11], c[12]
	m[4], m[8], m[12] = c[1], c[2], c[3]
	return m
end

--- Transform a point; returns clip-space x, y, z, w.
function Mat4.transformPoint(m: Mat, x: number, y: number, z: number): (number, number, number, number)
	return
		m[1] * x + m[2] * y + m[3] * z + m[4],
		m[5] * x + m[6] * y + m[7] * z + m[8],
		m[9] * x + m[10] * y + m[11] * z + m[12],
		m[13] * x + m[14] * y + m[15] * z + m[16]
end

--- Transform a direction (ignores translation).
function Mat4.transformDir(m: Mat, x: number, y: number, z: number): (number, number, number)
	return
		m[1] * x + m[2] * y + m[3] * z,
		m[5] * x + m[6] * y + m[7] * z,
		m[9] * x + m[10] * y + m[11] * z
end

return Mat4
