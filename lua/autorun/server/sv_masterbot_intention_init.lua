CMasterBotIntention = {}
CMasterBotIntention.__index = CMasterBotIntention

function CMasterBotIntention.New(bot, cls)
	cls = cls or CMasterBotIntention
	local b = setmetatable({}, cls)
	b.m_bot = bot
	b.m_noisyTimer = 0
	b.m_flTCRandom = 0
	b.m_flNextRandomTime = 0
	-- Кеш IsImmediateThreat: [entIndex] = { value, expires }
	b.m_immediateThreatCache = {}
	return b
end

function CMasterBotIntention:GetBot()
	return self.m_bot
end

function CMasterBotIntention:IsThreatAimingTowardMe(threat, cosTolerance)
	if (cosTolerance == nil) then
		cosTolerance = 0.8
	end
	
	local vecTo = (self:GetBot():GetPos() - threat:GetPos()):GetNormalized()
	
	if (vecTo:Dot(threat:EyeAngles():Forward()) > cosTolerance) then return true end
	
	return false
end

function CMasterBotIntention:IsThreatFiringAtMe(threat)
	if (threat.m_flWeaponFired == nil) then return false end
	
	local flTime = CurTime() - threat.m_flWeaponFired
	
	if (flTime < 0.0) then return false end
	
	-- Скорее всего только у игроков нормальная реализация EyeAngles, у NPC и некстботов неизвестно
	if (IsValid(threat) && threat:IsPlayer()) then
		return flTime <= 1.0 && self:IsThreatAimingTowardMe(threat)
	end
	
	-- TODO: Прикрутить IsThreatAimingTowardMe, у некоторых энтити EyeAngles может быть не валидным
	return flTime <= 1.0
end

local IMMEDIATE_THREAT_CACHE_TTL = 0.15

function CMasterBotIntention:IsImmediateThreat(threat)
	if (threat == nil || threat:GetEntity() == nil) then return false end
	
	local entIdx = threat:GetEntity():EntIndex()
	local cached = self.m_immediateThreatCache[entIdx]
	if (cached && CurTime() < cached.expires) then
		return cached.value
	end

	-- Расчёт
	local result = self:_ComputeIsImmediateThreat(threat)
	self.m_immediateThreatCache[entIdx] = { value = result, expires = CurTime() + IMMEDIATE_THREAT_CACHE_TTL }
	return result
end

function CMasterBotIntention:_ComputeIsImmediateThreat(threat)
	if (!threat:IsVisibleRecently()) then return false end
	if (!self:GetBot().m_Vision:IsEnemy(threat:GetEntity())) then return false end
	if (!threat:GetEntity():Alive()) then return false end
	-- Если между нами стена, то они не могут навредить мне
	if (!self:GetBot().m_Vision:IsAbleToSee(threat:GetEntity(), false)) then return false end
	
	local vecTo = (self:GetBot():GetPos() - threat:GetEntity():GetPos()):LengthSqr()
	
	-- Слишком близкие враги самые опасные
	if (vecTo < (500.0 * 500.0)) then return true end
	
	-- Враг стреляет в меня, очень опасен в FOV или вне его
	if (self:IsThreatFiringAtMe(threat:GetEntity())) then return true end
	
	-- Нахожусь ли я на мушке у снайпера?
	if (threat:GetEntity().m_isSniper) then
		local vecToMe = self:GetBot():GetPos() - threat:GetEntity():GetPos()
		vecToMe:Normalize()
		local sniperForward = threat:GetEntity():EyeAngles():Forward()
		
		if (vecToMe:Dot(sniperForward) > 0.0) then return true end
		
		return false
	end
	
	-- Хард и эксперты имеют приоритет в зависимости от класса врага
	if (self:GetBot().m_iBotSkill && self:GetBot().m_iBotSkill > 1) then
		-- Убиваем медиков в первую очередь
		if (threat:GetEntity().m_isMedic) then
			return true
		end
		
		-- Убиваем инженеров чтобы моя команда смогла уничтожить постройки и турели
		if (threat:GetEntity().m_isEngineer) then
			return true
		end
	end
	
	return false
end

function CMasterBotIntention:SelectMoreDangerousThreatInternal(me, threat1, threat2)
	if (threat1 == nil || threat1:IsObsolete()) then return threat2 end
	if (threat2 == nil || threat2:IsObsolete()) then return threat1 end
	
	local vecThreat1Pos = threat1:GetEntity():GetPos()
	local vecThreat2Pos = threat2:GetEntity():GetPos()
	local myPos         = self:GetBot():GetPos()

	local closerThreat
	if (myPos:DistToSqr(vecThreat1Pos) < myPos:DistToSqr(vecThreat2Pos)) then
		closerThreat = threat1
	else
		closerThreat = threat2
	end
	
	local isImmediateThreat1 = self:IsImmediateThreat(threat1)
	local isImmediateThreat2 = self:IsImmediateThreat(threat2)
	
	if (isImmediateThreat1 && !isImmediateThreat2) then
		return threat1
	elseif (!isImmediateThreat1 && isImmediateThreat2) then
		return threat2
	end
	
	-- Оба противника опасные
	
	if (self:IsThreatFiringAtMe(threat1:GetEntity())) then
		-- Оба стреляют по мне, возращаем того, кто ближе всех ко мне
		if (self:IsThreatFiringAtMe(threat2)) then
			return closerThreat
		end
		
		return threat1
	elseif (self:IsThreatFiringAtMe(threat2:GetEntity())) then
		return threat2
	end

	-- Никто из них не опасен, выбираем ближайший
	return closerThreat
