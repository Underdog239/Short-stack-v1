--!strict
--!native
--[[
	Rasterizer — the hot core: perspective-correct triangle fill with a depth
	buffer, written for Luau's native code generator.

	Why edge-function fill?
		Old software rasterizers (and the fastest public Roblox ones) walk a
		triangle one scanline at a time. Edge functions let us test coverage and
		interpolate every attribute with add-only inner loops, so the per-pixel
		cost is a few additions and one compare. `--!native` then compiles these
		functions to machine code — that is what separates "toy" from "usable".

	Every routine takes flat numeric arguments (never vertex tables) because a
	table index inside the inner loop would dominate the profile.

	Depth is stored as 1/w, so a fragment is nearer when its value is larger.

	Three entry points, each with its own inner loop so there is no per-pixel
	branch on "do I have a texture / colour":
		flat     — one solid colour (fastest)
		gouraud  — interpolated vertex colour
		textured — perspective-correct UV, modulated by vertex colour
]]

local Rasterizer = {}

local readu32 = buffer.readu32
local writeu32 = buffer.writeu32
local readf32 = buffer.readf32
local writef32 = buffer.writef32
local floor = math.floor
local ceil = math.ceil
local min = math.min
local max = math.max

local ALPHA = 4278190080 -- 255 << 24

--- Solid, depth-tested triangle. `packed` is one RGBA word.
function Rasterizer.flat(
	colorBuf: buffer, depthBuf: buffer, width: number, height: number,
	x0: number, y0: number, iw0: number,
	x1: number, y1: number, iw1: number,
	x2: number, y2: number, iw2: number,
	packed: number
)
	local area = (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0)
	if area == 0 then return end
	if area < 0 then
		x0, y0, iw0, x1, y1, iw1 = x1, y1, iw1, x0, y0, iw0
		area = -area
	end
	local invArea = 1 / area

	local minX = max(0, floor(min(x0, x1, x2)))
	local maxX = min(width - 1, ceil(max(x0, x1, x2)))
	local minY = max(0, floor(min(y0, y1, y2)))
	local maxY = min(height - 1, ceil(max(y0, y1, y2)))
	if minX > maxX or minY > maxY then return end

	local d01x, d01y = y0 - y1, x1 - x0
	local d12x, d12y = y1 - y2, x2 - x1
	local d20x, d20y = y2 - y0, x0 - x2

	local px, py = minX + 0.5, minY + 0.5
	local e01 = (x1 - x0) * (py - y0) - (y1 - y0) * (px - x0)
	local e12 = (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)
	local e20 = (x0 - x2) * (py - y2) - (y0 - y2) * (px - x2)

	for y = minY, maxY do
		local r01, r12, r20 = e01, e12, e20
		local idx = y * width + minX
		for _ = minX, maxX do
			if r01 >= 0 and r12 >= 0 and r20 >= 0 then
				local iw = (r12 * iw0 + r20 * iw1 + r01 * iw2) * invArea
				local o = idx * 4
				if iw > readf32(depthBuf, o) then
					writef32(depthBuf, o, iw)
					writeu32(colorBuf, o, packed)
				end
			end
			r01 += d01x
			r12 += d12x
			r20 += d20x
			idx += 1
		end
		e01 += d01y
		e12 += d12y
		e20 += d20y
	end
end

--- Smooth-shaded (Gouraud) triangle. Channel values are 0-255 and already
--- scaled by 1/w, so the fill is perspective correct.
function Rasterizer.gouraud(
	colorBuf: buffer, depthBuf: buffer, width: number, height: number,
	x0: number, y0: number, iw0: number, r0: number, g0: number, b0: number,
	x1: number, y1: number, iw1: number, r1: number, g1: number, b1: number,
	x2: number, y2: number, iw2: number, r2: number, g2: number, b2: number
)
	local area = (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0)
	if area == 0 then return end
	if area < 0 then
		x0, y0, iw0, r0, g0, b0, x1, y1, iw1, r1, g1, b1 = x1, y1, iw1, r1, g1, b1, x0, y0, iw0, r0, g0, b0
		area = -area
	end
	local invArea = 1 / area

	local minX = max(0, floor(min(x0, x1, x2)))
	local maxX = min(width - 1, ceil(max(x0, x1, x2)))
	local minY = max(0, floor(min(y0, y1, y2)))
	local maxY = min(height - 1, ceil(max(y0, y1, y2)))
	if minX > maxX or minY > maxY then return end

	local d01x, d01y = y0 - y1, x1 - x0
	local d12x, d12y = y1 - y2, x2 - x1
	local d20x, d20y = y2 - y0, x0 - x2

	local px, py = minX + 0.5, minY + 0.5
	local e01 = (x1 - x0) * (py - y0) - (y1 - y0) * (px - x0)
	local e12 = (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)
	local e20 = (x0 - x2) * (py - y2) - (y0 - y2) * (px - x2)

	for y = minY, maxY do
		local r01, r12, r20 = e01, e12, e20
		local idx = y * width + minX
		for _ = minX, maxX do
			if r01 >= 0 and r12 >= 0 and r20 >= 0 then
				local iw = (r12 * iw0 + r20 * iw1 + r01 * iw2) * invArea
				local o = idx * 4
				if iw > readf32(depthBuf, o) then
					writef32(depthBuf, o, iw)
					local k = invArea / iw
					local cr = (r12 * r0 + r20 * r1 + r01 * r2) * k
					local cg = (r12 * g0 + r20 * g1 + r01 * g2) * k
					local cb = (r12 * b0 + r20 * b1 + r01 * b2) * k
					if cr < 0 then cr = 0 elseif cr > 255 then cr = 255 end
					if cg < 0 then cg = 0 elseif cg > 255 then cg = 255 end
					if cb < 0 then cb = 0 elseif cb > 255 then cb = 255 end
					writeu32(colorBuf, o, floor(cr) + floor(cg) * 256 + floor(cb) * 65536 + ALPHA)
				end
			end
			r01 += d01x
			r12 += d12x
			r20 += d20x
			idx += 1
		end
		e01 += d01y
		e12 += d12y
		e20 += d20y
	end
