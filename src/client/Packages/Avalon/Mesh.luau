--!strict
--[[
	Mesh — indexed triangle geometry in "structure of arrays" form.

	Positions / normals / uvs are parallel arrays rather than an array of vertex
	tables. The transform loop therefore walks three flat arrays, which avoids a
	table indirection per attribute and keeps allocation out of the frame.

	Build your own, or use the procedural generators below (cube, plane, sphere,
	torus). All generators are original project code. Every triangle is wound
	counter-clockwise when viewed from outside, which is what the renderer's
	back-face culler expects.
]]

local Mesh = {}
Mesh.__index = Mesh

export type Class = typeof(setmetatable(
	{} :: {
		positions: { Vector3 },
		normals: { Vector3 },
		uvs: { Vector2 },
		indices: { number },
		vertexCount: number,
		triangleCount: number,
	},
	Mesh
))

function Mesh.new(positions: { Vector3 }, normals: { Vector3 }, uvs: { Vector2 }, indices: { number }): Class
	local self = setmetatable({}, Mesh) :: any
	self.positions = positions
	self.normals = normals
	self.uvs = uvs
	self.indices = indices
	self.vertexCount = #positions
	self.triangleCount = #indices // 3
	return self
end

function Mesh.fromVertices(verts: { { p: Vector3, n: Vector3, uv: Vector2 } }, indices: { number }): Class
	local positions, normals, uvs = {}, {}, {}
	for i, v in verts do
		positions[i] = v.p
		normals[i] = v.n
		uvs[i] = v.uv
	end
	return Mesh.new(positions, normals, uvs, indices)
end

-- Generators -----------------------------------------------------------------

local function quad(positions, normals, uvs, indices, p0, p1, p2, p3, normal)
	local base = #positions
	local pts = { p0, p1, p2, p3 }
	local tcs = { Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(1, 1), Vector2.new(0, 1) }
	for i = 1, 4 do
		positions[base + i] = pts[i]
		normals[base + i] = normal
		uvs[base + i] = tcs[i]
	end
	local n = #indices
	indices[n + 1], indices[n + 2], indices[n + 3] = base + 1, base + 2, base + 3
	indices[n + 4], indices[n + 5], indices[n + 6] = base + 1, base + 3, base + 4
end

--- Axis-aligned box centred at the origin. `size` is full extent on each axis.
function Mesh.cube(size: Vector3): Class
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local positions, normals, uvs, indices = {}, {}, {}, {}
	quad(positions, normals, uvs, indices,
		Vector3.new(-hx, -hy, hz), Vector3.new(hx, -hy, hz), Vector3.new(hx, hy, hz), Vector3.new(-hx, hy, hz), Vector3.new(0, 0, 1))
	quad(positions, normals, uvs, indices,
		Vector3.new(hx, -hy, -hz), Vector3.new(-hx, -hy, -hz), Vector3.new(-hx, hy, -hz), Vector3.new(hx, hy, -hz), Vector3.new(0, 0, -1))
	quad(positions, normals, uvs, indices,
		Vector3.new(hx, -hy, hz), Vector3.new(hx, -hy, -hz), Vector3.new(hx, hy, -hz), Vector3.new(hx, hy, hz), Vector3.new(1, 0, 0))
	quad(positions, normals, uvs, indices,
		Vector3.new(-hx, -hy, -hz), Vector3.new(-hx, -hy, hz), Vector3.new(-hx, hy, hz), Vector3.new(-hx, hy, -hz), Vector3.new(-1, 0, 0))
	quad(positions, normals, uvs, indices,
		Vector3.new(-hx, hy, hz), Vector3.new(hx, hy, hz), Vector3.new(hx, hy, -hz), Vector3.new(-hx, hy, -hz), Vector3.new(0, 1, 0))
	quad(positions, normals, uvs, indices,
		Vector3.new(-hx, -hy, -hz), Vector3.new(hx, -hy, -hz), Vector3.new(hx, -hy, hz), Vector3.new(-hx, -hy, hz), Vector3.new(0, -1, 0))
	return Mesh.new(positions, normals, uvs, indices)
