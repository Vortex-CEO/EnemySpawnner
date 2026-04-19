local EnemySpawnManager = {}
EnemySpawnManager.__index = EnemySpawnManager
 
-- setup manager and get folders  
function EnemySpawnManager.new()
	local self = setmetatable({}, EnemySpawnManager)

	-- References to enemy assets and stages
	self.EnemyFolder = game.ReplicatedFirst:WaitForChild("Main_RS"):WaitForChild("Enemies")
	self.StagesFolder = workspace:WaitForChild("Stages")

	-- enemies spawnPoint
	self.EnemySpawnPoints = workspace:WaitForChild("EnemySpawnPoints"):GetChildren()

	self.EnemySpawnRate = 1
	self.EnemySpawnDelay = 1

	-- store pathfinding once instead of calling getservice every time
	self.PathService = game:GetService("PathfindingService")

	self.spawnedEnemies = {}
	self:StartAutoReset()
	return self
end

-- spawn chances for each stage
local stageChances = {
	Stage1 = {Normal = 0.9, Master = 0.1, Boss = 0},
	Stage2 = {Normal = 0.5, Master = 0.5, Boss = 0},
	Stage3 = {Normal = 0.495, Master = 0.495, Boss = 0.01}
}

-- check if target is alive close enough and visible
function EnemySpawnManager:IsTargetAttackable(root, targetRoot)
	if not root or not targetRoot then return false end

	local targetHum = targetRoot.Parent:FindFirstChild("Humanoid")
	if not targetHum or targetHum.Health <= 0 then return false end

	local dist = (targetRoot.Position - root.Position).Magnitude
	if dist > 50 then return false end

	local dir = (targetRoot.Position - root.Position)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {
		targetRoot.Parent,
		root.Parent
	}

	local res = workspace:Raycast(root.Position, dir, params)
	if res then
		return false
	end
	return true
end

-- StartAutoReset:
-- resets all enemies every 900 seconds so server doesnt get messy in long runs
function EnemySpawnManager:StartAutoReset()
	task.spawn(function()
		while true do
			task.wait(900)
			self:ResetEnemies()
		end
	end)
end

-- wipe enemies
function EnemySpawnManager:ResetEnemies()
	local stages = {}
	for _, enemy in ipairs(self.spawnedEnemies) do
		if enemy and enemy.Parent then
			table.insert(stages, enemy.Parent)
		end
		if enemy then
			enemy:Destroy()
		end
	end

	table.clear(self.spawnedEnemies)
	for _, stage in ipairs(stages) do
		self:SpawnEnemy(stage)
	end
end