end

local INV255 = 1 / 255

--- Textured triangle: perspective-correct UV, modulated by interpolated vertex
--- colour (pass 255,255,255 for unlit). UVs and colours arrive scaled by 1/w.
function Rasterizer.textured(
	colorBuf: buffer, depthBuf: buffer, texBuf: buffer, texW: number, texH: number,
	width: number, height: number,
	x0: number, y0: number, iw0: number, u0: number, v0: number, r0: number, g0: number, b0: number,
	x1: number, y1: number, iw1: number, u1: number, v1: number, r1: number, g1: number, b1: number,
	x2: number, y2: number, iw2: number, u2: number, v2: number, r2: number, g2: number, b2: number
)
	local area = (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0)
	if area == 0 then return end
	if area < 0 then
		x0, y0, iw0, u0, v0, r0, g0, b0, x1, y1, iw1, u1, v1, r1, g1, b1 =
			x1, y1, iw1, u1, v1, r1, g1, b1, x0, y0, iw0, u0, v0, r0, g0, b0
		area = -area
	end
	local invArea = 1 / area

	local minX = max(0, floor(min(x0, x1, x2)))
	local maxX = min(width - 1, ceil(max(x0, x1, x2)))
	local minY = max(0, floor(min(y0, y1, y2)))
	local maxY = min(height - 1, ceil(max(y0, y1, y2)))
	if minX > maxX or minY > maxY then return end

	local d01x, d01y = y0 - y1, x1 - x0
	local d12x, d12y = y1 - y2, x2 - x1
	local d20x, d20y = y2 - y0, x0 - x2

	local px, py = minX + 0.5, minY + 0.5
	local e01 = (x1 - x0) * (py - y0) - (y1 - y0) * (px - x0)
	local e12 = (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)
	local e20 = (x0 - x2) * (py - y2) - (y0 - y2) * (px - x2)

	for y = minY, maxY do
		local r01, r12, r20 = e01, e12, e20
		local idx = y * width + minX
		for _ = minX, maxX do
			if r01 >= 0 and r12 >= 0 and r20 >= 0 then
				local iw = (r12 * iw0 + r20 * iw1 + r01 * iw2) * invArea
				local o = idx * 4
				if iw > readf32(depthBuf, o) then
					writef32(depthBuf, o, iw)
					local k = invArea / iw
					local tu = (r12 * u0 + r20 * u1 + r01 * u2) * k
					local tv = (r12 * v0 + r20 * v1 + r01 * v2) * k
					local tx = floor(tu * texW) % texW
					local ty = floor(tv * texH) % texH
					local texel = readu32(texBuf, (ty * texW + tx) * 4)
					local mr = (r12 * r0 + r20 * r1 + r01 * r2) * k * INV255
					local mg = (r12 * g0 + r20 * g1 + r01 * g2) * k * INV255
					local mb = (r12 * b0 + r20 * b1 + r01 * b2) * k * INV255
					if mr > 1 then mr = 1 elseif mr < 0 then mr = 0 end
					if mg > 1 then mg = 1 elseif mg < 0 then mg = 0 end
					if mb > 1 then mb = 1 elseif mb < 0 then mb = 0 end
					local cr = (texel % 256) * mr
					local cg = ((texel // 256) % 256) * mg
					local cb = ((texel // 65536) % 256) * mb
					writeu32(colorBuf, o, floor(cr) + floor(cg) * 256 + floor(cb) * 65536 + ALPHA)
				end
			end
			r01 += d01x
			r12 += d12x
			r20 += d20x
			idx += 1
		end
		e01 += d01y
		e12 += d12y
		e20 += d20y
	end
end

return Rasterizer
