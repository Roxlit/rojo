--[[
	LogCapture: Captures all Studio output and sends it to the Roxlit launcher.

	Hooks LogService.MessageOut to capture print(), warn(), and error() output
	from all scripts running in Studio. Batches messages and sends them to the
	launcher's POST /log endpoint every 1.5 seconds.

	License: MPL-2.0 (new code for Roxlit, extends Rojo plugin)
]]

local LogService = game:GetService("LogService")
local HttpService = game:GetService("HttpService")

local LAUNCHER_URL = "http://127.0.0.1:19556"
local FLUSH_INTERVAL = 1.5
local MAX_BATCH_SIZE = 100

local LogCapture = {}
LogCapture.__index = LogCapture

function LogCapture.new(roxlitBridge)
	local self = setmetatable({}, LogCapture)
	self._bridge = roxlitBridge
	self._running = false
	self._connection = nil
	self._buffer = {}
	return self
end

function LogCapture:start()
	if self._running then
		return
	end
	self._running = true

	self._connection = LogService.MessageOut:Connect(function(message, messageType)
		if not self._running then
			return
		end

		local level = "info"
		if messageType == Enum.MessageType.MessageWarning then
			level = "warn"
		elseif messageType == Enum.MessageType.MessageError then
			level = "error"
		end

		table.insert(self._buffer, {
			message = message,
			level = level,
			timestamp = os.clock(),
		})

		if #self._buffer >= MAX_BATCH_SIZE then
			self:_flush()
		end
	end)

	task.spawn(function()
		while self._running do
			task.wait(FLUSH_INTERVAL)
			self:_flush()
		end
	end)
end

function LogCapture:stop()
	self._running = false
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
	self:_flush()
end

function LogCapture:_flush()
	if #self._buffer == 0 then
		return
	end

	local status = self._bridge:getLastStatus()
	if not status or not status.active then
		self._buffer = {}
		return
	end

	local batch = self._buffer
	self._buffer = {}

	pcall(function()
		HttpService:PostAsync(
			LAUNCHER_URL .. "/log",
			HttpService:JSONEncode(batch),
			Enum.HttpContentType.ApplicationJson
		)
	end)
end

return LogCapture
