-- TODO: Более норм объяснение
--
-- Здесь располагается логика из трех слоёв
-- BehMainAction
-- BehTacticalMonitor
-- BehScenarioMonitor
-- Какое нибудь действие далее
--
-- ==============================
-- Как работает стек-машина с дочерними действиями
-- ==============================
--
-- В действиях CMBAction есть два независимых измерения:
--   1. m_buriedUnderMe / m_coveringMe - стек (горизонталь)
--   2. m_childBehavior / m_parent / m_child - контейнеры (вертикаль)
-- Иерархия контейнеров задаётся через InitialContainedAction. Это не одно и тоже!
--
-- Визуально работа контейнеров:
-- CMBBehavior.m_stack = [ BehMainAction ] (есть дочернее действие BehTacticalMonitor)
--                               |  m_childBehavior
--                           [ BehTacticalMonitor ] (есть дочернее действие BehScenarioMonitor)
--                                     |
--                                [ BehScenarioMonitor ] (есть дочернее действие BehELOF)
--                                          |
--                                       [ BehELOF ]
-- Порядок Update:
-- 1. BehELOF.Update()
-- 2. BehScenarioMonitor.Update()
-- 3. BehTacticalMonitor.Update()
-- 4. BehMainAction.Update()
--
-- ==============================
-- Как работает SuspendFor в дочерних действиях
-- ==============================
--
-- Действие в стеке: Есть действие A, A делает SuspendFor B, и B делает SuspendFor C
-- CMBBehavior.m_stack = [ A (пауза) -> B (пауза) -> C (Выполняется, остальные на паузе) ]
--
-- Действие в контейнере: Есть действия A, B, C. B делает SuspendFor D
-- CMBBehavior.m_stack = [ A (пауза) ] - на паузе из-за B который вызвал D
--                         [ B (пауза) -> D ] - выполняется D, B на паузе
--                           [ C (пауза) ] - на паузе из-за B который вызвал D
--
-- Исходя из этого: работает только одно действие, если A возвращает Continue, оно перейдёт к B и так далее по списку, пока есть Continue
--
-- ENGLISH
-- So we have a logic with a three layers
-- BehMainAction
-- BehTacticalMonitor
-- BehScenarioMonitor
-- Какое нибудь действие далее
--
-- ==============================
-- How stack-machine does work with children actions
-- ==============================
--
-- In CMBAction there are two axis:
--   1. m_buriedUnderMe / m_coveringMe - stack (horizontal)
--   2. m_childBehavior / m_parent / m_child - containers (vertical)
-- Container hierarchy are done via InitialContainedAction. The're not same!
--
-- Visual containers work:
-- CMBBehavior.m_stack = [ BehMainAction ] (child action BehTacticalMonitor)
--                               |  m_childBehavior
--                           [ BehTacticalMonitor ] (child action BehScenarioMonitor)
--                                     |
--                                [ BehScenarioMonitor ] (child action BehELOF)
--                                          |
--                                       [ BehELOF ]
-- Update:
-- 1. BehELOF.Update()
-- 2. BehScenarioMonitor.Update()
-- 3. BehTacticalMonitor.Update()
-- 4. BehMainAction.Update()
--
-- ==============================
-- How does SuspendFor work in child actions
-- ==============================
--
-- Действие в стеке: Есть действие A, A делает SuspendFor B, и B делает SuspendFor C
-- Action in stack: action A does SuspendFor B, B does SuspendFor C
-- CMBBehavior.m_stack = [ A (paused) -> B (paused) -> C (Executing, all paused) ]
--
-- Action in containers: We have actions A, B, C. B does SuspendFor D
-- CMBBehavior.m_stack = [ A (pause) ] - paused because of B who did SuspendFor D
--                         [ B (pause) -> D ] - executing D, B is paused
--                           [ C (pause) ] - paused because of B who did SuspendFor D
--
-- So basically: only one action executes, if A returns Continue, then it will go to B and go on while we have Continue

local function GetEnemy(bot)
	if (bot.GetEnemy) then
		return bot:GetEnemy()
	end
	
	local enemy = bot.m_Vision:GetPrimaryKnownThreat()
	
	if (enemy) then return enemy:GetEntity() end
	
	return NULL
end

local function RandFloat(lo, hi)
	return lo + math.Rand(0, 1) * (hi - lo)
