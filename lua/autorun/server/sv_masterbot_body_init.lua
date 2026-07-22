local function AngleNormalize(angle)
    angle = angle % 360.0
    if angle > 180  then angle = angle - 360 end
    if angle < -180 then angle = angle + 360 end
    return angle
end

local function AngleDiff(destAngle, srcAngle)
    return AngleNormalize(destAngle - srcAngle)
end

local function ApproachAngle(target, value, speed)
    local delta = AngleDiff(target, value)
    if speed < 0 then speed = -speed end
    if     delta >  speed then value = value + speed
    elseif delta < -speed then value = value - speed
    else                       value = target end
    return AngleNormalize(value)
end

local function RemapVal(val, A, B, C, D)
    if A == B then return val >= B and D or C end
    return C + (D - C) * (val - A) / (B - A)
end

local NB_HEAD_AIM_STEADY_MAX_RATE = 100.0   -- nb_head_aim_steady_max_rate
local NB_HEAD_AIM_SETTLE_DURATION  = 0.3    -- nb_head_aim_settle_duration
local NB_HEAD_AIM_RESETTLE_ANGLE   = 100.0  -- nb_head_aim_resettle_angle
local NB_HEAD_AIM_RESETTLE_TIME    = 0.3    -- nb_head_aim_resettle_time

local function GetMaxHeadAngularVelocity() return 1000.0 end  -- nb_saccade_speed
local function GetHeadAimSubjectLeadTime() return 0.0    end
local function GetHeadAimTrackingInterval() return 0.05  end

CMasterBotBody = {}
CMasterBotBody.__index = CMasterBotBody

-- Приоритеты прицеливания
CMasterBotBody.BORING      = 0
CMasterBotBody.INTERESTING = 1
CMasterBotBody.IMPORTANT   = 2
CMasterBotBody.CRITICAL    = 3
CMasterBotBody.MANDATORY   = 4

CMasterBotBody.DENIED = 0
CMasterBotBody.INTERRUPTED = 1
CMasterBotBody.FAILED = 2

function CMasterBotBody.New(bot, cls)
	cls = cls or CMasterBotBody
	
    local self = setmetatable({}, cls)
    self.m_bot = bot
    self:Reset()
	self:InitializeVKeyboard()
    return self
end

function CMasterBotBody:Reset()
    self.m_lookAtPos       = Vector(0, 0, 0)
    self.m_lookAtSubject   = nil
    self.m_lookAtVelocity  = Vector(0, 0, 0)
    self.m_lookAtPriority  = CMasterBotBody.BORING

    self.m_isSightedIn     = false
    self.m_hasBeenSightedIn = false

    self.m_lookAtReplyWhenAimed = nil

    self.m_priorAngles = Angle(0, 0, 0)

    self.m_headSteadyStart = -1
    self.m_lookAtExpireAt = -1
    self.m_lookAtDurationStart = 0
    self.m_anchorRepositionExpire = -1
    self.m_anchorForward = Vector(0, 0, 0)
    self.m_lookAtTrackingExpire = -1
	
	self.m_angCurrentAngles = Angle(0, 0, 0)
	self.m_vecEyePos = vector_zero

	-- Кеш анимаций
	self.m_seqCache = {}
end

function CMasterBotBody:SetEyePosition(vec)
	self.m_vecEyePos = vec
end

function CMasterBotBody:GetEyePosition()
	if (self.m_vecEyePos && self.m_vecEyePos != vector_zero) then return self.m_bot:EyePos() + self.m_vecEyePos end
    return self.m_bot:EyePos()
end

-- Вектор в направлении взгляда (из EyeAngles)
function CMasterBotBody:GetViewVector()
    return self.m_angCurrentAngles:Forward()
end

function CMasterBotBody:GetHeadAimTrackingInterval()
	
	if (self.m_bot.m_iBotSkill) then
		local skill = self.m_bot.m_iBotSkill
		if (skill == 0) then return 1.0
		elseif (skill == 1) then return 0.25
		elseif (skill == 2) then return 0.1
		elseif (skill == 2) then return 0.05 end
	end
	
	return 0.05
end

-- Возвращает true, если камера бота не делает резких поворотов
function CMasterBotBody:IsHeadSteady()
    return self.m_headSteadyStart >= 0
end

