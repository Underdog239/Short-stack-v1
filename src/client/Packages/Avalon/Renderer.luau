--!strict
--[[
	Renderer — the Avalon R1 pipeline.

	Owns the GUI surface (an ImageLabel bound to an EditableImage), the colour
	and depth planes, the camera and the frame loop. Meshes are transformed,
	near-plane clipped, back-face culled and handed to the Rasterizer.

	Ideas borrowed from the projects that came before and then pushed further
	(see CREDITS.md): a single EditableImage upload per frame, 32-bit buffer
	writes, a native-compiled rasterizer and a real depth buffer. Added here:
	near-plane clipping, adaptive resolution, and a scene-level API
	(Camera / Mesh / Texture) instead of raw pixel calls.
]]

local Mat4 = require(script.Parent.Mat4)
local Framebuffer = require(script.Parent.Framebuffer)
local Rasterizer = require(script.Parent.Rasterizer)
local Camera = require(script.Parent.Camera)

local Renderer = {}
Renderer.__index = Renderer

local floor = math.floor
local max = math.max
local min = math.min
local clamp = math.clamp

local AssetService = game:GetService("AssetService")

export type Options = {
	width: number?,
	height: number?,
	resolutionScale: number?,
	minScale: number?,
	maxScale: number?,
	adaptive: boolean?,
	targetFps: number?,
	background: Color3?,
	light: Vector3?,
	ambient: number?,
	camera: any?,
}

local function round(n: number): number
	return floor(n + 0.5)
end

function Renderer.new(parent: Instance, options: Options?)
	options = options or {}
	local self = setmetatable({}, Renderer) :: any

	self.baseWidth = options.width or 480
	self.baseHeight = options.height or 360
	self.scale = options.resolutionScale or 1
	self.minScale = options.minScale or 0.35
	self.maxScale = options.maxScale or 1
	self.adaptive = options.adaptive ~= false
	self.targetFps = options.targetFps or 60

	self.background = options.background or Color3.fromRGB(8, 8, 12)
	self.light = (options.light or Vector3.new(-0.4, -1, -0.6)).Unit
	self.ambient = options.ambient or 0.22

	self.camera = options.camera or Camera.new()
	self.stats = { triangles = 0, drawn = 0, clipped = 0, ms = 0 }

	-- GUI surface
	self.container = Instance.new("Frame")
	self.container.Name = "AvalonR1"
	self.container.BackgroundColor3 = Color3.new(0, 0, 0)
	self.container.BorderSizePixel = 0
	self.container.Size = UDim2.fromScale(1, 1)
	self.container.Parent = parent

	self._scratch = {
		cx = table.create(8), cy = table.create(8), cz = table.create(8), cw = table.create(8),
		cu = table.create(8), cv = table.create(8),
		cr = table.create(8), cg = table.create(8), cb = table.create(8),
		tx = table.create(8), ty = table.create(8), tz = table.create(8), tw = table.create(8),
		tu = table.create(8), tv = table.create(8),
		tr = table.create(8), tg = table.create(8), tb = table.create(8),
	}

	self:_allocate()
	return self
end

--- (Re)create the buffers, EditableImage and label at the current resolution.
function Renderer:_allocate()
	if self.label then self.label:Destroy() end
	if self.editable then self.editable:Destroy() end

	local w = max(16, round(self.baseWidth * self.scale))
	local h = max(16, round(self.baseHeight * self.scale))
	self.width, self.height = w, h
	self.fb = Framebuffer.new(w, h)

	self.editable = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
	local label = Instance.new("ImageLabel")
	label.Name = "Surface"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.ResampleMode = Enum.ResamplerMode.Pixelated
	label.ImageContent = Content.fromObject(self.editable)
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = w / h
	aspect.Parent = label
	label.Parent = self.container
	self.label = label
end

function Renderer:setResolutionScale(scale: number)
	scale = clamp(scale, self.minScale, self.maxScale)
	if math.abs(scale - self.scale) < 0.01 then return end
	self.scale = scale
	self:_allocate()
end

--- Start a frame: clear colour and depth.
function Renderer:beginFrame()
	local bg = self.background
	self.fb:clear(round(bg.R * 255), round(bg.G * 255), round(bg.B * 255), 255)
	self.stats.triangles, self.stats.drawn, self.stats.clipped = 0, 0, 0
	self.frameStart = os.clock()
end