end

--- A flat grid in the XZ plane, `segments` cells per side.
function Mesh.plane(size: number, segments: number): Class
	local positions, normals, uvs, indices = {}, {}, {}, {}
	local half = size / 2
	local step = size / segments
	for z = 0, segments do
		for x = 0, segments do
			positions[#positions + 1] = Vector3.new(-half + x * step, 0, -half + z * step)
			normals[#normals + 1] = Vector3.new(0, 1, 0)
			uvs[#uvs + 1] = Vector2.new(x / segments, z / segments)
		end
	end
	local stride = segments + 1
	for z = 0, segments - 1 do
		for x = 0, segments - 1 do
			local a = z * stride + x + 1
			local b = a + 1
			local c = a + stride
			local d = c + 1
			local n = #indices
			indices[n + 1], indices[n + 2], indices[n + 3] = a, c, b
			indices[n + 4], indices[n + 5], indices[n + 6] = b, c, d
		end
	end
	return Mesh.new(positions, normals, uvs, indices)
end

--- UV sphere of the given radius.
function Mesh.sphere(radius: number, rings: number, segments: number): Class
	local positions, normals, uvs, indices = {}, {}, {}, {}
	for ring = 0, rings do
		local v = ring / rings
		local phi = v * math.pi
		local y = math.cos(phi) * radius
		for seg = 0, segments do
			local u = seg / segments
			local theta = u * math.pi * 2
			local nx, ny, nz = math.sin(phi) * math.cos(theta), math.cos(phi), math.sin(phi) * math.sin(theta)
			positions[#positions + 1] = Vector3.new(nx * radius, y, nz * radius)
			normals[#normals + 1] = Vector3.new(nx, ny, nz)
			uvs[#uvs + 1] = Vector2.new(u, 1 - v)
		end
	end
	local stride = segments + 1
	for ring = 0, rings - 1 do
		for seg = 0, segments - 1 do
			local a = ring * stride + seg + 1
			local b = a + 1
			local c = a + stride
			local d = c + 1
			local n = #indices
			indices[n + 1], indices[n + 2], indices[n + 3] = a, b, c
			indices[n + 4], indices[n + 5], indices[n + 6] = b, d, c
		end
	end
	return Mesh.new(positions, normals, uvs, indices)
end

--- Torus in the XZ plane.
function Mesh.torus(major: number, minor: number, majorSegs: number, minorSegs: number): Class
	local positions, normals, uvs, indices = {}, {}, {}, {}
	for i = 0, majorSegs do
		local u = i / majorSegs
		local tu = u * math.pi * 2
		local cu, su = math.cos(tu), math.sin(tu)
		for j = 0, minorSegs do
			local v = j / minorSegs
			local tv = v * math.pi * 2
			local cv, sv = math.cos(tv), math.sin(tv)
			local x = (major + minor * cv) * cu
			local z = (major + minor * cv) * su
			local y = minor * sv
			positions[#positions + 1] = Vector3.new(x, y, z)
			normals[#normals + 1] = Vector3.new(cv * cu, sv, cv * su)
			uvs[#uvs + 1] = Vector2.new(u, v)
		end
	end
	local stride = minorSegs + 1
	for i = 0, majorSegs - 1 do
		for j = 0, minorSegs - 1 do
			local a = i * stride + j + 1
			local b = a + 1
			local c = a + stride
			local d = c + 1
			local n = #indices
			indices[n + 1], indices[n + 2], indices[n + 3] = a, b, c
			indices[n + 4], indices[n + 5], indices[n + 6] = b, d, c
		end
	end
	return Mesh.new(positions, normals, uvs, indices)
end

return Mesh
