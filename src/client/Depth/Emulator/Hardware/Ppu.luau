--!strict
--[[ Emulator/Hardware/Ppu.luau

 GBA picture processing unit: display modes 0-5, text + affine backgrounds,
 sprites (regular + affine), windows, colour effects (alpha/brighten/darken)
 and mosaic. Rendering is scanline based, so cost scales with visible pixels.

 Output is packed RGBA in a 240x160 byte buffer consumed by Render/.
 ]]

local Interrupts = require(script.Parent.Interrupts)

local W, H = 240, 160
local CYCLES_PER_LINE = 1232
local LINES_TOTAL = 228

local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local lshift, rshift, arshift, rrotate = bit32.lshift, bit32.rshift, bit32.arshift, bit32.rrotate

local Ppu = {}
Ppu.__index = Ppu
Ppu.WIDTH = W
Ppu.HEIGHT = H

function Ppu.new(bus: any, interrupts: any)
	local ppu = {
		bus = bus, interrupts = interrupts,
		dispcnt = 0, dispstat = 0,
		bgcnt = { 0, 0, 0, 0 },
		bghofs = { 0, 0, 0, 0 }, bgvofs = { 0, 0, 0, 0 },
		bgpa = { 256, 256 }, bgpb = { 0, 0 }, bgpc = { 0, 0 }, bgpd = { 256, 256 },
		bgx = { 0, 0 }, bgy = { 0, 0 },
		winh = { 0, 0 }, winv = { 0, 0 }, winin = 0, winout = 0,
		mosaic = 0, bldcnt = 0, bldalpha = 0, bldy = 0,
		dot = 0, line = 0, frameComplete = false, frame = 0,
		renderEvery = 1, drawThisFrame = true, frameRendered = false,
		framebuffer = buffer.create(W * H * 4),
		scanline = table.create(W, 0),
		scanPrio = table.create(W, 4),
		scanLayer = table.create(W, 0),
		scanSemi = table.create(W, false),
		scanUnder = table.create(W, 0),
		scanUnderLayer = table.create(W, 0),
		scanUnderPrio = table.create(W, 4),
	}
	return setmetatable(ppu, Ppu) :: any
end

-- Registers -----------------------------------------------------------------

