local projectileHandler = {}
projectileHandler.__index = projectileHandler

local runService = game:GetService("RunService")
local debris = game:GetService("Debris")

-- types for clarity and strict mode
type weaponType = "Pistol" | "SMG" | "Sniper"

type projectileData = {
	bulletType: weaponType,
	muzzleRef: Attachment,
	mousePos: Vector3,
	player: Player
}

-- custom signal class handles internal events
local internalSignal = {}
internalSignal.__index = internalSignal

function internalSignal.new()
	local self = setmetatable({}, internalSignal)
	self._activeConnections = {}
	return self
end

function internalSignal:connect(callback)
	local connection = {callback = callback, isActive = true}
	table.insert(self._activeConnections, connection)
	return {disconnect = function() connection.isActive = false end}
end

function internalSignal:fire(...)
	for i = #self._activeConnections, 1, -1 do
		local conn = self._activeConnections[i]
		if conn.isActive then
			task.spawn(conn.callback, ...)
		else
			table.remove(self._activeConnections, i)
		end
	end
end

function internalSignal:destroy()
	self._activeConnections = {}
end

-- projectile class manages movement and collision for a single bullet
local bulletObj = {}
bulletObj.__index = bulletObj

-- create new projectile instance with specific weapon properties
function bulletObj.new(data: projectileData)
	local self = setmetatable({}, bulletObj)

	-- core settings
	self.user = data.player
	self.kind = data.bulletType
	self.spawnPos = data.muzzleRef.WorldPosition
	self.currentPos = self.spawnPos 
	self.creationTime = os.clock()
	self.isDead = false

	-- calculate trajectory direction
	local dirVector = (data.mousePos - self.spawnPos)
	local lookDir = dirVector.Unit

	-- safety check for zero magnitude
	if dirVector.Magnitude < 0.001 then
		lookDir = Vector3.new(0, 1, 0)
	end

	-- set physical attributes based on type
	if self.kind == "Sniper" then
		self.velocityValue = 550
		self.dropForce = Vector3.new(0, -8, 0)
		self.pierceCount = 3
		self.partSize = Vector3.new(0.1, 0.1, 5)
		self.mainColor = Color3.fromRGB(255, 40, 40)
	elseif self.kind == "SMG" then
		self.velocityValue = 220
		self.dropForce = Vector3.new(0, -45, 0)
		self.pierceCount = 0
		self.partSize = Vector3.new(0.1, 0.1, 1.8)
		self.mainColor = Color3.fromRGB(255, 255, 255)
	else
		self.velocityValue = 160
		self.dropForce = Vector3.new(0, -30, 0)
		self.pierceCount = 0
		self.partSize = Vector3.new(0.1, 0.1, 1.2)
		self.mainColor = Color3.fromRGB(255, 210, 0)
	end

	self.currentVelocity = lookDir * self.velocityValue
	self.onHit = internalSignal.new()

	-- validate shot before rendering
	local canSpawn = self:_runSecurityChecks(data.muzzleRef)

	if canSpawn then
		self:_buildVisuals(lookDir)
	else
		self:remove()
	end

	return self
end

-- prevent firing through walls or exploit distances
function bulletObj:_runSecurityChecks(muzzle: Attachment) : boolean
	local char = self.user.Character
	if not char then return false end

	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart
	if not root then return false end

	-- max distance check between player and gun muzzle
	local gap = (muzzle.WorldPosition - root.Position).Magnitude
	if gap > 18 then return false end

	-- raycast to ensure player isn't clipping through objects
	local wallParams = RaycastParams.new()
	wallParams.FilterType = Enum.RaycastFilterType.Exclude
	wallParams.FilterDescendantsInstances = {char}

	local hitWall = workspace:Raycast(root.Position, (muzzle.WorldPosition - root.Position), wallParams)

	if hitWall then
		return false
	end

	return true
end

-- generate projectile visual and align before parenting
function bulletObj:_buildVisuals(direction: Vector3)
	local bulletModel = Instance.new("Part")
	bulletModel.Size = self.partSize
	bulletModel.Color = self.mainColor
	bulletModel.Material = Enum.Material.Neon
	bulletModel.Anchored = true
	bulletModel.CanCollide = false
	bulletModel.CanQuery = false
	bulletModel.CastShadow = false

	-- instant cframe placement to prevent origin flicker
	bulletModel.CFrame = CFrame.new(self.currentPos, self.currentPos + direction)
	bulletModel.Parent = workspace

	-- visual attachments and trail
	local startAtt = Instance.new("Attachment", bulletModel)
	startAtt.Position = Vector3.new(0, self.partSize.Y/2, 0)
	local endAtt = Instance.new("Attachment", bulletModel)
	endAtt.Position = Vector3.new(0, -self.partSize.Y/2, 0)

	local tracer = Instance.new("Trail", bulletModel)
	tracer.Attachment0 = startAtt
	tracer.Attachment1 = endAtt
	tracer.Color = ColorSequence.new(self.mainColor)
	tracer.Transparency = NumberSequence.new(0, 1)
	tracer.Lifetime = 0.08

	self.visualPart = bulletModel
end

-- physics step handles motion and collision detection
function bulletObj:update(dt: number)
	if self.isDead then return end
	if os.clock() - self.creationTime > 3.5 then self:remove() return end

	local oldPos = self.currentPos
	local nextVel = self.currentVelocity + (self.dropForce * dt)
	local moveAmount = (self.currentVelocity + nextVel) * 0.5 * dt

	-- update position with raycast for high speed collision
	local castParams = RaycastParams.new()
	castParams.FilterType = Enum.RaycastFilterType.Exclude
	castParams.FilterDescendantsInstances = {self.visualPart, self.user.Character}

	local hitResult = workspace:Raycast(oldPos, moveAmount, castParams)

	if hitResult then
		self:_onCollision(hitResult)
	else
		self.currentPos = self.currentPos + moveAmount
		self.currentVelocity = nextVel
	end

	-- update part cframe to follow logical position
	if self.visualPart then
		self.visualPart.CFrame = CFrame.new(self.currentPos, self.currentPos + self.currentVelocity)
	end
