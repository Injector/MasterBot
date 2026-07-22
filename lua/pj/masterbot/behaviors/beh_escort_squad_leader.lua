local SQUAD_ESCORT_RANGE    = 500    -- tf_bot_squad_escort_range
local FORMATION_RADIUS      = 125    -- юниты от лидера до солдата
local MAX_SEPARATION_ANGLE  = 30     -- градусы между слотами построения
local FORMATION_MAX_ROTATION = 30    -- градусы/секунда — скорость поворота formation forward
local REPATH_MIN            = 0.1    -- секунды между построениями пути
local REPATH_MAX            = 0.2
local AT_GOAL_DIST          = 25     -- лидер считается у цели если ближе (для fwd вектора)
local NEAR_SPOT_DIST        = 50     -- юниты - "уже почти на месте"
local TOO_FAR_DIST          = 750    -- юниты - строй считается разорванным
local MAX_FORMATION_ERROR   = 100    -- юниты - нормировочный знаменатель ошибки

local FORMATION_DEBUG = false        -- аналог tf_bot_formation_debug

local function GetSquadLeader(bot)
    if CMasterBotSquadManager.GetBotSquadLeader then
        return CMasterBotSquadManager:GetBotSquadLeader(bot)
    end
	
    for _, m in ipairs(CMasterBotSquadManager:GetBotSquadMembers(bot)) do
        if (IsValid(m) && m.m_bIsLeader) then return m end
    end
    return nil
end

-- Проверить что отряд в построении (все члены с ошибкой ниже порога)
local function SquadIsInFormation(bot)
    local threshold = NEAR_SPOT_DIST * 1.5
    for _, m in ipairs(CMasterBotSquadManager:GetBotSquadMembers(bot)) do
        if (IsValid(m)) then
            local err = m.m_formationError or 0
            if (err > threshold) then return false end
        end
    end
    return true
end

-- Размер построения отряда
local function GetFormationSize(bot)
    local sq = CMasterBotSquadManager.Get && CMasterBotSquadManager:Get(bot.m_squadId)
    if (sq && sq.formationSize && sq.formationSize > 0) then
        return sq.formationSize
    end
    return FORMATION_RADIUS
end

-- ============================================================
-- Бот поддерживает позицию в веерном построении вокруг лидера
-- actionAfterDisband - действие которое нужно сделать после роспуска
-- ============================================================

BehEscortSquadLeader = setmetatable({}, { __index = CMBAction })
BehEscortSquadLeader.__index = BehEscortSquadLeader

function BehEscortSquadLeader:New(actionAfterDisband)
    local b = CMBAction.New(self, "EscortSquadLeader")
    b.m_actionAfterDisband = actionAfterDisband or nil

    -- Нормированный вектор направления построения (ось вперёд лидера)
    -- Плавно поворачивается со скоростью FORMATION_MAX_ROTATION
    b.m_formationForward = Vector(0, 0, 0)

    -- Таймер перестройки пути к слоту
    b.m_repathAt = 0

    -- Текущая цель слота (для дебага)
    b.m_formationSpot = nil

    return b
end

function BehEscortSquadLeader:OnStart(bot, prior)
    self.m_formationForward = Vector(0, 0, 0)
    self.m_repathAt         = 0
    self.m_formationSpot    = nil
    return self:Continue()
end