end

local function GetImperfectAimSpot(bot, threat, s)
	local toThreat = threat:GetPos() - bot:GetPos()
	toThreat:Normalize()
	local threatRange = toThreat:Length()
	
	local err = threatRange * math.sin(s)
	
	local imperfectAimSpot = threat:WorldSpaceCenter()
	
	imperfectAimSpot.x = imperfectAimSpot.x + RandFloat(-err, err)
	imperfectAimSpot.y = imperfectAimSpot.y + RandFloat(-err, err)
	
	return imperfectAimSpot
end

-- ── BehMainAction ────────────────────────────────────────────────────
-- Самый верхний уровень
-- Дочернее действие: BehTacticalMonitor

BehMainAction = setmetatable({}, { __index = CMBAction })
BehMainAction.__index = BehMainAction

function BehMainAction:New()
    local b = CMBAction.New(self, "MainAction")
	b.m_priorYaw = 0
	b.m_yawRate = 0
	b.m_hearedTime = 0
    return b
end

-- Запускает TacticalMonitor как дочернее действие
function BehMainAction:InitialContainedAction(bot)
    return BehTacticalMonitor:New()
end

function BehMainAction:OnStart(bot, prior)
    return self:Continue()
end

-- Запускается последним
function BehMainAction:Update(bot, dt)
	
	-- Для снайперов чтобы компенсировать аимбот
	if (bot.m_isSniper && bot.m_sniperUseSteady) then
		local deltaYaw = bot.m_Body.m_angCurrentAngles.y - self.m_priorYaw
		self.m_yawRate = math.abs(deltaYaw / (dt + 0.0001))
		self.m_priorYaw = bot.m_Body.m_angCurrentAngles.y
		
		if (self.m_yawRate < 20) then -- 10
			if (bot.m_steadyTimer == 0) then
				bot.m_steadyTimer = CurTime()
			end
		else
			bot.m_steadyTimer = 0
		end
	end
	
    return self:Continue()
end

function BehMainAction:ShouldRetreat(bot)
    -- local myPos  = bot:GetPos()
    -- local nearby = 750

    -- local friendScore = 0
    -- local foeScore    = 0

    -- -- Считаем союзников
    -- for _, m in ipairs(CMasterBotSquadManager:GetBotSquadMembers(bot)) do
        -- if (IsValid(m) && m != bot && myPos:Distance(m:GetPos()) < nearby) then
            -- friendScore = friendScore + 1
        -- end
    -- end

    -- -- Считаем видимых врагов
	-- -- TODO: Заменить GetEnemy на ents.FindInSphere
    -- local enemy = bot:GetEnemy()
    -- if (IsValid(enemy) && myPos:Distance(enemy:GetPos()) < nearby) then
        -- foeScore = foeScore + 1
    -- end

    -- if (foeScore > friendScore + 1) then
        -- return ANSWER_YES -- Слишком много врагов, отступаем
    -- end
	
	-- Никогда не отступаем если у нас оружие ближнего боя
	if (bot.m_wpn && bot.m_wpn.m_bIsMelee) then return CMBAction.ANSWER_NO end

    return CMBAction.ANSWER_UNDEFINED
end

function BehMainAction:OnCommandString(bot, command)
	return self:TryContinue()
end

