BehMvMEngineerIdle = setmetatable({}, { __index = CMBAction })
BehMvMEngineerIdle.__index = BehMvMEngineerIdle

local function CTFGameRules_PushAllPlayersAway(fromThisPoint, range, force, noPushUp)
	local toPlayer = vector_origin
	local vPush = vector_origin
	
	for _, ply in player.Iterator() do
		
		toPlayer = ply:EyePos() - fromThisPoint
		--toPlayer = ply:GetPos() - fromThisPoint
		
		if (toPlayer:LengthSqr() < range * range) then
			
			toPlayer.z = 0.0
			toPlayer:Normalize()
			toPlayer.z = 1.0
			
			vPush = force * toPlayer
			
			if (noPushUp) then
				vPush.z = 1.0
			end
			
			ply:SetVelocity(vPush)
		end
	end
end

function BehMvMEngineerIdle:New()
	local b = CMBAction.New(self, "MvMEngineerIdle")
	
	b.m_repathTimer = CurTime()
	b.m_sentryInjuredTimer = CurTime()
	b.m_sentryRebuildTimer = CurTime()
	b.m_teleporterRebuildTimer = CurTime()
	b.m_findHintTimer = CurTime()
	b.m_reevaluatreNestTimer = CurTime()
	
	return b
end

function BehMvMEngineerIdle:OnStart(bot, prior)
	self.m_sentryHint = nil
	self.m_teleporterHint = nil
	self.m_nestHint = nil
	self.m_teleportedCount = 0
	self.m_teleportedToHint = false
	self.m_triedToDetonateStaleNest = false
	
	-- Не смотрим на противников, чтобы не отвлекаться от работы над постройками
	bot.m_dontLookAtThreat = true
	bot.m_isLookingAroundForEnemies = false
	
	return self:Continue()
end

function BehMvMEngineerIdle:Update(bot, dt)

	if (!IsValid(self.m_nestHint) || self:ShouldAdvance(bot)) then
		if (self.m_findHintTimer > CurTime()) then
			return self:Continue()
		end
		
		self.m_findHintTimer = CurTime() + math.Rand(1.0, 2.0)
		
		local bShouldTeleportToHint = false
		local bShouldCheckForBlockingObject = !self.m_teleportedToHint && bShouldTeleportToHint
		local newNest = nil
		
		if (IsValid(self.m_nestHint)) then
			self.m_nestHint:SetOwner(nil)
		end
		
		self.m_nestHint = newNest
		self.m_nestHint:SetOwner(bot)
		--
		self:TakeOverStaleNest(self.m_sentryHint, bot)
		
		
	end
	
	if (!self.m_teleportedToHint && self.m_hasAttribute) then
		self.m_teleportedCount = self.m_teleportedCount + 1
		local bFirstTeleportSpawn = self.m_teleportedCount == 1
		self.m_teleportedToHint = true
		return self:SuspendFor(BehMvMEngineerTeleportSpawn(self.m_nestHint, bFirstTeleportSpawn), "In spawn area - teleport to the teleporter hint")
	end
	
	local rebuildInterval = 3.0
	local mySentry = nil
	
	if (IsValid(self.m_sentryHint)) then
		
		if (IsValid(mySentry)) then
			self.m_sentryRebuildTimer = CurTime() + rebuildInterval
		else
			if (IsValid(self.m_sentryHint:GetOwner()) && self.m_sentryHint:GetOwner().m_bBuilding) then
				
				mySentry:SetOwner(bot)
			else
				if (CurTime() > self.m_sentryRebuildTimer) then
					return self:SuspendFor(BehMvMEngineerBuildSentryGun:New(self.m_sentryHint), "No sentry - building a new one")
				else
					return self:SuspendFor(BehRetreat:New(), "Lost my sentry - retreat!")
				end
			end
		end
	end
	
	if (IsValid(mySentry) && mySentry:Health() < mySentry:GetMaxHealth() && mySentry.m_bIsBuilding) then
		self.m_sentryInjuredTimer = CurTime() + 3.0
	end
	
	local myTeleporter = nil
	if (IsValid(self.m_teleporterHint) && CurTime() > self.m_sentryInjuredTimer) then
		if (IsValid(self.m_teleporterHint:GetOwner()) && self.m_teleporterHint:GetOwner().m_bBaseObject) then
			myTeleporter = self.m_teleporterHint:GetOwner()
			self.m_teleporterRebuildTimer = CurTime() + rebuildInterval
		elseif (CurTime() > self.m_teleporterRebuildTimer) then
			return self:SuspendFor(BehMvMEngineerBuildTeleporterExit(self.m_teleporterHint), "Sentry is safe - building a teleport exit")
		end
	end
	
	if (IsValid(myTeleporter) && CurTime() > self.m_sentryInjuredTimer && myTeleporter:Health() < myTeleporter:GetMaxHealth()) then
		local rangeToTeleporter = self:GetPos():DistToSqr(myTeleporter:GetPos())
		
		local nearTeleporterRange = 75.0 * 75.0
		
		if (rangeToTeleporter < 1.2 * nearTeleporterRange) then
			bot.m_Body:PressCrouchButton()
		end
		
		if (CurTime() > self.m_repathTimer) then
			self.m_repathTimer = CurTime() + math.Random(1.0, 2.0)
			
			local toTeleporter = myTeleporter:GetPos() - bot:GetPos()
			local hittingTeleporterPos = myTeleporter:GetPos() - 50.0 * toTeleporter:GetNormalized()
			
			bot:NavGoTo(hittingTeleporterPos, bot.m_navSpeed)
		end
		
		if (rangeToTeleporter < nearTeleporterRange) then
			bot.m_Body:AimHeadTowardsPos(myTeleporter:WorldSpaceCenter(), CMasterBotBody.CRITICAL, 1.0, "Work on my Teleporter")
			bot.m_Body:PressFireButton()
		end
	elseif (IsValid(mySentry)) then
		local rangeToSentry = bot:GetPos():DistToSqr(mySentry:GetPos())
		local nearSentryRange = 75.0 * 75.0
		
		if (rangeToSentry < 1.2 * nearSentryRange) then
			bot.m_Body:PressCrouchButton()
		end
		
		if (CurTime() > self.m_repathTimer) then
			self.m_repathTimer = CurTime() + math.Random(1.0, 2.0)
			
			local mySentryForward = vector_origin
			--mySentryForward = mySentry:GetTurretAngles()
			
			local behindSentrySpot = mySentry:GetPos() - 50.0 * mySentryForward
			
			bot:NavGoTo(behindSentrySpot, bot.m_navSpeed)
		end
		
		if (rangeToSentry < nearSentryRange) then
			bot.m_Body:AimHeadTowardsPos(mySentry:WorldSpaceCenter(), CMasterBotBody.CRITICAL, 1.0, "Work on my Sentry")
			bot.m_Body:PressFireButton()
		end
	end
	
	self:TryToDetonateStaleNest()
	
    return self:Continue()