function BehEscortSquadLeader:Update(bot, dt)
    -- ── Проверка отряда ───────────────────────────────────────
    if (!CMasterBotSquadManager:IsInSquad(bot)) then
        if (self.m_actionAfterDisband) then
            return self:ChangeTo(self.m_actionAfterDisband, "Not in a squad")
        end
        return self:Done("Not in a squad")
    end

    local leader = GetSquadLeader(bot)
    if (!IsValid(leader) || leader:Health() <= 0) then
        CMasterBotSquadManager:Leave(bot)
        if (self.m_actionAfterDisband) then
            return self:ChangeTo(self.m_actionAfterDisband, "Squad leader is dead")
        end
        return self:Done("Squad leader is dead")
    end

    -- Если бот является лидером, то заканчиваем это действие
	-- Это может произойти, когда прошлый лидер отряда умер, и теперь он лидер
    -- (у лидера своё поведение, а остальные следуют за ним)
    if (CMasterBotSquadManager:IsLeader(bot)) then
        return self:Done("I am the leader")
    end

    -- ── Обновляем formation forward ────────────────────────────
    self:_UpdateFormationForward(leader, dt)

    -- ── Вычисляем слот в построении ────────────────
    local formationSpot, formationForward = self:_ComputeMySlot(bot, leader)
    self.m_formationSpot = formationSpot

    if (FORMATION_DEBUG && formationSpot) then
        debugoverlay.Cross(formationSpot, 16, 0.1, Color(0, 255, 0), true)
    end

    -- ── Ошибка позиции (0 = на месте, 1 = далеко) ────────────
    local to = formationSpot - bot:GetPos()
    local error = to:Length2D()

    local normalizedError = 1.0
    if (error < MAX_FORMATION_ERROR) then
        normalizedError = error / MAX_FORMATION_ERROR
    end
    bot.m_formationError = normalizedError  -- используется SquadIsInFormation()

    -- ── Движение к слоту ──────────────────────────────────────
    if (error < 50) then
        -- Почти на месте
        if (formationForward && to:Dot(formationForward) > 0) then
            -- Чуть впереди слота, подходим напрямую без навигации
            bot.loco:Approach(formationSpot, 1.0)
            bot.loco:SetDesiredSpeed(leader.loco:GetVelocity():Length() * (1 + normalizedError))
			--print("close")
        else
            -- В слоте (скорость = скорость лидера чтобы не отставать)
            bot.m_formationError = 0
            local leaderSpeed = leader.loco:GetVelocity():Length()
            bot.loco:SetDesiredSpeed(leaderSpeed)
            -- Стоим на месте
            bot.m_Locomotion:Stop()
        end
    else
        -- Далеко, идем через навигацию
        if (CurTime() >= self.m_repathAt) then
            self.m_repathAt = CurTime() + REPATH_MIN + math.random() * (REPATH_MAX - REPATH_MIN)

            local brokenFormation = false

            -- Скорость = скорость лидера × (1 + ошибка), чтобы быстрее догнать
            local chaseSpeed = math.max(
                150,
                leader.loco:GetVelocity():Length() * (1 + normalizedError * 2)
            )
            bot.m_Locomotion:NavMove(formationSpot, chaseSpeed)
			--print("daleko", error, NEAR_SPOT_DIST)

            -- Проверяем длину пути
            if (bot.m_navPath && bot.m_navPath:IsValid()) then
                if (bot.m_navPath:GetLength() > TOO_FAR_DIST) then
                    brokenFormation = true
                end
            end

            bot.m_brokenFormation = brokenFormation
        end
    end

    return self:Continue()
end


-- Обновление m_formationForward (вперед построения) с ограничением скорости поворота
function BehEscortSquadLeader:_UpdateFormationForward(leader, dt)
	-- В lua нету доступа к Path::Segment, используем m_navDest лидера
    local leaderFwd
    if (leader.m_navDest) then
        leaderFwd = (leader.m_navDest - leader:GetPos())
        if (leaderFwd:LengthSqr() < AT_GOAL_DIST * AT_GOAL_DIST) then
            -- Лидер у самой цели, используем скорость как замену следующего сегмента
            local vel = leader.loco:GetVelocity()
            if (vel:LengthSqr() > 1) then leaderFwd = vel end
        end
    else
        leaderFwd = leader.loco:GetVelocity()
    end

    if (!leaderFwd || leaderFwd:LengthSqr() < 0.01) then return end
    leaderFwd.z = 0
    leaderFwd:Normalize()

    -- Сразу принимаем направление если нулевое
    if (self.m_formationForward:LengthSqr() < 0.01) then
        self.m_formationForward = leaderFwd
        return
    end

    -- Плавный поворот с максимальной скоростью FORMATION_MAX_ROTATION
    local leaderYaw     = math.deg(math.atan2(leaderFwd.y, leaderFwd.x))
    local formationYaw  = math.deg(math.atan2(self.m_formationForward.y, self.m_formationForward.x))
    local angleDiff     = math.AngleDifference(leaderYaw, formationYaw)
    local maxDelta      = FORMATION_MAX_ROTATION * dt

    if (angleDiff < -maxDelta) then
        formationYaw = formationYaw - maxDelta
    elseif (angleDiff > maxDelta) then
        formationYaw = formationYaw + maxDelta
    else
        formationYaw = formationYaw + angleDiff
    end

    local rad = math.rad(formationYaw)
    self.m_formationForward.x = math.cos(rad)
    self.m_formationForward.y = math.sin(rad)
    self.m_formationForward.z = 0
