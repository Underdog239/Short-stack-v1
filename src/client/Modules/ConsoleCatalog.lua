--!strict

export type ConsoleInfo = {
	id: string,
	name: string,
	shortName: string,
	manufacturer: string,
	family: string,
	era: string,
	resolution: string,
	accent: Color3,
	format: string,
	coreRequirement: string,
}

local consoles: { ConsoleInfo } = {
	{
		id = "gba",
		name = "Game Boy Advance",
		shortName = "GBA",
		manufacturer = "Nintendo",
		family = "Handheld",
		era = "2001",
		resolution = "240 × 160",
		accent = Color3.fromRGB(140, 153, 255),
		format = "32-bit handheld",
		coreRequirement = "Depth GBA source and demo path are linked; Studio test is pending",
	},
	{
		id = "nes",
		name = "Nintendo Entertainment System",
		shortName = "NES",
		manufacturer = "Nintendo",
		family = "Home",
		era = "1983",
		resolution = "256 × 240",
		accent = Color3.fromRGB(255, 125, 105),
		format = "8-bit home console",
		coreRequirement = "NES core needed",
	},
	{
		id = "gb",
		name = "Game Boy",
		shortName = "GB",
		manufacturer = "Nintendo",
		family = "Handheld",
		era = "1989",
		resolution = "160 × 144",
		accent = Color3.fromRGB(184, 211, 132),
		format = "Monochrome handheld",
		coreRequirement = "Game Boy core needed",
	},
	{
		id = "gbc",
		name = "Game Boy Color",
		shortName = "GBC",
		manufacturer = "Nintendo",
		family = "Handheld",
		era = "1998",
		resolution = "160 × 144",
		accent = Color3.fromRGB(255, 190, 108),
		format = "Color handheld · GB compatible",
		coreRequirement = "Game Boy Color core needed",
	},
	{
		id = "sms",
		name = "Master System",
		shortName = "SMS",
		manufacturer = "SEGA",
		family = "Home",
		era = "1985",
		resolution = "256 × 192",
		accent = Color3.fromRGB(104, 181, 255),
		format = "8-bit home console",
		coreRequirement = "Master System core needed",
	},
	{
		id = "gg",
		name = "Game Gear",
		shortName = "GG",
		manufacturer = "SEGA",
		family = "Handheld",
		era = "1990",
		resolution = "160 × 144",
		accent = Color3.fromRGB(109, 208, 184),
		format = "Color handheld",
		coreRequirement = "Game Gear core needed",
	},
	{
		id = "atari2600",
		name = "Atari 2600",
		shortName = "2600",
		manufacturer = "Atari",
		family = "Home",
		era = "1977",
		resolution = "160 × 192",
		accent = Color3.fromRGB(255, 156, 105),
		format = "8-bit home console",
		coreRequirement = "Atari 2600 core needed",
	},
	{
		id = "snes",
		name = "Super Nintendo",
		shortName = "SNES",
		manufacturer = "Nintendo",
		family = "Home",
		era = "1990",
		resolution = "256 × 224",
		accent = Color3.fromRGB(200, 143, 255),
		format = "16-bit home console",
		coreRequirement = "SNES core needed",
	},
}

local byId: { [string]: ConsoleInfo } = {}
for _, console in ipairs(consoles) do
	byId[console.id] = console
end

table.freeze(consoles)
table.freeze(byId)

local ConsoleCatalog = {}

function ConsoleCatalog.GetAll(): { ConsoleInfo }
	local result: { ConsoleInfo } = table.create(#consoles)
	for index, console in ipairs(consoles) do
		result[index] = console
	end
	return result
end

function ConsoleCatalog.Get(id: string): ConsoleInfo?
	return byId[id]
end

return ConsoleCatalog
