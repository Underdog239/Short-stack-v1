--!strict
-- Local-only GBA ROM loader. It reads base64 from StringValues under the
-- ShortStack LocalScript tree. It deliberately does not require ROM ModuleScripts
-- (which execute code) and never performs HTTP, asset-ID, or filesystem loads.

local projectRoot = script:FindFirstAncestor("ShortStack")
assert(projectRoot, "Depth must be mounted under ShortStack")
local shared = projectRoot:WaitForChild("Shared")
local Base64 = require(shared:WaitForChild("Base64") :: ModuleScript)

local ROMLoader = {}
local MAX_ROM = 32 * 1024 * 1024
local MAX_ENCODED = math.ceil(MAX_ROM / 3) * 4
local MAX_CHUNKS = 4096

local function decode(text: string, source: string): (buffer?, string?)
	if #text > MAX_ENCODED then
		return nil, source .. " exceeds the 32 MiB ROM limit"
	end
	if not text:find("%S") then
		return nil, nil
	end

	local ok, bytes = pcall(Base64.decodeToBuffer, text)
	if not ok then
		return nil, source .. " is not valid base64: " .. tostring(bytes)
	end
	local byteCount = buffer.len(bytes)
	if byteCount < 0xC0 or byteCount > MAX_ROM then
		return nil, source .. " must decode to 192 bytes–32 MiB"
	end
	return bytes, source
end

local function fromFolder(folder: Folder, source: string): (buffer?, string?)
	local chunks: { [number]: string } = {}
	local count = 0
	local encodedSize = 0
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("StringValue") then
			local indexText = child.Name
			local index = indexText:match("^%d+$") and tonumber(indexText) or nil
			if not index or index < 1 then
				return nil, source .. " has a non-numeric chunk name"
			end
			if chunks[index] ~= nil then
				return nil, source .. " has duplicate chunk indices"
			end
			if count >= MAX_CHUNKS then
				return nil, source .. " exceeds the 4096 chunk limit"
			end
			encodedSize += #child.Value
			if encodedSize > MAX_ENCODED then
				return nil, source .. " exceeds the 32 MiB ROM limit"
			end
			chunks[index] = child.Value
			count += 1
		end
	end
	if count == 0 then
		return nil, nil
	end

	local ordered = table.create(count)
	for index = 1, count do
		local value = chunks[index]
		if value == nil then
			return nil, source .. " has a missing chunk index"
		end
		ordered[index] = value
	end
	return decode(table.concat(ordered), source)
end

local function fromValue(value: Instance?, source: string): (buffer?, string?)
	if value == nil then
		return nil, nil
	elseif value:IsA("StringValue") then
		return decode(value.Value, source)
	elseif value:IsA("Folder") then
		return fromFolder(value, source)
	elseif value:IsA("ModuleScript") then
		return nil, source .. " must be a StringValue or numbered StringValue folder; ModuleScripts are not executed"
	end
	return nil, source .. " must be a StringValue or numbered StringValue folder"
end

--- Locate an installed, locally embedded ROM. No ROM is bundled by default.
function ROMLoader.find(): (buffer?, string?)
	local assets = projectRoot:FindFirstChild("Assets")
	if assets then
		local bytes, source = fromValue(assets:FindFirstChild("ROM"), "Assets.ROM")
		if bytes or source then
			return bytes, source
		end
	end

	local bytes, source = fromValue(projectRoot:FindFirstChild("GBAROM"), "GBAROM")
	if bytes or source then
		return bytes, source
	end
	return nil, "No local ROM is installed. Add an authorized base64 StringValue named ROM under ShortStack.Assets."
end

return ROMLoader