function BehMainAction:SelectTargetPoint(bot, subject)
	if (bot.m_wpn) then
		-- Логика наводки с ракетомета
		if (bot.m_wpn.m_bIsRocketLauncher) then
			local aboveTolerance = 30.0
			
			-- Наводимся сначала на ноги противника, если ноги не видны, то в центр, и наконец в глаза
			if (subject:GetPos().z - aboveTolerance > bot:GetPos().z) then
				if (bot.m_Vision:IsAbleToSeePos(subject:GetPos())) then
					return subject:GetPos()
				end
				
				if (bot.m_Vision:IsAbleToSeePos(subject:WorldSpaceCenter())) then
					return subject:WorldSpaceCenter()
				end
				
				return subject:EyePos()
			end
			
			-- Если противник находится в воздухе, и расстояние от противника и земли не больше 200, то стреляем ему под ноги
			-- чтобы гаранитрованно нанести ему урон от сплеша ракеты
			if (!IsValid(subject:GetGroundEntity())) then
				local tr = util.TraceLine({ start = subject:GetPos(), endpos = subject:GetPos() + Vector(0, 0, -200), mask = MASK_SHOT, filter = subject })
				if (tr.Hit) then
					return tr.HitPos
				end
			end
			
			local missleSpeed = 1100.0
			local rangeBetween = bot:GetPos():Distance(subject:GetPos())
			
			local veryCloseRange = 150
			-- Наводимся в ту точку, куда пойдёт игрок (предугадываем)
			if (rangeBetween > veryCloseRange) then
				local timeToTravel = rangeBetween / missleSpeed
				
				local targetPos = subject:GetPos() + timeToTravel * subject:GetVelocity()
				
				if (bot.m_Vision:IsAbleToSeePos(targetPos)) then
					return targetPos
				end
				
				return subject:EyePos() + timeToTravel * subject:GetVelocity()
			end
			
			-- Очень рядом, нет смысла предугадывать
			return subject:EyePos()
		-- Логика наводки с лука
		elseif (bot.m_wpn.m_bIsBow) then
			-- Мастерботы с легким уровнем сложности целятся в тупую
			if (bot.m_iBotSkill != 0) then
				local missleSpeed = 110
				local rangeBetween = bot:GetPos():Distance(subject:GetPos())
				
				local veryCloseRange = 150.0
				if (rangeBetween > veryCloseRange) then
					local timeToTravel = rangeBetween / missleSpeed
					-- Мастерботы с нормальным уровнем сложности целятся в центр и учитывают угол, на харде и выше целятся в голову и учитывают угол тоже
					local targetSpot = bot.m_iBotSkill == 1 and subject:WorldSpaceCenter() or subject:EyePos()
					local leadTargetSpot = targetSpot + timeToTravel * subject:GetVelocity()
					local elevationAngle = rangeBetween * 0.0001
					if (elevationAngle > 45.0) then
						elevationAngle = 45.0
					end
					
					local s = math.sin(elevationAngle * math.pi / 180.0)
					local c = math.cos(elevationAngle * math.pi / 180.0)
					
					if (c > 0.0) then
						local elevation = rangeBetween * s / c
						return leadTargetSpot + Vector(0, 0, elevation)
					end
					
					return leadTargetSpot
				end
			end
		elseif (bot.m_wpn.m_bIsGrenadeLauncher) then
			local toThreat = subject:GetPos() - bot:GetPos()
			toThreat:Normalize()
			local threatRange = toThreat:Length()
			local elevationAngle = threatRange * 0.01
			
			if (elevationAngle > 45.0) then
				elevationAngle = 45.0
			end
			
			local s = math.sin(elevationAngle * math.pi / 180.0)
			local c = math.cos(elevationAngle * math.pi / 180.0)
			
			if (c > 0.0) then
				local elevation = threatRange * s / c
				return subject:WorldSpaceCenter() + Vector(0, 0, elevation)
			end
		end
	end
	return nil
end

function BehMainAction:OnOtherKilled(bot, victim, attacker, inflictor)
	
	if (bot.m_customHandleOnOtherKilled) then
		return self:TryContinue()
	end
	
	if (!IsValid(victim) || !IsValid(attacker)) then return self:TryContinue() end
	if (victim:EntIndex() == bot:EntIndex()) then return self:TryContinue() end
	
	-- Кто-то убил моего союзника, он становится врагом автоматически для меня (узнали по рации)
	if (victim:IsNextBot() && victim.m_iMasterBotTeam && bot.m_iMasterBotTeam) then
		if (victim.m_iMasterBotTeam == bot.m_iMasterBotTeam) then
			bot.m_Vision:AddKnownEntity(attacker)
			-- Если я был нейтральным к атакующему, но он убил моего союзника, то я больше не нейтрален к нему
			if (bot.RememberEntityAsEnemy) then
				bot:RememberEntityAsEnemy(attacker)
			end
		end
	end
	
	-- Если мы можем увидеть обидчика, то наводимся на него
	if (bot.m_Vision:IsAbleToSee(attacker, false)) then
		local toThreat = attacker:GetPos() - bot:GetPos()
		toThreat:Normalize()
		local threatRange = toThreat:Length()
		
		local err = threatRange * math.sin(math.pi / 6)
		
		local imperfectAimSpot = attacker:WorldSpaceCenter()
		imperfectAimSpot.x = imperfectAimSpot.x + math.Rand(-err, err)
		imperfectAimSpot.y = imperfectAimSpot.y + math.Rand(-err, err)
		
		bot.m_Body:AimHeadTowardsPos(imperfectAimSpot, CMasterBotBody.IMPORTANT, 1.0, "Someone killed my teammate")
	end
	
	return self:TryContinue()
