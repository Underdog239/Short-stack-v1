--!strict
--[[ Shared/Signal.luau -- minimal, allocation-light event emitter.
     Used by the diagnostics bus so subsystems can publish findings without
     depending on Roblox BindableEvents (which are async + slow). ]]

export type Connection = { disconnect: (self: Connection) -> () }

export type Signal = {
	connect: (self: Signal, fn: (...any) -> ()) -> Connection,
	once: (self: Signal, fn: (...any) -> ()) -> Connection,
	fire: (self: Signal, ...any) -> (),
	clear: (self: Signal) -> (),
	size: (self: Signal) -> number,
}

local Signal = {}
Signal.__index = Signal

function Signal.new(): Signal
	return setmetatable({ _handlers = {} }, Signal) :: any
end

function Signal:connect(fn: (...any) -> ()): Connection
	local h = { fn = fn, active = true }
	table.insert(self._handlers, h)
	return {
		disconnect = function()
			if h.active then
				h.active = false
				local idx = table.find(self._handlers, h)
				if idx then table.remove(self._handlers, idx) end
			end
		end,
	}
end

function Signal:once(fn: (...any) -> ()): Connection
	local conn
	conn = self:connect(function(...)
		conn.disconnect()
		fn(...)
	end)
	return conn
end

function Signal:fire(...): ()
	-- iterate over a copy so handlers may disconnect during dispatch
	local handlers = table.clone(self._handlers)
	for _, h in handlers do
		if h.active then
			-- pcall keeps one bad handler from killing the emulator loop
			local ok, err = pcall(h.fn, ...)
			if not ok then
				task.spawn(error, `[Signal] handler errored: {tostring(err)}`, 2)
			end
		end
	end
end

function Signal:clear(): ()
	for _, h in self._handlers do h.active = false end
	table.clear(self._handlers)
end

function Signal:size(): number
	return #self._handlers
end

return Signal