-- Возвращает сколько секунд камера нацелилась
function CMasterBotBody:GetHeadSteadyDuration()
    if self.m_headSteadyStart < 0 then return 0.0 end
    return CurTime() - self.m_headSteadyStart
end

function CMasterBotBody:IsHeadAimingOnTarget()
	return self.m_isSightedIn
end

-- Максимальная угловая скорость поворота головы (градус/сек)
function CMasterBotBody:GetMaxHeadAngularVelocity()
    return GetMaxHeadAngularVelocity()
end

function CMasterBotBody:GetHeadAimSubjectLeadTime()
	return 0
end

-- Вызвать один раз при создании бота (или после смены модели)
-- Заполняет m_seqCache для O(1) доступа вместо LookupSequence каждый тик
function CMasterBotBody:BuildSequenceCache(seqNames)
	local bot = self.m_bot
	if not IsValid(bot) then return end
	self.m_seqCache = {}
	for _, name in ipairs(seqNames) do
		local idx = bot:LookupSequence(name)
		if idx and idx >= 0 then
			self.m_seqCache[name] = idx
		end
	end
end

-- O(1) доступ к sequence ID. Fallback на LookupSequence если не кеширован
function CMasterBotBody:GetCachedSequence(name)
	local cached = self.m_seqCache[name]
	if cached then return cached end
	-- Fallback + автодобавление в кеш
	local idx = self.m_bot:LookupSequence(name)
	if idx and idx >= 0 then
		self.m_seqCache[name] = idx
		return idx
	end
	return nil
end

