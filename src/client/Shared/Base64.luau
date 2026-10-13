--!strict
--[[ Shared/Base64.luau -- dependency-free base64 for ROM/save transfer.
     Roblox clients cannot read local files, so ROMs are pasted as base64 text
     and decoded here (or supplied programmatically as a byte array). ]]

local Base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DECODE: { [number]: number } = {}
for i = 1, #ALPHABET do
	DECODE[string.byte(ALPHABET, i)] = i - 1
end

function Base64.encode(bytes: { number }): string
	local out = table.create(math.ceil(#bytes / 3) * 4)
	local i = 1
	while i + 2 <= #bytes do
		local n = bytes[i] * 0x10000 + bytes[i + 1] * 0x100 + bytes[i + 2]
		out[#out + 1] = string.sub(ALPHABET, n // 0x40000 % 64 + 1, n // 0x40000 % 64 + 1)
		out[#out + 1] = string.sub(ALPHABET, n // 0x1000 % 64 + 1, n // 0x1000 % 64 + 1)
		out[#out + 1] = string.sub(ALPHABET, n // 0x40 % 64 + 1, n // 0x40 % 64 + 1)
		out[#out + 1] = string.sub(ALPHABET, n % 64 + 1, n % 64 + 1)
		i += 3
	end
	local rem = #bytes - i + 1
	if rem == 1 then
		local n = bytes[i] * 0x10000
		out[#out + 1] = string.sub(ALPHABET, n // 0x40000 % 64 + 1, n // 0x40000 % 64 + 1)
		out[#out + 1] = string.sub(ALPHABET, n // 0x1000 % 64 + 1, n // 0x1000 % 64 + 1)
		out[#out + 1] = "="
		out[#out + 1] = "="
	elseif rem == 2 then
		local n = bytes[i] * 0x10000 + bytes[i + 1] * 0x100
		out[#out + 1] = string.sub(ALPHABET, n // 0x40000 % 64 + 1, n // 0x40000 % 64 + 1)
		out[#out + 1] = string.sub(ALPHABET, n // 0x1000 % 64 + 1, n // 0x1000 % 64 + 1)
		out[#out + 1] = string.sub(ALPHABET, n // 0x40 % 64 + 1, n // 0x40 % 64 + 1)
		out[#out + 1] = "="
	end
	return table.concat(out)
end

--- Decode base64 straight into a native buffer (the fast path used for ROMs).
-- Groups are written as a single 32-bit store where there is room, which is
-- three times fewer stores than a byte-at-a-time loop.
function Base64.decodeToBuffer(text: string): buffer
	-- Most ROM data has no whitespace. Avoid cloning a potentially large base64
	-- string unless normalization is actually needed.
	if text:find("%s") then
		text = text:gsub("%s", "")
	end
	local n = #text
	assert(n % 4 == 0, "Invalid base64 length")
	assert(not text:find("[^%w+/=]"), "Invalid base64 character")
	local firstPadding = text:find("=", 1, true)
	if firstPadding then
		assert(firstPadding >= n - 1 and text:sub(firstPadding):match("^=+$"), "Invalid base64 padding")
	end
	local padding = 0
	if n >= 1 and string.byte(text, n) == 61 then padding += 1 end
	if n >= 2 and string.byte(text, n - 1) == 61 then padding += 1 end
	local size = (n // 4) * 3 - padding
	if size < 0 then size = 0 end

	local buf = buffer.create(size)
	local i = 1
	local o = 0
	while i + 3 <= n do
		local c1 = DECODE[string.byte(text, i)]
		local c2 = DECODE[string.byte(text, i + 1)]
		local c3 = DECODE[string.byte(text, i + 2)]
		local c4 = DECODE[string.byte(text, i + 3)]
		assert(c1 ~= nil and c2 ~= nil, "Invalid base64 group")
		local b0 = c1 * 4 + c2 // 16
		local b1 = 0
		local b2 = 0
		if c3 ~= nil then
			b1 = (c2 % 16) * 16 + c3 // 4
			if c4 ~= nil then b2 = (c3 % 4) * 64 + c4 end
		end
		if o + 4 <= size then
			-- one store covers three payload bytes; the 4th is rewritten by the
			-- next group, so it never escapes into the result.
			buffer.writeu32(buf, o, b0 + b1 * 0x100 + b2 * 0x10000)
		else
			if o < size then buffer.writeu8(buf, o, b0) end
			if c3 ~= nil and o + 1 < size then buffer.writeu8(buf, o + 1, b1) end
			if c4 ~= nil and o + 2 < size then buffer.writeu8(buf, o + 2, b2) end
		end
		o += 3
		i += 4
	end
	return buf
end

--- Decode base64 into a 1-based byte array (convenience / tests).
function Base64.decode(text: string): { number }
	local buf = Base64.decodeToBuffer(text)
	local n = buffer.len(buf)
	local out = table.create(n, 0)
	for i = 0, n - 1 do out[i + 1] = buffer.readu8(buf, i) end
	return out
end

return Base64