end

-- handles impact logic and specialized penetration
function bulletObj:_onCollision(result: RaycastResult)
	local partHit = result.Instance
	local modelHit = partHit:FindFirstAncestorOfClass("Model")
	local targetHuman = modelHit and modelHit:FindFirstChildOfClass("Humanoid")

	-- apply damage if humanoid exists
	if targetHuman and targetHuman.Health > 0 then
		local damageTable = {
			Sniper = 80,
			SMG = 10,
			Pistol = 25
		}

		local finalDmg = damageTable[self.kind] or 20
		targetHuman:TakeDamage(finalDmg)
	end

	-- trigger hit event for external systems
	self.onHit:fire(partHit, result.Position, targetHuman)

	-- sniper specific penetration through non-humanoid objects
	if self.kind == "Sniper" and self.pierceCount > 0 then
		if not targetHuman then
			self.pierceCount = self.pierceCount - 1
			self.currentPos = result.Position + (self.currentVelocity.Unit * 0.6)
			return
		end
	end

	-- visual effect
	self:_spawnImpactVFX(result.Position)

	-- destroy projectile
	self:remove()
end

-- visual particles on collision
function bulletObj:_spawnImpactVFX(pos: Vector3)
	local vfxAnchor = Instance.new("Part")
	vfxAnchor.Size = Vector3.new(0.05, 0.05, 0.05)
	vfxAnchor.Transparency = 1
	vfxAnchor.Anchored = true
	vfxAnchor.Position = pos
	vfxAnchor.CanCollide = false
	vfxAnchor.Parent = workspace

	local sparks = Instance.new("ParticleEmitter", vfxAnchor)
	sparks.Color = ColorSequence.new(self.mainColor)
	sparks.Size = NumberSequence.new(0.25, 0)
	sparks.Lifetime = NumberRange.new(0.15, 0.35)
	sparks.Speed = NumberRange.new(6, 12)
	sparks.Rate = 500
	sparks:emit(12)

	debris:AddItem(vfxAnchor, 0.6)
end

-- clean up projectile and signals
function bulletObj:remove()
	if self.isDead then return end
	self.isDead = true

	if self.visualPart then 
		self.visualPart:Destroy() 
	end

	self.onHit:destroy()
	setmetatable(self, nil)
end

-- service functions to manage multiple projectiles
local activeBullets = {}

-- fire pistol bullet
function projectileHandler.firePistol(muzzle, target, owner)
	local b = bulletObj.new({bulletType = "Pistol", muzzleRef = muzzle, mousePos = target, player = owner})
	if b and not b.isDead then table.insert(activeBullets, b) end
end

-- fire smg bullet
function projectileHandler.fireSMG(muzzle, target, owner)
	local b = bulletObj.new({bulletType = "SMG", muzzleRef = muzzle, mousePos = target, player = owner})
	if b and not b.isDead then table.insert(activeBullets, b) end
end

-- fire sniper bullet
function projectileHandler.fireSniper(muzzle, target, owner)
	local b = bulletObj.new({bulletType = "Sniper", muzzleRef = muzzle, mousePos = target, player = owner})
	if b and not b.isDead then table.insert(activeBullets, b) end
end

-- core update loop runs every frame
runService.Heartbeat:Connect(function(dt)
	for i = #activeBullets, 1, -1 do
		local b = activeBullets[i]
		if not b or b.isDead then
			table.remove(activeBullets, i)
		else
			b:update(dt)
		end
	end
end)

return projectileHandler

--how to use the library down there

-- localScript inside the tool that handler for weapons
--[[(localScript)
local weaponTool = script.Parent
local clientPlayer = game.Players.LocalPlayer
local runService = game:GetService("RunService")

-- this event must exist inside the tool
local shootEvent = weaponTool:WaitForChild("ShootEvent") 

-- setup weapon specs
local fireRate = 0.5 -- (put here the weapon fire rate)
local lastShotTime = 0

local function attemptFire()
	if os.clock() - lastShotTime < fireRate then return end
	lastShotTime = os.clock()

	local mouse = clientPlayer:GetMouse()
	local target = mouse.Hit.Position

	-- send the signal to the server
	shootEvent:FireServer(target)
end

-- trigger the fire function
weaponTool.Activated:Connect(function()
	attemptFire()
end)]]

--[[(ServerScript)
-- server-side handler that communicates with the module
local weaponTool = script.Parent
local storage = game:GetService("ReplicatedStorage")

-- this event must be manually created inside the tool
local shootEvent = weaponTool:WaitForChild("ShootEvent") 

-- require our main projectile module
local bulletManager = require(storage:WaitForChild("ProjectileService"))

-- configurations
local gunHandle = weaponTool:WaitForChild("Handle")
local muzzlePoint = gunHandle:WaitForChild("Muzzle")

shootEvent.OnServerEvent:Connect(function(player, targetPos)	
	local weaponType = "Pistol" 
	
	if weaponType == "Pistol" then
		bulletManager.firePistol(muzzlePoint, targetPos, player)
	elseif weaponType == "SMG" then
		bulletManager.fireSMG(muzzlePoint, targetPos, player)
	elseif weaponType == "Sniper" then
		bulletManager.fireSniper(muzzlePoint, targetPos, player)
	end
end)
]]

--DONE!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