-- Главный метод, вызывать каждый тик для плавной и точной наводки к цели
function CMasterBotBody:Upkeep()
    local bot = self.m_bot
    if not IsValid(bot) then return end

	local deltaT = FrameTime()
    if deltaT < 0.00001 then return end

    -- Текущие углы взгляда
    local eyeAng   = self.m_angCurrentAngles
	local currentAngles = eyeAng

	-- Определяем, нацелилась ли камера (не делает резких поворотов)
    local isSteady = true

    local pitchRate = math.abs(AngleDiff(currentAngles.p, self.m_priorAngles.p))
    if pitchRate > NB_HEAD_AIM_STEADY_MAX_RATE * deltaT then
        isSteady = false
    else
        local yawRate = math.abs(AngleDiff(currentAngles.y, self.m_priorAngles.y))
        if yawRate > NB_HEAD_AIM_STEADY_MAX_RATE * deltaT then
            isSteady = false
        end
    end

    if isSteady then
        if self.m_headSteadyStart < 0 then
            -- Нацелились - запускаем таймер
            self.m_headSteadyStart = CurTime()
        end
    else
        -- Камера двигается - сбрасываем таймер
        self.m_headSteadyStart = -1
    end

    self.m_priorAngles = currentAngles

	-- Если текущий look at истёк и камера уже навелась, ничего не делаем
    local lookAtExpired = (self.m_lookAtExpireAt < 0) or (CurTime() >= self.m_lookAtExpireAt)
    if self.m_hasBeenSightedIn and lookAtExpired then
        return
    end

	-- Ограничение диапазона поворота (имитация ограниченного коврика мыши)
	local forward = currentAngles:Forward()

	-- FIXME: Действительно это нужно? m_anchorForward всегда стоит на нулевом векторе, ничего ее не изменяет. dotAnchor всегда 0, deltaAngle всегда 90
    -- Угол между текущим направлением и опорным (anchor)
    local dotAnchor   = math.Clamp(forward:Dot(self.m_anchorForward), -1.0, 1.0)
    local deltaAngle  = math.deg(math.acos(dotAnchor))

    if deltaAngle > NB_HEAD_AIM_RESETTLE_ANGLE then
		-- Перецентрируем виртуальную мышь, делаем паузу
        local pause = math.Rand(0.9, 1.1) * NB_HEAD_AIM_RESETTLE_TIME
        self.m_anchorRepositionExpire = CurTime() + pause
        self.m_anchorForward = Vector(forward.x, forward.y, forward.z)
        return
    end

    -- Ждём, пока пауза перецентровки не закончится
	-- FIXME: В этот момент m_isSightedIn для IsHeadAimingOnTarget не обновляется
    if self.m_anchorRepositionExpire >= 0 and CurTime() < self.m_anchorRepositionExpire then
        return
    end
    self.m_anchorRepositionExpire = -1  -- пауза окончена

	-- Трекинг субъекта (если есть сущность-цель а не вектор позиции)
    local subject = self.m_lookAtSubject
    if IsValid(subject) then
        local trackingExpired = (self.m_lookAtTrackingExpire < 0) or (CurTime() >= self.m_lookAtTrackingExpire)
        if trackingExpired then
            -- Обновляем желаемую позицию и скорость слежения
			-- По умолчанию мы целимся в центр модели
            local desiredPos = subject:WorldSpaceCenter()
			
			-- Если поведение возращает новую точку прицеливания, выбираем её
			if (bot.m_Intention) then
				local newPos = bot.m_Intention:SelectTargetPoint(subject)
				if (newPos) then
					desiredPos = newPos
				end
			end
			
			desiredPos = desiredPos + self:GetHeadAimSubjectLeadTime() * subject:GetVelocity()

            local errorVec = desiredPos - self.m_lookAtPos
            local errLen   = errorVec:Length()
            if errLen > 0 then
                errorVec:Normalize()
            end

            local trackInterval = self:GetHeadAimTrackingInterval()
            if trackInterval < deltaT then
                trackInterval = deltaT
            end

            local errorVel = errLen / trackInterval
            local subjVel  = subject:GetVelocity()

            self.m_lookAtVelocity = errorVec * errorVel + subjVel

            self.m_lookAtTrackingExpire = CurTime() + math.Rand(0.8, 1.2) * trackInterval
        end

        -- Двигаем точку прицеливания по скорости
        self.m_lookAtPos = self.m_lookAtPos + self.m_lookAtVelocity * deltaT
    end

    -- Вычисляем желаемые углы взгляда
    local eyePos = self:GetEyePosition()
    local toTarget = self.m_lookAtPos - eyePos
    toTarget:Normalize()

    local desiredAngles = toTarget:Angle()

    -- Проверяем, наведена ли голова на цель
    local onTargetTolerance = 0.98
    local dot = forward:Dot(toTarget)

    if dot > onTargetTolerance then
        self.m_isSightedIn = true
        if not self.m_hasBeenSightedIn then
            self.m_hasBeenSightedIn = true
            -- Вызываем callback успеха один раз
            if self.m_lookAtReplyWhenAimed then
                local reply = self.m_lookAtReplyWhenAimed
                self.m_lookAtReplyWhenAimed = nil
                if reply.OnSuccess then reply.OnSuccess(bot) end
            end
			
			if CMasterBot.IsDebug() then
				--CMasterBot.DebugConColorMsg(2, Color(255, 100, 0, 255), "%3.2f: %s Look At SIGHTED IN\n", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot))
			end
        end
    else
        self.m_isSightedIn = false
    end

    -- Плавный поворот головы: скорость пропорциональна углу до цели
    local approachRate = self:GetMaxHeadAngularVelocity()

    -- Замедляемся при приближении к цели
    local easeOut = 0.7
    if dot > easeOut then
        local t = RemapVal(dot, easeOut, 1.0, 1.0, 0.02)
        approachRate = approachRate * math.sin(math.pi * 0.5 * t)
    end

    -- Плавный разгон в начале нового look-at
    local easeInTime = 0.25
    local durationElapsed = CurTime() - self.m_lookAtDurationStart
    if durationElapsed < easeInTime then
        approachRate = approachRate * (durationElapsed / easeInTime)
    end

    -- Рассчитываем новые углы (yaw быстрее ака x, pitch ака y - вдвое медленнее)
    local newYaw   = ApproachAngle(desiredAngles.y, currentAngles.y, approachRate * deltaT)
    local newPitch = ApproachAngle(desiredAngles.p, currentAngles.p, 0.5 * approachRate * deltaT)

    local finalAngle = Angle(
        AngleNormalize(newPitch),
        AngleNormalize(newYaw),
        0
    )

	self.m_angCurrentAngles = finalAngle
	
	if CMasterBot.IsDebug() then
		local thickness = 3.0
		local r = 0
		local g = 0
		
		if (isSteady) then
			thickness = 1.0 --2.0
		end
		
		if (self.m_isSightedIn) then
			r = 255
		end
		
		if (IsValid(subject)) then
			g = 255
		end
		
		if (self.m_bot.SetDebugLaserThickness) then
			self.m_bot:SetDebugLaserThickness(thickness)
		end
		if (self.m_bot.SetDebugLaserColorR) then
			self.m_bot:SetDebugLaserColorR(r)
		end
		if (self.m_bot.SetDebugLaserColorG) then
			self.m_bot:SetDebugLaserColorG(g)
		end
		if (self.m_bot.SetDebugLaserColorB) then
			self.m_bot:SetDebugLaserColorB(255)
		end
		if (self.m_bot.SetDebugLaserEndPos) then
			self.m_bot:SetDebugLaserEndPos(self.m_lookAtPos)
		end
		if (self.m_bot.SetDebugLaserStartPos) then
			self.m_bot:SetDebugLaserStartPos(self:GetEyePosition())
		end
	end
