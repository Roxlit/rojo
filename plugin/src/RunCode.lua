--[[
	RunCode: Enables AI tools (MCP) to execute Luau code in Studio.

	Since plugins can't open HTTP servers, this uses a polling pattern:
	1. MCP sends code to the Roxlit launcher (POST /mcp/run-code)
	2. Launcher queues the command
	3. This module polls GET /mcp/pending-command every 200ms
	4. Executes the code, sends result back via POST /mcp/command-result

	License: MPL-2.0 (new code for Roxlit, extends Rojo plugin)
]]

local HttpService = game:GetService("HttpService")

local LAUNCHER_URL = "http://127.0.0.1:19556"
local POLL_INTERVAL = 0.2 -- 200ms

local RunCode = {}
RunCode.__index = RunCode

function RunCode.new()
	local self = setmetatable({}, RunCode)
	self._polling = false
	return self
end

-- Start polling for pending MCP commands.
function RunCode:start()
	if self._polling then
		return
	end

	self._polling = true

	task.spawn(function()
		while self._polling do
			self:_pollOnce()
			task.wait(POLL_INTERVAL)
		end
	end)
end

-- Stop polling.
function RunCode:stop()
	self._polling = false
end

function RunCode:_pollOnce()
	-- Check for pending command
	local success, response = pcall(function()
		return HttpService:GetAsync(LAUNCHER_URL .. "/mcp/pending-command")
	end)

	if not success or not response or response == "" then
		return
	end

	local ok, command = pcall(function()
		return HttpService:JSONDecode(response)
	end)

	if not ok or type(command) ~= "table" or not command.code then
		return
	end

	-- Execute the code
	local execSuccess, execResult = self:_execute(command.code)

	-- Send result back
	pcall(function()
		HttpService:PostAsync(
			LAUNCHER_URL .. "/mcp/command-result",
			HttpService:JSONEncode({
				id = command.id,
				success = execSuccess,
				result = execResult,
			}),
			Enum.HttpContentType.ApplicationJson
		)
	end)
end

function RunCode:_execute(code: string): (boolean, string)
	-- Capture print output
	local output = {}
	local originalPrint = print
	local originalWarn = warn

	-- Override print/warn to capture output
	local env = setmetatable({
		print = function(...)
			local args = table.pack(...)
			local parts = {}
			for i = 1, args.n do
				table.insert(parts, tostring(args[i]))
			end
			local line = table.concat(parts, "\t")
			table.insert(output, line)
			originalPrint(...)
		end,
		warn = function(...)
			local args = table.pack(...)
			local parts = {}
			for i = 1, args.n do
				table.insert(parts, tostring(args[i]))
			end
			local line = "[warn] " .. table.concat(parts, "\t")
			table.insert(output, line)
			originalWarn(...)
		end,
		game = game,
		workspace = workspace,
		script = script,
	}, { __index = getfenv(0) })

	local fn, compileErr = loadstring(code)
	if not fn then
		return false, "Compile error: " .. tostring(compileErr)
	end

	setfenv(fn, env)

	local success, result = pcall(fn)

	local captured = table.concat(output, "\n")

	if not success then
		if #captured > 0 then
			return false, captured .. "\nError: " .. tostring(result)
		end
		return false, "Runtime error: " .. tostring(result)
	end

	-- Return captured output + return value
	if result ~= nil then
		if #captured > 0 then
			return true, captured .. "\n" .. tostring(result)
		end
		return true, tostring(result)
	end

	if #captured > 0 then
		return true, captured
	end

	return true, "OK (no output)"
end

return RunCode