end

function BehMainAction:OnInjured(bot, info)
	-- Если у нас есть свой код в ENT:OnTakeDamage, игнорируем
	if (bot.m_customHandleOnInjured) then
		return self:TryContinue()
	end
	
	local attacker = info:GetAttacker()
	if (!IsValid(attacker)) then return self:TryContinue() end
	
	if (bot.m_playersNeutral) then
		if (bot.RememberEntityAsEnemy) then
			bot:RememberEntityAsEnemy(attacker)
		end
	end
	
	if (!bot.m_flagAggressive && !bot.m_coverAt) then
		self.m_coverAt = CurTime() + 2.0
	end
	
	bot.m_Vision:AddKnownEntity(attacker)
	
	local squad = CMasterBotSquadManager:GetBotSquadMembers(bot)
	for _, m in ipairs(squad) do
		if (m.m_playersNeutral) then
			m.m_Vision:AddKnownEntity(attacker)
			if (m.RememberEntityAsEnemy) then
				m:RememberEntityAsEnemy(attacker)
			end
		end
	end
	
	if (!bot.m_isLookingAroundForEnemies && !bot.m_sniperIsLookingAroundForEnemies && !IsValid(GetEnemy(bot)) && !bot.m_Vision:IsInFieldOfViewEnt(attacker)) then
		
		local toThreat = attacker:GetPos() - bot:GetPos()
		toThreat:Normalize()
		local threatRange = toThreat:Length()
		
		local err = threatRange * math.sin(math.pi / 6)
		
		local imperfectAimSpot = attacker:WorldSpaceCenter()
		imperfectAimSpot.x = imperfectAimSpot.x + math.Rand(-err, err)
		imperfectAimSpot.y = imperfectAimSpot.y + math.Rand(-err, err)
		
		bot.m_Body:AimHeadTowardsPos(imperfectAimSpot, CMasterBotBody.IMPORTANT, 1.0, "Something hurt me!")
	end
	
	return self:TryContinue()
end

function BehMainAction:OnSound(bot, source, pos, data)
	if (!IsValid(source)) then return self:TryContinue() end
	
	if (bot.m_Vision:GetPrimaryKnownThreat() == nil) then
		if (string.find(data.SoundName, "footstep") && CurTime() > self.m_hearedTime) then
			--print("footstep", data.SoundLevel, data.Pitch, data.Volume)
			if (bot.m_Vision:IsEnemy(source) && bot.m_Vision:IsAbleToSee(source, false) && data.Volume > 0.18) then
				local distToNotice = 500.0 * 500.0
				
				if (bot:GetPos():DistToSqr(source:GetPos()) < distToNotice) then
					self.m_hearedTime = CurTime() + 5.0
					
					local imperfectAimSpot = GetImperfectAimSpot(bot, source, math.pi / 4)
					
					bot.m_Body:AimHeadTowardsPos(imperfectAimSpot, CMasterBotBody.INTERESTING, 1.5, "Heared enemy footsteps")
				end 
			end
		end
	end
	
	return self:TryContinue()
end

-- ── BehTacticalMonitor ───────────────────────────────────────────────
-- Тактический монитор, дочернее действие будет сценарный монитор BehScenarioMonitor
-- Может прерваться для поиска здоровья, патронов, отступления или выполнения логикой с отрядом и т.д. и т.п.

BehTacticalMonitor = setmetatable({}, { __index = CMBAction })
BehTacticalMonitor.__index = BehTacticalMonitor

function BehTacticalMonitor:New()
    local b = CMBAction.New(self, "TacticalMonitor")
    return b
end

function BehTacticalMonitor:InitialContainedAction(bot)
    return BehScenarioMonitor:New()
end

function BehTacticalMonitor:OnStart(bot, prior)
    return self:Continue()
end

