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
	self._wasRunning = false
	self._playtestCount = 0
	self._buffer = {}
	self._flushErrors = 0
	return self
end

function LogCapture:start()
	if self._running then
		return
	end
	-- Only run in edit mode — LogService.MessageOut captures ALL contexts (server+client)
	if not RunService:IsEdit() then
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

	-- Detect playtest start/end and insert markers (poll-based, Running is not a property)
	task.spawn(function()
		while self._running do
			local isRunning = RunService:IsRunning()
			if isRunning and not self._wasRunning then
				self._wasRunning = true
				self._playtestCount += 1
				table.insert(self._buffer, {
					message = string.format("PLAYTEST #%d START", self._playtestCount),
					level = "marker",
					timestamp = os.clock(),
				})
				self:_flush()
			elseif not isRunning and self._wasRunning then
				self._wasRunning = false
				table.insert(self._buffer, {
					message = string.format("PLAYTEST #%d END", self._playtestCount),
					level = "marker",
					timestamp = os.clock(),
				})
				self:_flush()
			end
			task.wait(0.5)
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
	self:_flush()
end

function LogCapture:_flush()
	if #self._buffer == 0 then
		return
	end

	local batch = self._buffer
	self._buffer = {}

	local ok, err = pcall(function()
		HttpService:PostAsync(
			LAUNCHER_URL .. "/log",
			HttpService:JSONEncode(batch),
			Enum.HttpContentType.ApplicationJson
		)
	end)
	if not ok then
		self._flushErrors += 1
		if self._flushErrors <= 3 then
			warn("[LogCapture] flush failed:", err)
		end
	else
		if self._flushErrors > 0 then
			self._flushErrors = 0
		end
	end
end

return LogCapture