function Ppu:read16(addr: number): number
	if addr == 0x000 then return self.dispcnt % 0x10000 end
	if addr == 0x002 then return self.dispcnt // 0x10000 end
	if addr == 0x004 then
		local stat = band(self.dispstat, 0xFFF8)
		if self.line >= 160 and self.line < 227 then stat = bor(stat, 1) end
		if self.dot >= 1006 then stat = bor(stat, 2) end
		if self.line == band(self.dispstat // 0x100, 0xFF) then stat = bor(stat, 4) end
		return stat
	end
	if addr == 0x006 then return self.line end
	if addr >= 0x008 and addr <= 0x00E then return self.bgcnt[(addr - 0x008) // 2 + 1] end
	if addr >= 0x010 and addr <= 0x01E then
		local i = (addr - 0x010) // 4 + 1
		return (addr % 4 == 0) and self.bghofs[i] or self.bgvofs[i]
	end
	if addr >= 0x028 and addr <= 0x03F and (addr % 8) >= 8 - 8 + 0 then
		if addr == 0x028 then return band(self.bgx[1], 0xFFFF) end
		if addr == 0x02A then return band(self.bgx[1] // 0x10000, 0xFFFF) end
		if addr == 0x02C then return band(self.bgy[1], 0xFFFF) end
		if addr == 0x02E then return band(self.bgy[1] // 0x10000, 0xFFFF) end
		if addr == 0x038 then return band(self.bgx[2], 0xFFFF) end
		if addr == 0x03A then return band(self.bgx[2] // 0x10000, 0xFFFF) end
		if addr == 0x03C then return band(self.bgy[2], 0xFFFF) end
		if addr == 0x03E then return band(self.bgy[2] // 0x10000, 0xFFFF) end
	end
	if addr >= 0x020 and addr <= 0x03F then
		local i = (addr - 0x020) // 16 + 1
		local reg = (addr - 0x020) % 8
		if reg == 0 then return band(self.bgpa[i], 0xFFFF) end
		if reg == 2 then return band(self.bgpb[i], 0xFFFF) end
		if reg == 4 then return band(self.bgpc[i], 0xFFFF) end
		if reg == 6 then return band(self.bgpd[i], 0xFFFF) end
	end
	if addr >= 0x040 and addr <= 0x046 then
		local i = ((addr - 0x040) % 4) // 2 + 1
		return addr < 0x044 and self.winh[i] or self.winv[i]
	end
	if addr == 0x048 then return self.winin end
	if addr == 0x04A then return self.winout end
	if addr == 0x04C then return self.mosaic end
	if addr == 0x050 then return self.bldcnt end
	if addr == 0x052 then return self.bldalpha end
	if addr == 0x054 then return self.bldy end
	return 0
end

function Ppu:write16(addr: number, value: number)
	value = band(value, 0xFFFF)
	if addr == 0x000 then self.dispcnt = bor(band(self.dispcnt, 0xFFFF0000), value)
	elseif addr == 0x002 then self.dispcnt = bor(band(self.dispcnt, 0xFFFF), lshift(value, 16))
	elseif addr == 0x004 then self.dispstat = band(value, 0xFFF8)
	elseif addr == 0x008 then self.bgcnt[1] = value
	elseif addr == 0x00A then self.bgcnt[2] = value
	elseif addr == 0x00C then self.bgcnt[3] = value
	elseif addr == 0x00E then self.bgcnt[4] = value
	elseif addr >= 0x010 and addr <= 0x01E then
		local i = (addr - 0x010) // 4 + 1
		if addr % 4 == 0 then self.bghofs[i] = band(value, 0x1FF) else self.bgvofs[i] = band(value, 0x1FF) end
	elseif addr == 0x028 then
		self.bgx[1] = bor(band(self.bgx[1], 0xFFFF0000), value)
	elseif addr == 0x02A then
		local hi = band(value, 0xFFF) * 0x10000
		local v = bor(band(self.bgx[1], 0xFFFF), hi)
		if v >= 0x8000000 then v -= 0x10000000 end
		self.bgx[1] = v
	elseif addr == 0x02C then
		self.bgy[1] = bor(band(self.bgy[1], 0xFFFF0000), value)
	elseif addr == 0x02E then
		local hi = band(value, 0xFFF) * 0x10000
		local v = bor(band(self.bgy[1], 0xFFFF), hi)
		if v >= 0x8000000 then v -= 0x10000000 end
		self.bgy[1] = v
	elseif addr == 0x038 then
		self.bgx[2] = bor(band(self.bgx[2], 0xFFFF0000), value)
	elseif addr == 0x03A then
		local hi = band(value, 0xFFF) * 0x10000
		local v = bor(band(self.bgx[2], 0xFFFF), hi)
		if v >= 0x8000000 then v -= 0x10000000 end
		self.bgx[2] = v
	elseif addr == 0x03C then
		self.bgy[2] = bor(band(self.bgy[2], 0xFFFF0000), value)
	elseif addr == 0x03E then
		local hi = band(value, 0xFFF) * 0x10000
		local v = bor(band(self.bgy[2], 0xFFFF), hi)
		if v >= 0x8000000 then v -= 0x10000000 end
		self.bgy[2] = v
	elseif addr >= 0x020 and addr <= 0x03F then
		local i = (addr - 0x020) // 16 + 1
		local reg = (addr - 0x020) % 8
		local s = value >= 0x8000 and value - 0x10000 or value
		if reg == 0 then self.bgpa[i] = s
		elseif reg == 2 then self.bgpb[i] = s
		elseif reg == 4 then self.bgpc[i] = s
		elseif reg == 6 then self.bgpd[i] = s end
	elseif addr >= 0x040 and addr <= 0x046 then
		local i = ((addr - 0x040) % 4) // 2 + 1
		if addr < 0x044 then self.winh[i] = value else self.winv[i] = value end
	elseif addr == 0x048 then self.winin = value
	elseif addr == 0x04A then self.winout = value
	elseif addr == 0x04C then self.mosaic = value
	elseif addr == 0x050 then self.bldcnt = value
	elseif addr == 0x052 then self.bldalpha = value
	elseif addr == 0x054 then self.bldy = band(value, 0x1F)
	end
end

function Ppu:reset()
	local fresh = Ppu.new(self.bus, self.interrupts)
	for k, v in fresh do self[k] = v end
end

-- Render at HBlank entry, then advance scanline timing. HBlank IRQs also occur
-- in VBlank; HBlank DMA runs only on visible lines.
function Ppu:tick(cycles: number)
	while cycles > 0 do
		local boundary = self.dot < 1006 and 1006 or CYCLES_PER_LINE
		local step = math.min(cycles, boundary - self.dot)
		self.dot += step
		cycles -= step
		if self.dot == 1006 then
			if self.line < H then
				if self.drawThisFrame then
					self:_renderScanline(self.line)
					self:_blitLine(self.line)
				end
				if self.dma then self.dma:trigger(2) end
			end
			if band(self.dispstat, 0x10) ~= 0 then self.interrupts:raise(Interrupts.HBLANK) end
		elseif self.dot == CYCLES_PER_LINE then
			self.dot = 0
			self.line = (self.line + 1) % LINES_TOTAL
			if self.line == 0 then
				-- Latch at the beginning of a frame so policy changes never
				-- produce a display with only some scanlines updated.
				self.drawThisFrame = self.frame % math.max(1, self.renderEvery) == 0
			end
			if self.line == H then
				if band(self.dispstat, 8) ~= 0 then self.interrupts:raise(Interrupts.VBLANK) end
				if self.dma then self.dma:trigger(1) end
				self.frame += 1
				self.frameComplete = true
				self.frameRendered = self.drawThisFrame
			end
			if self.line == band(self.dispstat // 0x100, 0xFF) and band(self.dispstat, 0x20) ~= 0 then
				self.interrupts:raise(Interrupts.VCOUNT)
			end
		end
	end
end

-- Backing stores ------------------------------------------------------------

function Ppu:_pal(idx: number): number
	local p = self.bus.pal
	local o = idx * 2
	return (p[o + 1] or 0) + (p[o + 2] or 0) * 0x100
end

function Ppu:_vram8(off: number): number
	return self.bus.vram[off + 1] or 0
end

function Ppu:_vram16(off: number): number
	local v = self.bus.vram
	return (v[off + 1] or 0) + (v[off + 2] or 0) * 0x100
end

function Ppu:_oam16(off: number): number
	local v = self.bus.oam
	return (v[off + 1] or 0) + (v[off + 2] or 0) * 0x100
end

local function expand5(v: number): number
	return band(v, 0x1F) * 255 // 31
end

-- 15-bit RGB -> packed RGBA8, precomputed once. The mapping is a pure function
-- of the colour value, so palette edits never invalidate it.
local RGBA_LUT = table.create(0x8000)
for c = 0, 0x7FFF do
	local r = expand5(c)
	local g = expand5(c // 0x20)
	local b = expand5(c // 0x400)
	RGBA_LUT[c + 1] = r + g * 0x100 + b * 0x10000 + 0xFF000000
end
Ppu.RGBA_LUT = RGBA_LUT

--- Write one composed scanline straight into the RGBA upload buffer.
-- One 32-bit store per pixel: no intermediate table, no per-channel packing at
-- frame time.
function Ppu:_blitLine(y: number)
	local fb = self.framebuffer
	local line = self.scanline
	local base = y * W * 4
	for x = 1, W do
		buffer.writeu32(fb, base + (x - 1) * 4, RGBA_LUT[line[x] + 1] or 0xFF000000)
	end
end

-- Pixel compositor -----------------------------------------------------------
-- Layer ids: 1..4 = BG0..BG3, 5 = OBJ, 6 = backdrop.
-- Lower priority number wins. On a tie the layer drawn *first* wins, so we draw
-- BG0 -> BG1 -> BG2 -> BG3 -> OBJ, which matches hardware precedence.

local function put(self, x: number, color: number, prio: number, layer: number, semi: boolean)
	if color == 0 then return end
	if prio < self.scanPrio[x] then
		self.scanUnder[x] = self.scanline[x]
		self.scanUnderLayer[x] = self.scanLayer[x]
		self.scanUnderPrio[x] = self.scanPrio[x]
		self.scanline[x] = color
		self.scanPrio[x] = prio
		self.scanLayer[x] = layer
		self.scanSemi[x] = semi
	elseif prio < self.scanUnderPrio[x] and self.scanUnderPrio[x] > self.scanPrio[x] then
		self.scanUnder[x] = color
		self.scanUnderLayer[x] = layer
		self.scanUnderPrio[x] = prio
	end
end

-- Text backgrounds (modes 0 and 1) -------------------------------------------

function Ppu:_renderTextBg(bg: number, y: number, maskArr: { number })
	local cnt = self.bgcnt[bg]
	local layerBit = lshift(1, bg - 1)
	local prio = band(cnt, 3)
	local charBase = band(cnt // 4, 3) * 0x4000
	local colors8 = band(cnt, 0x80) ~= 0
	local screenBase = band(cnt // 0x100, 0x1F) * 0x800
	local size = band(cnt // 0x4000, 3)
	local mapW = (size == 1 or size == 3) and 512 or 256
	local mapH = (size == 2 or size == 3) and 512 or 256
	local hofs, vofs = self.bghofs[bg], self.bgvofs[bg]
	local msize = (band(cnt, 0x40) ~= 0) and (band(self.mosaic, 0xF) + 1) or 1
	local sy = y + vofs
	if msize > 1 then sy = (sy // msize) * msize end
	sy %= mapH
	local mapRow = screenBase + (sy // 256) * (mapW // 256) * 0x800 + ((sy % 256) // 8) * 64
	local row = sy % 8
	local vram, palette = self.bus.vram, self.bus.pal
	local previousEntry, tileRow, pbank, hflip = -1, 0, 0, false

	for x = 1, W do
		if band(maskArr[x], layerBit) == 0 then continue end
		local sx = (x - 1 + hofs)
		if msize > 1 then
			sx = (sx // msize) * msize
		end
		sx %= mapW
		local entryOffset = mapRow + (sx // 256) * 0x800 + ((sx % 256) // 8) * 2
		-- Map entries and tile-row flags stay constant for eight pixels. The
		-- CPU/DMA cannot mutate VRAM during this synchronous scanline render.
		if entryOffset ~= previousEntry then
			previousEntry = entryOffset
			local entry = (vram[entryOffset + 1] or 0) + (vram[entryOffset + 2] or 0) * 0x100
			local py = band(entry, 0x800) ~= 0 and 7 - row or row
			tileRow = charBase + band(entry, 0x3FF) * (colors8 and 64 or 32) + py * (colors8 and 8 or 4)
			pbank = band(entry // 0x1000, 0xF) * 16
			hflip = band(entry, 0x400) ~= 0
		end
		local px = sx % 8
		if hflip then px = 7 - px end
		local idx
		if colors8 then
			idx = vram[tileRow + px + 1] or 0
		else
			local b = vram[tileRow + (px // 2) + 1] or 0
			idx = (px % 2 == 0) and band(b, 0xF) or b // 0x10
		end
		if idx ~= 0 then
			local palOffset = (colors8 and idx or (pbank + idx)) * 2
			local color = (palette[palOffset + 1] or 0) + (palette[palOffset + 2] or 0) * 0x100
			put(self, x, color, prio, bg, false)
		end
	end
end

-- Affine backgrounds (modes 1 and 2) -----------------------------------------

local AFFINE_DIM = { 128, 256, 512, 1024 }

function Ppu:_renderAffineBg(bg: number, y: number, maskArr: { number })
	local cnt = self.bgcnt[bg]
	local layerBit = lshift(1, bg - 1)
	local prio = band(cnt, 3)
	local charBase = band(cnt // 4, 3) * 0x4000
	local screenBase = band(cnt // 0x100, 0x1F) * 0x800
	local wrap = band(cnt, 0x2000) ~= 0
	local size = band(cnt // 0x4000, 3)
	local dim = AFFINE_DIM[size + 1]
	local ai = bg - 1 -- BG2 -> 1, BG3 -> 2
	local pa, pb = self.bgpa[ai], self.bgpb[ai]
	local pc, pd = self.bgpc[ai], self.bgpd[ai]
	local refX, refY = self.bgx[ai], self.bgy[ai]
	local msize = (band(cnt, 0x40) ~= 0) and (band(self.mosaic, 0xF) + 1) or 1
	local tilesPerRow = dim // 8

	-- Reference is 1/256 px; y contribution added once for the whole line.
	local rowX = refX + pb * msize * (y // 1)
	local rowY = refY + pd * msize * (y // 1)

	for x = 1, W do
		if band(maskArr[x], layerBit) == 0 then continue end
		local sampleX = x - 1
		local px = rowX + pa * msize * sampleX
		local py = rowY + pc * msize * sampleX
		local tx = px // 256
		local ty = py // 256
		local idx = 0
		if wrap then
			tx %= dim
			ty %= dim
			idx = self:_vram8(screenBase + (ty // 8) * tilesPerRow + (tx // 8))
		else
			if tx >= 0 and tx < dim and ty >= 0 and ty < dim then
				idx = self:_vram8(screenBase + (ty // 8) * tilesPerRow + (tx // 8))
			else
				idx = 0
			end
		end
		if idx ~= 0 then
			local tileAddr = charBase + idx * 64
			local pxi = tx % 8
			local pyi = ty % 8
			local color = self:_vram8(tileAddr + pyi * 8 + pxi)
			if color ~= 0 then
				put(self, x, self:_pal(256 + color), prio, bg, false)
			end
		end
	end
end

-- Sprites (OBJ) --------------------------------------------------------------

local OBJ_SIZES = {
	[0] = { { 8, 8 }, { 16, 16 }, { 32, 32 }, { 64, 64 } },     -- square
	[1] = { { 16, 8 }, { 32, 8 }, { 32, 16 }, { 64, 32 } },     -- wide
	[2] = { { 8, 16 }, { 8, 32 }, { 16, 32 }, { 32, 64 } },     -- tall
}

function Ppu:_objTileAddr(tileNum: number, colors8: boolean, oneD: boolean): number
	local bytes = colors8 and 64 or 32
	if oneD then
		return 0x10000 + tileNum * bytes
	end
	return 0x10000 + ((tileNum % 32) * bytes + (tileNum // 32) * 32 * bytes)
end

--- Read one sprite pixel; returns palette index (0 = transparent).
function Ppu:_objPixel(colors8: boolean, addr: number, px: number, py: number): number
	if colors8 then
		return self:_vram8(addr + py * 8 + px)
	end
	local b = self:_vram8(addr + py * 4 + (px // 2))
	if px % 2 == 0 then return band(b, 0xF) end
	return b // 0x10
end

function Ppu:_renderObj(y: number, maskArr: { number }, objWinArr: { boolean })
	local dispcnt = self.dispcnt
	local oneD = band(dispcnt, 0x40) ~= 0
	local oam = self.bus.oam
	local msize = (band(dispcnt, 0x40) ~= 0) and 1 or 1
	msize = msize -- mosaic handled per-sprite below

	for i = 0, 127 do
		local o = i * 8
		local attr0 = (oam[o + 1] or 0) + (oam[o + 2] or 0) * 0x100
		local attr1 = (oam[o + 3] or 0) + (oam[o + 4] or 0) * 0x100
		local attr2 = (oam[o + 5] or 0) + (oam[o + 6] or 0) * 0x100

		local shape = (attr0 // 0x4000) % 4
		if shape == 3 then continue end
		local size = (attr1 // 0x4000) % 4
		local dims = OBJ_SIZES[shape][size + 1]
		local w, h = dims[1], dims[2]

		local sy = band(attr0, 0xFF)
		if sy > 159 then sy -= 256 end
		local sx = band(attr1, 0x1FF)
		if sx > 239 then sx -= 512 end

		local rot = band(attr0, 0x100) ~= 0
		local dbl = band(attr0, 0x200) ~= 0
		local mode = (attr0 // 0x400) % 4
		if mode == 3 then continue end
		local mosaic = band(attr0, 0x1000) ~= 0
		local colors8 = band(attr0, 0x2000) ~= 0
		local prio = (attr2 // 0x400) % 4
		local palBank = (attr2 // 0x1000) * 16
		local tileNum = band(attr2, 0x3FF)
		local key = prio * 2048 - 1024 - i

		local boxW = rot and (dbl and w * 2 or w) or w
		local boxH = rot and (dbl and h * 2 or h) or h
		if y < sy or y >= sy + boxH then
			-- still need to know it does not cover this line
			if rot then
				if y < sy or y >= sy + boxH then continue end
			else
				continue
			end
		end

		if rot then
			local affineIndex = (attr1 // 0x200) % 32
			local po = affineIndex * 32
			local pa = (oam[po + 7] or 0) + (oam[po + 8] or 0) * 0x100
			local pb = (oam[po + 15] or 0) + (oam[po + 16] or 0) * 0x100
			local pc = (oam[po + 23] or 0) + (oam[po + 24] or 0) * 0x100
			local pd = (oam[po + 31] or 0) + (oam[po + 32] or 0) * 0x100
			pa = pa >= 0x8000 and pa - 0x10000 or pa
			pb = pb >= 0x8000 and pb - 0x10000 or pb
			pc = pc >= 0x8000 and pc - 0x10000 or pc
			pd = pd >= 0x8000 and pd - 0x10000 or pd
			local halfW, halfH = w // 2, h // 2
			local cy = (y - sy) - boxH // 2
			local addr = self:_objTileAddr(tileNum, colors8, oneD)
			for bx = 0, boxW - 1 do
				local cx = bx - boxW // 2
				local tx = (pa * cx + pb * cy) // 256 + halfW
				local ty = (pc * cx + pd * cy) // 256 + halfH
				if tx >= 0 and tx < w and ty >= 0 and ty < h then
					local px = sx + bx
					if px >= 0 and px < W then
						local idx = self:_objPixel(colors8, addr, tx, ty)
						if idx ~= 0 then
							local x = px + 1
							if mode == 2 then
								objWinArr[x] = true
							elseif band(maskArr[x], 0x10) ~= 0 then
								local color = self:_pal(colors8 and idx or (palBank + idx))
								put(self, x, color, key, 5, mode == 1)
							end
						end
					end
				end
			end
		else
			local hflip = band(attr1, 0x1000) ~= 0
			local vflip = band(attr1, 0x2000) ~= 0
			local addr = self:_objTileAddr(tileNum, colors8, oneD)
			local m = mosaic and (band(self.mosaic, 0xF) + 1) or 1
			local ly = y - sy
			if vflip then ly = h - 1 - ly end
			if m > 1 then ly = (ly // m) * m end
			for bx = 0, w - 1 do
				local px = sx + bx
				if px >= 0 and px < W then
					local lx = bx
					if hflip then lx = w - 1 - bx end
					if m > 1 then lx = (lx // m) * m end
					local idx = self:_objPixel(colors8, addr, lx, ly)
					if idx ~= 0 then
						local x = px + 1
						if mode == 2 then
							objWinArr[x] = true
						elseif band(maskArr[x], 0x10) ~= 0 then
							local color = self:_pal(colors8 and idx or (palBank + idx))
							put(self, x, color, key, 5, mode == 1)
						end
					end
				end
			end
		end
	end
end

-- Bitmap backgrounds (modes 3, 4, 5) -----------------------------------------

function Ppu:_renderBitmapBg(mode: number, y: number, maskArr: { number })
	local dispcnt = self.dispcnt
	local layerBit = 0x4 -- BG2
	local page = band(dispcnt, 0x10) ~= 0 and 1 or 0
	if mode == 3 then
		local base = y * 240 * 2
		for x = 1, W do
			if band(maskArr[x], layerBit) == 0 then continue end
			local color = self:_vram16(base + (x - 1) * 2)
			if color ~= 0 then put(self, x, color, 0, 3, false) end
		end
	elseif mode == 4 then
		local base = page * 0xA000 + y * 240
		for x = 1, W do
			if band(maskArr[x], layerBit) == 0 then continue end
			local idx = self:_vram8(base + (x - 1))
			if idx ~= 0 then put(self, x, self:_pal(idx), 0, 3, false) end
		end
	elseif mode == 5 then
		if y >= 128 then return end
		local base = page * 0xA000 + y * 160 * 2
		for x = 1, math.min(W, 160) do
			if band(maskArr[x], layerBit) == 0 then continue end
			local color = self:_vram16(base + (x - 1) * 2)
			if color ~= 0 then put(self, x, color, 0, 3, false) end
		end
	end
end

-- Windows --------------------------------------------------------------------

function Ppu:_computeWindows(y: number, objWinArr: { boolean }, maskArr: { number })
	local dispcnt = self.dispcnt
	local hasWin = band(dispcnt, 0xE000) ~= 0
	if not hasWin then
		for x = 1, W do maskArr[x] = 0x3F end
		return
	end
	local winin, winout = self.winin, self.winout
	local w0h, w0v = self.winh[1], self.winv[1]
	local w1h, w1v = self.winh[2], self.winv[2]
	local w0ok = band(dispcnt, 0x2000) ~= 0
	local w1ok = band(dispcnt, 0x4000) ~= 0
	local objwinOk = band(dispcnt, 0x8000) ~= 0
	for x = 1, W do
		local px = x - 1
		local in0 = false
		if w0ok then
			local left = band(w0h // 0x100, 0xFF)
			local right = band(w0h, 0xFF)
			local top = band(w0v // 0x100, 0xFF)
			local bottom = band(w0v, 0xFF)
			local xIn = (left <= right) and (px >= left and px <= right) or (px >= left or px <= right)
			local yIn = (top <= bottom) and (y >= top and y <= bottom) or (y >= top or y <= bottom)
			in0 = xIn and yIn
		end
		local mask
		if in0 then
			mask = band(winin, 0x3F)
		else
			local in1 = false
			if w1ok then
				local left = band(w1h // 0x100, 0xFF)
				local right = band(w1h, 0xFF)
				local top = band(w1v // 0x100, 0xFF)
				local bottom = band(w1v, 0xFF)
				local xIn = (left <= right) and (px >= left and px <= right) or (px >= left or px <= right)
				local yIn = (top <= bottom) and (y >= top and y <= bottom) or (y >= top or y <= bottom)
				in1 = xIn and yIn
			end
			if in1 then
				mask = band(winin // 0x100, 0x3F)
			elseif objwinOk and objWinArr[x] then
				mask = band(winout, 0x3F)
			else
				mask = band(winout // 0x100, 0x3F)
			end
		end
		maskArr[x] = mask
	end
end

-- Colour special effects -----------------------------------------------------

local function blendChannel(c1: number, c2: number, eva: number): number
	local r = (c1 * eva + c2 * (16 - eva)) // 16
	return r > 31 and 31 or r
end

local function brightenChannel(c: number, evy: number): number
	local r = c + (31 - c) * evy // 16
	return r > 31 and 31 or r
end

local function darkenChannel(c: number, evy: number): number
	local r = c - c * evy // 16
	return r < 0 and 0 or r
end

local function effectLayerBit(layer: number): number
	if layer >= 1 and layer <= 4 then return lshift(1, layer - 1) end
	if layer == 5 then return 0x10 end
	return 0x20
end

function Ppu:_applyEffects(maskArr: { number })
	local bldcnt = self.bldcnt
	local effect = (bldcnt // 0x40) % 4
	if effect == 0 then return end
	local target1 = band(bldcnt, 0x3F)
	local target2 = band(bldcnt // 0x100, 0x3F)
	local eva = band(self.bldalpha, 0x1F)
	local evy = band(self.bldy, 0x1F)

	for x = 1, W do
		if band(maskArr[x], 0x20) == 0 then continue end
		local top = self.scanline[x]
		local topLayer = self.scanLayer[x]
		local semi = self.scanSemi[x]
		local doAlpha = false
		if semi and topLayer == 5 then
			doAlpha = true
		elseif effect == 1 and band(target1, effectLayerBit(topLayer)) ~= 0
			and band(target2, effectLayerBit(self.scanUnderLayer[x])) ~= 0 then
			doAlpha = true
		end
		if doAlpha then
			local under = self.scanUnder[x]
			local r1 = band(top, 0x1F)
			local g1 = band(top // 0x20, 0x1F)
			local b1 = band(top // 0x400, 0x1F)
			local r2 = band(under, 0x1F)
			local g2 = band(under // 0x20, 0x1F)
			local b2 = band(under // 0x400, 0x1F)
			local r = blendChannel(r1, r2, eva)
			local g = blendChannel(g1, g2, eva)
			local b = blendChannel(b1, b2, eva)
			self.scanline[x] = r + g * 0x20 + b * 0x400
		elseif effect == 2 and band(target1, effectLayerBit(topLayer)) ~= 0 then
			local r = brightenChannel(band(top, 0x1F), evy)
			local g = brightenChannel(band(top // 0x20, 0x1F), evy)
			local b = brightenChannel(band(top // 0x400, 0x1F), evy)
			self.scanline[x] = r + g * 0x20 + b * 0x400
		elseif effect == 3 and band(target1, effectLayerBit(topLayer)) ~= 0 then
			local r = darkenChannel(band(top, 0x1F), evy)
			local g = darkenChannel(band(top // 0x20, 0x1F), evy)
			local b = darkenChannel(band(top // 0x400, 0x1F), evy)
			self.scanline[x] = r + g * 0x20 + b * 0x400
		end
	end
end

-- Scanline orchestration -----------------------------------------------------

function Ppu:_renderScanline(y: number)
	local pal0 = self:_pal(0)
	for x = 1, W do
		self.scanline[x] = pal0
		self.scanPrio[x] = 0x7FFFFFF0
		self.scanLayer[x] = 6
		self.scanSemi[x] = false
		self.scanUnder[x] = pal0
		self.scanUnderLayer[x] = 6
		self.scanUnderPrio[x] = 0x7FFFFFF0
	end

	local dispcnt = self.dispcnt
	if band(dispcnt, 0x80) ~= 0 then
		for x = 1, W do self.scanline[x] = 0x7FFF end
		return
	end

	local maskArr = self._maskArr or table.create(W, 0x3F)
	self._maskArr = maskArr
	local approx = self._approxMask or table.create(W, 0x3F)
	self._approxMask = approx
	local objWinArr = self._objWinArr or table.create(W, false)
	self._objWinArr = objWinArr
	for x = 1, W do objWinArr[x] = false end

	local mode = dispcnt % 8
	local bgEn = (dispcnt // 0x100) % 16

	self:_computeWindows(y, objWinArr, approx)
	if band(dispcnt, 0x1000) ~= 0 then
		self:_renderObj(y, approx, objWinArr)
	end
	self:_computeWindows(y, objWinArr, maskArr)

	local function enabled(bg: number): boolean
		return band(bgEn, lshift(1, bg)) ~= 0
	end

	if mode == 0 then
		for b = 0, 3 do
			if enabled(b) then self:_renderTextBg(b + 1, y, maskArr) end
		end
	elseif mode == 1 then
		if enabled(0) then self:_renderTextBg(1, y, maskArr) end
		if enabled(1) then self:_renderTextBg(2, y, maskArr) end
		if enabled(2) then self:_renderAffineBg(3, y, maskArr) end
	elseif mode == 2 then
		if enabled(2) then self:_renderAffineBg(3, y, maskArr) end
		if enabled(3) then self:_renderAffineBg(4, y, maskArr) end
	elseif mode == 3 then
		if enabled(2) then self:_renderBitmapBg(3, y, maskArr) end
	elseif mode == 4 then
		if enabled(2) then self:_renderBitmapBg(4, y, maskArr) end
	elseif mode == 5 then
		if enabled(2) then self:_renderBitmapBg(5, y, maskArr) end
	end

	self:_applyEffects(maskArr)
end

return Ppu
