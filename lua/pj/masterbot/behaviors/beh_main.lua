-- ============================================================
local MELEE_RANGE = 75
local FIRE_RANGE = 1400
local SQUAD_RADIUS = 2000
local SQUAD_SPACING = 120
local COVER_DELAY = 2.0
local STRAFE_INTERVAL = 1.6
local PATH_RATE = 0.3
local RELOAD_DURATION = 2.8
local MAG_SIZE = 30
local FIRE_RATE = 0.1
local FLANK_COOLDOWN = { 12, 20 }
local FLANK_ARRIVE_DIST = 65
local FLANK_MIN_ENEMY_DIST = 220
local FLANK_MAX_ENEMY_DIST = 750
local FLANK_IDEAL_ENEMY_DIST = 420

local OBSTACLE_CHECK_DIST = 120
local OBSTACLE_PUSH_FORE = 180000
local STEER_DURATION = 0.6
local REPATH_INTERVAL = 0.15
local STUCK_PUSH_THRESHOLD = 0.4
local AVOIDANCE_RAYS = 5
local AVOIDANCE_RAYS_SPREAD = 90
local HULL_MINS = Vector(-16, -16, 0)
local HULL_MAXS = Vector(16, 16, 72)
local ARRIVAL_TOLERANCE = 55
local OBSTACLE_PUSH_FORCE = 500

-- Утилиты
-- ============================================================
local function CanSee(from, to)
    if not IsValid(to) then return false end
	return from.m_Vision:IsLineOfSightClear(to)
end

local function GetEnemy(bot)
	if (bot.GetEnemy) then
		return bot:GetEnemy()
	end
	
	local enemy = bot.m_Vision:GetPrimaryKnownThreat()
	
	if (enemy) then return enemy:GetEntity() end
	
	return NULL
end

local COVER_MIN_THREAT_DIST = 120
local COVER_EYE_HEIGHT = 64
local COVER_BODY_HEIGHT = 48

local function NavAreaKey(area)
	if area.GetID then return area:GetID() end
	return area
end

local function GetThreatEyePos(threatPos)
	return threatPos + Vector(0, 0, COVER_EYE_HEIGHT)
end

local function GetCoverTraceFilter(bot)
	return { bot }
end

local function IsHiddenFromThreat(bot, threatPos, coverPos)
	local threatEye = GetThreatEyePos(threatPos)
	local coverEye = coverPos + Vector(0, 0, COVER_BODY_HEIGHT)
	local filter = GetCoverTraceFilter(bot)

	local tr = util.TraceLine({
		start  = threatEye,
		endpos = coverEye,
		filter = filter,
		mask   = MASK_BLOCKLOS_AND_NPCS,
	})
	if (tr.Fraction < 0.95) then return true end

	tr = util.TraceHull({
		start  = threatEye,
		endpos = coverEye,
		filter = filter,
		mask   = MASK_BLOCKLOS_AND_NPCS,
		mins   = Vector(-12, -12, 0),
		maxs   = Vector(12, 12, 72),
	})
	return tr.Fraction < 0.95
end

local function CollectNavAreaSpots(area)
	local c = area:GetCenter()
	return {
		c,
		c + Vector(48, 0, 0),
		c + Vector(-48, 0, 0),
		c + Vector(0, 48, 0),
		c + Vector(0, -48, 0),
	}
end

local function ScoreCoverSpot(botPos, threatPos, coverPos, hasLosBlock)
	local dBot = botPos:Distance(coverPos)
	local dThreat = coverPos:Distance(threatPos)
	local score = dThreat * 0.75 - dBot * 0.25
	if (hasLosBlock) then
		score = score + 200
	end
	return score
end

local function TryAddCoverCandidate(candidates, bot, botPos, threatPos, coverPos, maxDist, requireHidden)
	local dBot = botPos:Distance(coverPos)
	local dThreat = coverPos:Distance(threatPos)
	if (dBot > maxDist || dBot < 40 || dThreat < COVER_MIN_THREAT_DIST) then return end

	local hidden = IsHiddenFromThreat(bot, threatPos, coverPos)
	if (requireHidden && !hidden) then return end

	candidates[#candidates + 1] = {
		pos = Vector(coverPos.x, coverPos.y, coverPos.z),
		score = ScoreCoverSpot(botPos, threatPos, coverPos, hidden),
	}
end

local function FindCoverPos(bot, threatPos, maxDist)
	maxDist = maxDist or 750

	local botPos = bot:GetPos()
	local away = botPos - threatPos
	away.z = 0
	if (away:LengthSqr() < 64) then
		away = bot:GetForward()
		away.z = 0
	end
	away:Normalize()

	local perp = Vector(-away.y, away.x, 0)
	local seenAreas = {}
	local candidates = {}

	local function considerArea(area, requireHidden)
		if (!area) then return end
		local key = NavAreaKey(area)
		if (seenAreas[key]) then return end
		seenAreas[key] = true

		for _, spot in ipairs(CollectNavAreaSpots(area)) do
			TryAddCoverCandidate(candidates, bot, botPos, threatPos, spot, maxDist, requireHidden)
		end
	end

	-- Сэмплы вокруг бота относительно противника
	local angles = { 0, 25, -25, 50, -50, 75, -75, 110, -110, 145, -145, 180 }
	local dists = { 100, 180, 260, 340, 420, 520, 620, 720 }
	for _, dist in ipairs(dists) do
		if (dist > maxDist) then continue end
		for _, ang in ipairs(angles) do
			local rad = math.rad(ang)
			local cosA, sinA = math.cos(rad), math.sin(rad)
			local dir = Vector(
				away.x * cosA + perp.x * sinA,
				away.y * cosA + perp.y * sinA,
				0
			)
			local sample = botPos + dir * dist
			considerArea(navmesh.GetNearestNavArea(sample, false, 280, false, true), true)
		end
	end

	-- Соседние и видимые nav-зоны от текущей позиции
	local myArea = navmesh.GetNearestNavArea(botPos, false, 220, false, true)
	if (myArea) then
		considerArea(myArea, true)
		if (myArea.GetAdjacentAreas) then
			for _, adj in ipairs(myArea:GetAdjacentAreas()) do
				considerArea(adj, true)
			end
		end
		if (myArea.GetVisibleAreas) then
			for _, vis in ipairs(myArea:GetVisibleAreas()) do
				considerArea(vis, true)
			end
		end
	end

	local best, bestScore = nil, -1e9
	for i = 1, #candidates do
		local c = candidates[i]
		if (c.score > bestScore) then
			bestScore = c.score
			best = c.pos
		end
	end

	if (!best) then
		--print("Fallback")
		for _, dist in ipairs(dists) do
			if dist > maxDist then continue end
			local area = navmesh.GetNearestNavArea(botPos + away * dist, false, 320, false, true)
			if (!area) then continue end
			for _, spot in ipairs(CollectNavAreaSpots(area)) do
				local dBot = botPos:Distance(spot)
				if (dBot > maxDist || dBot < 40) then continue end
				local score = spot:Distance(threatPos) - dBot * 0.35
				if (score > bestScore) then
					bestScore = score
					best = Vector(spot.x, spot.y, spot.z)
				end
			end
		end
	end

	return best
end

local function GetFlankSlot(bot)
	if (bot.m_flankSlot != nil) then
		return bot.m_flankSlot
	end
	return bot:EntIndex() % 5