end

-- Навестись на точку lookAtPos
-- lookAtPos (Vector) - мировая точка прицеливания
-- priority (int) - приоритет, более высокий перекроет - CMasterBotBody.BORING / INTERESTING / IMPORTANT / CRITICAL
-- duration (float) - сколько секунд удерживать прицел (0 = 0.1 сек)
-- reason (string) - причина почему мы наводимся для отладки
-- reply (table|nil) - { OnSuccess = function(bot), OnFail = function(bot, reason) }
function CMasterBotBody:AimHeadTowardsPos(lookAtPos, priority, duration, reason, reply)
    if duration <= 0 then duration = 0.1 end

    -- Та же приоритетность — ждём пока голова не устоится
    if self.m_lookAtPriority == priority then
        if not self:IsHeadSteady() or self:GetHeadSteadyDuration() < NB_HEAD_AIM_SETTLE_DURATION then
			
			if CMasterBot.IsDebug() then
				if (!self.m_dbgAlerted) then
					self.m_dbgAlerted = true
					--CMasterBot.DebugConColorMsg(2, Color(255, 0, 0, 255), "%3.2f: %s Look At '%s' rejected - previous aim not %s\n", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), reason or "", self:IsHeadSteady() and "settled long enough" or "head-stready")
				end
			end
			
            if reply and reply.OnFail then reply.OnFail(self.m_bot, "DENIED") end
            return
        end
    end

    -- Если более высокий приоритет ещё не истёк - то отказываем
    local lookAtExpired = (self.m_lookAtExpireAt < 0) or (CurTime() >= self.m_lookAtExpireAt)
    if self.m_lookAtPriority > priority and not lookAtExpired then
		
		if CMasterBot.IsDebug() then
			if (!self.m_dbgAlertedPriority) then
				self.m_dbgAlertedPriority = true
				--CMasterBot.DebugConColorMsg(2, Color(255, 0, 0, 255), "%3.2f: %s Look At '%s' rejected - higher priority aim in progress\n", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), reason or "")
			end
		end
		
        if reply and reply.OnFail then reply.OnFail(self.m_bot, "DENIED") end
        return
    end

    -- Прерываем предыдущий незавершённый aim-callback
    if self.m_lookAtReplyWhenAimed then
        local old = self.m_lookAtReplyWhenAimed
        self.m_lookAtReplyWhenAimed = nil
        if old.OnFail then old.OnFail(self.m_bot, "INTERRUPTED") end
    end

    self.m_lookAtReplyWhenAimed = reply
    self.m_lookAtExpireAt       = CurTime() + duration

    -- Та же точка - просто обновляем приоритет, ничего не сбрасываем
    local epsilon = 1.0
    if (self.m_lookAtPos - lookAtPos):LengthSqr() < epsilon * epsilon then
        self.m_lookAtPriority = priority
        return
    end

    -- Новая точка прицеливания
    self.m_lookAtPos        = Vector(lookAtPos.x, lookAtPos.y, lookAtPos.z)
    self.m_lookAtSubject    = nil
    self.m_lookAtPriority   = priority
    self.m_lookAtDurationStart = CurTime()
    self.m_hasBeenSightedIn = false
	
	if CMasterBot.IsDebug() then
		self.m_dbgAlerted = false
		self.m_dbgAlertedPriority = false
		
		local priName = "BORING"
		if (priority == 1) then
			priName = "INTERESTING"
		elseif (priority == 2) then
			priName = "IMPORTANT"
		elseif (priority == 3) then
			priName = "CRITICAL"
		elseif (priority == 4) then
			priName = "MANDATORY"
		end
		
		--CMasterBot.DebugConColorMsg(2, Color(255, 100, 0, 255), "%3.2f: %s Look At ( %g, %g, %g ) for %3.2f s, Pri = %s, Reason = %s\n", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), lookAtPos.x, lookAtPos.y, lookAtPos.z, duration, priName, reason or "")
		if (self.m_bot.GetDebugTextLookAt) then
			if (!self.m_dbgTime) then self.m_dbgTime = 0 end
			
			if (!self.m_dbgReason) then self.m_dbgReason = "" end
			
			if (self.m_dbgTime > CurTime() && self.m_dbgReason != reason) then self.m_dbgTime = 0 end
			
			if (CurTime() > self.m_dbgTime) then
				self.m_dbgTime = CurTime() + 0.2 -- 0.2
				local last = self.m_bot:GetDebugTextLookAt()
				local newMsg = string.format("Look At ( %g, %g, %g ) for %3.2f s, Pri = %s, Reason = %s\n", lookAtPos.x, lookAtPos.y, lookAtPos.z, duration, priName, reason or "")
				if (last != newMsg) then
					self.m_bot:SetDebugTextLookAt(newMsg)
				end
				
				self.m_dbgReason = reason
			end
		end
	end
