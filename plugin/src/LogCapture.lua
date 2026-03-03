--[[
	LogCapture: Captures all Studio output and sends it to the Roxlit launcher.

	Hooks LogService.MessageOut to capture print(), warn(), and error() output
	from all scripts running in Studio. Batches messages and sends them to the
	launcher's POST /log endpoint every 1.5 seconds.

	Detects playtest start via RunService to rotate output logs per play session.

	License: MPL-2.0 (new code for Roxlit, extends Rojo plugin)
]]

local LogService = game:GetService("LogService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local LAUNCHER_URL = "http://127.0.0.1:19556"
local FLUSH_INTERVAL = 1.5
local MAX_BATCH_SIZE = 100

local LogCapture = {}
LogCapture.__index = LogCapture

function LogCapture.new()
	local self = setmetatable({}, LogCapture)
	self._running = false
	self._logConnection = nil
	self._runConnection = nil
	self._buffer = {}
	return self
end

function LogCapture:start()
	if self._running then
		return
	end
	self._running = true

	self._logConnection = LogService.MessageOut:Connect(function(message, messageType)
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

	-- Detect playtest start to rotate output.log
	self._runConnection = RunService:GetPropertyChangedSignal("Running"):Connect(function()
		if RunService:IsRunning() then
			-- Flush pending logs before rotation
			self:_flush()
			pcall(function()
				HttpService:PostAsync(
					LAUNCHER_URL .. "/playtest-start",
					"{}",
					Enum.HttpContentType.ApplicationJson
				)
			end)
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
	if self._logConnection then
		self._logConnection:Disconnect()
		self._logConnection = nil
	end
	if self._runConnection then
		self._runConnection:Disconnect()
		self._runConnection = nil
	end
	self:_flush()
end

function LogCapture:_flush()
	if #self._buffer == 0 then
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