end

function CMasterBotIntention:OnWeaponFired(whoFired, weapon)
	if (self:GetBot() == whoFired) then return end
	-- Так как оно может вызываться тысяча раз, используем DistToSqr
	if (self:GetBot():GetPos():DistToSqr(whoFired:GetPos()) >= (3000.0 * 3000.0)) then return end
	
	local iNoticeChance = 100
	if (self:IsQuietWeapon(weapon)) then
		if (self:GetBot():GetPos():DistToSqr(whoFired:GetPos()) >= (500.0 * 500.0)) then return end
	
		local iDifficulty = self:GetBot().m_iBotSkill or 1
		
		if (iDifficulty == 0) then
			iNoticeChance = 10
		elseif (iDifficulty == 1) then
			iNoticeChance = 30
		elseif (iDifficulty == 2) then
			iNoticeChance = 60
		elseif (iDifficulty == 3) then
			iNoticeChance = 90
		end
		
		if (CurTime() > self.m_noisyTimer) then
			iNoticeChance = iNoticeChance / 2
		end
	elseif (self:GetBot():GetPos():DistToSqr(whoFired:GetPos()) < (1000.0 * 1000.0)) then
		self.m_noisyTimer = CurTime() + 3.0
	end
	
	if (math.random(1, 100) > iNoticeChance) then return end
	
	-- Добавляем в память, бот сам найдет врага в поведениях или UpdateLooking
	self:GetBot().m_Vision:AddKnownEntity(whoFired)
end

function CMasterBotIntention:IsQuietWeapon(weapon)
	if (!IsValid(weapon)) then return false end
	if (weapon:GetClass() == "weapon_crowbar") then return true end
	return false
end

function CMasterBotIntention:SelectMoreDangerousThreat(me, threat1, threat2)
	local answer = me.m_Behavior:SelectMoreDangerousThreat(threat1, threat2)
	if (answer) then return answer end
	
	local threat = self:SelectMoreDangerousThreatInternal(me, threat1, threat2)
	
	-- Боты с легким уровнем сложности никогда не целятся в медика
	if (self:GetBot().m_iBotSkill == nil or self:GetBot().m_iBotSkill == 0) then return threat end
	
	if (CurTime() > self.m_flNextRandomTime) then
		self.m_flTCRandom     = math.random()
		self.m_flNextRandomTime = CurTime() + 10.0
	end
	
	-- Боты с нормальным уровнем сложности будут целиться в медика с 50% шансом. Шанс обновляется каждые 10 секунд
	if (self:GetBot().m_iBotSkill == 1 && self.m_flTCRandom < 0.5) then return threat end
	
	-- Боты с хард или экспертном уровнем сложности боты целятся сначало в медика которого хилит нашу цель
	-- Если медика нету, он вернет оригинальный threat а не nil
	return self:GetHealerOfThreat(threat)
end

function CMasterBotIntention:SelectTargetPoint(threat)
	local bot = self:GetBot()
	local answer = bot.m_Behavior:SelectTargetPoint(threat)
	if (answer != nil) then return answer end
	
	local _, desiredPos = bot.m_Vision:IsLineOfSightClear(threat)
	if (desiredPos != vector_origin) then return desiredPos end
	
	return threat:WorldSpaceCenter()
end

function CMasterBotIntention:GetHealerOfThreat(threat)
	-- TODO: Поддержка лечащих медиков-ботов через ents.FindInSphere(threat:GetPos(), 800)
	-- for _, v in player.Iterator() do
		-- if (v.m_hPatient == threat:GetEntity()) then
			-- local knownHealer = self:GetBot().m_Vision:GetKnown(v)
			
			-- if (knownHealer && knownHealer:IsVisibleInFOVNow()) then
				-- return knownHealer
			-- end
		-- end
	-- end
	
	return threat
end

function CMasterBotIntention:ShouldAttack(enemy, defaultAnswer)
	return self:GetBot().m_Behavior:QueryAnswerDeep("ShouldAttack", defaultAnswer or CMBAction.ANSWER_UNDEFINED, enemy)
end

function CMasterBotIntention:ShouldRetreat(defaultAnswer)
	return self:GetBot().m_Behavior:QueryAnswerDeep("ShouldRetreat", defaultAnswer or CMBAction.ANSWER_UNDEFINED)
end

function CMasterBotIntention:ShouldHurry(defaultAnswer)
	return self:GetBot().m_Behavior:QueryAnswerDeep("ShouldHurry", defaultAnswer or CMBAction.ANSWER_UNDEFINED)
end

setmetatable(CMasterBotIntention, { __call = CMasterBotIntention.new })