end

-- Навестись на сущность с трекингом
-- subject (Entity) - цель
-- priority (int) - приоритет, более высокий перекроет - CMasterBotBody.BORING / INTERESTING / IMPORTANT / CRITICAL
-- duration (float) - сколько секунд удерживать прицел (0 = 0.1 сек)
-- reason (string) - причина почему мы наводимся для отладки
-- reply (table|nil) - { OnSuccess = function(bot), OnFail = function(bot, reason) }
function CMasterBotBody:AimHeadTowardsEnt(subject, priority, duration, reason, reply)
    if duration <= 0 then duration = 0.1 end
    if not IsValid(subject) then return end

    -- Та же приоритетность, ждём пока голова не будет делать резких движений
    if self.m_lookAtPriority == priority then
        if not self:IsHeadSteady() or self:GetHeadSteadyDuration() < NB_HEAD_AIM_SETTLE_DURATION then
			
			if CMasterBot.IsDebug() then
				if (!self.m_dbgAlerted) then
					self.m_dbgAlerted = true
					--CMasterBot.DebugConColorMsg(2, Color(255, 0, 0, 255), "%3.2f: %s Look At '%s' rejected - previous aim not %s\n", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), reason or "", self:IsHeadSteady() and "settled long enough" or "head-stready")
				end
			end
			
            if reply and reply.OnFail then reply.OnFail(self.m_bot, "DENIED") end
            return
        end
    end

    -- Если более высокий приоритет ещё не истёк - то отказываем
    local lookAtExpired = (self.m_lookAtExpireAt < 0) or (CurTime() >= self.m_lookAtExpireAt)
    if self.m_lookAtPriority > priority and not lookAtExpired then
		
		if CMasterBot.IsDebug() then
			if (!self.m_dbgAlertedPriority) then
				self.m_dbgAlertedPriority = true
				--CMasterBot.DebugConColorMsg(2, Color(255, 0, 0, 255), "%3.2f: %s Look At '%s' rejected - higher priority aim in progress\n", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), reason or "")
			end
		end
		
        if reply and reply.OnFail then reply.OnFail(self.m_bot, "DENIED") end
        return
    end

    -- Прерываем предыдущий незавершённый aim-callback
    if self.m_lookAtReplyWhenAimed then
        local old = self.m_lookAtReplyWhenAimed
        self.m_lookAtReplyWhenAimed = nil
        if old.OnFail then old.OnFail(self.m_bot, "INTERRUPTED") end
    end

    self.m_lookAtReplyWhenAimed = reply
    self.m_lookAtExpireAt       = CurTime() + duration

    -- Тот же субъект - просто обновляем приоритет
    if subject == self.m_lookAtSubject then
        self.m_lookAtPriority = priority
        return
    end

    -- Новый субъект
    self.m_lookAtSubject       = subject
    -- Инициализируем позицию, чтобы первый кадр трекинга не был нулевым
    self.m_lookAtPos           = subject:WorldSpaceCenter()
    self.m_lookAtPriority      = priority
    self.m_lookAtDurationStart = CurTime()
    self.m_hasBeenSightedIn    = false
    -- Форсируем немедленное обновление трекинга на следующем Upkeep
    self.m_lookAtTrackingExpire = -1
	
	if CMasterBot.IsDebug() then
		self.m_dbgAlerted = false
		self.m_dbgAlertedPriority = false
		
		local priName = "BORING"
		if (priority == 1) then
			priName = "INTERESTING"
		elseif (priority == 2) then
			priName = "IMPORTANT"
		elseif (priority == 3) then
			priName = "CRITICAL"
		elseif (priority == 4) then
			priName = "MANDATORY"
		end
		
		--CMasterBot.DebugConColorMsg(2, Color(255, 100, 0, 255), "%3.2f: %s Look At subject %s for %3.2f s, Pri = %s, Reason = %s\n", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), CMasterBot.FormatDebugIdentifier(subject), duration, priName, reason or "")
		if (self.m_bot.GetDebugTextLookAt) then
			if (!self.m_dbgTime) then self.m_dbgTime = 0 end
			
			if (!self.m_dbgReason) then self.m_dbgReason = "" end
			
			if (self.m_dbgTime > CurTime() && self.m_dbgReason != reason) then self.m_dbgTime = 0 end
			
			if (CurTime() > self.m_dbgTime) then
				self.m_dbgTime = CurTime() + 0.2
				local last = self.m_bot:GetDebugTextLookAt()
				local newMsg = string.format("Look At subject %s for %3.2f s, Pri = %s, Reason = %s\n", CMasterBot.FormatDebugIdentifier(subject), duration, priName, reason or "")
				if (last != newMsg) then
					self.m_bot:SetDebugTextLookAt(newMsg)
				end
				
				self.m_dbgReason = reason
			end
		end
	end