-- spawn logic and enemies types
function EnemySpawnManager:SpawnEnemy(stageFolder)
	if not stageFolder then return end
	local probs = stageChances[stageFolder.Name]
	if not probs then return end

	local rand = math.random()
	local eType = "Normal"

	if rand <= probs.Normal then
		eType = "Normal"
	elseif rand <= probs.Normal + probs.Master then
		eType = "Master"
	elseif probs.Boss > 0 then
		eType = "Boss"
	end

	local clone
	if eType == "Normal" then
		clone = self.EnemyFolder.Normal.NormalZombie:Clone()
	elseif eType == "Master" then
		clone = self.EnemyFolder.Master.MasterZombie:Clone()
	elseif eType == "Boss" then
		clone = self.EnemyFolder.Boss.BossZombie:Clone()
	end

	local pt = self.EnemySpawnPoints[math.random(#self.EnemySpawnPoints)]
	clone:PivotTo(pt.CFrame)

	clone.Parent = stageFolder
	table.insert(self.spawnedEnemies, clone)

	self:EnemyAI(clone)
end

-- attack types
local attacks = {}

function attacks.Normal(_, hum)
	if hum then hum:TakeDamage(10) end
end

function attacks.Master(_, hum)
	if hum then hum:TakeDamage(25) end
end

function attacks.Boss(_, hum)
	if hum then hum:TakeDamage(50) end
end

-- hitbox logic to damage player
function EnemySpawnManager:AttackState(model, humanoid, targetRoot)
	if not targetRoot then return end

	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local hitbox = Instance.new("Part")
	hitbox.Size = Vector3.new(5, 3, 5)
	hitbox.Transparency = 1
	hitbox.CanCollide = false
	hitbox.Anchored = true
	hitbox.CFrame = root.CFrame * CFrame.new(0, -1, -3)
	hitbox.Parent = workspace

	local parts = hitbox:GetTouchingParts()
	hitbox:Destroy()

	local hitHums = {}
	for _, p in pairs(parts) do
		local char = p:FindFirstAncestorOfClass("Model")

		if char and char ~= model then
			local hum = char:FindFirstChild("Humanoid")

			if hum and hum.Health > 0 then
				if not hitHums[hum] then
					hitHums[hum] = true
					local fName = model.Parent.Name
					if attacks[fName] then
						attacks[fName](model, hum)
					end
				end
			end
		end
	end
end

-- movement using pathfinding (now using self.PathService)
function EnemySpawnManager:MoveState(root, humanoid, targetRoot, lastTime, cooldown)
	if not targetRoot then return lastTime end
	if tick() - lastTime >= cooldown then

		local path = self.PathService:CreatePath({
			AgentCanJump = true,
			AgentRadius = 3,
			AgentHeight = 6,
			AgentCanClimb = true,
			WaypointSpacing = 4,
			Costs = {
				Water = 20,
				Neon = 15,
				Lava = math.huge,
				Mud = 10,
				Ice = 8,

				DangerZone = math.huge,
				Fire = 50,
				DeepWater = 100,
				Sand = 5,
				Door = 2,
				Window = 15
			}
		})

		local ok = pcall(function()
			path:ComputeAsync(root.Position, targetRoot.Position)
		end)

		if ok and path.Status == Enum.PathStatus.Success then
			local points = path:GetWaypoints()
			local nxt = points[2] or points[1]

			if nxt then
				humanoid:MoveTo(nxt.Position)
			end
		end
		lastTime = tick()
	end
	return lastTime
end

-- animation state handler
function EnemySpawnManager:AnimationState(model, humanoid, state)
	if not model or not humanoid then return end

	local anim = humanoid:FindFirstChildOfClass("Animator")
	if not anim then
		anim = Instance.new("Animator")
		anim.Parent = humanoid
	end

	if model:GetAttribute("CurrentAnimationState") == state then return end

	for _, t in pairs(anim:GetPlayingAnimationTracks()) do
		t:Stop()
	end

	local fldr = model:FindFirstChild("Animations")
	if fldr then
		local obj = fldr:FindFirstChild(state)
		if obj and obj:IsA("Animation") then
			local track = anim:LoadAnimation(obj)
			track:Play()
		end
	end
	model:SetAttribute("CurrentAnimationState", state)
end

-- main AI loop
function EnemySpawnManager:EnemyAI(model)
	local hum = model:FindFirstChild("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")

	if not hum or not root then return end

	local players = game:GetService("Players")

	local repathTime = 0.5
	local lastTime = 0

	task.spawn(function()
		while model.Parent do
			task.wait(0.2)

			local closestDist = math.huge
			local tRoot = nil

			for _, plr in pairs(players:GetPlayers()) do
				local char = plr.Character
				if char then
					local hrp = char:FindFirstChild("HumanoidRootPart")
					local tHum = char:FindFirstChild("Humanoid")

					if hrp and tHum and tHum.Health > 0 then
						if not self:IsTargetAttackable(root, hrp) then
							continue
						end

						local dist = (hrp.Position - root.Position).Magnitude

						if dist < closestDist then
							closestDist = dist
							tRoot = hrp
						end
					end
				end
			end

			local state = "Idle"

			if tRoot then
				state = (closestDist < 5) and "Attack" or "Move"
			end

			self:AnimationState(model, hum, state)

			if state == "Attack" then
				self:AttackState(model, hum, tRoot)
			elseif state == "Move" then
				lastTime = self:MoveState(root, hum, tRoot, lastTime, repathTime)
			end
		end
	end)
end

return EnemySpawnManager
