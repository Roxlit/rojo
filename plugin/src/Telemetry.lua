--[[
	Telemetry: Real-time property tracking for debugging.

	The AI registers trackers via MCP → launcher HTTP. This module polls the
	launcher for tracker definitions and resolves paths lazily using FindFirstChild.
	Instances don't need to exist when trackers are registered — they activate
	automatically when found (e.g. during playtest).

	Data is sent to the launcher via POST /telemetry every flush cycle.
	Only changes above a significance threshold are recorded to avoid noise.

	License: MPL-2.0
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local LAUNCHER_URL = "http://127.0.0.1:19556"
local FLUSH_INTERVAL = 1 -- seconds between flushes to launcher
local POLL_INTERVAL = 3 -- seconds between polling launcher for tracker config
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
	self._buffer = {} -- array of telemetry lines
	self._lastValues = {} -- [path][property] = last recorded value
	self._trackers = {} -- array of { path, properties, group, enabled } from launcher
	self._resolved = {} -- [path] = Instance or false (cache)
	self._startTime = 0
	return self
end

-- Resolve a dot-separated path using FindFirstChild (handles spaces in names)
local function resolvePath(pathStr)
	local parts = string.split(pathStr, ".")
	if #parts == 0 then
		return nil
	end

	-- Start from game, skip "game" if present
	local current = game
	local startIdx = 1
	if parts[1] == "game" then
		startIdx = 2
	end

	for i = startIdx, #parts do
		local child = current:FindFirstChild(parts[i])
		if not child then
			return nil
		end
		current = child
	end

	return current
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

local function getContext()
	if RunService:IsClient() then
		return "CLIENT"
	else
		return "SERVER"
	end
end

-- Poll the launcher for tracker definitions
function Telemetry:_pollTrackers()
	local ok, result = pcall(function()
		return HttpService:GetAsync(LAUNCHER_URL .. "/telemetry/trackers")
	end)

	if ok and result then
		local parseOk, trackers = pcall(function()
			return HttpService:JSONDecode(result)
		end)
		if parseOk and type(trackers) == "table" then
			-- Check if config changed (simple length + path comparison)
			local changed = #trackers ~= #self._trackers
			if not changed then
				for i, t in trackers do
					local old = self._trackers[i]
					if not old or old.path ~= t.path or old.properties ~= t.properties or old.enabled ~= t.enabled then
						changed = true
						break
					end
				end
			end

			if changed then
				self._trackers = trackers
				-- Clear resolve cache so paths get re-resolved
				self._resolved = {}
			end
		end
	end
end

-- Sample all tracked instances
function Telemetry:_sample()
	if #self._trackers == 0 then
		return
	end

	local elapsed = os.clock() - self._startTime
	local context = getContext()

	for _, tracker in self._trackers do
		-- Skip disabled trackers
		if tracker.enabled == false then
			continue
		end

		local path = tracker.path
		local propList = tracker.properties

		-- Resolve path (with cache)
		local inst = self._resolved[path]
		if inst == nil then
			-- Not cached yet — try to resolve
			inst = resolvePath(path)
			self._resolved[path] = inst or false -- cache nil as false
		end

		-- Skip unresolved or destroyed instances
		if not inst or inst == false then
			continue
		end
		if not inst.Parent then
			-- Instance was destroyed, clear cache
			self._resolved[path] = nil
			self._lastValues[path] = nil
			continue
		end

		if not self._lastValues[path] then
			self._lastValues[path] = {}
		end

		local parts = {}
		local hasChange = false

		for propName in string.gmatch(propList, "[^,]+") do
			propName = propName:match("^%s*(.-)%s*$") -- trim
			local ok, value = pcall(function()
				return (inst :: any)[propName]
			end)

			if ok then
				local lastVal = self._lastValues[path][propName]
				if significantChange(lastVal, value) then
					hasChange = true
					self._lastValues[path][propName] = value
				end
				table.insert(parts, propName .. ": " .. formatValue(value))
			end
		end

		if hasChange then
			local group = tracker.group or ""
			local prefix = if group ~= "" and group ~= "default" then "[" .. group .. "] " else ""
			local line = string.format(
				"[T+%.3f] [%s] %s%s %s",
				elapsed,
				context,
				prefix,
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
	self._trackers = {}
	self._resolved = {}

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

	-- Poll + flush loop
	task.spawn(function()
		local pollCounter = 0
		local pollEvery = math.ceil(POLL_INTERVAL / FLUSH_INTERVAL)
		while self._running do
			task.wait(FLUSH_INTERVAL)
			pollCounter += 1

			-- Poll for tracker config every POLL_INTERVAL seconds
			if pollCounter % pollEvery == 0 then
				self:_pollTrackers()
				-- Clear resolve cache periodically so new instances get found
				self._resolved = {}
			end

			self:_flush()
		end
	end)
end

-- Stop telemetry collection
function Telemetry:stop()
	self._running = false
	if self._heartbeatConn then
		self._heartbeatConn:Disconnect()
		self._heartbeatConn = nil
	end
	-- Final flush
	self:_flush()
end

return Telemetry