end

function BehMvMEngineerIdle:TakeOverStaleNest(hint, bot)
	-- Владельцем хинта является постройка, если у постройки нет владельца, мы забираем под своё крыло
	if (IsValid(hint) && IsValid(hint:GetOwner()) && !IsValid(hint:GetOwner():GetOwner())) then
		local obj = hint:GetOwner()
		obj:SetOwner(bot)
	end
end

function BehMvMEngineerIdle:TryToDetonateStaleNest()
	
end

function BehMvMEngineerIdle:FindHint(shouldCheckForBlockingObjects, allowOutOfRangeNest, foundNest)
	
end

function BehMvMEngineerIdle:ShouldAdvanceNestSpot(bot)
	return false
end

function BehMvMEngineerIdle:ShouldRetreat(bot)
    return CMBAction.ANSWER_NO
end

function BehMvMEngineerIdle:ShouldAttack(bot)
	return CMBAction.ANSWER_NO
end

function BehMvMEngineerIdle:ShouldHurry(bot)
	return CMBAction.ANSWER_YES
end

BehMvMEngineerBuildSentryGun = setmetatable({}, { __index = CMBAction })
BehMvMEngineerBuildSentryGun.__index = BehMvMEngineerBuildSentryGun

function BehMvMEngineerBuildSentryGun:New(sentryHint)
	local b = CMBAction.New(self, "MvMEngineerBuildSentryGun")
	
	b.m_sentryHint = sentryHint
	b.m_repathTimer = 0
	b.m_delayBuildTime = 0
	return b
end

function BehMvMEngineerBuildSentryGun:OnStart(bot, prior)
	--bot:StartBuildingObjectOfType()
	return self:Continue()
end

