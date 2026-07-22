CMasterBotLocomotion = {}
CMasterBotLocomotion.__index = CMasterBotLocomotion

local OBSTACLE_CHECK_DIST = 200 --120
local OBSTACLE_PUSH_FORE = 180000
local STEER_DURATION = 0.6
local REPATH_INTERVAL = 0.15
local STUCK_PUSH_THRESHOLD = 0.4
local AVOIDANCE_RAYS = 5
local AVOIDANCE_RAYS_SPREAD = 90
local HULL_MINS = Vector(-16, -16, 0)
local HULL_MAXS = Vector(16, 16, 72)
--local ARRIVAL_TOLERANCE = 55
local ARRIVAL_TOLERANCE = 30
local OBSTACLE_PUSH_FORCE = 500

function CMasterBotLocomotion.New(bot, cls)
	cls = cls or CMasterBotLocomotion
	
	local b = setmetatable({}, cls)
	b.m_bot = bot
	
	b.m_runSpeed = 160
	b.m_walkSpeed = 100
	
	b.m_controlSpeedByButtons = false
	
	-- Навигация для ThinkMove
	b.m_navDest = nil
	b.m_navSpeed = 150
	b.m_navStopped = false
	b.m_navPath = nil
	b.m_navRepath = 0
	
	-- Страф для ThinkMove
	b.m_strafeDest = 0
	b.m_strafeEnemy = nil
	b.m_strafeDest = nil
	
	-- Состояние обхода prop_physics
	b.m_avoid = {
		active = false,
		endTime = 0,
		direction = nil,
		stuckSince = nil,
		lastObstacle = nil,
	}
	return b
end

function CMasterBotLocomotion:SetWalkSpeed(speed)
	self.m_walkSpeed = speed
end

function CMasterBotLocomotion:SetRunSpeed(speed)
	self.m_runSpeed = speed
end

function CMasterBotLocomotion:GetWalkSpeed()
	return self.m_walkSpeed
end

function CMasterBotLocomotion:GetRunSpeed()
	return self.m_runSpeed
end

function CMasterBotLocomotion:SetControlSpeedByButtons(flag)
	self.m_controlSpeedByButtons = flag
end

function CMasterBotLocomotion:Compute(pos, speed)
	return self:NavMove(pos, speed)
end

function CMasterBotLocomotion:NavMove(dest, speed)
	-- Перестраивать путь только при смене цели
    local changed = !self.m_navDest or (self.m_navDest - dest):Length() > 20

    self.m_navDest    = dest
    self.m_navSpeed   = speed or 150
    self.m_navStopped = false
    self.m_strafeDir  = 0  -- NavGoTo сбрасывает страф
    self.m_strafeDest = nil

    if changed then
        self.m_navPath   = nil  -- принудительный repath на следующем тике
        self.m_navRepath = 0
    end
end

function CMasterBotLocomotion:Stop()
	self.m_navDest = nil
	self.m_navStopped = true
	self.m_navPath = nil
	self.m_strafeDir = nil
	self.m_bot.loco:SetDesiredSpeed(0)
end

function CMasterBotLocomotion:NavClear()
	self.m_navDest = nil
	self.m_navPath    = nil
    self.m_navStopped = false   -- ВАЖНО: иначе бот зависает после OnResume
    self.m_strafeDir  = 0
end

local PATH_RATE = 0.25