end

-- Виртуальная клавиатура для ботов
-- 

function CMasterBotBody:PressFireButton(timer)
	self.m_btnFire = true
	self.m_btnFireTime = CurTime() + (timer or 0.1)
end

function CMasterBotBody:ReleaseFireButton()
	self.m_btnFire = false
	self.m_btnFireTime = 0
end

function CMasterBotBody:PressAltFireButton(timer)
	self.m_btnAltFire = true
	self.m_btnAltFireTime = CurTime() + (timer or 0.1)
end

function CMasterBotBody:ReleaseAltFireButton()
	self.m_btnAltFire = false
	self.m_btnAltFireTime = 0
end

function CMasterBotBody:PressSpecialFireButton(timer)
	self.m_btnSpecialFire = true
	self.m_btnSpecialFireTime = CurTime() + (timer or 0.1)
end

function CMasterBotBody:ReleaseSpecialFireButton()
	self.m_btnSpecialFire = false
	self.m_btnSpecialFireTime = 0
end

function CMasterBotBody:PressReloadButton(timer)
	self.m_btnReload = true
	self.m_btnReloadTime = CurTime() + (timer or 0.1)
end

function CMasterBotBody:ReleaseReloadButton()
	self.m_btnReload = false
	self.m_btnReloadTime = 0
end

function CMasterBotBody:PressUseButton(timer)
	self.m_btnUse = true
	self.m_btnUseTime = CurTime() + (timer or 0.1)
end

function CMasterBotBody:ReleaseUseButton()
	self.m_btnUse = false
	self.m_btnUseTime = 0
end

function CMasterBotBody:PressCrouchButton(timer)
	self.m_btnCrouch = true
	self.m_btnCrouchTime = CurTime() + (timer or 0.1)
end

function CMasterBotBody:ReleaseCrouchButton()
	self.m_btnCrouch = false
	self.m_btnCrouchTime = 0
end

function CMasterBotBody:PressShiftButton(timer)
	self.m_btnShift = true
	self.m_btnShiftTime = CurTime() + (timer or 0.1)
end

function CMasterBotBody:ReleaseShiftButton()
	self.m_btnShift = false
	self.m_btnShiftTime = 0
end