end

local function GetFlankMatePositions(bot)
	local mates = {}
	if (!CMasterBotSquadManager || !CMasterBotSquadManager.GetBotSquadMembers) then
		return mates
	end
	for _, m in ipairs(CMasterBotSquadManager:GetBotSquadMembers(bot)) do
		if (IsValid(m) && m != bot) then
			mates[#mates + 1] = m:GetPos()
		end
	end
	return mates
end

local function BuildFlankSamplePoints(ePos, right, fwd)
	return {
		ePos + right * 450,
		ePos - right * 450,
		ePos - fwd * 380 + right * 280,
		ePos - fwd * 380 - right * 280,
		ePos - fwd * 500,
	}
end

local function IsFlankApproachHidden(bot, ePos, flankPos)
	local tr = util.TraceLine({
		start  = ePos + Vector(0, 0, 64),
		endpos = flankPos + Vector(0, 0, 48),
		filter = { bot },
		mask   = MASK_BLOCKLOS_AND_NPCS,
	})
	return tr.Fraction < 0.92
end

local function ScoreFlankPos(bot, enemy, flankPos, slotIndex, matePositions)
	local ePos = enemy:GetPos()
	local score = 0

	for i = 1, #matePositions do
		score = score + flankPos:Distance(matePositions[i]) * 0.45
	end

	local slotDist = math.abs((slotIndex - 1) - GetFlankSlot(bot))
	score = score + (5 - slotDist) * 90

	local dEnemy = flankPos:Distance(ePos)
	if (dEnemy < FLANK_MIN_ENEMY_DIST) then
		score = score - 600
	elseif (dEnemy > FLANK_MAX_ENEMY_DIST) then
		score = score - 250
	else
		score = score + 120 - math.abs(dEnemy - FLANK_IDEAL_ENEMY_DIST) * 0.2
	end

	score = score - bot:GetPos():Distance(flankPos) * 0.12

	if (IsFlankApproachHidden(bot, ePos, flankPos)) then
		score = score + 180
	end

	return score
end

local function FindFlankPos(bot, enemy)
	if (!IsValid(enemy)) then return nil end

	local ePos = enemy:GetPos()
	local right = enemy:GetRight()
	local fwd = enemy:GetForward()
	local samples = BuildFlankSamplePoints(ePos, right, fwd)
	local matePositions = GetFlankMatePositions(bot)

	local bestPos, bestScore = nil, -1e9

	for i = 1, #samples do
		local area = navmesh.GetNearestNavArea(samples[i], false, 300, false, true)
		if (!area) then continue end

		local flankPos = area:GetCenter()
		local score = ScoreFlankPos(bot, enemy, flankPos, i, matePositions)
		if (score > bestScore) then
			bestScore = score
			bestPos = flankPos
		end
	end

	return bestPos
end

local function CanStrafe(bot, dir)
    local right  = bot:GetRight()
    local target = bot:GetPos() + right * (dir * 70)
    local tr = util.TraceLine({
        start  = bot:GetPos() + Vector(0, 0, 32),
        endpos = target        + Vector(0, 0, 32),
        filter = bot,
        mask   = MASK_PLAYERSOLID,
    })
    return tr.Fraction > 0.70
end

-- ============================================================
-- Перезарядка оружия
-- ============================================================

BehReload = setmetatable({}, { __index = CMBAction })
BehReload.__index = BehReload

function BehReload:New()
    local b = CMBAction.New(self, "Reload")
    b.m_endTime = 0
    return b
end

function BehReload:OnStart(bot, prior)
	self.m_endTime = CurTime() + bot.m_wpn.m_flReloadDur
    bot.m_isReloading = true
    bot.m_Locomotion:Stop()
    bot:EmitSound("npc/combine_soldier/reload1.wav")
    return self:Continue()
end

function BehReload:Update(bot, dt)
    -- Держим бота на месте на протяжении всей перезарядки
    bot.m_Locomotion:Stop()
	
	bot.m_Body:PressReloadButton()
	
	if (bot.m_wpn && bot.m_wpn.m_bReloadByPart) then
		if (bot.m_wpn.m_iClip1 >= bot.m_wpn.m_iMaxClip1) then
			return self:Done("Reloaded")
		end
		
		return self:Continue()
	end
	
    if (CurTime() >= self.m_endTime) then
		bot.m_ammo = bot.m_wpn.m_iMaxClip1
		bot.m_wpn.m_iClip1 = bot.m_wpn.m_iMaxClip1
        bot.m_isReloading = false
        bot:EmitSound("npc/combine_soldier/gear1.wav")
        return self:Done("Reload complete")
    end
    return self:Continue()
end

function BehReload:OnEnd(bot, next)
    bot.m_isReloading = false
end

function BehReload:ShouldAttack(bot, enemy) return CMBAction.ANSWER_NO end
function BehReload:ShouldHurry(bot) return CMBAction.ANSWER_YES end

-- ============================================================
-- Преследование игрока
-- Если игрок вне поле зрения, преследуем его
-- ============================================================

BehChase = setmetatable({}, { __index = CMBAction })
BehChase.__index = BehChase

function BehChase:New()
    local b = CMBAction.New(self, "ChaseThreat")
    b.m_timeout    = 0
    b.m_destUpdate = 0
    return b
end

function BehChase:OnStart(bot, prior)
    self.m_timeout    = CurTime() + 9
    self.m_destUpdate = 0
	
	-- Вместо того, чтобы втупую идти к противнику, если мы потеряли его из виду
	-- Мы можем проверить, есть ли место слева или справа. Если есть - двигаем к нему
	local enemy = GetEnemy(bot)
	
	if (enemy && bot:GetPos():DistToSqr(enemy:GetPos()) > 400.0 * 400.0) then
		local dirs = { 70, 120, -70, -120 }
		
		local bNotInWallSpot = false
		local bCanSeeSpot = false
		local bHaveGroundSpot = false
		local bCanSeeThreatSpot = false
		local bCanMoveSpot = false
		local bestDest = nil
		
		for i = 1, #dirs do
			local vecEndPos = bot:GetPos() + bot:GetRight() * (dirs[i])
			
			local tr = util.TraceHull({ start = bot:GetPos() + Vector(0, 0, 32), endpos = vecEndPos, filter = bot, mask = MASK_PLAYERSOLID })
			
			-- Точка начинается в стене, скип
			if (tr.StartSolid) then
				continue
			end
			
			bNotInWallSpot = true
			
			-- Мы не видим точку, должно быть она за стеной, скип
			if (!bot.m_Vision:IsAbleToSeePos(vecEndPos)) then
				
				continue
			end
			
			bCanSeeSpot = true
			
			tr = util.TraceLine({ start = vecEndPos, endpos = vecEndPos + Vector(0, 0, -50), filter = bot, mask = MASK_PLAYERSOLID })
			
			if (!tr.HitWorld) then
				iFailedTimes = iFailedTimes + 1
				-- Под нами нету земли, скип
				continue
			end
			
			bHaveGroundSpot = true
			
			tr = util.TraceHull({ start = vecEndPos, endpos = enemy:WorldSpaceCenter(), filter = bot, mask = MASK_PLAYERSOLID })
			
			if (tr.Entity != enemy) then
				continue
			end
			
			bCanSeeThreatSpot = true
			
			if (!bCanMoveSpot) then
				if (bot.m_Locomotion.m_navPath) then
					bCanMoveSpot = bot.m_Locomotion.m_navPath:Compute(bot, vecEndPos)
					if (bCanMoveSpot) then
						bestDest = vecEndPos
					end
				else
					bCanMoveSpot = true
					bestDest = vecEndPos
				end
			end
			
			--bestDest = vecEndPos
		end
		
		if (bHaveGroundSpot && bCanSeeSpot && bNotInWallSpot && bCanSeeThreatSpot) then
			self.m_bestDestForAim = bestDest
		end
	end
	
    self:UpdateDest(bot)
    return self:Continue()
end

function BehChase:UpdateDest(bot)
    local dest = self.m_bestDestForAim or bot.m_lastEnemyPos
    if (!dest) then return end
	bot.m_Body:PressShiftButton()
    bot.m_Locomotion:NavMove(dest, bot.m_overrideNavSpeedChase or 200)
    self.m_destUpdate = CurTime() + PATH_RATE
end

function BehChase:Update(bot, dt)
	local enemy = GetEnemy(bot)
    if (IsValid(enemy) && CanSee(bot, enemy)) then
        return self:Done("Enemy visible again")
    end
    if (CurTime() > self.m_timeout) then
        return self:Done("Chase timeout")
    end
    if (CurTime() > self.m_destUpdate) then
        self:UpdateDest(bot)
    end
	
	bot.m_Body:PressShiftButton()
	
	if (self.m_bestDestForAim && bot.m_Locomotion:IsArrived(10)) then
		self.m_bestDestForAim = nil
		bot.m_Locomotion:NavMove(bot.m_lastEnemyPos)
		return self:Continue()
	end
	
    --if (bot.m_Locomotion:IsArrived(70)) then
	if (bot.m_Locomotion:IsArrived(10)) then
        return self:Done("Reached last known pos")
    end
    return self:Continue()
end

function BehChase:OnResume(bot, intr)
    self:UpdateDest(bot)
end

function BehChase:OnEnd(bot, next)
    bot.m_Locomotion:NavClear()
end

-- ============================================================
-- Преследование игрока
-- Если игрок за пределами огня оружия, то преследуем
-- TODO: Объединить в одно поведение
-- ============================================================

BehGetThreat = setmetatable({}, { __index = CMBAction })
BehGetThreat.__index = BehGetThreat

function BehGetThreat:New()
	local b = CMBAction.New(self, "GetThreat")
	b.m_timeout = 0
	b.m_destUpdate = 0
	return b
end

function BehGetThreat:OnStart(bot, prior)
	self.m_destUpdate = 0
	self:UpdateDest(bot)
	return self:Continue()
end

function BehGetThreat:UpdateDest(bot)
	local dest = nil -- bot.m_lastEnemyPos
	local enemy = GetEnemy(bot)
	
	if (IsValid(enemy)) then
		dest = enemy:GetPos()
	end
	bot.m_Locomotion:NavMove(dest, bot.m_overrideNavSpeedChase or 200)
	self.m_destUpdate = CurTime() + PATH_RATE
end

function BehGetThreat:Update(bot, dt)
	local enemy = GetEnemy(bot)
	if (!IsValid(enemy)) then
		return self:Done("No enemy")
	end
	
	if (bot:GetRangeTo(enemy:GetPos()) <= bot.m_wpn.m_flFireRange) then
		return self:Done("Enemy is within fire range")
	end
	
	bot.m_Body:PressShiftButton()
	
	if (CurTime() > self.m_destUpdate) then
		self:UpdateDest(bot)
	end
	
	if (bot.m_Locomotion:IsArrived(70)) then
		return self:Done("Reached pos")
	end
	
	return self:Continue()
end

function BehGetThreat:OnResume(bot, intr)
	self:UpdateDest(bot)
end

function BehGetThreat:OnEnd(bot, next)
	bot.m_Locomotion:NavClear()
end

-- ============================================================
-- Отступление
-- Если игрок слишком близко подошел, отступаем
-- ============================================================

BehMeleeRetreat = setmetatable({}, { __index = CMBAction })
BehMeleeRetreat.__index = BehMeleeRetreat

function BehMeleeRetreat:New()
    local b = CMBAction.New(self, "MeleeRetreat")
    b.m_endTime = 0
    return b
end

function BehMeleeRetreat:OnStart(bot, prior)
    self.m_endTime = CurTime() + 2.2

    local enemy = GetEnemy(bot)
    if (IsValid(enemy)) then
        local awayDir = (bot:GetPos() - enemy:GetPos()):GetNormalized()
        local dest    = bot:GetPos() + awayDir * 320
        local area    = navmesh.GetNearestNavArea(dest, false, 220)
		
		local finalPath = dest
		
		-- Иногда length может быть ниже ARRIVAL_TOLERANCE, и тогда мастербот будет просто стоять на месте во время отступления. Если меньше, то используем dest вместо area:GetCenter()
		if (area) then
			if ((bot:GetPos() - area:GetCenter()):Length() > ARRIVAL_TOLERANCE) then
				finalPath = area:GetCenter()
			end
		end
		
        bot.m_Locomotion:NavMove(finalPath, 220)
    end
    return self:Continue()
end

function BehMeleeRetreat:Update(bot, dt)
    local enemy = GetEnemy(bot)
    local farEnough = !IsValid(enemy) or bot:GetPos():Distance(enemy:GetPos()) > MELEE_RANGE * 3.5
	
	bot.m_Body:PressShiftButton()

    if (farEnough || CurTime() > self.m_endTime) then
        return self:Done("Melee retreat done")
    end
    return self:Continue()
end

function BehMeleeRetreat:OnEnd(bot, next)
    bot.m_Locomotion:NavClear()
end

-- Если застряли во время отступления, заканчиваем
function BehMeleeRetreat:OnStuck(bot)
	return self:TryDone(CMBAction.RESULT_CRITICAL, "Got stuck while melee retreating")
end

function BehMeleeRetreat:OnMoveToFailure(bot, path, reason)
	return self:TryDone(CMBAction.RESULT_CRITICAL, "Failed path")
end

BehRetreatToCover = setmetatable({}, { __index = CMBAction })
BehRetreatToCover.__index = BehRetreatToCover

function BehRetreatToCover:New(changeTo, waitInCoverDuration)
	local b = CMBAction.New(self, "RetreatToCover")
	b.m_dest = nil
	b.m_atCoverAt = nil
	b.m_waitInCover = waitInCoverDuration or 3.5
	b.m_changeToAction = changeTo
	b.m_retryCount = 0
	return b
end

function BehRetreatToCover:OnStart(bot, prior)
	local enemy = bot.m_Vision:GetPrimaryKnownThreat()
	local from = enemy and IsValid(enemy:GetEntity()) and enemy:GetEntity():GetPos() or bot:GetPos()
	self.m_dest = FindCoverPos(bot, from)
	self.m_pathTimer = 0
	if (self.m_dest) then
		bot.m_Locomotion:NavMove(self.m_dest, 220)
	end
	return self:Continue()
end

function BehRetreatToCover:Update(bot, dt)
	if (!self.m_dest) then
		if (self.m_changeToAction) then
			return self:ChangeTo(self.m_changeToAction, "No cover found, doing given action")
		else
			return self:Done("No cover found")
		end
	end
	
	-- Если мы вдруг получаем ответ от ниже стоящих действий в стеке, то прекращаем отступление
	if (bot.m_Intention:ShouldRetreat(CMBAction.ANSWER_UNDEFINED) == CMBAction.ANSWER_NO) then
		return self:Done("No longer need to retreat")
	end
	
	bot.m_Body:PressShiftButton()
	
	if (CurTime() > self.m_pathTimer) then
		bot.m_Locomotion:NavMove(self.m_dest, 220)
		self.m_pathTimer = CurTime() + 0.35
	end
	
	-- На месте, в укрытии
	if (bot.m_Locomotion:IsArrived(75)) then
		if (!self.m_atCoverAt) then
			self.m_atCoverAt = CurTime()
			bot.m_Locomotion:Stop()
		end
		
		if (self.m_changeToAction) then
			return self:ChangeTo(self.m_changeToAction, "Doing given action now that I'm in cover")
		end
		
		-- Если я на месте и меня все равно видно, незачем сидеть в укрытии дальше
		local threat = bot.m_Vision:GetPrimaryKnownThreat()
		if (threat && threat:IsVisibleInFOVNow()) then
			return self:Done("Exposed by a threat")
		end
		
		if (CurTime() - self.m_atCoverAt > self.m_waitInCover) then
			return self:Done("In cover, time is over")
		end
	end
	
	return self:Continue()
end

function BehRetreatToCover:OnEnd(bot, next)
	bot.m_Locomotion:NavClear()
end

-- Иногда по пути к укрытию мы можем застять, в таком случае мы забиваем на отступление
-- Если нам нужно сделать какое то действие, то делаем его щас
function BehRetreatToCover:OnStuck(bot)
	if (self.m_changeToAction) then
		bot.loco:ClearStuck()
		return self:TryChangeTo(self.m_changeToAction, CMBAction.RESULT_CRITICAL, "Stuck, doing given action now")
	end
	
	bot.loco:ClearStuck()
	return self:TryDone(CMBAction.RESULT_CRITICAL, "Stuck while retreating")
end

-- Иногда FindCoverPos может возвращать невалидные точки, чаще всего у границ карты 
-- Если у нас путь провалился больше 3 раз, или забиваем на отступление, или делаем действие если у нас есть
function BehRetreatToCover:OnMoveToFailure(bot, path, reason)
	if (self.m_retryCount < 3) then
		self.m_retryCount = self.m_retryCount + 1
		
		local enemy = bot.m_Vision:GetPrimaryKnownThreat()
		self.m_dest = FindCoverPos(bot, enemy and enemy:GetEntity():GetPos() or bot:GetPos())
	else
		if (self.m_changeToAction) then
			return self:TryChangeTo(self.m_changeToAction, CMBAction.RESULT_CRITICAL, "Path to cover failed too mane times, doing given action now")
		else
			return self:TryDone(CMBAction.RESULT_CRITICAL, "Path to cover failed too many times")
		end
	end
	
	return self:TryContinue()
end

-- Атакуем при отступлении. Даже если у нас нету патронов, то ничего не произойдет
function BehRetreatToCover:ShouldAttack()
	return CMBAction.ANSWER_YES
end

function BehRetreatToCover:ShouldHurry()
	return CMBAction.ANSWER_YES
end

BehRetreatToReload = setmetatable({}, { __index = CMBAction })
BehRetreatToReload.__index = BehRetreatToReload

function BehRetreatToReload:New()
	local b = CMBAction.New(self, "RetreatToReload")
	b.m_retryCount = 0
	b.m_pathTimer = 0
	return b
end

function BehRetreatToReload:OnStart(bot, prior)
	local enemy = bot.m_Vision:GetPrimaryKnownThreat()
	local from = enemy and IsValid(enemy:GetEntity()) and enemy:GetEntity():GetPos() or bot:GetPos()
	self.m_dest = FindCoverPos(bot, from)
	if (self.m_dest) then
		bot.m_Locomotion:NavMove(self.m_dest, 220)
	end
	return self:Continue()
end

function BehRetreatToReload:Update(bot, dt)
	if (!self.m_dest) then
		return self:ChangeTo(BehReload:New(), "No cover, reload in place")
	end
	
	bot.m_Body:PressShiftButton()
	
	if (CurTime() > self.m_pathTimer) then
		bot.m_Locomotion:NavMove(self.m_dest, bot.m_Locomotion.m_navSpeed)
		self.m_pathTimer = CurTime() + 0.35
	end
	
	if (bot.m_Locomotion:IsArrived(60)) then
		return self:ChangeTo(BehReload:New(), "At cover, reloading")
	end
	
	return self:Continue()
end

function BehRetreatToCover:OnEnd(bot, next)
	bot.m_Locomotion:NavClear()
end

function BehRetreatToReload:OnStuck(bot)
	bot.loco:ClearStuck()
	return self:TryChangeTo(BehReload:New(), CMBAction.RESULT_CRITICAL, "Stuck, reloading now")
end

function BehRetreatToReload:OnMoveToFailure(bot, path, reason)
	if (self.m_retryCount < 3) then
		self.m_retryCount = self.m_retryCount + 1
		
		
	else
		return self:TryChangeTo(BehReload:New(), CMBAction.RESULT_CRITICAL, "Path failed, reloading now")
	end
	
	return self:TryContinue()
end

function BehRetreatToReload:ShouldAttack(bot)
	return CMBAction.ANSWER_YES
end

function BehRetreatToReload:ShouldHurry(bot)
	return CMBAction.ANSWER_YES
end

-- ============================================================
-- Фланг
-- Атакуем с разных сторон, после получения приказа нашего командира
-- ============================================================

BehFlank = setmetatable({}, { __index = CMBAction })
BehFlank.__index = BehFlank

function BehFlank:New(enemy)
    local b = CMBAction.New(self, "Flank")
    b.m_enemy      = enemy
    b.m_dest       = nil
    b.m_destUpdate = 0
    b.m_timeout    = 0
	b.m_retryCount = 0
    return b
end

function BehFlank:OnStart(bot, prior)
    self.m_timeout = CurTime() + 15
    local enemy   = IsValid(self.m_enemy) and self.m_enemy or GetEnemy(bot)
    if (!IsValid(enemy)) then return self:Done("No flank target") end

    self.m_dest = FindFlankPos(bot, enemy)
    if (!self.m_dest) then return self:Done("No flank position") end

    bot.m_Locomotion:NavMove(self.m_dest, 200)
    --bot:EmitSound("npc/combine_soldier/vo/flank1.wav")
    return self:Continue()
end

function BehFlank:Update(bot, dt)
    local enemy = IsValid(self.m_enemy) and self.m_enemy or GetEnemy(bot)
    if (!IsValid(enemy)) then return self:Done("Flank target gone") end
    if (CurTime() > self.m_timeout) then return self:Done("Flank timeout")     end

    if (bot.m_Locomotion:IsArrived(90)) then
        return self:Done("Flank position reached")
    end
	
	bot.m_Body:PressShiftButton()

    -- Пересчитываем каждые 2с если враг сдвинулся
    if (CurTime() > self.m_destUpdate) then
        self.m_destUpdate = CurTime() + 2.0
        local newDest = FindFlankPos(bot, enemy)
        if (newDest && (!self.m_dest || (newDest - self.m_dest):Length() > 80)) then
            self.m_dest = newDest
            bot.m_Locomotion:NavMove(self.m_dest, 200)
        end
    end

    return self:Continue()
end

function BehFlank:OnEnd(bot, next)
    bot.m_Locomotion:NavClear()
end

function BehFlank:OnMoveToFailure(bot, path, reason)
	if (self.m_retryCount < 3) then
		self.m_retryCount = self.m_retryCount + 1
		local enemy = GetEnemy(bot)
		if (!IsValid(enemy)) then
			return self:TryDone(CMBAction.RESULT_CRITICAL, "No enemy to flank")
		end
		
		self.m_dest = FindFlankPos(bot, enemy)
	else
		return self:TryDone(CMBAction.RESULT_CRITICAL, "Path failed too many times")
	end
	
	return self:TryContinue()
end

function BehFlank:OnStuck(bot)
	bot.loco:ClearStuck()
	return self:TryDone(CMBAction.RESULT_CRITICAL, "Got stuck while flanking")
end

-- ============================================================
-- Патрулирование местности
-- ============================================================

BehDefensive = setmetatable({}, { __index = CMBAction })
BehDefensive.__index = BehDefensive

function BehDefensive:New()
    local b = CMBAction.New(self, "Defensive")
    b.m_pathTimer = 0
	b.m_nextCheck = 0
    return b
end

function BehDefensive:OnStart(bot, prior)
    bot.m_Locomotion.m_navSpeed = 75
    return self:Continue()
end

function BehDefensive:Update(bot, dt)
    if (IsValid(GetEnemy(bot))) then return self:Done("Enemy spotted") end

    if (CurTime() > self.m_pathTimer) then
		if (bot.m_dontPatrol) then self:Continue() end
		
        self.m_pathTimer = CurTime() + 6.5
        local offsets = {
            Vector(300,0,0), Vector(-300,0,0), Vector(0,300,0), Vector(0,-300,0),
            Vector(220,220,0), Vector(-220,-220,0),
        }
        local areas = {}
        for _, off in ipairs(offsets) do
            local a = navmesh.GetNearestNavArea(bot:GetPos() + off, false, 200)
            if a then table.insert(areas, a) end
        end
        if (#areas > 0) then
            bot.m_Locomotion:NavMove(areas[math.random(#areas)]:GetCenter(), 75)
        end
    end

    return self:Continue()
end

function BehDefensive:OnEnd(bot, next)
    bot.m_Locomotion:NavClear()
end

function BehDefensive:OnResume(bot, intr)
    bot.m_Locomotion:NavClear()
	
	if (self.m_pathTimer) then
		self.m_pathTimer = CurTime() + 10
	end
end

function BehDefensive:OnSight(bot, ent)
	return self:TryContinue()
end

function BehDefensive:OnCommandString(bot, command)
	return self:TryContinue()
end

-- ============================================================
-- Установить линию огня (главная логика солдата)
-- ============================================================

BehELOF = setmetatable({}, { __index = CMBAction })
BehELOF.__index = BehELOF

function BehELOF:New()
    local b = CMBAction.New(self, "EstablishLineOfFire")
    b.m_nextStrafeDecision = 0
    b.m_nextFlankOrder = 0
	b.m_nextAttackSound = CurTime() + 5
    return b
end

function BehELOF:OnStart(bot, prior)
    bot.m_Locomotion.m_navSpeed = bot.m_overrideNavSpeed or 150
    bot.m_Locomotion.m_strafeDir = 0
    bot.m_Locomotion.m_strafeEnemy = NULL
    return self:Continue()
end

function BehELOF:Update(bot, dt)
    local enemy = GetEnemy(bot)

    if (!IsValid(enemy)) then
        bot.m_Locomotion:Stop()
		
		if (IsValid(self.m_escortEnt)) then
			return self:SuspendFor(BehEscort:New(self.m_escortEnt), "Continue escorting")
		end
		
		if (!bot.m_flagAggressive) then
            return self:SuspendFor(BehDefensive:New(), "No enemy, patrolling alone")
        end
		
        return self:Continue()
    end

    local dist = bot:GetPos():Distance(enemy:GetPos())

    -- Ближний бой
    if (dist <= MELEE_RANGE && CurTime() > (bot.m_meleeCooldown or 0)) then
        bot.m_meleeCooldown = CurTime() + 2.5
        bot:DoMelee(enemy)
        return self:SuspendFor(BehMeleeRetreat:New(), "Melee")
    end

    -- Приказ фланга от командира
    if (bot.m_pendingFlank) then
        local fe = bot.m_pendingFlankEnemy
        bot.m_pendingFlank = false
        bot.m_pendingFlankEnemy = nil
        bot:EmitMasterBotSound("Flank", 40, { 0.1, 0.5 })
        return self:SuspendFor(BehFlank:New(fe), "Flank order")
    end

    if (!CanSee(bot, enemy)) then
        return self:SuspendFor(BehChase:New(), "Enemy out of LOS")
    end

    if (CanSee(bot, enemy) && bot:GetRangeTo(enemy:GetPos()) > bot.m_wpn.m_flFireRange) then
        return self:SuspendFor(BehGetThreat:New(), "Enemy out of fire range")
    end

    -- Командир раздаёт приказы на флангование
    if (CMasterBotSquadManager:IsLeader(bot) && CurTime() > self.m_nextFlankOrder) then
        self.m_nextFlankOrder = CurTime() + math.random(FLANK_COOLDOWN[1], FLANK_COOLDOWN[2])
		local members = CMasterBotSquadManager:GetBotSquadMembers(bot)
        for _, m in ipairs(members) do
            if IsValid(m) && m:EntIndex() != bot:EntIndex() then
                if (!m.m_flagDontFlank) then
                    m.m_pendingFlank = true
                    m.m_pendingFlankEnemy = enemy
                end
            end
        end
    end

    -- Держать дистанцию от напарников
    self:KeepSpacing(bot)

	-- Страф (влево вправо), только выбор направления, исполняется в ThinkMove
    if (!bot.m_flagDontStrafe) then
        self:DecideStrafe(bot, enemy)
    end

    if (CurTime() > self.m_nextAttackSound) then
        self.m_nextAttackSound = CurTime() + math.random(10.0, 30.0)
        bot:EmitMasterBotSound("Attack", 60)
    end

    return self:Continue()
end

-- Выбираем направление страфа в ThinkMove()
function BehELOF:DecideStrafe(bot, enemy)
    if (CurTime() < self.m_nextStrafeDecision) then return end
    self.m_nextStrafeDecision = CurTime() + STRAFE_INTERVAL + math.random() * 0.6

    local r = math.random(100)
    local dir
    if (r <= 33) then
        dir = CanStrafe(bot, -1) and -1 or (CanStrafe(bot, 1) and 1 or 0)
    elseif (r <= 66) then
        dir = CanStrafe(bot, 1) and  1 or (CanStrafe(bot, -1) and -1 or 0)
    else
        dir = 0
    end
	
	-- Вычисляем точку страфа один раз, а не каждый раз при изменении позиции
	-- Сделано из-за того, что в мультиплеере мастербот будет передвигаться дерганно
    if (dir != 0) then
		local toEnemy  = (enemy:GetPos() - bot:GetPos()):GetNormalized()
        local perp     = Vector(-toEnemy.y, toEnemy.x, 0)
        local rawDest  = bot:GetPos() + perp * (dir * 110)
		
		bot.m_Locomotion.m_strafeDest = rawDest
		bot.m_Locomotion.m_strafeDir   = dir
		bot.m_Locomotion.m_strafeEnemy = enemy
		bot.m_Locomotion.m_navDest     = nil
		bot.m_Locomotion.m_navSpeed    = bot.m_overrideNavSpeedStrafe or 150
    else
        bot.m_Locomotion.m_strafeDest = nil
		bot.m_Locomotion.m_strafeDir = 0
    end
end

function BehELOF:KeepSpacing(bot)
    for _, m in ipairs(CMasterBotSquadManager:GetBotSquadMembers(bot)) do
        if (IsValid(m) and m != bot) then
            if (bot:GetPos():Distance(m:GetPos()) < SQUAD_SPACING) then
                local away   = (bot:GetPos() - m:GetPos()):GetNormalized()
                local target = bot:GetPos() + away * (SQUAD_SPACING * 1.5)
                -- Маленький прямой толчок
                bot.loco:Approach(target, 0.7)
                return
            end
        end
    end
end

function BehELOF:OnResume(bot, intr)
    bot.m_Locomotion.m_strafeDir   = 0
    bot.m_Locomotion.m_strafeEnemy = NULL
    bot.m_Locomotion.m_strafeDest = nil
    bot.m_Locomotion:NavClear()
end

function BehELOF:SelectTargetPoint(bot, subject)
	-- Если близко, целимся в голову
	if (IsValid(subject)) then
		local dist1 = bot.m_wpn.m_flFireRange / 1.6
		local dist = dist1 * dist1
		
		if (bot:GetPos():DistToSqr(subject:GetPos()) <= dist) then
			-- Голова видна, целимся в нее, иначе в центр
			if (bot.m_Vision:IsLineOfSightClearEntPos(subject, subject:EyePos(), true)) then
				return subject:EyePos()
			end
		end
	end
	
	-- Далеко, используем дефолт
	return nil
end

function BehELOF:OnSightOnce(bot, ent)
	-- Мы можем замечать не только враждебных целей, но и нейтралов
	if (!bot.m_Vision:IsEnemy(ent)) then return self:TryContinue() end
	
	-- Первый раз увидели противника, говорим об этом с задержкой от 0.1 секунды до 0.45
	bot:EmitMasterBotSound("Enemy", nil, { 0.1, 0.45 })
	
	return self:TryContinue()
end

function BehELOF:OnSight(bot, ent)
	-- Мастербот может замечать и дружественные цели
	if (!bot.m_Vision:IsEnemy(ent)) then return end

	-- Увидел противника, даю знать всем своим товарищам в отряде
	
	if (bot.m_squadId) then
		local members = CMasterBotSquadManager:GetBotSquadMembers(bot)
		for _, m in ipairs(members) do
			if (IsValid(m) && m:EntIndex() != bot:EntIndex() && !IsValid(GetEnemy(m))) then
				if (m.SetEnemy) then
					m:SetEnemy(ent)
				else
					m.m_Vision:AddKnownEntity(ent)
				end
				m:SetEnemy(ent)
			end
		end
	end
	
	return self:TryContinue()
end

function BehELOF:OnCommandApproachEnt(bot, target)
	local curAction = bot.m_Behavior:DeepActive()
	
	-- Не добавляем новое действие, просто обновляем уже текущее действие
	if (curAction && curAction:Name() == "Escort") then
		self.m_escortEnt = target
		curAction.m_subject = target
	else
		self.m_escortEnt = target
		return self:TrySuspendFor(BehEscort:New(target), CMBAction.RESULT_TRY, "Escorting the target")
	end
	
	return self:TryContinue()
end

BehMoveToPoint = setmetatable({}, { __index = CMBAction })
BehMoveToPoint.__index = BehMoveToPoint

function BehMoveToPoint:New(point, speed)
	local b = CMBAction.New(self, "MoveToPoint")
	b.m_dest = point
	b.m_runSpeed = speed or 80
	b.m_destUpdate = 0
	return b
end

function BehMoveToPoint:Update(bot, dt)
	if (!self.m_dest) then
		return self:Done("No destination")
	end
	
	if (bot.m_Vision:GetPrimaryKnownThreat() != nil) then
		return self:Done("Enemy spotted")
	end
	
	if (self.m_dest && CurTime() > self.m_destUpdate) then
		bot.m_Locomotion:NavMove(self.m_dest, self.m_runSpeed)
		self.m_destUpdate = CurTime() + PATH_RATE
	end
	
	--if (bot.m_Locomotion:IsArrived(75)) then
	if (bot.m_Locomotion:IsArrived()) then
		return self:Done("Arrived to point")
	end
	
	return self:Continue()
end

function BehMoveToPoint:OnEnd(bot, next)
    bot.m_Locomotion:NavClear()
end

BehEscort = setmetatable({}, { __index = CMBAction })
BehEscort.__index = BehEscort

function BehEscort:New(subject)
	local b = CMBAction.New(self, "Escort")
	b.m_subject = subject
	b.m_runSpeed = 80
	b.m_destUpdate = 0
	return b
end

function BehEscort:Update(bot, dt)
	if (!IsValid(self.m_subject)) then
		return self:Done("No subject")
	end
	
	if (bot.m_Vision:GetPrimaryKnownThreat() != nil) then
		return self:Done("Enemy spotted")
	end
	
	local dest = bot:GetPos():DistToSqr(self.m_subject:GetPos())
	local destToRun = 500.0 * 500.0
	
	if (dest > destToRun) then
		self.m_runSpeed = 200
		bot.m_Body:PressShiftButton()
	else
		self.m_runSpeed = 80
	end
	
	if (CurTime() > self.m_destUpdate) then
		bot.m_Locomotion:NavMove(self.m_subject:GetPos(), self.m_runSpeed)
		self.m_destUpdate = CurTime() + PATH_RATE
	end
	
	if (bot.m_Locomotion:IsArrived(70)) then
		bot.m_Locomotion:Stop()
		return self:Continue()
	end
	
	return self:Continue()
end

function BehEscort:OnEnd(bot, next)
	bot.m_Locomotion:NavClear()
end

-- TODO: Доделать

BehOpenDoor = setmetatable({}, { __index = CMBAction })
BehOpenDoor.__index = BehOpenDoor

function BehOpenDoor:New(door, button)
	local b = CMBAction.New(self, "OpenDoor")
	b.m_door = door
	b.m_button = button
	b.m_pathTimer = CurTime()
	b.m_clicked = false
	b.m_timeout = CurTime() + 10
	return b
end

function BehOpenDoor:Update(bot, dt)
	
	if (!IsValid(self.m_door)) then
		return self:Done("No door")
	end
	
	if (self.m_door:GetInternalVariable("m_toggle_state") == 0) then
		return self:Done("Door is already opened")
	end
	
	if (CurTime() > self.m_timeout) then
		return self:Done("Timeout")
	end
	
	local goalPos = self.m_door:GetPos()
	
	if (IsValid(self.m_button)) then
		goalPos = self.m_button:GetPos()
	end
	
	bot.m_Body:PressShiftButton()
	
	if (CurTime() > self.m_pathTimer) then
		self.m_pathTimer = CurTime() + 0.30
		bot.m_Locomotion:NavMove(goalPos)
	end
	
	if (bot:GetPos():DistToSqr(goalPos) <= 70.0 * 70.0) then
		if (IsValid(self.m_button)) then
			if (!self.m_clicked) then
				bot.m_Body:AimHeadTowardsPos(self.m_button:GetPos(), CMasterBotBody.MANDATORY, 1.0, "Aiming at button")
				self.m_button:Use(bot)
				self.m_clicked = true
			end
		elseif (IsValid(self.m_door)) then
			if (!self.m_clicked) then
				bot.m_Body:AimHeadTowardsPos(self.m_door:WorldSpaceCenter(), CMasterBotBody.MANDATORY, 1.0, "Aiming at door")
				self.m_door:Use(bot)
				self.m_clicked = true
			end
		end
	end
	
	local iDoorState = self.m_door:GetInternalVariable("m_toggle_state")
	
	if (iDoorState == 0) then
		return self:Done("Opened door")
	end
	
	return self:Continue()
end

function BehOpenDoor:OnEnd(bot)
	bot.m_Locomotion:NavClear()
	return self:Continue()
end

-- TODO: Доделать

BehEscapeGrenade = setmetatable({}, { __index = CMBAction })
BehEscapeGrenade.__index = BehEscapeGrenade

function BehEscapeGrenade:New(grenade)
	local b = CMBAction.New(self, "EscapeGrenade")
	b.m_grenade = grenade
	b.m_pathTimer = CurTime()
	return b
end

function BehEscapeGrenade.GetGrenadeReactionTime(bot)
	local skill = bot.m_iBotSkill
	
	if (skill) then
		if (skill == 0) then return 2.0
		elseif (skill == 1) then return 1.0
		elseif (skill == 2) then return 0.8
		elseif (skill == 3) then return 0.5 end
	end
	
	return 2.0
end

function BehEscapeGrenade:Update(bot, dt)
	-- TODO: Доделать
	-- После обнаружения гранаты, мы собираем враждебных энтити через ents.FindInSphere и ищем позицию
	-- где противников не будет, чтобы бот не бежал к противникам, спасаясь от взрыва гранаты
	if (!IsValid(self.m_grenade)) then
		return self:Done("No grenade")
	end
	
	local dir = bot:GetPos() - self.m_grenade:GetPos()
	dir:Normalize()
	local escapePoint = bot:GetPos() + (dir * -500)
	
	-- local nearestArea = navmesh.GetNearestNavArea(escapePoint, true, 300)
	
	-- if (nearestArea) then
		-- --escapePoint = nearestArea:GetClosestPointOnArea(
	-- end
	
	bot.m_Body:PressShiftButton()
	
	if (CurTime() > self.m_pathTimer) then
		self.m_pathTimer = CurTime() + 0.3
		bot.m_Locomotion:NavMove(escapePoint, 200)
	end
	
	return self:Continue()
end

function BehEscapeGrenade:NavClear(bot)
	bot.m_Locomotion:NavClear()
end

-- TODO: Протестить

BehSilentApproachThreat = setmetatable({}, { __index = CMBAction })
BehSilentApproachThreat.__index = BehSilentApproachThreat

function BehSilentApproachThreat:New(subject)
	local b = CMBAction.New(self, "SilentApproachThreat")
	b.m_pathTimer = CurTime()
	b.m_nextEnemiesCheckTimer = CurTime()
	b.m_subject = subject
	return b
end

function BehSilentApproachThreat:Update(bot, dt)
	local enemy = self.m_subject
	
	if (!IsValid(enemy)) then
		return self:Done("No threat")
	end
	
	-- Если враг видит меня и навелся на меня, то забрасываем
	if (bot.m_Vision:IsAbleToSee(enemy, false) && bot.m_Intention:IsThreatAimingTowardMe(enemy)) then
		return self:Done("My silent approach is blowen up!")
	end
	
	-- Проверяем на наличие других противников, которые могут спалить меня
	-- Если такой противник нашелся, и он смотрит на меня, то забрасываем
	if (CurTime() > self.m_nextEnemiesCheckTimer) then
		self.m_nextEnemiesCheckTimer = CurTime() + 0.5
		
		local nearby = ents.FindInSphere(bot:GetPos(), 800)
		
		local n = #nearby
		for i = 1, n do
			local ent = nearby[i]
			if (ent:IsPlayer() || ent:IsNPC() || ent:IsNextBot()) then
				if (ent:EntIndex() == bot:EntIndex()) then continue end
				if (bot.m_Vision:IsIgnored(ent)) then continue end
				if (!ent:Alive()) then continue end
				
				if (bot.m_Vision:IsAbleToSee(ent, false)) then
					if (bot.m_Intention:IsThreatAimingTowardMe(ent)) then
						return self:Done("Someone else blowen up my silent approach!")
					end
				end
			end
		end
	end
	
	if (CurTime() > self.m_pathTimer) then
		self.m_pathTimer = CurTime() + 0.3
		bot.m_Locomotion:NavMove(enemy:GetPos(), 100)
	end
	
	-- Удалось подкраться
	if (bot:GetPos():DistToSqr(enemy:GetPos()) < 300.0 * 300.0) then
		return self:Done("Approached my threat, attack!")
	end
	
	return self:Continue()
end

function BehSilentApproachThreat:OnEnd(bot, next)
	-- Пробуем подкрасться в следующий раз
	bot.m_silentApproachTimer = CurTime() + math.Rand(10.0, 20.0)
	bot.m_Locomotion:NavClear()
	return self:Continue()
end

function BehSilentApproachThreat:OnInjured(bot)
	return self:TryDone(CMBAction.RESULT_CRITICAL, "Someone else attacked me while silent approach, abandon it")
end

function BehSilentApproachThreat:OnStuck(bot)
	return self:TryDone(CMBAction.RESULT_CRITICAL, "Got stuck while silent approach, abandon it")
end

function BehSilentApproachThreat:ShouldAttack(bot)
	return CMBAction.ANSWER_NO
end

function BehSilentApproachThreat:ShouldHurry(bot)
	return CMBAction.ANSWER_YES
end

function BehSilentApproachThreat:ShouldRetreat(bot)
	return CMBAction.ANSWER_NO
end

BehGuard = setmetatable({}, { __index = CMBAction })
BehGuard.__index = BehGuard

function BehGuard:New(objectToGuard, seq, ignoreEnemies)
	local b = CMBAction.New(self, "Guard")
	b.m_objectToGuard = objectToGuard
	b.m_seq = seq
	b.m_ignoreEnemies = ignoreEnemies
	return b
end

function BehGuard:OnStart(bot)
	
	return self:Continue()
end

function BehGuard:Update(bot, dt)
	if (IsValid(GetEnemy(bot)) && !ignoreEnemies) then
		return self:Done("Enemy spotted")
	end
	
	bot.m_Locomotion:Stop()
	
	return self:Continue()
end

function BehGuard:OnInjured(bot, dmginfo)
	if (!self.m_ignoreEnemies) then
		return self:TryDone(CMBAction.RESULT_CRITICAL, "Got injured, abandon guard")
	end
	
	return self:TryContinue()
end

function BehGuard:OnOtherKilled(bot)
	
	
	
	return self:TryContinue()
end

function BehGuard:OnCommandString(bot, command)
	
	if (command == "stop guard") then
		return self:TryDone(CMBAction.RESULT_CRITICAL, "Got command to stop guarding")
	end
	
	return self:TryContinue()
end

function BehGuard:OnCommandApproachPos(bot, pos)
	
	--return self:TrySustain(CMBAction.RESULT_CRITICAL, "Got command to move")
	return self:TryContinue()
end

BehTalkToPlayer = setmetatable({}, { __index = CMBAction })
BehTalkToPlayer.__index = BehTalkToPlayer

function BehTalkToPlayer:New(subject)
	local b = CMBAction.New(self, "TalkToPlayer")
	b.m_subject = subject
	return b
end

function BehTalkToPlayer:OnStart(bot)
	return self:Continue()
end

function BehTalkToPlayer:Update(bot, dt)
	if (!IsValid(self.m_subject)) then
		return self:Done("No subject to talk to")
	end
	
	if (bot.m_Vision:GetPrimaryKnownThreat()) then
		return self:Done("Enemy spotted")
	end
	
	local nearby = 75.0 * 75.0
	if (bot:GetPos():DistToSqr(self.m_subject:GetPos()) > nearby) then
		return self:Done("Subject is too far away")
	end
	
	bot.m_Locomotion:Stop()
	
	bot.m_Body:AimHeadTowardsPos(self.m_subject:EyePos(), CMasterBotBody.MANDATORY, 1.0, "Looking at my subject that talk with me")
	
	return self:Continue()
end

function BehTalkToPlayer:OnEnd(bot, next)
    bot.m_Locomotion:NavClear()
end

function BehTalkToPlayer:OnInjured(bot)
	return self:TryDone(CMBAction.RESULT_CRITICAL, "Got injured")
end

function BehTalkToPlayer:OnOtherKilled(bot)
	return self:TryContinue()
end

-- TODO: Доделать

BehMeleeAttack = setmetatable({}, { __index = CMBAction })
BehMeleeAttack.__index = BehMeleeAttack

function BehMeleeAttack:New()
    local b = CMBAction.New(self, "MeleeAttack")
    b.m_destUpdate = 0
    return b
end

function BehMeleeAttack:OnStart(bot, prior)
    self.m_destUpdate = 0
	bot.m_Locomotion.m_navSpeed = 200
    return self:Continue()
end

function BehMeleeAttack:Update(bot, dt)
	local threat = bot.m_Vision:GetPrimaryKnownThreat()
	
	if (!threat) then
		return self:Done("No enemy")
	end
	
	if (bot:GetPos():DistToSqr(threat:GetPos()) > 70.0 * 70.0) then
		if (CurTime() > self.m_destUpdate) then
			self.m_destUpdate = CurTime() + 0.25
			bot.m_Locomotion:NavMove(threat:GetPos(), bot.m_Locomotion.m_navSpeed)
		end
	end
	
    return self:Continue()
end

function BehMeleeAttack:OnResume(bot, intr)
    return self:Continue()
end

function BehMeleeAttack:OnEnd(bot, next)
    bot.m_Locomotion:NavClear()
	return self:Continue()
end

function BehMeleeAttack:ShouldAttack()
	return CMBAction.ANSWER_YES
end

function BehMeleeAttack:ShouldHurry()
	return CMBAction.ANSWER_YES
end

function BehMeleeAttack:ShouldRetreat()
	return CMBAction.ANSWER_NO
end

-- TODO: Доделать

BehAttack = setmetatable({}, { __index = CMBAction })
BehAttack.__index = BehAttack

function BehAttack:New(subject)
	local b = CMBAction.New(self, "Attack")
	b.m_subject = subject
	return b
end

function BehAttack:Update(bot, dt)
	local threat = bot.m_Vision:GetPrimaryKnownThreat()
	
	if (!threat) then
		return self:Done("No threat")
	end
	
	if (!threat:IsVisibleRecently()) then
		if (threat:IsVisibleRecently()) then
			
		else
			if (bot:GetPos():DistToSqr(threat:GetLastKnownPosition()) < 70.0 * 70.0) then
				
				return self:Done("I lost my target!")
			end
			
			if (bot:GetPos():DistToSqr(threat:GetLastKnownPosition()) < 1000.0 * 1000.0) then
				bot.m_Body:AimHeadTowardsPos(threat:GetLastKnownPosition() + Vector(0, 0, 72), CMasterBotBody.IMPORTANT, 0.2, "Looking towards where we lost sight of our victim")
			end
		end
	end
	
	return self:Continue()
end

-- TODO: Доделать

BehDestroyEnemySentry = setmetatable({}, { __index = CMBAction })
BehDestroyEnemySentry.__index = BehDestroyEnemySentry

local function FindSafeAttackAreaOper(area, priorArea, travelDistanceSoFar)
	
end

function BehDestroyEnemySentry:ComputeSafeAttackSpot(bot)
	self.m_hasSafeAttackSpot = false
	
	
end

BehCheckNoise = setmetatable({}, { __index = CMBAction })
BehCheckNoise.__index = BehCheckNoise

function BehCheckNoise:New(pos)
	local b = CMBAction.New(self, "CheckNoise")
	b.m_wait = 0
	b.m_lastPos = vector_origin
	b.m_pathTimer = 0
	b.m_isArrivedFirtSpot = false
	b.m_dest = pos
	b.m_retries = 0
	b.m_nextTryLook = 0
	return b
end

function BehCheckNoise:OnStart(bot, pr)
	self.m_wait = CurTime() + 3.0
	self.m_lastPos = bot:GetPos()
	return self:Continue()
end

function BehCheckNoise:Update(bot, dt)
	if (bot.m_Vision:GetPrimaryKnownThreat()) then
		return self:Done("Enemy spotted")
	end
	
	-- Стоим и смотрим на подозрительный звук
	if (self.m_wait > CurTime()) then
		return self:Continue()
	end
	
	-- После этого мы свободно идем к звуку
	if (CurTime() > self.m_pathTimer) then
		self.m_pathTimer = CurTime() + 0.3
		bot.m_Locomotion:NavMove(self.m_dest, 150)
	end
	
	-- Прибыли на место, ждем несколько секунд, оглядываясь
	if (!self.m_isArrivedFirtSpot && bot.m_Locomotion:IsArrived(10)) then
		self.m_isArrivedFirtSpot = true
		
		self.m_waitForNextSpot = CurTime() + math.Rand(5.0, 8.0)
	end
	
	if (self.m_isArrivedFirtSpot) then
		
		if (self.m_retries < 3 && CurTime() > self.m_nextTryLook) then
			local pos = bot.m_Body:GetEyePosition()
			local randomDir = Vector(math.Rand(-1, 1), math.Rand(-1, 1), 0)
			local pos = pos + randomDir * 100
			
			bot.m_Body:AimHeadTowardsPos(pos, CMasterBotBody.IMPORTANT, 2.0, "Looking around for a strange noise")
			self.m_retries = self.m_retries + 1
			self.m_nextTryLook = CurTime() + 2.0
		end
	end
	
	-- Ничего не нашли, возвращаемся на исходную позицию и заканчиваем действие
	if (self.m_retries >= 3) then
		self.m_dest = self.m_lastPos
		return self:Continue()
		--return self:Done("Done")
	end
	
	if (self.m_retries >= 3 && bot.m_Locomotion:IsArrived()) then
		return self:Done("Done")
	end
	
	return self:Continue()
end

function BehCheckNoise:OnEnd(bot, next)
    bot.m_Locomotion:NavClear()
end