-- Вызывается после ScenarioMonitor и выше
-- Если BehTacticalMonitor возвращает SuspendFor то ScenarioMonitor и всё что внутри него
-- ПАУЗИРУЮТСЯ до завершения нового действия!
function BehTacticalMonitor:Update(bot, dt)
	
    -- ── Патроны закончились ────────────
    if bot.m_ammo <= 0 then
		if (bot.m_flagAggressive) then
			return self:SuspendFor(BehReload:New(), "Out of ammo - reloading")
		else
			return self:SuspendFor(BehRetreatToReload:New(), "Out of ammo - retreating to reload")
		end
    end

    -- ── Таймер укрытия после урона ────────────────────────────────
	-- Таймер отступления после получения урона
	-- TODO: Добавить новый ShouldRetreatAfterDamage вместо m_canRetreatAfterDamage?
    if (!bot.m_flagAggressive && bot.m_coverAt && CurTime() >= bot.m_coverAt && bot.m_canRetreatAfterDamage) then
        bot.m_coverAt = nil
        --return self:SuspendFor(BehRetreat:New(false, true), "Taking cover after damage")
		
		local deepAction = bot.m_Behavior:DeepActive()
		
		-- Не отступаем после получение урона если мы преследуем врага (не видим его или вышел за пределы выстрела)
		if (deepAction && deepAction:Name() != "ChaseThreat" && deepAction:Name() != "GetThreat") then
			return self:SuspendFor(BehRetreatToCover:New(), "Taking cover after damage")
		end
    end
	
	local shouldRetreat = bot.m_Intention:ShouldRetreat(CMBAction.ANSWER_UNDEFINED)
	
	-- Агрессивные никогда не отступают, только в особых случаях выше
	if (bot.m_flagAggressive) then
		shouldRetreat = CMBAction.ANSWER_NO
	end
	
	if (shouldRetreat == CMBAction.ANSWER_YES) then
		--return self:SuspendFor(BehRetreat:New(false, true), "Backing off")
		return self:SuspendFor(BehRetreatToCover:New(), "Backing off")
	end

    -- ── Численное превосходство противника ───────────────────────
	-- TODO: Доделать
	-- Получает ответ только в этом действии: BehTacticalMonitor, остальные ответы в стеке оно игнорирует
    -- local shouldRetreat = bot.m_Behavior:QueryAnswer("ShouldRetreat", CMBAction.ANSWER_NO)
    -- if (shouldRetreat == CMBAction.ANSWER_YES) then
        -- return self:SuspendFor(BehRetreat:New(false), "Outnumbered - retreating")
    -- end

    return self:Continue()
end

function BehTacticalMonitor:ShouldHurry(bot)
    -- if bot.m_ammo <= math.floor(MAG_SIZE * 0.25) then
        -- return CMBAction.ANSWER_YES  -- мало патронов
    -- end
    return CMBAction.ANSWER_UNDEFINED
end

-- ── BehScenarioMonitor ───────────────────────────────────────────────
-- Сценарный монитор, далее в дочернее поведение выбирает начальное поведение исходя из роли
-- Может прерываться для сценарных событий

BehScenarioMonitor = setmetatable({}, { __index = CMBAction })
BehScenarioMonitor.__index = BehScenarioMonitor

function BehScenarioMonitor:New()
    local b = CMBAction.New(self, "ScenarioMonitor")
    b.m_nextFormationWait = 0 -- кулдаун чтобы не срабатывать каждый раз
	b.m_nextCheck = 0
    return b
end

-- Выбираем дочернее действие с главной логикой
function BehScenarioMonitor:InitialContainedAction(bot)
	
	if (bot.m_isSniper) then
		return BehSniperLurk:New()
	end
	
	if (bot.m_isRobotEngineer) then
		return BehMvMEngineerIdle:New()
	end
	
    if CMasterBotSquadManager:IsInSquad(bot) then
        if CMasterBotSquadManager:IsLeader(bot) then
            return BehELOF:New()
        else
            --return BehEscortSquadLeader:New(BehELOF:New())
        end
    end
    return BehELOF:New()
end

function BehScenarioMonitor:OnStart(bot, prior)
	self.m_hearedTime = 0
	self.m_checkGrenade = 0
    return self:Continue()
end