function CMasterBotBody:UpdateVKeyboard()
	if (self.m_btnFireTime != 0 && CurTime() > self.m_btnFireTime) then
		self:ReleaseFireButton()
	end
	
	if (self.m_btnAltFireTime != 0 && CurTime() > self.m_btnAltFireTime) then
		self:ReleaseAltFireButton()
	end
	
	if (self.m_btnSpecialFireTime != 0 && CurTime() > self.m_btnSpecialFireTime) then
		self:ReleaseSpecialFireButton()
	end
	
	if (self.m_btnReloadTime != 0 && CurTime() > self.m_btnReloadTime) then
		self:ReleaseReloadButton()
	end
	
	if (self.m_btnUseTime != 0 && CurTime() > self.m_btnUseTime) then
		self:ReleaseUseButton()
	end
	
	if (self.m_btnCrouchTime != 0 && CurTime() > self.m_btnCrouchTime) then
		self:ReleaseCrouchButton()
	end
	
	if (self.m_btnShiftTime != 0 && CurTime() > self.m_btnShiftTime) then
		self:ReleaseShiftButton()
	end
end

function CMasterBotBody:IsFireButtonPressed()
	return self.m_btnFire
end

function CMasterBotBody:InitializeVKeyboard()
	self.m_btnFireTime = 0
	self.m_btnAltFireTime = 0
	self.m_btnSpecialFireTime = 0
	self.m_btnReloadTime = 0
	self.m_btnUseTime = 0
	self.m_btnCrouchTime = 0
	self.m_btnShiftTime = 0
end

-- Animations

function CMasterBotBody:LockAnimations(lock)
	self.m_lockAnimate = lock
end

function CMasterBotBody:IsGestureActive(seq)
	for i = 0, 15 do
		local layerSeq = self.m_bot:GetLayerSequence(i)
		
		if (layerSeq && layerSeq == seq) then
			return true
		end
	end
	
	return false
end

function CMasterBotBody:ReplayGesture(seq)
	local found = false
	for i = 0, 15 do
		local layerSeq = self.m_bot:GetLayerSequence(i)
		
		if (layerSeq && layerSeq == seq) then
			self.m_bot:SetLayerCycle(i, 0.0)
			found = true
		end
	end
	
	if (!found) then
		self.m_bot:AddGestureSequence(seq, true)
	end
end

function CMasterBotBody:GetSeq(name)
	if (!name) then return nil end
	
	local cached = self.m_seqCache[name]
	if (cached) then return cached end
	
	local idx = self.m_bot:LookupSequence(name)
	if (idx && idx >= 0) then
		self.m_seqCache[name] = idx
		return idx
	end
	return nil
end

local ANIMATE_RATE = 0.02