function CMasterBotLocomotion:Upkeep()
	if (self.m_navStopped) then
		self.m_bot.loco:SetDesiredSpeed(0)
		return
	end
	
	-- Если true, то мы контролируем скорость с помощью кнопок в m_Body, а именно через shift, а не через NavMove(..., 150)
	if (self.m_controlSpeedByButtons) then
		if (self.m_bot.m_Body.m_btnShift) then
			self.m_navSpeed = self.m_runSpeed
		else
			self.m_navSpeed = self.m_walkSpeed
		end
	end
	
	-- Обход препятствий (перехватывает управление если есть проп)
    local avoidDir = self:UpdateObstacleAvoidance()
    if avoidDir then
        self.m_bot.loco:SetDesiredSpeed(self.m_navSpeed or 150)
        local target = self.m_bot:GetPos() + avoidDir * 80
        self.m_bot.loco:FaceTowards(target)
        self.m_bot.loco:Approach(target, 1.0)
        return
    end
	
    -- Навигация к фиксированной точке
    if self.m_navDest then
		-- Когда мастербот почти прибывает, он очень дерганно или очень медленно идет до конечной точки
		-- Поэтому мы используем Approach вместо Compute
		-- FIXME: Иногда может ходить туда сюда когда прибывает на точку
        if ((self.m_bot:GetPos() - self.m_navDest):Length() < ARRIVAL_TOLERANCE) then
			self.m_bot.loco:SetDesiredSpeed(self.m_navSpeed or 100)
			self.m_bot.loco:Approach(self.m_navDest, 1.0)
			
			local goalDist = self.m_navPath and self.m_navPath:GetGoalTolerance() or 5
			
			--print(goalDist)
			if (!goalDist || goalDist < 5) then
				goalDist = 5
			end
			
			if ((self.m_bot:GetPos() - self.m_navDest):Length() <= goalDist) then
				self.m_bot.m_Behavior:ProcessEvent("OnMoveToSuccess", self.m_navPath)
				self.m_navPath = nil
				self.m_navDest = nil
				self.m_navStopped = true
				self.m_bot.loco:SetDesiredSpeed(0)
				return
			end
			
			return
        end

        self.m_bot.loco:SetDesiredSpeed(self.m_navSpeed or 150)

        -- Создаем путь только если оно невалидное
		-- Если создавать путь постоянно, то мастербот будет передвигаться дерганно, особенно заметно в мультиплеере
		local needRepath = !self.m_navPath || !self.m_navPath:IsValid()

        if needRepath then
            local p = Path("Follow")
            p:SetMinLookAheadDistance(300)
			p:SetGoalTolerance(5)
            local isValidPath = p:Compute(self.m_bot, self.m_navDest)
            self.m_navPath   = p
            
			if (!isValidPath) then
				self.m_bot.m_Behavior:ProcessEvent("OnMoveToFailure", self.m_navPath, 0)
			end
        end
		
		-- Обновляем позицию пути по таймеру
		if (CurTime() > self.m_navRepath && self.m_navPath && self.m_navPath:IsValid()) then
			local isValidPath = self.m_navPath:Compute(self.m_bot, self.m_navDest)
			self.m_navRepath = CurTime() + PATH_RATE
			
			if (!isValidPath) then
				self.m_bot.m_Behavior:ProcessEvent("OnMoveToFailure", self.m_navPath, 0)
			end
		end

        if self.m_navPath && self.m_navPath:IsValid() then
            self.m_navPath:Update(self.m_bot)
        end
		
		if CMasterBot.IsDebug() then
			if (self.m_bot.SetDebugGroundMotion) then
				self.m_bot:SetDebugGroundMotion(self.m_bot.loco:GetGroundMotionVector())
			end
			
			if (self.m_bot.SetDebugMotion) then
				local vel = self.m_bot:GetVelocity()
				local speed = vel:Length()
				local motionVector = Vector(1, 0, 0)
				
				if (speed > 10.0) then
					motionVector = vel / speed
				end
				
				self.m_bot:SetDebugMotion(motionVector)
			end
		end

    -- Страф, идём к фиксированной мировой точке
    elseif (self.m_strafeDir != 0 && self.m_strafeDest) then
        self.m_bot.loco:SetDesiredSpeed(self.m_navSpeed or 150)
		-- m_strafeDest точка страфа, котораая вычисленная один раз, например в BehELOF DecideStrafe
		-- Это нужно чтобы мастербот не дергался в мультиплеере
        -- Когда бот достигает точки (или приходит следующий DecideStrafe) то цикл сбрасывается
        self.m_bot.loco:Approach(self.m_strafeDest, 1.0)

    -- Нет ни цели ни страфа, стоим
    else
        self.m_bot.loco:SetDesiredSpeed(0)
    end
end

function CMasterBotLocomotion:IsArrived(threshold)
	if (!self.m_navDest) then return true end
	
	local newThreshold = 5
	
	if (self.m_navPath) then
		newThreshold = self.m_navPath:GetGoalTolerance()
		if (newThreshold < 3) then
			newThreshold = 5
		end
	end
	
	if (threshold) then
		newThreshold = threshold
	end
	
	return (self.m_bot:GetPos() - self.m_navDest):Length()  <= newThreshold
end

-- Система обхода prop_physics