--- Upload the finished frame to the EditableImage (one GPU-side write).
function Renderer:present()
	self.editable:WritePixelsBuffer(Vector2.zero, Vector2.new(self.width, self.height), self.fb.color)
	self.stats.ms = (os.clock() - self.frameStart) * 1000
	self:_adapt()
end

--- Adaptive resolution: shrink when the frame budget is missed, grow when we
--- have headroom. Runs at most a few times a second so it never thrashes.
function Renderer:_adapt()
	if not self.adaptive then return end
	local now = os.clock()
	if not self._adaptAt then self._adaptAt = now end
	if now - self._adaptAt < 0.5 then return end
	self._adaptAt = now
	local budget = 1 / self.targetFps
	local used = self.stats.ms / 1000
	if used > budget * 1.25 and self.scale > self.minScale then
		self:setResolutionScale(self.scale * 0.85)
	elseif used < budget * 0.7 and self.scale < self.maxScale then
		self:setResolutionScale(self.scale * 1.08)
	end
end

function Renderer:setLight(dir: Vector3)
	self.light = dir.Unit
end

function Renderer:destroy()
	if self.label then self.label:Destroy() end
	if self.editable then self.editable:Destroy() end
	self.container:Destroy()
end

function Renderer:setCamera(cam: any)
	self.camera = cam
end

function Renderer:setBackground(c: Color3)
	self.background = c
end

