--!strict
--[[ Shared/Config.luau -- single source of truth for tunables (v1.0).
     Every layer (core, renderer, diagnostics, audio, saves) reads from here so
     behaviour is consistent across the whole build. ]]

local Config = {}

Config.VERSION = "0.3.0-testing"

-- Emulation clock targets ---------------------------------------------------
-- GBA: 16.777216 MHz CPU, 59.7275 Hz display, 280896 cycles per frame.
Config.CPU_HZ = 16777216
Config.FPS = 59.7275
Config.CYCLES_PER_FRAME = 280896
Config.SCREEN_W = 240
Config.SCREEN_H = 160
Config.FRAME_PIXELS = Config.SCREEN_W * Config.SCREEN_H

-- Renderer ------------------------------------------------------------------
Config.RENDER = {
	scale = 2,
	-- "native"   : present every produced frame
	-- "adaptive" : present on a schedule that holds the target FPS
	-- "grid"     : force the coarse Frame-grid backend (fallback / debugging)
	mode = "native" :: "native" | "adaptive" | "grid",
	minFps = 30,
	targetFps = 60,
	autoScale = true,
}

-- Core loop -----------------------------------------------------------------
Config.CORE = {
	-- Yield the client frame after this budget; headless tests run whole frames.
	clientSliceMs = 8,
	-- Skip only proven unchanged THUMB wait loops, stopping before each event.
	idleLoopSkip = true,
	-- Dispatch hardware in batches bounded by timers, video/audio events and IO.
	tickBatchCycles = 64,
	-- Hard ceiling on emulated instructions per rendered frame. Prevents a
	-- runaway frame from freezing the Roblox client (watchdog guards too).
	maxCyclesPerFrame = Config.CYCLES_PER_FRAME * 2,
	-- When true, ignore VBlank pacing and run a fixed cycle budget per frame
	-- (used for benchmarking and for titles that need a speed nudge).
	skipFrameCap = false,
	fixedCyclesPerFrame = Config.CYCLES_PER_FRAME,
	-- Emit a per-instruction trace. Extremely costly; diagnostics only.
	traceInstructions = false,
}

-- PCM monitoring plus optional uploaded square-wave approximation.
-- Full PCM playback is unavailable through public Roblox client APIs.
Config.AUDIO = {
	enabled = true,
	sampleRate = 32768,
	mode = "monitor" :: "off" | "monitor",
	master = 0.6,
	squareAssetId = "", -- Upload output/Depth-square-256Hz.wav; enter its Roblox ID.
}

-- Diagnostics ---------------------------------------------------------------
Config.DIAG = {
	enabled = true,
	scanInterval = 10.0,
	maxEvents = 500,
	minSeverity = "info",
	categories = { "error", "bug", "vulnerability", "unfinished" },
	stallMs = 250,
}

-- Input ---------------------------------------------------------------------
Config.INPUT = {
	-- 0=A 1=B 2=Select 3=Start 4=Right 5=Left 6=Up 7=Down 8=R 9=L
	defaultKeyboard = {
		[Enum.KeyCode.Z] = 0,
		[Enum.KeyCode.X] = 1,
		[Enum.KeyCode.RightShift] = 2,
		[Enum.KeyCode.Return] = 3,
		[Enum.KeyCode.Right] = 4,
		[Enum.KeyCode.Left] = 5,
		[Enum.KeyCode.Up] = 6,
		[Enum.KeyCode.Down] = 7,
		[Enum.KeyCode.C] = 8,
		[Enum.KeyCode.A] = 9,
	},
	defaultGamepad = {
		[Enum.KeyCode.ButtonA] = 0,
		[Enum.KeyCode.ButtonB] = 1,
		[Enum.KeyCode.ButtonSelect] = 2,
		[Enum.KeyCode.ButtonStart] = 3,
		[Enum.KeyCode.DPadRight] = 4,
		[Enum.KeyCode.DPadLeft] = 5,
		[Enum.KeyCode.DPadUp] = 6,
		[Enum.KeyCode.DPadDown] = 7,
		[Enum.KeyCode.ButtonR1] = 8,
		[Enum.KeyCode.ButtonL1] = 9,
	},
	stickDeadzone = 0.25,
}

return Config
