--[[
	Telemetry: Tracks properties of instances registered via _G._roxlit_telemetry.

	AI tools call `telemetry_track` which runs code like:
	  _G._roxlit_telemetry:track(workspace.MyCar.Chassis, "CFrame,AssemblyLinearVelocity")

	Data is sent to the launcher via POST /telemetry every flush cycle.
	Only changes above a significance threshold are recorded to avoid noise.

	License: MPL-2.0
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local LAUNCHER_URL = "http://127.0.0.1:19556"
local FLUSH_INTERVAL = 1 -- seconds between flushes to launcher
local SAMPLE_INTERVAL = 5 -- sample every N heartbeats (~12 samples/sec at 60fps)
local POSITION_THRESHOLD = 0.1 -- studs
local ANGLE_THRESHOLD = 0.5 -- degrees
local SCALAR_THRESHOLD = 0.01

local Telemetry = {}
Telemetry.__index = Telemetry

function Telemetry.new()
	local self = setmetatable({}, Telemetry)
	self._running = false
	self._heartbeatConn = nil
	self._frameCount = 0
	self._buffer = {} -- array of telemetry entries
	self._lastValues = {} -- [instKey][property] = last recorded value
	self._tracked = {} -- array of { instance, properties }
	self._startTime = 0
	return self
end

-- Register an instance for tracking
function Telemetry:track(instance, properties)
	-- Remove existing entry for same instance
	for i, entry in self._tracked do
		if entry.instance == instance then
			table.remove(self._tracked, i)
			break
		end
	end
	table.insert(self._tracked, { instance = instance, properties = properties })
end

-- Unregister an instance from tracking
function Telemetry:untrack(instance)
	for i, entry in self._tracked do
		if entry.instance == instance then
			table.remove(self._tracked, i)
			break
		end
	end
end

-- Format a value for logging (human-readable)
local function formatValue(value)
	if typeof(value) == "CFrame" then
		local pos = value.Position
		local rx, ry, rz = value:ToEulerAnglesYXZ()
		return string.format(
			"%.1f,%.1f,%.1f / %.0f,%.0f,%.0f",
			pos.X, pos.Y, pos.Z,
			math.deg(rx), math.deg(ry), math.deg(rz)
		)
	elseif typeof(value) == "Vector3" then
		return string.format("%.1f,%.1f,%.1f", value.X, value.Y, value.Z)
	elseif typeof(value) == "Vector2" then
		return string.format("%.1f,%.1f", value.X, value.Y)
	elseif type(value) == "number" then
		return string.format("%.2f", value)
	else
		return tostring(value)
	end
end

-- Check if a value changed significantly from the last recorded value
local function significantChange(old, new)
	if old == nil then
		return true
	end

	if typeof(new) == "CFrame" and typeof(old) == "CFrame" then
		local posDelta = (new.Position - old.Position).Magnitude
		if posDelta > POSITION_THRESHOLD then
			return true
		end
		local rx1, ry1, rz1 = old:ToEulerAnglesYXZ()
		local rx2, ry2, rz2 = new:ToEulerAnglesYXZ()
		local angleDelta = math.abs(math.deg(rx2 - rx1)) + math.abs(math.deg(ry2 - ry1)) + math.abs(math.deg(rz2 - rz1))
		return angleDelta > ANGLE_THRESHOLD
	elseif typeof(new) == "Vector3" and typeof(old) == "Vector3" then
		return (new - old).Magnitude > POSITION_THRESHOLD
	elseif type(new) == "number" and type(old) == "number" then
		return math.abs(new - old) > SCALAR_THRESHOLD
	else
		return new ~= old
	end
end

-- Get the context label (client or server)
local function getContext()
	if RunService:IsClient() then
		return "CLIENT"
	else
		return "SERVER"
	end
end

-- Sample all tracked instances
function Telemetry:_sample()
	if #self._tracked == 0 then
		return
	end

	local elapsed = os.clock() - self._startTime
	local context = getContext()

	for _, entry in self._tracked do
		local inst = entry.instance
		local propList = entry.properties

		-- Skip destroyed instances
		if not inst.Parent then
			continue
		end

		local instKey = inst:GetFullName()
		if not self._lastValues[instKey] then
			self._lastValues[instKey] = {}
		end

		local parts = {}
		local hasChange = false

		for propName in string.gmatch(propList, "[^,]+") do
			propName = propName:match("^%s*(.-)%s*$") -- trim
			local ok, value = pcall(function()
				return (inst :: any)[propName]
			end)

			if ok then
				local lastVal = self._lastValues[instKey][propName]
				if significantChange(lastVal, value) then
					hasChange = true
					self._lastValues[instKey][propName] = value
				end
				table.insert(parts, propName .. ": " .. formatValue(value))
			end
		end

		if hasChange then
			local line = string.format(
				"[T+%.3f] [%s] %s %s",
				elapsed,
				context,
				inst.Name,
				table.concat(parts, " | ")
			)
			table.insert(self._buffer, line)
		end
	end
end

-- Flush buffer to launcher
function Telemetry:_flush()
	if #self._buffer == 0 then
		return
	end

	local lines = table.concat(self._buffer, "\n")
	self._buffer = {}

	pcall(function()
		HttpService:PostAsync(
			LAUNCHER_URL .. "/telemetry",
			HttpService:JSONEncode({
				lines = lines,
			}),
			Enum.HttpContentType.ApplicationJson
		)
	end)
end

-- Start telemetry collection
function Telemetry:start()
	if self._running then
		return
	end
	self._running = true
	self._startTime = os.clock()
	self._frameCount = 0
	self._buffer = {}
	self._lastValues = {}
	self._tracked = {}

	-- Expose globally so run_code can register instances
	_G._roxlit_telemetry = self

	-- Heartbeat for sampling
	self._heartbeatConn = RunService.Heartbeat:Connect(function()
		if not self._running then
			return
		end

		self._frameCount += 1
		if self._frameCount % SAMPLE_INTERVAL == 0 then
			self:_sample()
		end
	end)

	-- Flush loop
	task.spawn(function()
		while self._running do
			task.wait(FLUSH_INTERVAL)
			self:_flush()
		end
	end)
end

-- Stop telemetry collection
function Telemetry:stop()
	self._running = false
	_G._roxlit_telemetry = nil
	if self._heartbeatConn then
		self._heartbeatConn:Disconnect()
		self._heartbeatConn = nil
	end
	-- Final flush
	self:_flush()
end

return Telemetry