function BehScenarioMonitor:Update(bot, dt)
	if (CMasterBotSquadManager:IsInSquad(bot) && CMasterBotSquadManager:IsLeader(bot) && CMasterBotSquadManager:ShouldLeaderWaitForFormation(CMasterBotSquadManager:Get(bot.m_squadId))) then
		return self:SuspendFor(BehWaitForFormation:New(2.0), "Waiting for squad formation")
	end
	
	if (bot.m_canTalkTo && bot.m_Vision:GetPrimaryKnownThreat() == nil && CurTime() > self.m_nextCheck) then
		self.m_nextCheck = CurTime() + 0.5
		local hEnts = ents.FindInSphere(bot:GetPos(), 75.0)
		
		for _, v in ipairs(hEnts) do
			-- Делаем проверку на дистанцию, потому-что FindInSphere с 75 недостаточно + DistToSqr это не точная проверка дистнации
			-- В противом случае бот будет спамить переходами действий туда сюда
			if (v:IsPlayer() && bot:GetPos():DistToSqr(v:GetPos()) < 75.0 * 75.0) then
				return self:SuspendFor(BehTalkToPlayer:New(v), "Found a nearby player to talk")
			end
		end
	end
	
	-- if (CurTime() > self.m_checkGrenade && !self.m_realizedGrenade) then
		-- self.m_checkGrenade = CurTime() + 0.2
		
		-- local bestDist = math.huge
		-- local bestGrenade = NULL
		
		-- local hEnts = ents.FindInSphere(bot:GetPos(), 700)
		-- local n = #hEnts
		-- for i = 1, n do
			-- local ent = hEnts[i]
			-- if (ent:GetClass() == "grenade") then
				-- local dSqr = bot:GetPos():DistToSqr(ent:GetPos())
				-- if (dSqr < bestDist) then
					-- bestDist = dSqr
					-- bestGrenade = ent
				-- end
			-- end
		-- end
		
		-- if (IsValid(bestGrenade)) then
			-- self.m_grenade = bestGrenade
			-- self.m_realizedGrenade = CurTime()
		-- end
	-- end
	
	-- if (self.m_realizedGrenade) then
		-- if (CurTime() - self.m_realizedGrenade > BehEscapeGrenade.GetGrenadeReactionTime(bot)) then
			-- self.m_realizedGrenade = nil
			
			-- return self:SuspendFor(BehEscapeGrenade:New(self.m_grenade), "Escaping grenade!")
		-- end
	-- end

    return self:Continue()
end

function BehScenarioMonitor:OnCommandApproach(bot, pos)
	local curAction = bot.m_Behavior:DeepActive()
	
	if (curAction && curAction:Name() == "MoveToPoint") then
		curAction.m_dest = pos
	else
		return self:TrySuspendFor(BehMoveToPoint:New(pos), CMBAction.RESULT_IMPORTANT, "Received command to approach position")
	end
	
	return self:TryContinue()
end

function BehScenarioMonitor:OnCommandApproachEnt(bot, ent)
	
	local curAction = bot.m_Behavior:DeepActive()
	
	if (curAction && curAction:Name() == "Escort") then
		curAction.m_subject = subject
	else
		return self:TrySuspendFor(BehEscort:New(ent), CMBAction.RESULT_IMPORTANT, "Received command to escort target")
	end
	
	return self:TryContinue()
end

function BehScenarioMonitor:OnCommandString(bot, command)
	if (command == "escort squad") then
		local members = CMasterBotSquadManager:GetBotSquadMembers(bot)
		for _, m in ipairs(members) do
			if (!m.m_bIsLeader) then
				m:CommandString("escort squad leader")
			end
		end
	elseif (command == "escort squad leader") then
		return self:TrySuspendFor(BehEscortSquadLeader:New(), CMBAction.RESULT_IMPORTANT, "Received command from leader to escort him")
	end
	
	return self:TryContinue()
end

function BehScenarioMonitor:OnInjured(bot, info)
	return self:TryContinue()
end

function BehScenarioMonitor:OnCommand(bot, command, data)
	local curAction = bot.m_Behavior:DeepActive()

	if (command == "open door") then
		if (curAction && curAction:Name() == "OpenDoor") then
			curAction.m_door = data.door
			curAction.m_button = data.button
		else
			return self:TrySuspendFor(BehOpenDoor:New(data.door, data.button), CMBAction.RESULT_IMPORTANT, "Received command to open door")
		end
	end
	
	return self:TryContinue()
end