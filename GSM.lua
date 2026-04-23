local gsm = {}

local runService = game:GetService("RunService")

-- main config for easy changes later
local config = {
	debugMode = false,
	defaultTick = 1,
	version = "1.0.2"
}

gsm.activeTimers = {
	rounds = {},
	rewards = {},
	standard = {}
}

-- timer class handles creating and managing a single timer
local Timer = {}
Timer.__index = Timer

-- create a new timer with name, time and category
function Timer.new(name, duration, category)
	local self = setmetatable({}, Timer)

	self.name = name or "NewTimer"
	self.category = category or "standard"
	
	-- make sure duration is a valid number
	local finalDuration = tonumber(duration) or 60
	self.duration = finalDuration
	self.timeLeft = finalDuration

	-- timer states
	self.running = false
	self.paused = false
	self.destroyed = false
	
	-- events for UI and other scripts
	self.finished = Instance.new("BindableEvent")
	self.tick = Instance.new("BindableEvent")
	self.stateChanged = Instance.new("BindableEvent")

	-- debug message when enabled
	if config.debugMode then
		print(string.format("[gsm-debug] timer created: %s in %s (%ds)", self.name, self.category, self.duration))
	end
	return self
end

-- core loop runs the countdown
function Timer:_startLoop()
	task.spawn(function()
		while not self.destroyed do
			-- stop conditions
			if not self.running then break end
			if self.timeLeft <= 0 then break end

			-- wait per tick
			local deltaTime = task.wait(config.defaultTick)

			-- handle pause state
			if self.paused then
				repeat 
					task.wait(0.1) 
				until not self.paused or not self.running or self.destroyed
				
				if not self.running or self.destroyed then break end
			end

			-- decrease time
			self.timeLeft = self.timeLeft - deltaTime

			-- prevent negative values
			if self.timeLeft < 0 then
				self.timeLeft = 0
			end

			-- send update to UI
			self.tick:Fire(self.timeLeft)

			-- finish check
			if self.timeLeft <= 0 then
				self:_onFinish()
				break
			end
		end
	end)
end

-- public controls (start, pause, stop etc)
-- start the timer
function Timer:start()
	if self.running or self.destroyed then return end
	
	self.running = true
	self.paused = false
	self:_startLoop()
	
	self.stateChanged:Fire("started")
end

-- pause the timer
function Timer:pause()
	if not self.running or self.destroyed then return end
	self.paused = true
	self.stateChanged:Fire("paused")
end

-- resume paused timer
function Timer:resume()
	if not self.running or self.destroyed then return end
	self.paused = false
	self.stateChanged:Fire("resumed")
end

-- stop the timer completely
function Timer:stop()
	self.running = false
	self.stateChanged:Fire("stopped")
	
	if config.debugMode then
		print("[gsm] timer stopped:", self.name)
	end
end

-- reset timer time
function Timer:reset(customTime)
	self.timeLeft = tonumber(customTime) or self.duration
	self.tick:Fire(self.timeLeft)
	
	if config.debugMode then
		print("[gsm] timer reset:", self.name)
	end
end

-- add or remove time
function Timer:adjustTime(seconds)
	if type(seconds) ~= "number" then return end
	
	self.timeLeft = math.max(0, self.timeLeft + seconds)
	self.tick:Fire(self.timeLeft)
end

-- called when timer finishes
function Timer:_onFinish()
	self.running = false
	self.finished:Fire()
	
	if config.debugMode then
		print("[gsm] timer finished:", self.name)
	end
end

-- destroy timer and clean memory
function Timer:destroy()
	if self.destroyed then return end
	self.destroyed = true
	
	self:stop()
	
	self.finished:Destroy()
	self.tick:Destroy()
	self.stateChanged:Destroy()
	
	if gsm.activeTimers[self.category] then
		gsm.activeTimers[self.category][self.name] = nil
	end
	
	setmetatable(self, nil)
