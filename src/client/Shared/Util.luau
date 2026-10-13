--!strict
--[[ Shared/Util.luau -- small, dependency-free helpers used everywhere. ]]

local Util = {}

-- Buffer/array helpers -----------------------------------------------------

--- Create a zero-filled plain array of length n.
function Util.zeroArray(n: number): {number}
	local t = table.create(n, 0)
	return t
end

--- Copy `len` bytes from `src[srcStartOff]` into `dst[dstStartOff]`.
function Util.copyBytes(dst: {number}, dstStartOff: number, src: {number}, srcStartOff: number, len: number)
	for i = 0, len - 1 do
		dst[dstStartOff + i] = src[srcStartOff + i]
	end
end

--- Read a little-endian unsigned integer of `bytes` width from an array.
function Util.readLE(arr: {number}, off: number, bytes: number): number
	local v = 0
	for i = 0, bytes - 1 do
		v += (arr[off + i] or 0) * (2 ^ (8 * i))
	end
	return v
end

--- Write a little-endian unsigned integer of `bytes` width into an array.
function Util.writeLE(arr: {number}, off: number, bytes: number, value: number)
	for i = 0, bytes - 1 do
		arr[off + i] = (value // (2 ^ (8 * i))) % 256
	end
end

--- Convert a string into a 1-based byte array (fast path via string.byte).
function Util.stringToBytes(s: string): {number}
	local n = #s
	local out = table.create(n, 0)
	local b = 0
	local i = 1
	-- process 8 at a time to reduce interpreter overhead
	while i + 7 <= n do
		out[b + 1], out[b + 2], out[b + 3], out[b + 4], out[b + 5], out[b + 6], out[b + 7], out[b + 8] =
			string.byte(s, i, i + 7)
		b += 8; i += 8
	end
	while i <= n do
		out[b + 1] = string.byte(s, i)
		b += 1; i += 1
	end
	return out
end

--- Convert a 1-based byte array back into a string.
function Util.bytesToString(arr: {number}, off: number?, len: number?): string
	off = off or 1
	len = len or (#arr - off + 1)
	local chunks: {string} = table.create(math.ceil(len / 256))
	local i = 0
	while i < len do
		local run = math.min(256, len - i)
		chunks[#chunks + 1] = string.char(table.unpack(arr, off + i, off + i + run - 1))
		i += run
	end
	return table.concat(chunks)
end

-- Native buffer interop ------------------------------------------------------
-- The emulator keeps large byte stores (ROM, framebuffer) in Luau `buffer`s.
-- A buffer is exactly N bytes; a Lua array of the same data costs roughly 16x
-- that in TValue overhead and creates serious GC pressure.

--- Convert a 1-based byte array into a native buffer.
function Util.bytesToBuffer(bytes: { number }): buffer
	local n = #bytes
	local buf = buffer.create(n)
	for i = 1, n do
		buffer.writeu8(buf, i - 1, bit32.band(bytes[i] or 0, 0xFF))
	end
	return buf
end

--- Convert a native buffer into a 1-based byte array (tests / debugging).
function Util.bufferToBytes(buf: buffer): { number }
	local n = buffer.len(buf)
	local out = table.create(n, 0)
	for i = 0, n - 1 do out[i + 1] = buffer.readu8(buf, i) end
	return out
end

--- True when `v` is a native buffer.
function Util.isBuffer(v: any): boolean
	return type(v) == "buffer"
end

-- Timing -------------------------------------------------------------------

function Util.now(): number
	return os.clock()
end

-- Bit helpers (thin wrappers so intent is readable) -----------------------

function Util.band(a: number, b: number): number return bit32.band(a, b) end
function Util.bor(a: number, b: number): number return bit32.bor(a, b) end
function Util.bxor(a: number, b: number): number return bit32.bxor(a, b) end
function Util.bnot(a: number): number return bit32.bnot(a) end
function Util.lshift(a: number, b: number): number return bit32.lshift(a, b) end
function Util.rshift(a: number, b: number): number return bit32.rshift(a, b) end
function Util.arshift(a: number, b: number): number return bit32.arshift(a, b) end

--- Signed interpretation of a 32-bit value.
function Util.signed32(v: number): number
	v %= 0x100000000
	if v >= 0x80000000 then
		return v - 0x100000000
	end
	return v
end

--- Clamp with optional integer rounding.
function Util.clamp(v: number, lo: number, hi: number): number
	if v < lo then return lo elseif v > hi then return hi end
	return v
end

return Util
