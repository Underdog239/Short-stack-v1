--!strict
--[[ Shared/Logger.luau -- leveled logger that mirrors into Diagnostics when
     available. Every subsystem logs through this so the catcher sees the full
     story, not just crashes. ]]

local Config = require(script.Parent.Config)

local Logger = {}

local LEVELS = { trace = 10, debug = 20, info = 30, warn = 40, error = 50, fatal = 60 }
local ORDER = { "trace", "debug", "info", "warn", "error", "fatal" }

Logger.level = LEVELS.info
Logger._sink = nil :: ((level: string, msg: string, meta: any?) -> ())?
Logger._history = {} :: { { level: string, msg: string, ts: number } }
local MAX_HISTORY = 200

function Logger.setLevel(name: string)
	Logger.level = LEVELS[name] or LEVELS.info
end

--- Attach a sink (normally Diagnostics.capture). Safe to call repeatedly.
function Logger.attachSink(sink: (level: string, msg: string, meta: any?) -> ())
	Logger._sink = sink
end

local function emit(levelName: string, ...)
	if LEVELS[levelName] < Logger.level then return end
	local parts = table.create(select("#", ...))
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	local msg = table.concat(parts, " ")
	local line = `[GBA/{string.upper(levelName)}] {msg}`
	if levelName == "error" or levelName == "fatal" then
		warn(line)
	elseif levelName == "warn" then
		warn(line)
	else
		print(line)
	end
	local rec = { level = levelName, msg = msg, ts = os.clock() }
	table.insert(Logger._history, rec)
	if #Logger._history > MAX_HISTORY then table.remove(Logger._history, 1) end
	if Logger._sink then
		pcall(Logger._sink, levelName, msg, nil)
	end
end

function Logger.trace(...) emit("trace", ...) end
function Logger.debug(...) emit("debug", ...) end
function Logger.info(...) emit("info", ...) end
function Logger.warn(...) emit("warn", ...) end
function Logger.error(...) emit("error", ...) end
function Logger.fatal(...) emit("fatal", ...) end

function Logger.history() return Logger._history end

Logger.VERSION = Config.VERSION
return Logger
