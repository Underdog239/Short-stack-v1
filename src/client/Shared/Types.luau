--!strict
--[[
	Types.luau
	Central type definitions shared across the emulator, renderer and diagnostics.
	Keeping these in one place lets every subsystem agree on interfaces without
	circular requires.
]]

export type U8 = number
export type U16 = number
export type U32 = number

-- A flat RGBA byte buffer: 4 bytes per pixel (R,G,B,A), length = w*h*4.
export type PixelBuffer = { [number]: number }

export type FrameBuffer = {
	width: number,
	height: number,
	-- `pixels` is a plain Lua array of bytes (1-based) used with buffer APIs.
	pixels: PixelBuffer,
	-- monotonically increasing frame counter (for the renderer / diag)
	frameId: number,
}

export type KeyMask = number

export type RomInfo = {
	title: string,
	gameCode: string,
	makerCode: string,
	version: number,
	entryPoint: U32,
	headerChecksum: number,
	headerChecksumOk: boolean,
	romSizeBytes: number,
	saveType: string, -- "NONE" | "EEPROM" | "SRAM" | "FLASH512" | "FLASH1024"
	sizeIndex: number,
}

export type EmulatorOptions = {
	-- Path/instance to a real GBA BIOS (16 KiB). If nil we use HLE.
	bios: { [number]: number }?,
	-- ROM image bytes
	rom: { [number]: number },
	-- Render scale (integer). 1 = 240x160 native.
	scale: number?,
	-- Emulated CPU budget per rendered frame (safety valve).
	cyclesPerFrame: number?,
	-- Diagnostics controller, if any.
	diag: any?,
}

return {}