function CMasterBotBody:AnimationUpkeep()
	if (self.m_lockAnimate) then return end
	if (CurTime() < (self.m_nextThinkAnimate or 0)) then return end
	self.m_nextThinkAnimate = CurTime() + ANIMATE_RATE

    local speed = self.m_bot.loco:GetVelocity():Length()
    local seq
	local lockBaseAnim = false
	
	local enemy = nil
	if (self.m_bot.GetEnemy) then
		enemy = self.m_bot:GetEnemy()
	end
	
	if (!IsValid(enemy)) then
		enemy = self.m_bot.m_Vision:GetPrimaryKnownThreat() and self.m_bot.m_Vision:GetPrimaryKnownThreat():GetEntity()
	end
	
	if (self.m_bot.m_isReloading) then
		self.m_wasReloading = true
		if (self.m_bot.m_animReloadIsGesture) then
			if (speed < 5) then
				seq = self:GetSeq(self.m_bot.m_szAnimCombatIdle or "CombatIdle1")
				lockBaseAnim = true
			end
			
			if (self.m_bot.m_szAnimReloadLoop) then
				if (!self.m_nextReloadAnim) then
					local rs = self:GetSeq(self.m_bot.m_szAnimReload)
					
					if (rs) then
						self.m_bot:AddGestureSequence(rs, true)
					end
					
					self.m_nextReloadAnim = CurTime() + 1.0
				elseif (CurTime() > self.m_nextReloadAnim) then
					local rs = self:GetSeq(self.m_bot.m_szAnimReloadLoop)
					
					if (rs) then
						if (!self:IsGestureActive(rs)) then
							self.m_bot:AddGestureSequence(rs, true)
						end
					end
				end
			else
				if (!self.m_playedAnimGesture) then
					local rs = self:GetSeq(self.m_bot.m_szAnimReload or "reload")
					if (rs) then
						self.m_bot:AddGestureSequence(rs, true)
					end
					self.m_playedAnimGesture = true
				end
			end
		else
			seq = self:GetSeq(self.m_bot.m_szAnimReload or "reload")
			lockBaseAnim = true
		end
	end

	if (!lockBaseAnim) then
		if (speed >= self.m_bot.m_Locomotion:GetRunSpeed()) then -- speed > 160
			if (self.m_flagCombatAnims || IsValid(enemy) || self.m_isSighting) then
				if (self.m_bot.m_isCrouching) then
					seq = self:GetSeq(self.m_bot.m_szAnimCrouchWalk or "")
				else
					seq = self:GetSeq(self.m_bot.m_szAnimCombatRun or "RunAIMALL1")
				end
			else
				if (self.m_bot.m_isCrouching) then
					seq = self:GetSeq(self.m_bot.m_szAnimCrouchWalk or "")
				else
					seq = self:GetSeq(self.m_bot.m_szAnimRun or "RunAIMALL1")
				end
			end
		elseif (speed > 20) then
			if (self.m_bot.m_flagCombatAnims || IsValid(enemy) || self.m_bot.m_isSighting) then
				if (self.m_bot.m_isCrouching) then
					seq = self:GetSeq(self.m_bot.m_szAnimCrouchWalk or "")
				else
					seq = self:GetSeq(self.m_bot.m_szAnimCombatWalk or "Walk_aiming_all")
				end
			else
				if (self.m_bot.m_isCrouching) then
					seq = self:GetSeq(self.m_bot.m_szAnimCrouchWalk or "")
				else
					seq = self:GetSeq(self.m_bot.m_szAnimWalk or "Walk_aiming_all")
				end
			end
		elseif (IsValid(enemy) || self.m_bot.m_flagCombatAnims || self.m_bot.m_isSighting) then
			if (self.m_bot.m_isCrouching) then
				seq = self:GetSeq(self.m_bot.m_szAnimCrouchIdle or "")
			else
				seq = self:GetSeq(self.m_bot.m_szAnimCombatIdle or "CombatIdle1")
			end
		else
			if (self.m_bot.m_isCrouching) then
				seq = self:GetSeq(self.m_bot.m_szAnimCrouchIdle or "")
			else
				seq = self:GetSeq(self.m_bot.m_szAnimIdle or "Idle1")
			end
		end
	end
	
	if (!self.m_bot.m_isReloading) then
		self.m_playedAnimGesture = false
	end
	
	if (!self.m_bot.m_isReloading && self.m_wasReloading && self.m_bot.m_szAnimReloadEnd) then
		self.m_wasReloading = false
		local rs = self:GetSeq(self.m_bot.m_szAnimReloadEnd or "reload")
		
		if (rs) then
			self.m_bot:AddGestureSequence(rs, true)
		end
	end
	
	if (!self.m_bot.m_isAttacking) then
		self.m_playedAnimGestureAttack = false
	end
	
	if (seq) then
		local act = self.m_bot:GetSequenceActivity(seq)
		if (act && self.m_bot:GetActivity() != act) then
			self.m_bot:StartActivity(act)
		end
	end
	
	-- move_yaw - направление ног, устаревший вариант, встречается в моделях HL2
	-- move_x, move_y - направление ног, новый вариант, встречается в моделях TF2
	local vecMotion = self.m_bot.loco:GetGroundMotionVector()
	local yaw = vecMotion:Angle().y
	self.m_bot:SetPoseParameter("move_yaw", math.AngleDifference(yaw, self.m_bot:GetAngles().y))
	self.m_bot:SetPoseParameter("move_x", vecMotion:Dot(self.m_bot:GetForward()))
	self.m_bot:SetPoseParameter("move_y", vecMotion:Dot(self.m_bot:GetRight()))
	
	local eyePos = self.m_bot.m_Body:GetEyePosition()
	local dir    = eyePos + self.m_bot.m_Body.m_angCurrentAngles:Forward() * 100
	local dirFinal = (dir - eyePos):Angle()
	self.m_bot:SetPoseParameter("aim_pitch", math.NormalizeAngle(dirFinal.p))
	self.m_bot:SetPoseParameter("aim_yaw",   math.NormalizeAngle(dirFinal.y - self.m_bot:GetAngles().y))
	
	self.m_bot:SetPoseParameter("body_yaw", math.NormalizeAngle(dirFinal.y - self.m_bot:GetAngles().y))
	self.m_bot:SetPoseParameter("body_pitch", math.NormalizeAngle(dirFinal.p) * -1)
end