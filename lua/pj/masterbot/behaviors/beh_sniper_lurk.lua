-- Главная логика снайпера
-- Если Вы хотите, чтобы снайпер передвигался по карте, а не стоял на одной точке, установите m_snipingGoalEntity
-- self.m_Behavior:DeepActive().m_snipingGoalEntity = Entity(1)
-- Если Вы хотите, чтобы снайпер смотрел в разные стороны, а не в одну точку, используйте аддон CMasterBotLookAround
-- 
-- Main logic for sniper
-- If you want the sniper to move around the map instead of standing in one spot, set m_snipingGoalEntity
-- self.m_Behavior:DeepActive().m_snipingGoalEntity = Entity(1)
-- If you want the sniper to look in different directions instead of at one spot, use CMasterBotLookAround addon

local SNIPER_SPOT_MIN_RANGE           = 1000
local SNIPER_SPOT_MAX_COUNT           = 10
local SNIPER_SPOT_SEARCH_COUNT        = 10
local SNIPER_SPOT_POINT_TOLERANCE     = 750
local SNIPER_SPOT_EPSILON             = 100
local SNIPER_GOAL_ENTITY_MOVE_TOL     = 500

local SNIPER_PATIENCE_DURATION        = 10
local SNIPER_TARGET_LINGER_DURATION   = 2
local SNIPER_ALLOW_OPPORTUNISTIC      = true
local SNIPER_MELEE_RANGE              = 200
local SNIPER_DEBUG                    = false

local HOME_RANGE                      = 60 --25
local EYE_OFFSET_Z                    = 60

local REPATH_MIN                      = 1.0
local REPATH_MAX                      = 2.0
local FIND_HOME_MIN                   = 1.0
local FIND_HOME_MAX                   = 2.0
local RETRY_SPOT_SETUP_MIN            = 5.0
local RETRY_SPOT_SETUP_MAX            = 10.0

local HINT_CLASS                      = "func_tfbot_hint"
local HINT_NEAR_RANGE                 = 500

local SNIPER_AIM_ERROR				  = 0.01

local function RandFloat(lo, hi)
	return lo + math.Rand(0, 1) * (hi - lo)
end

local function RandInt(lo, hi)
	return math.random(lo, hi)
end

local function NavAreaRandomPoint(area)
	if (area.GetRandomPoint) then
		local p = area:GetRandomPoint()
		if p then return p end
	end
	local c = area:GetCenter()
	return c + Vector(math.Rand(-40, 40), math.Rand(-40, 40), 0)
end

-- расстояние от центра nav-зоны до цели
local function GetAreaGoalDistance(area, goalCenter)
	return area:GetCenter():Distance(goalCenter)
end

local function GetSnipingGoal(bot)
	if (bot.m_snipingGoalEntity && IsValid(bot.m_snipingGoalEntity)) then
		return bot.m_snipingGoalEntity, bot.m_snipingGoalEntity:GetPos() + bot.m_snipingGoalEntity:OBBCenter()
	end
	if (bot.m_snipingGoalPos) then
		return nil, bot.m_snipingGoalPos
	end
	return nil, nil
end

local function IsLineOfFireClearPositions(bot, fromPos, toPos)
	local filter = { bot }

	local tr = util.TraceLine({
		start  = fromPos,
		endpos = toPos,
		filter = filter,
		mask   = MASK_SHOT,
	})

	return tr.Fraction >= 0.99 or tr.Entity == nil
end

BehSniperLurk = setmetatable({}, { __index = CMBAction })
BehSniperLurk.__index = BehSniperLurk

