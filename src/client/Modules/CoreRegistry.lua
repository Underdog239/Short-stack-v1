--!strict
-- This registry never fetches or requires remote assets. Emulator modules must be
-- included as reviewed local source and explicitly registered by the owner.

export type CoreModule = {
	apiVersion: number,
	id: string,
	Create: (configuration: { [string]: any }) -> any,
}

local ConsoleCatalog = require(script.Parent:WaitForChild("ConsoleCatalog") :: ModuleScript)

local API_VERSION = 1
local cores: { [string]: CoreModule } = {}

local CoreRegistry = {}

function CoreRegistry.Register(consoleId: string, core: CoreModule): (boolean, string)
	if type(consoleId) ~= "string" or consoleId == "" then
		return false, "A console id is required."
	end
	if ConsoleCatalog.Get(consoleId) == nil then
		return false, "The console id is not present in the local catalog."
	end
	if type(core) ~= "table" then
		return false, "A core must be a local module returning a table."
	end
	if core.apiVersion ~= API_VERSION then
		return false, string.format("Core API mismatch; expected version %d.", API_VERSION)
	end
	if core.id ~= consoleId then
		return false, "The core id does not match the selected console."
	end
	if type(core.Create) ~= "function" then
		return false, "The core must implement Create(configuration)."
	end
	if cores[consoleId] ~= nil then
		return false, "A core is already registered for this console."
	end

	cores[consoleId] = core
	return true, "Core registered."
end

function CoreRegistry.Get(consoleId: string): CoreModule?
	return cores[consoleId]
end

function CoreRegistry.GetStatus(consoleId: string): { ready: boolean, label: string, detail: string }
	local core = cores[consoleId]
	if core then
		return {
			ready = true,
			label = "CORE LINKED",
			detail = "A local, client-side core adapter is registered; Roblox Studio runtime validation is still pending.",
		}
	end

	return {
		ready = false,
		label = "CORE NEEDED",
		detail = "No local emulator core is installed for this system.",
	}
end

function CoreRegistry.Count(): number
	local count = 0
	for _ in pairs(cores) do
		count += 1
	end
	return count
end

function CoreRegistry.GetApiVersion(): number
	return API_VERSION
end

return CoreRegistry