-- Обнаружение динамического препятствия впереди.
-- Возвращает (Entity или nil, Vector направления уклонения или nil)
function CMasterBotLocomotion:DetectObstacle()
    local pos     = self.m_bot:GetPos()
    local forward = self.m_bot:GetForward()
	-- Отправляем из центра модели
    local eyePos  = pos + Vector(0, 0, 40)
	--local eyePos = self.m_Body:GetEyePosition()

    -- Центральный луч (TraceHull = учитывает габариты бота)
    local trC = util.TraceHull({
        start  = eyePos,
        endpos = eyePos + forward * OBSTACLE_CHECK_DIST,
        mins   = HULL_MINS * 0.5,
        maxs   = HULL_MAXS * 0.5,
        filter = self,
        mask   = MASK_SOLID,
    })

    local hitProp = nil
	-- Пропы без столкновения игнорируются
    if (trC.Hit && IsValid(trC.Entity) && trC.Entity:GetClass() == "prop_physics" && trC.Entity:GetCollisionGroup() != COLLISION_GROUP_WORLD) then
        hitProp = trC.Entity
    end

    -- Веер боковых лучей, ищем свободное направление
    local bestDir  = nil
    local bestDist = -1
    local half     = AVOIDANCE_RAYS_SPREAD / 2

    for i = 0, AVOIDANCE_RAYS - 1 do
        local frac     = (AVOIDANCE_RAYS > 1) && (i / (AVOIDANCE_RAYS - 1)) || 0.5
        local angleDeg = -half + frac * AVOIDANCE_RAYS_SPREAD
        local rotated  = forward:Angle()
        rotated.y      = rotated.y + angleDeg
        local dir      = rotated:Forward()

        if (math.abs(angleDeg) > 10) then   -- пропускаем центр
            local tr   = util.TraceLine({
                start  = eyePos,
                endpos = eyePos + dir * OBSTACLE_CHECK_DIST * 1.5,
                filter = self,
                mask   = MASK_SOLID,
            })
            local dist = tr.Hit && tr.Fraction * OBSTACLE_CHECK_DIST * 1.5 || OBSTACLE_CHECK_DIST * 1.5
            if (dist > bestDist) then bestDist = dist; bestDir = dir end
        end
    end

    return hitProp, bestDir
end

-- Выталкиваем проп физической силой
function CMasterBotLocomotion:PushObstacle(prop)
    if !IsValid(prop) then return end
    local phys = prop:GetPhysicsObject()
    if !IsValid(phys) then return end
    local toProb = (prop:GetPos() - self.m_bot:GetPos()):GetNormalized()
    phys:ApplyForceCenter((toProb + Vector(0, 0, 0.3)):GetNormalized() * OBSTACLE_PUSH_FORCE)
    phys:Wake()
end

-- Вызывается из ThinkMove каждый тик.
-- Возвращает Vector направления уклонения, если нужно обходить, иначе nil
function CMasterBotLocomotion:UpdateObstacleAvoidance()
    -- Не проверяем в режиме остановки или страфа
    if self.m_navStopped then return nil end
    if not self.m_navDest then return nil end
    if self.m_bot.loco:GetVelocity():Length() < 10 then return nil end

    local av = self.m_avoid

    -- Продолжаем активное уклонение
    if (av.active) then
        if (CurTime() < av.endTime) then
            return av.direction
        end
        -- Уклонение закончилось, перестраиваем путь
        av.active    = false
        self.m_navPath   = nil
        self.m_navRepath = 0
    end

    local hitProp, bestDir = self:DetectObstacle()

    if hitProp then
        -- Отслеживаем застревание
        if not av.stuckSince then
            av.stuckSince = CurTime()
        elseif CurTime() - av.stuckSince > STUCK_PUSH_THRESHOLD then
            self:PushObstacle(hitProp)
            av.stuckSince = nil
        end

        -- Начинаем уклонение
        if bestDir then
            av.active       = true
            av.endTime      = CurTime() + STEER_DURATION
            av.direction    = bestDir
            av.lastObstacle = hitProp
            -- Сброс пути — после уклонения перестроим с нуля
            self.m_navPath   = nil
            self.m_navRepath = CurTime() + REPATH_INTERVAL
            return bestDir
        end
    else
        av.stuckSince = nil
    end

    return nil
end