function BehMvMEngineerBuildSentryGun:Update(bot, dt)
	if (!IsValid(self.m_sentryHint)) then
		return self:Done("No hint entity")
	end
	
	local rangeToBuildSpot = bot:GetPos():DistToSqr(self.m_sentryHint:GetPos())
	
	if (rangeToBuildSpot < 200.0 * 200.0) then
		bot:PressCrouchButton()
		bot.m_Body:AimHeadTowardsPos(self.m_sentryHint:GetPos(), CMasterBotBody.MANDATORY, 0.1, "Placing sentry")
	end
	
	if (rangeToBuildSpot > 25.0 * 25.0) then
		if (CurTime() > self.m_repathTimer) then
			self.m_repathTimer = CurTime() + math.Random(1.0, 2.0)
			
			bot:NavGoTo(self.m_sentryHint:GetPos(), bot.m_navSpeed)
		end
		
		return self:Continue()
	end
	
	if (self.m_delayBuildTime == 0) then
		self.m_delayBuildTime = CurTime() + 0.1
		CTFGameRules_PushAllPlayersAway(self.m_sentryHint:GetPos(), 400, 500)
	elseif (CurTime() > self.m_delayBuildTime) then
		--CreateEntity
		self.m_sentryHint:IncrementUseCount()
		self.m_sentryHint:SetOwner(sentry)
		
		return self:Done("Built a sentry")
	end
	
	return self:Continue()
end

BehMvMEngineerBuildTeleporterExit = setmetatable({}, { __index = CMBAction })
BehMvMEngineerBuildTeleporterExit.__index = BehMvMEngineerBuildTeleporterExit

function BehMvMEngineerBuildTeleporterExit:New(teleporterHint)
	local b = CMBAction.New(self, "MvMEngineerBuildTeleporterExit")
	
	b.m_teleporterHint = teleporterHint
	b.m_delayBuildTime = 0
	b.m_repathTimer = 0
	return b
end

function BehMvMEngineerBuildTeleporterExit:OnStart(bot, prior)
	--bot:StartBuildingObjectOfType()
	return self:Continue()
end

function BehMvMEngineerBuildTeleporterExit:Update(bot, dt)
	if (!IsValid(self.m_teleporterHint)) then
		return self:Done("No hint entity")
	end
	
	if (bot:GetPos():DistToSqr(self.m_teleporterHint:GetPos()) > 25.0 * 25.0) then
		if (CurTime() > self.m_repathTimer) then
			self.m_repathTimer = CurTime() + math.Random(1.0, 2.0)
			bot:NavGoTo(self.m_teleporterHint:GetPos(), bot.m_navSpeed)
		end
		
		return self:Continue()
	end
	
	if (self.m_delayBuildTime == 0) then
		self.m_delayBuildTime = CurTime() + 0.1
		--PushAllPlayersAway(self.m_teleporterHint:GetPos(), 400, 500)
		CTFGameRules_PushAllPlayersAway(self.m_teleporterHint:GetPos(), 400, 500)
	elseif (CurTime() > self.m_delayBuildTime) then
		--CreateEntity
		
		self.m_teleporterHint:SetOwner(myTeleporter)
		--bot:EmitSound("Engineer.MVM_AutoBuildingTeleporter02")
		return self:Done("Teleporter exit built")
	end
	
	return self:Continue()
end

BehMvMEngineerTeleportSpawn = setmetatable({}, { __index = CMBAction })
BehMvMEngineerTeleportSpawn.__index = BehMvMEngineerTeleportSpawn

function BehMvMEngineerTeleportSpawn:New(hint, firstTeleportSpawn)
	local b = CMBAction.New(self, "MvMEngineerTeleportSpawn")
	
	b.m_hintEntity = hint
	b.m_firstTeleportSpawn = firstTeleportSpawn
	b.m_teleportDelay = 0
	return b
end

function BehMvMEngineerTeleportSpawn:OnStart(bot, prior)
	--bot:StartBuildingObjectOfType()
	return self:Continue()
end

function BehMvMEngineerTeleportSpawn:Update(bot, dt)
	if (self.m_teleportDelay == 0) then
		self.m_teleportDelay = CurTime() + 0.1
		if (IsValid(self.m_hintEntity)) then
			--PushAllPlayersAway
			CTFGameRules_PushAllPlayersAway(self.m_hintEntity:GetPos(), 400, 500)
		end
	elseif (CurTime() > self.m_teleportDelay) then
		if (!IsValid(self.m_hintEntity)) then
			return self:Done("Cannot teleport to hint")
		end
		
		local origin = self.m_hintEntity:GetPos()
		origin.z = origin.z + 10.0
		
		bot:SetPos(origin)
		bot:SetAngles(self.m_hintEntity:GetAngles())
		
		--ParticleEffect teleported_blue
		--ParticleEffect player_sparkles_blue
		
		if (self.m_firstTeleportSpawn) then
			--ParticleEffect teleported_mvm_bot
			--bot:EmitSound("Engineer.MVM_BattleCry07")
			self.m_hintEntity:EmitSound("MVM.Robot_Engineer_Spawn")
		end
		
		return self:Done()
	end
	
	return self:Continue()
end