end

function BehEscortSquadLeader:_ComputeMySlot(bot, leader)
    local members = CMasterBotSquadManager:GetBotSquadMembers(bot)

    -- Исключаем лидера из списка (он всегда первый — which=0 в C++)
    local nonLeaders = {}
    for _, m in ipairs(members) do
        if (IsValid(m) && !m.m_isLeader) then
			nonLeaders[#nonLeaders + 1] = m
        end
    end

    -- Найти позицию этого бота в списке (which в C++)
    local which = 0
    for i, m in ipairs(nonLeaders) do
        if (m == bot) then which = i - 1; break end
    end

    -- slot = (which+1)/2  (целочисленное деление, как в C++)
    local slot         = math.floor((which + 1) / 2)
    local formationRad = math.rad(slot * MAX_SEPARATION_ANGLE)

    -- Если индекс нечетный, то выбираем отрицательный угол (левая сторона)
    if ((which % 2) == 1) then
        formationRad = -formationRad
    end

    -- Повернуть formationForward на formationRad
    local fwd  = self.m_formationForward
    local s    = math.sin(formationRad)
    local c    = math.cos(formationRad)
    local slotFwd = Vector(
        fwd.x * c - fwd.y * s,
        fwd.y * c + fwd.x * s,
        0
    )

    local radius = GetFormationSize(bot)
    local rawSpot = leader:GetPos() + slotFwd * radius

    -- Если слот за стеной, сдвинуть к стене
    local eyeOff = Vector(0, 0, 36)  -- HalfHumanHeight
    local tr = util.TraceLine({
        start  = leader:GetPos() + eyeOff,
        endpos = rawSpot + eyeOff,
        filter = { bot, leader },
        mask   = MASK_PLAYERSOLID,
    })

    local formationSpot = rawSpot
    if (tr.Hit && tr.HitWorld) then
        -- Сдвигаем слот к нормали стены (result.plane.normal * hullWidth * 0.6)
        local hullWidth = 32  -- ширина бота (16 * 2)
        formationSpot = tr.HitPos - eyeOff + tr.HitNormal * hullWidth * 0.6
    end

    return formationSpot, slotFwd
end

function BehEscortSquadLeader:OnEnd(bot, next)
    bot.m_Locomotion:NavClear()
    bot.m_formationError  = 0
    bot.m_brokenFormation = false
end

function BehEscortSquadLeader:OnCommandString(bot, command)
	
	if (command == "stop escort squad leader") then
		return self:TryDone(CMBAction.RESULT_CRITICAL, "Received command to stop escorting the leader")
	end
	
	return self:TryContinue()
end

-- ============================================================
-- Лидер ждёт до 2 секунд пока отряд не соберётся в построение.
-- Используется только лидером
-- ============================================================

BehWaitForFormation = setmetatable({}, { __index = CMBAction })
BehWaitForFormation.__index = BehWaitForFormation

-- timeout - секунды ожидания, по умолчанию 2
function BehWaitForFormation:New(timeout)
    local b = CMBAction.New(self, "WaitForFormation")
    b.m_timeout = timeout or 2.0
    b.m_endTime = 0
    return b
end

function BehWaitForFormation:OnStart(bot, prior)
    self.m_endTime = CurTime() + self.m_timeout
    bot.m_Locomotion:Stop()  -- лидер стоит на месте пока ждёт
    return self:Continue()
end

function BehWaitForFormation:Update(bot, dt)
    -- Таймаут
    if (CurTime() >= self.m_endTime) then
        return self:Done("Timeout")
    end

    -- Вышли из отряда или больше не лидер
    if (!CMasterBotSquadManager:IsInSquad(bot) || !CMasterBotSquadManager:IsLeader(bot)) then
        return self:Done("Not leader / no squad")
    end

    -- Все в построении — можно двигаться
	if (CMasterBotSquadManager:IsInFormation(CMasterBotSquadManager:Get(bot.m_squadId))) then
        return self:Done("Everyone is in formation")
    end

    return self:Continue()
end

function BehWaitForFormation:OnEnd(bot, next)
    bot.m_Locomotion:NavClear()
end