--- Draw an indexed mesh into the current frame.
-- opts.transform : model matrix (Mat4, default identity)
-- opts.shading   : "flat" | "gouraud" | "textured"
-- opts.texture   : Texture (required for "textured")
-- opts.color     : Color3 tint (default white)
-- opts.cull      : boolean (default true)
function Renderer:drawMesh(mesh: any, opts: any?)
	opts = opts or {}
	local fb = self.fb
	local W, H = fb.width, fb.height
	local colorBuf, depthBuf = fb.color, fb.depth
	local viewProj = self.camera:viewProjection(W / H)
	local model = opts.transform or Mat4.identity()
	local mvp = Mat4.mul(viewProj, model)
	local shading = opts.shading or "flat"
	local texture = opts.texture
	local cull = opts.cull ~= false
	local tint = opts.color or Color3.new(1, 1, 1)
	local tR, tG, tB = tint.R * 255, tint.G * 255, tint.B * 255

	local lx, ly, lz = self.light.X, self.light.Y, self.light.Z
	local ambient = self.ambient
	local near = self.camera.near
	local sqrt = math.sqrt

	local positions, normals, uvs, indices = mesh.positions, mesh.normals, mesh.uvs, mesh.indices
	local s = self._scratch
	local cx, cy, cz, cw = s.cx, s.cy, s.cz, s.cw
	local cu, cv, cr, cg, cb = s.cu, s.cv, s.cr, s.cg, s.cb
	local tx, ty, tw = s.tx, s.ty, s.tw
	local tu, tv, tr, tg, tb = s.tu, s.tv, s.tr, s.tg, s.tb

	local function lit(nx: number, ny: number, nz: number): (number, number, number)
		local wx = model[1] * nx + model[2] * ny + model[3] * nz
		local wy = model[5] * nx + model[6] * ny + model[7] * nz
		local wz = model[9] * nx + model[10] * ny + model[11] * nz
		local len = sqrt(wx * wx + wy * wy + wz * wz)
		if len > 1e-6 then wx, wy, wz = wx / len, wy / len, wz / len end
		local d = -(wx * lx + wy * ly + wz * lz)
		if d < 0 then d = 0 end
		local k = ambient + (1 - ambient) * d
		return tR * k, tG * k, tB * k
	end

	local function rasterTri(i: number, j: number, k: number)
		local ax, ay = tx[i], ty[i]
		local bx, by = tx[j], ty[j]
		local qx, qy = tx[k], ty[k]
		local area = (bx - ax) * (qy - ay) - (by - ay) * (qx - ax)
		if cull and area >= 0 then return end
		self.stats.drawn += 1
		if shading == "textured" and texture then
			Rasterizer.textured(colorBuf, depthBuf, texture.pixels, texture.width, texture.height, W, H,
				ax, ay, tw[i], tu[i], tv[i], tr[i], tg[i], tb[i],
				bx, by, tw[j], tu[j], tv[j], tr[j], tg[j], tb[j],
				qx, qy, tw[k], tu[k], tv[k], tr[k], tg[k], tb[k])
		elseif shading == "gouraud" then
			Rasterizer.gouraud(colorBuf, depthBuf, W, H,
				ax, ay, tw[i], tr[i], tg[i], tb[i],
				bx, by, tw[j], tr[j], tg[j], tb[j],
				qx, qy, tw[k], tr[k], tg[k], tb[k])
		else
			local r = (cr[1] + cr[2] + cr[3]) / 3
			local g = (cg[1] + cg[2] + cg[3]) / 3
			local b = (cb[1] + cb[2] + cb[3]) / 3
			local packed = floor(clamp(r, 0, 255)) + floor(clamp(g, 0, 255)) * 256
				+ floor(clamp(b, 0, 255)) * 65536 + 4278190080
			Rasterizer.flat(colorBuf, depthBuf, W, H, ax, ay, tw[i], bx, by, tw[j], qx, qy, tw[k], packed)
		end
	end

	for t = 1, mesh.triangleCount do
		local i0, i1, i2 = indices[t * 3 - 2], indices[t * 3 - 1], indices[t * 3]
		local p0, p1, p2 = positions[i0], positions[i1], positions[i2]
		local n0, n1, n2 = normals[i0], normals[i1], normals[i2]
		local q0, q1, q2 = uvs[i0], uvs[i1], uvs[i2]

		local x0, y0, z0, w0 = Mat4.transformPoint(mvp, p0.X, p0.Y, p0.Z)
		local x1, y1, z1, w1 = Mat4.transformPoint(mvp, p1.X, p1.Y, p1.Z)
		local x2, y2, z2, w2 = Mat4.transformPoint(mvp, p2.X, p2.Y, p2.Z)
		local r0, g0, b0 = lit(n0.X, n0.Y, n0.Z)
		local r1, g1, b1 = lit(n1.X, n1.Y, n1.Z)
		local r2, g2, b2 = lit(n2.X, n2.Y, n2.Z)

		cx[1], cy[1], cz[1], cw[1] = x0, y0, z0, w0
		cx[2], cy[2], cz[2], cw[2] = x1, y1, z1, w1
		cx[3], cy[3], cz[3], cw[3] = x2, y2, z2, w2
		cu[1], cv[1], cr[1], cg[1], cb[1] = q0.X, q0.Y, r0, g0, b0
		cu[2], cv[2], cr[2], cg[2], cb[2] = q1.X, q1.Y, r1, g1, b1
		cu[3], cv[3], cr[3], cg[3], cb[3] = q2.X, q2.Y, r2, g2, b2

		-- Near-plane clip: Sutherland-Hodgman against the single plane w > near.
		local ax, ay, az, aw = cx[1], cy[1], cz[1], cw[1]
		local au, av, ar, ag, ab = cu[1], cv[1], cr[1], cg[1], cb[1]
		local n = 0
		for e = 1, 3 do
			local f = e % 3 + 1
			local bx, by, bz, bw = cx[f], cy[f], cz[f], cw[f]
			local bu, bv, br, bg, bb = cu[f], cv[f], cr[f], cg[f], cb[f]
			local aIn, bIn = aw > near, bw > near
			if aIn then
				n += 1
				tx[n], ty[n], tw[n] = ax, ay, aw
				tu[n], tv[n] = au, av
				tr[n], tg[n], tb[n] = ar, ag, ab
			end
			if aIn ~= bIn then
				local tt = (near - aw) / (bw - aw)
				n += 1
				tx[n] = ax + (bx - ax) * tt
				ty[n] = ay + (by - ay) * tt
				tw[n] = near
				tu[n] = au + (bu - au) * tt
				tv[n] = av + (bv - av) * tt
				tr[n] = ar + (br - ar) * tt
				tg[n] = ag + (bg - ag) * tt
				tb[n] = ab + (bb - ab) * tt
			end
			ax, ay, az, aw = bx, by, bz, bw
			au, av, ar, ag, ab = bu, bv, br, bg, bb
		end
		if n < 3 then
			self.stats.clipped += 1
			continue
		end

		-- Perspective divide -> screen space; keep 1/w for depth + interpolation.
		for p = 1, n do
			local iw = 1 / tw[p]
			tx[p] = (tx[p] * iw * 0.5 + 0.5) * W
			ty[p] = (0.5 - ty[p] * iw * 0.5) * H
			tw[p] = iw
			tu[p] *= iw
			tv[p] *= iw
			tr[p] *= iw
			tg[p] *= iw
			tb[p] *= iw
		end

		-- Fan-triangulate the clipped polygon (3 or 4 vertices).
		for i = 2, n - 1 do
			rasterTri(1, i, i + 1)
		end
	end
end

return Renderer
