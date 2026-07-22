include("shared.lua")

ENT.AutomaticFrameAdvance = true

-- Прячем нелокализированное сообщение, у каждого мастербота будет свое имя внезависимости от "базового" энтити мастербота
-- Например, Комбайн с моделькой комбайна, Охранник Нова Проспект с моделькой комбайна, но уже с другим скином и тд
hook.Add("AddDeathNotice", "MasterBot_Combine_Death", function(attacker, attackerTeam, inflictor, victim, victimTeam)
	if (attacker == "#masterbot_combine_soldier" || victim == "#masterbot_combine_soldier") then
		return false
	end
end)

-- Из-за того что сетевой код Некстботов находится в плачевном состоянии, мы изобретаем велосипед с интерполяцией
-- Подробности проблемы можно почитать в init.lua ENT:ThinkFace()
-- ============================================================
-- interpPeriod = max(cl_interp, cl_interp_ratio / cl_updaterate) - стандартная формула
-- ============================================================

local SNAP_DIST   = 250   -- юниты, дальше - телепорт, передвигаем без интерполяции
local BUFFER_SIZE = 32    -- история снапшотов

local cv_interp       = GetConVar("cl_interp")
local cv_interp_ratio = GetConVar("cl_interp_ratio")
local cv_updaterate   = GetConVar("cl_updaterate")

local function GetInterpPeriod()
    local interp     = cv_interp       and cv_interp:GetFloat()       or 0.04
    local ratio      = cv_interp_ratio and cv_interp_ratio:GetFloat() or 1
    local updaterate = cv_updaterate   and cv_updaterate:GetFloat()   or 66
    return math.max(interp, ratio / updaterate)
end

-- ── Кольцевой буфер снапшотов ────────────────────────────
local function NewBuffer()
    return { data = {}, head = 0, count = 0 }
end

local function PushSnapshot(buf, t, pos, ang)
    buf.head = (buf.head % BUFFER_SIZE) + 1
    buf.data[buf.head] = { t = t, pos = pos, ang = ang }
    if (buf.count < BUFFER_SIZE) then buf.count = buf.count + 1 end
end

-- Найти пару снапшотов засчет renderTime
-- Возвращает (snapA, snapB, alpha) или (snap, nil, 0)
local function FindSnapshots(buf, renderTime)
    if (buf.count == 0) then return nil, nil, 0 end

    local newer, older
    for i = 0, buf.count - 1 do
        local idx  = ((buf.head - 1 - i) % BUFFER_SIZE) + 1
        local snap = buf.data[idx]
        if (!snap) then continue end
        if (snap.t <= renderTime) then
            older = snap
            break
        end
        newer = snap
    end

    if (!older) then
        local idx = ((buf.head - buf.count) % BUFFER_SIZE) + 1
        return buf.data[idx], nil, 0
    end
    if (!newer) then
        return buf.data[buf.head], nil, 0
    end

    local dt    = newer.t - older.t
    local alpha = dt > 0 && (renderTime - older.t) / dt || 0
    return older, newer, math.Clamp(alpha, 0, 1)
end

function ENT:Initialize()
    self:SetIK(false)
    self._snapBuf   = NewBuffer()
    self._smoothPos = self:GetPos()
    self._smoothAng = self:GetAngles()
    -- Заполняем буфер начальным снапшотом
    local t0 = RealTime()
    for i = 1, 4 do
        PushSnapshot(self._snapBuf, t0 - (4 - i) * 0.016, self:GetPos(), self:GetAngles())
    end
end

function ENT:Think()
    local buf = self._snapBuf
    if not buf then self:Initialize(); buf = self._snapBuf end

    local now    = RealTime()
    local curPos = self:GetPos()
    local curAng = self:GetAngles()

    -- При телепорте сбрасываем буфер
    local last = buf.count > 0 && buf.data[buf.head]
    if (last && (curPos - last.pos):Length() > SNAP_DIST) then
        self._snapBuf = NewBuffer(); buf = self._snapBuf
        for i = 1, 4 do
            PushSnapshot(buf, now - (4 - i) * 0.016, curPos, curAng)
        end
        self._smoothPos = curPos
        self._smoothAng = curAng
        return
    end

    -- Пишем снапшот только при изменении (не дублируем одну позицию)
    if (!last || (curPos - last.pos):LengthSqr() > 1 || math.abs(math.AngleDifference(curAng.y, last.ang.y)) > 0.2) then
        PushSnapshot(buf, now, curPos, curAng)
    end
	
    local renderTime          = now - GetInterpPeriod()
    local snapA, snapB, alpha = FindSnapshots(buf, renderTime)

    if (snapA && snapB) then
        self._smoothPos = LerpVector(alpha, snapA.pos, snapB.pos)
        self._smoothAng = LerpAngle(alpha, snapA.ang, snapB.ang)
    elseif (snapA) then
        self._smoothPos = snapA.pos
        self._smoothAng = snapA.ang
    end
end

-- Отрисовка

local function ApplySmoothToChild(child, smoothPos, smoothAng)
    if (!IsValid(child)) then return end
    local worldPos, worldAng = LocalToWorld(
        child:GetLocalPos(), child:GetLocalAngles(),
        smoothPos, smoothAng
    )
    child:SetRenderOrigin(worldPos)
    child:SetRenderAngles(worldAng)
end

function ENT:Draw()
	-- IK очень ужасно работает в мультиплеере, нет нормальной возможности изменить IK кости
    self:SetIK(false)

    local pos = self._smoothPos or self:GetPos()
    local ang = self._smoothAng or self:GetAngles()

    self:SetRenderOrigin(pos)
    self:SetRenderAngles(ang)
    self:DrawModel()

	-- Прикрепленные энтити, оружия через SetParent и EF_BONEMERGE
    for _, child in ipairs(self:GetChildren()) do
        ApplySmoothToChild(child, pos, ang)
        -- Сбрасываем после кадра чтобы хитбоксы оружия оставались на месте
        child:SetRenderOrigin()
        child:SetRenderAngles()
    end

    -- Сброс основной модели чтобы были нормальные хитбоксы и тени
    self:SetRenderOrigin()
    self:SetRenderAngles()
end

-- function ENT:DrawTranslucent()
    -- self:Draw()
-- end