end

-- formatting helpers convert seconds into readable text
-- mins:secs format
function gsm:formatMS(seconds)
	seconds = tonumber(seconds) or 0
	local mins = math.floor(seconds / 60)
	local secs = math.floor(seconds % 60)
	return string.format("%02d:%02d", mins, secs)
end

-- hours:mins:secs format
function gsm:formatHMS(seconds)
	seconds = tonumber(seconds) or 0
	local hrs = math.floor(seconds / 3600)
	local mins = math.floor((seconds % 3600) / 60)
	local secs = math.floor(seconds % 60)
	return string.format("%02d:%02d:%02d", hrs, mins, secs)
end

-- fancy format like days hours mins secs
function gsm:formatFancy(seconds)
	seconds = math.max(0, tonumber(seconds) or 0)
	
	if seconds <= 0 then return "Ready" end
	
	local days = math.floor(seconds / 86400)
	local hours = math.floor((seconds % 86400) / 3600)
	local mins = math.floor((seconds % 3600) / 60)
	local secs = math.floor(seconds % 60)
	
	local result = ""
	if days > 0 then result ..= days .. "d " end
	if hours > 0 then result ..= hours .. "h " end
	if mins > 0 then result ..= mins .. "m " end
	if secs > 0 or result == "" then result ..= secs .. "s" end
	
	return result
end

-- system functions (create, get, cleanup)
-- create a new timer
function gsm:createTimer(category, timerName, duration)
	if not self.activeTimers[category] then
		self.activeTimers[category] = {}
	end
	
	-- remove old timer if exists
	if self.activeTimers[category][timerName] then
		self.activeTimers[category][timerName]:destroy()
	end
	
	local newT = Timer.new(timerName, duration, category)
	self.activeTimers[category][timerName] = newT
	
	return newT
end

-- start a round timer
function gsm:startRound(duration, onFinishCallback)
	local roundTimer = self:createTimer("rounds", "currentRound", duration)
	
	if type(onFinishCallback) == "function" then
		roundTimer.finished.Event:Connect(onFinishCallback)
	end
	
	roundTimer:start()
	return roundTimer
end

-- get a specific timer
function gsm:getTimer(category, name)
	if self.activeTimers[category] then
		return self.activeTimers[category][name]
	end
	return nil
end

-- clear all timers in a category
function gsm:clearCategory(category)
	if not self.activeTimers[category] then return end
	
	for _, timerObj in pairs(self.activeTimers[category]) do
		timerObj:destroy()
	end
	
	self.activeTimers[category] = {}
end

-- shutdown whole system
function gsm:shutdown()
	for catName in pairs(self.activeTimers) do
		self:clearCategory(catName)
	end

	if config.debugMode then 
		print("[gsm] system shutdown complete") 
	end
end

return gsm

--example serverScript
--[[
local GSM = require(path.to.module)
local roundTimer = GSM:createTimer("rounds", "MatchTimer", 60)

roundTimer.tick.Event:Connect(function(timeLeft)
    print("Time remaining: " .. GSM:formatMS(timeLeft))
end)

roundTimer:start()]]

--example localScript
--[[
local GSM = require(path.to.module)

--ur plauerGUI
local playerGui = game.Players.LocalPlayer:WaitForChild("PlayerGui")
--ur timerText
local timerLabel = playerGui:WaitForChild("MainGui"):WaitForChild("TimerLabel") 

local roundTimer = GSM:createTimer("rounds", "MatchTimer", 60)

roundTimer.tick.Event:Connect(function(timeLeft)
 -- We'll use the formatting function in the module to display it as 01:00
timerLabel.Text = GSM:formatMS(timeLeft)
end)

--end timerEventroundTimer.finished.Event:Connect(function()
    timerLabel.Text = "Time's up"
    print("The timer has run out for the player")
end)

--startTimer
roundTimer:start()]]