local function CollectSphereTargets(bot)
	local entsInRange = ents.FindInSphere(bot:GetPos(), bot.m_Vision:GetMaxVisionRange())
	local candidates = {}
	
	for i = 1, #entsInRange do
		local ent = entsInRange[i]
		
		if (ent:IsPlayer() && ent:IsAlive() || ent:IsNPC() && ent:Health() > 0 || ent:IsNextBot()) then
			if (bot.m_Vision:IsEnemy(ent)) then
				candidates[#candidates + 1] = ent
			end
		end
	end
	
	return candidates
end

function BehSniperLurk.ClearSniperSpots(bot)
	bot.m_sniperSpotVector           = {}
	bot.m_sniperVantageAreaVector    = {}
	bot.m_sniperTheaterAreaVector    = {}
	bot.m_snipingGoalEntity          = nil
	bot.m_lastSnipingGoalEntityPosition = nil
	bot.m_retrySniperSpotSetupAt     = CurTime() + RandFloat(RETRY_SPOT_SETUP_MIN, RETRY_SPOT_SETUP_MAX)
end

-- Уже настроено для той же цели и она почти не сдвинулась
local function SniperSpotAccumulationIsCurrent(bot, goalEntity, goalCenter)
	if (!bot.m_lastSnipingGoalEntityPosition) then
		return false
	end

	if (goalCenter:Distance(bot.m_lastSnipingGoalEntityPosition) >= SNIPER_GOAL_ENTITY_MOVE_TOL) then
		return false
	end

	if (goalEntity) then
		if (goalEntity != bot.m_snipingGoalEntity) then
			return false
		end
	elseif (bot.m_snipingGoalEntity) then
		return false
	end

	local vantageAreas = bot.m_sniperVantageAreaVector
	local theaterAreas = bot.m_sniperTheaterAreaVector
	if (!vantageAreas || #vantageAreas == 0 || !theaterAreas || #theaterAreas == 0) then
		return false
	end
	
	return true
end

function BehSniperLurk.SetupSniperSpotAccumulation(bot)
	local goalEntity, goalCenter = GetSnipingGoal(bot)
	if (!goalCenter) then
		BehSniperLurk.ClearSniperSpots(bot)
		return
	end

	if (SniperSpotAccumulationIsCurrent(bot, goalEntity, goalCenter)) then
		return
	end

	BehSniperLurk.ClearSniperSpots(bot)

	local goalEntityArea = navmesh.GetNearestNavArea(goalCenter, false, 500, true, true)
	if (!goalEntityArea) then
		return
	end

	local isDefendingPoint = bot.m_sniperDefendingGoal ~= false
	local goalDist0 = GetAreaGoalDistance(goalEntityArea, goalCenter)

	local vantageAreas = bot.m_sniperVantageAreaVector
	local theaterAreas = bot.m_sniperTheaterAreaVector
	local myTolerance = SNIPER_SPOT_POINT_TOLERANCE

	if (!isDefendingPoint) then
		myTolerance = -myTolerance
	end

	local allAreas = navmesh.GetAllNavAreas()
	for i = 1, #allAreas do
		local area = allAreas[i]
		if (!IsValid(area)) then continue end

		local areaDist = GetAreaGoalDistance(area, goalCenter)

		if (areaDist > goalDist0 + 50) then
			theaterAreas[#theaterAreas + 1] = area
		end

		if (isDefendingPoint) then
			if (areaDist <= goalDist0 + myTolerance) then
				vantageAreas[#vantageAreas + 1] = area
			end
		else
			if (areaDist >= goalDist0 + math.abs(myTolerance)) then
				vantageAreas[#vantageAreas + 1] = area
			end
		end
	end

	bot.m_snipingGoalEntity = goalEntity
	bot.m_lastSnipingGoalEntityPosition = Vector(goalCenter)
end

function BehSniperLurk.AccumulateSniperSpots(bot)
	BehSniperLurk.SetupSniperSpotAccumulation(bot)

	local vantageAreas = bot.m_sniperVantageAreaVector or {}
	local theaterAreas = bot.m_sniperTheaterAreaVector or {}

	if (#vantageAreas == 0 || #theaterAreas == 0) then
		if (CurTime() >= (bot.m_retrySniperSpotSetupAt || 0)) then
			BehSniperLurk.ClearSniperSpots(bot)
		end
		return
	end

	local _, goalCenter = GetSnipingGoal(bot)
	goalCenter = goalCenter or bot:GetPos()

	local spots = bot.m_sniperSpotVector or {}
	bot.m_sniperSpotVector = spots

	local eyeOffset = Vector(0, 0, EYE_OFFSET_Z)

	for _ = 1, SNIPER_SPOT_SEARCH_COUNT do
		local vantageArea = vantageAreas[RandInt(1, #vantageAreas)]
		local theaterArea = theaterAreas[RandInt(1, #theaterAreas)]

		local vantageSpot = NavAreaRandomPoint(vantageArea)
		local theaterSpot = NavAreaRandomPoint(theaterArea)

		local range = vantageSpot:Distance(theaterSpot)
		if (range < SNIPER_SPOT_MIN_RANGE) then
			continue
		end

		local tooClose = false
		for j = 1, #spots do
			if (vantageSpot:Distance(spots[j].vantageSpot) < SNIPER_SPOT_EPSILON) then
				tooClose = true
				break
			end
		end
		if (tooClose) then continue end

		if (!IsLineOfFireClearPositions(bot, vantageSpot + eyeOffset, theaterSpot + eyeOffset)) then
			continue
		end

		local advantage = GetAreaGoalDistance(vantageArea, goalCenter) - GetAreaGoalDistance(theaterArea, goalCenter)

		local info = {
			vantageArea  = vantageArea,
			vantageSpot  = vantageSpot,
			theaterArea  = theaterArea,
			theaterSpot  = theaterSpot,
			range        = range,
			advantage    = advantage,
		}

		if (#spots >= SNIPER_SPOT_MAX_COUNT) then
			local worst = 1
			for j = 2, #spots do
				if (spots[j].advantage < spots[worst].advantage) then
					worst = j
				end
			end
			if (info.advantage > spots[worst].advantage) then
				spots[worst] = info
			end
		else
			spots[#spots + 1] = info
		end
	end

	if (SNIPER_DEBUG) then
		for j = 1, #spots do
			debugoverlay.Cross(spots[j].vantageSpot, 5, 0.1, 255, 0, 255, true)
			debugoverlay.Line(spots[j].vantageSpot, spots[j].theaterSpot, 0.1, 0, 200, 0, true)
		end
	end
end

function BehSniperLurk.GetSniperSpots(bot)
	return bot.m_sniperSpotVector or {}
end

function BehSniperLurk:New()
	local b = CMBAction.New(self, "SniperLurk")
	b.m_homePosition = Vector(0, 0, 0)
	b.m_isHomePositionValid = false
	b.m_isAtHome = false
	b.m_failCount = 0
	b.m_isOpportunistic = SNIPER_ALLOW_OPPORTUNISTIC
	b.m_hintVector = {}
	b.m_priorHint = nil
	b.m_boredAt = 0
	b.m_repathAt = 0
	b.m_findHomeAt = 0
	
	b.m_aimAdjustTime = 0
	b.m_aimErrorAngle = 0
	b.m_aimErrorRadius = 0
	b.m_vectorUp = Vector(0, 0, 1)
	return b
end

function BehSniperLurk:OnStart(bot, prior)
	self.m_boredAt = CurTime() + RandFloat(0.9, 1.1) * SNIPER_PATIENCE_DURATION
	self.m_homePosition = bot:GetPos()
	self.m_isHomePositionValid = false
	self.m_isAtHome = false
	self.m_failCount = 0
	self.m_isOpportunistic = SNIPER_ALLOW_OPPORTUNISTIC
	self.m_hintVector = {}
	self.m_priorHint = nil
	self.m_repathAt = 0
	self.m_findHomeAt = 0

	if (!bot.m_sniperSpotVector) then
		BehSniperLurk.ClearSniperSpots(bot)
	end

	-- TODO: сделать хинты
	for _, hint in ipairs(ents.FindByClass(HINT_CLASS)) do
		if (!IsValid(hint)) then continue end

		
	end

	self.m_priorHint = nil
	
	bot.m_sniperIsLookingAroundForEnemies = true
	bot.m_canRetreatAfterDamage = false
	return self:Continue()
end

function BehSniperLurk:Update(bot, dt)
	BehSniperLurk.AccumulateSniperSpots(bot)

	if (!self.m_isHomePositionValid) then
		self:FindNewHome(bot)
	end

	local threat = bot.m_Vision:GetPrimaryKnownThreat()
	if (threat) then
		local ent = threat:GetEntity()
		if (!IsValid(ent) || !ent:Alive()) then
			threat = nil
		end
	end

	local isSightingRifle = false

	if (threat && threat:IsVisibleInFOVNow()) then
		self.m_failCount = 0

		local threatPos = threat:GetLastKnownPosition()
		if ((threatPos - bot:GetPos()):Length() < SNIPER_MELEE_RANGE) then
			local giveUpRange = 1.25 * SNIPER_MELEE_RANGE
			if (BehMeleeRetreat) then
				-- TOOD: Ближний бой
				return self:SuspendFor(BehMeleeRetreat:New(), "Melee attacking nearby threat")
			end
		end
	end

	if (threat && threat:GetTimeSinceLastSeen() < SNIPER_TARGET_LINGER_DURATION && IsValid(threat:GetEntity()) && bot.m_Vision:IsLineOfFireClear(threat:GetEntity())) then
		if (self.m_isOpportunistic) then
			isSightingRifle = true
			self.m_boredAt = CurTime() + RandFloat(0.9, 1.1) * SNIPER_PATIENCE_DURATION

			if (!self.m_isHomePositionValid) then
				self.m_homePosition = bot:GetPos()
			end
		end
	end

	local home2D = Vector(self.m_homePosition.x, self.m_homePosition.y, 0)
	local bot2D = Vector(bot:GetPos().x, bot:GetPos().y, 0)
	self.m_isAtHome = home2D:Distance(bot2D) < HOME_RANGE

	if (self.m_isAtHome) then
		isSightingRifle = true
		self.m_isOpportunistic = SNIPER_ALLOW_OPPORTUNISTIC

		if (CurTime() >= self.m_boredAt) then
			self.m_failCount = self.m_failCount + 1
			if (self:FindNewHome(bot)) then
				self.m_boredAt = CurTime() + RandFloat(0.9, 1.1) * SNIPER_PATIENCE_DURATION
			else
				self.m_boredAt = CurTime() + 1.0
			end
		end
		
		bot:SetDrawLaser(true)
	else
		self.m_boredAt = CurTime() + RandFloat(0.9, 1.1) * SNIPER_PATIENCE_DURATION
		bot:SetDrawLaser(false)
	end

	if (isSightingRifle) then
		bot.m_Locomotion:Stop()
		bot.m_isSighting = true
	else
		if (CurTime() >= self.m_repathAt) then
			self.m_repathAt = CurTime() + RandFloat(REPATH_MIN, REPATH_MAX)
			bot.m_Locomotion:NavMove(self.m_homePosition, bot.m_overrideNavSpeed or 150)
		end
		
		bot.m_isSighting = false
	end

	return self:Continue()
end

function BehSniperLurk:OnEnd(bot, nextAction)
	self:ReleaseHint()
	bot.m_Locomotion:NavClear()
	bot.m_sniperIsLookingAroundForEnemies = false
	bot:SetDrawLaser(false)
end

function BehSniperLurk:OnSuspend(bot, interruptingAction)
	self:ReleaseHint()
	bot:SetDrawLaser(false)
	bot.m_sniperIsLookingAroundForEnemies = false
end

function BehSniperLurk:OnResume(bot, interruptingAction)
	self.m_repathAt = 0
	self.m_priorHint = nil
	self:FindNewHome(bot)
	bot.m_sniperIsLookingAroundForEnemies = true
	return self:Continue()
end

function BehSniperLurk:ReleaseHint()
	if (IsValid(self.m_priorHint) and self.m_priorHint.SetOwnerEntity) then
		self.m_priorHint:SetOwnerEntity(nil)
	end
	self.m_priorHint = nil
end

function BehSniperLurk:FindHint(bot)
	local activeHints = {}
	for i = 1, #self.m_hintVector do
		local hint = self.m_hintVector[i]
		if (IsValid(hint)) then
			if (!hint.IsFor || hint:IsFor(bot)) then
				activeHints[#activeHints + 1] = hint
			end
		end
	end

	if #activeHints == 0 then
		return false
	end

	self:ReleaseHint()

	local hint = nil

	if (IsValid(self.m_priorHint) && self.m_failCount < 2) then
		local nearHints = {}
		local priorCenter = self.m_priorHint:GetPos()

		for i = 1, #activeHints do
			local h = activeHints[i]
			if (h == self.m_priorHint) then continue end
			if (h:GetPos():Distance(priorCenter) > HINT_NEAR_RANGE) then continue end
			if (h.GetOwner and IsValid(h:GetOwner())) then continue end
			nearHints[#nearHints + 1] = h
		end

		if (#nearHints == 0) then
			self.m_failCount = self.m_failCount + 1
			return false
		end

		hint = nearHints[RandInt(1, #nearHints)]
	else
		local victims = {}
		victims = CollectSphereTargets(bot)

		local hotHints = {}
		local freeHints = {}

		for i = 1, #activeHints do
			local h = activeHints[i]
			if (h.GetOwner and IsValid(h:GetOwner())) then continue end

			freeHints[#freeHints + 1] = h

			for p = 1, #victims do
				if (bot.m_Vision:IsLineOfSightClear(victims[p])) then
					local seePos = victims[p]:WorldSpaceCenter()
					local tr = util.TraceLine({
						start  = h:GetPos(),
						endpos = seePos,
						filter = { bot, victims[p] },
						mask   = MASK_SOLID_BRUSHONLY,
					})
					if (tr.Fraction >= 0.97) then
						hotHints[#hotHints + 1] = h
						break
					end
				end
			end
		end

		if (#hotHints > 0) then
			hint = hotHints[RandInt(1, #hotHints)]
		elseif (#freeHints > 0) then
			hint = freeHints[RandInt(1, #freeHints)]
		else
			hint = activeHints[RandInt(1, #activeHints)]
		end
	end

	if (!IsValid(hint)) then
		return false
	end

	local mins, maxs = hint:OBBMins(), hint:OBBMaxs()
	local center = hint:GetPos()
	local hintSpot = Vector(
		center.x + math.Rand(mins.x, maxs.x),
		center.y + math.Rand(mins.y, maxs.y),
		center.z + (mins.z + maxs.z) * 0.5
	)

	self.m_homePosition = hintSpot
	self.m_isHomePositionValid = true
	self.m_priorHint = hint

	if (hint.SetOwner) then
		hint:SetOwner(bot)
	end

	return true
end

function BehSniperLurk:FindNewHome(bot)
	if (CurTime() < self.m_findHomeAt) then
		return false
	end
	self.m_findHomeAt = CurTime() + RandFloat(FIND_HOME_MIN, FIND_HOME_MAX)

	if (self:FindHint(bot)) then
		return true
	end

	local spots = BehSniperLurk.GetSniperSpots(bot)
	if (#spots > 0) then
		local pick = spots[RandInt(1, #spots)]
		self.m_homePosition = pick.vantageSpot
		self.m_isHomePositionValid = true
		
		--print("Pick", pick.vantageSpot, pick.theaterSpot)
		return true
	end

	self.m_isHomePositionValid = false
	self.m_homePosition = bot:GetPos()
	return false
end

function BehSniperLurk:ShouldAttack(bot, them)
	return CMBAction.ANSWER_YES
end

function BehSniperLurk:ShouldRetreat(bot)
	return CMBAction.ANSWER_NO
end

function BehSniperLurk:SelectTargetPoint(bot, subject)
	-- На самом деле добавление ошибки к прицеливаю не играет какой либо роли
	-- Для видимого результата нужно использовать радиус от 0.1 до 0.2
	
	-- При ошибочном радиусе 0.01 отклонение от нужной позиции прицеливания составляет 0.010012521408498 hammer units или 0.00019 метров или 0.019 сантиметров или 0.19 милиметров
	-- Изначально планировал чтобы как только видел врага сначало он наводился с ошибкой, а потом стабилизировал прицел со временем
	-- Но мне кажется это и так дает слишком большую фору, из-за чего игроки будут постоянно выбегать из укрытия, стрелять и снова прятаться
	if (CurTime() > self.m_aimAdjustTime) then
		self.m_aimAdjustTime = CurTime() + math.Rand(0.5, 1.5)
		
		self.m_aimErrorAngle = math.Rand(-math.pi, math.pi)
		self.m_aimErrorRadius = math.Rand(0.0, 0.01)
	end
	
	local toThreat = subject:GetPos() - bot:GetPos()
	toThreat:Normalize()
	local threatRange = toThreat:Length2D()
	
	local s1 = math.sin(self.m_aimErrorRadius)
	local c1 = math.cos(self.m_aimErrorRadius)
	
	local err = threatRange * s1
	
	local up = self.m_vectorUp
	local side = toThreat:Cross(up)
	
	local s = math.sin(self.m_aimErrorAngle)
	local c = math.cos(self.m_aimErrorAngle)
	
	-- Easy
	-- Целимся в туловище / Aim for body
	local desiredAimSpot = subject:WorldSpaceCenter()
	
	-- Hard/Expert
	-- Целимся в точно в голову, скорость реакции и наводки зависит от уровня скилла бота
	-- Aim for a head, reaction time and tracking interval depends on bot skill value
	if (bot.m_iBotSkill >= 2) then
		desiredAimSpot = subject:EyePos()
	-- Normal
	-- Целимся примерно в голову, отклонение от головы примерно 9 хаммер юнитов или 0.17 метров или 17 сантиметров (9 * 0.01905)
	-- Aim for a head, deviation from  the head is approximately 9 hammer units or 0.17 meters or 17 centimeters (9 * 0.01905)
	elseif (bot.m_iBotSkill == 1) then
		desiredAimSpot = (subject:EyePos() + subject:EyePos() + subject:WorldSpaceCenter()) / 3.0
	end
	
	local imperfectAimSpot = desiredAimSpot + err * s * up + err * c * side
	
	return imperfectAimSpot
end

function BehSniperLurk:SelectMoreDangerousThreat(bot, threat1, threat2)
	if (!threat1) then return threat2 end
	if (!threat2) then return threat1 end
	
	if (!threat1:IsVisibleRecently()) then
		if (threat2:IsVisibleRecently()) then
			return threat2
		end
	elseif (!threat2:IsVisibleRecently()) then
		return threat1
	end
	
	if (threat1 && threat2) then
		local rangeSqr1 = bot:GetPos():DistToSqr(threat1:GetEntity():GetPos())
		local rangeSqr2 = bot:GetPos():DistToSqr(threat2:GetEntity():GetPos())
		
		local nearbyRangeSqr = 500.0 * 500.0
		
		if (rangeSqr1 < nearbyRangeSqr) then
			if (rangeSqr2 > nearbyRangeSqr) then
				return threat1
			end
		end
	elseif (rangeSqr2 < nearbyRangeSqr) then
		return threat2
	end
	
	-- Оба слишком близко или оба слишком далеко, используем выбор опасного противника по умолчанию
	-- Both of them are either too close or too far away, use default
	
	return nil
end

function BehSniperLurk:OnCommandSniper(bot, snipingGoal)
	
	self.m_snipingGoalEntity = snipingGoal
	
	return self:TryContinue()
end