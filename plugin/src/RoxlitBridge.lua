--[[
	RoxlitBridge: Detects the Roxlit launcher and provides launcher status.

	The Roxlit launcher runs an HTTP server on 127.0.0.1:19556.
	This module polls /status to detect if the launcher is active and
	retrieve project configuration (placeId, projectPath, rojoPort).

	License: MPL-2.0 (new code for Roxlit, extends Rojo plugin)
]]

local HttpService = game:GetService("HttpService")

local LAUNCHER_URL = "http://127.0.0.1:19556"
local POLL_INTERVAL = 5
local REQUEST_TIMEOUT = 2

local RoxlitBridge = {}
RoxlitBridge.__index = RoxlitBridge

export type LauncherStatus = {
	active: boolean,
	projectPath: string?,
	placeId: number?,
	universeId: number?,
	rojoPort: number?,
}

function RoxlitBridge.new()
	local self = setmetatable({}, RoxlitBridge)
	self._polling = false
	self._lastStatus = nil :: LauncherStatus?
	self._onStatusChange = nil :: ((LauncherStatus?) -> ())?
	return self
end

-- Check launcher status once. Returns nil if launcher is not reachable.
function RoxlitBridge:checkStatus(): LauncherStatus?
	local success, result = pcall(function()
		return HttpService:GetAsync(LAUNCHER_URL .. "/status")
	end)

	if not success then
		return nil
	end

	local ok, data = pcall(function()
		return HttpService:JSONDecode(result)
	end)

	if not ok or type(data) ~= "table" then
		return nil
	end

	return {
		active = data.active == true,
		projectPath = data.projectPath,
		placeId = data.linkedPlaceId,
		universeId = data.linkedUniverseId,
		rojoPort = data.rojoPort,
	}
end

-- Start polling for launcher status changes.
function RoxlitBridge:startPolling(onStatusChange: (LauncherStatus?) -> ())
	if self._polling then
		return
	end

	self._polling = true
	self._onStatusChange = onStatusChange

	task.spawn(function()
		while self._polling do
			local status = self:checkStatus()
			local wasActive = self._lastStatus and self._lastStatus.active
			local isActive = status and status.active

			-- Notify on state change (nil→active, active→nil, placeId change, etc.)
			if wasActive ~= isActive or self._lastStatus == nil then
				self._lastStatus = status
				if self._onStatusChange then
					self._onStatusChange(status)
				end
			end

			self._lastStatus = status
			task.wait(POLL_INTERVAL)
		end
	end)
end

-- Stop polling.
function RoxlitBridge:stopPolling()
	self._polling = false
	self._onStatusChange = nil
end

-- Get the last known status without making a request.
function RoxlitBridge:getLastStatus(): LauncherStatus?
	return self._lastStatus
end

-- Check if a placeId matches the launcher's configured project.
-- Returns: "match", "no_link" (first time), or "mismatch"
function RoxlitBridge:validatePlaceId(studioPlaceId: number): string
	local status = self._lastStatus
	if not status or not status.active then
		return "match" -- No launcher, allow anything
	end
	if not status.placeId or status.placeId == 0 then
		return "no_link" -- No placeId configured yet (first time)
	end
	if status.placeId == studioPlaceId then
		return "match"
	end
	return "mismatch"
end

-- Send placeId to launcher for linking (first time connecting a place).
function RoxlitBridge:linkPlace(placeId: number, universeId: number?, placeName: string?)
	pcall(function()
		HttpService:PostAsync(
			LAUNCHER_URL .. "/link-place",
			HttpService:JSONEncode({
				placeId = placeId,
				universeId = universeId,
				placeName = placeName,
			}),
			Enum.HttpContentType.ApplicationJson
		)
	end)
end

return RoxlitBridge
