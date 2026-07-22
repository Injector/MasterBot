
CMasterBotAddonLookAround = CMasterBotAddonLookAround or {}

local HUMAN_HEIGHT = 72
local GAZE_Z_OFFSET = 0.75 * HUMAN_HEIGHT
local AIM_ERROR_RAD = math.pi / 6

-- Дистанция у всех зон как минимум состовляет 1200, при слишком маленьком значении бот никуда не будет смотреть
--local BEHIND_TOLERANCE = 100
local BEHIND_TOLERANCE = 1200
local VISIBLE_BFS_DEPTH = 3
local INVASION_CACHE_TTL = 3.0
local GAZE_ENEMY_REJECT_DIST = 140
local GAZE_AIM_DOT_REJECT = 0.5
--local GAZE_AIM_DOT_REJECT = 0.96

-- TODO: Заменить MASK_SOLID_BRUSHONLY на filter = список игроков и некстботов
-- Игроков можно через Iterator, некстботов через хуки OnEntityCreated

local function IsLineOfSightClearPos(bot, pos)
	local tr = util.TraceLine({ start = bot.m_Body:GetEyePosition(), endpos = pos, filter = bot, mask = MASK_SOLID + CONTENTS_HITBOX })
	return tr.Fraction >= 0.99 && !tr.StartSolid
end

-- TODO: Заменить MASK_SOLID_BRUSHONLY
local function IsLineOfSightClearEntityIgnoreActors(bot, ent)
	local tr = util.TraceLine({ start = bot.m_Body:GetEyePosition(), endpos = ent:WorldSpaceCenter(), filter = bot, mask = MASK_SOLID_BRUSHONLY })
	return tr.Fraction >= 0.99 && !tr.StartSolid
end

local function GetLastKnownArea(bot)
	return navmesh.GetNearestNavArea(bot:GetPos(), false, 200, false, true)
end

local function NavAreaGazeSpot(area)
	if (!area) then return nil end
	-- local c = area:GetCenter()
	-- spot = Vector(c.x + math.random(-80, 80), c.y + math.random(-80, 80), c.z)
	local spot = area:GetRandomPoint()
	return spot + Vector(0, 0, GAZE_Z_OFFSET)
end

local function IsInterestingEntity(ent, bot)
	if (!IsValid(ent) || ent == bot) then return false end
	if (ent:IsPlayer()) then return ent:Alive() end
	if (ent:IsNPC()) then return ent:Health() > 0 end
	if (ent:IsNextBot()) then return true end
	return false
end

local function CollectSphereTargets(bot, lookForEnemies)
	local entsInRange = ents.FindInSphere(bot:GetPos(), bot.m_Vision:GetMaxVisionRange())
	local candidates = {}
	
	for i = 1, #entsInRange do
		local ent = entsInRange[i]
		if (!IsInterestingEntity(ent, bot)) then continue end
		
		local isEnemy = bot.m_Vision:IsEnemy(ent)
		
		if (lookForEnemies) then
			if (isEnemy) then
				candidates[#candidates + 1] = ent
			end
		elseif (!isEnemy) then
			candidates[#candidates + 1] = ent
		end
	end
	
	return candidates
end

local function EntityGazeSpot(ent)
	return ent:WorldSpaceCenter()
end

local function FindClosestVisibleAreaNearPos(bot, pos)
	local myArea = GetLastKnownArea(bot)
	if (!myArea) then return nil end
	
	local visible = myArea:GetVisibleAreas()
	if (!visible || #visible == 0) then return nil end
	
	local bestArea
	local bestDistSqr = math.huge
	
	local n = #visible
	for i = 1, n do
		local area = visible[i]
		if (area) then
			local dSqr = area:GetCenter():DistToSqr(pos)
			if (dSqr < bestDistSqr) then
				bestDistSqr = dSqr
				bestArea = area
			end
		end
	end
	
	return bestArea
end

local function NavAreaId(area)
	return area:GetID()
end

local function ForEachAdjacent(area, fn)
	if (!area) then return end
	local list = area:GetAdjacentAreas()
	local n = #list
	for i = 1, n do
		fn(list[i])
	end
end

local function CollectPotentiallyVisibleSet(homeArea, maxDepth)
	local set = {}
	local queue = { { area = homeArea, depth = 0 } }
	set[homeArea] = true
	
	local head = 1
	local n = #queue
	while (head <= n) do
		local node = queue[head]
		head = head + 1
		if (node.depth >= maxDepth) then continue end
		
		local visible = node.area:GetVisibleAreas()
		local n2 = #visible
		for i = 1, n2 do
			local v = visible[i]
			if (v && !set[v]) then
				set[v] = true
				queue[#queue + 1] = { area = v, depth = node.depth + 1 }
			end
		end
	end
	
	return set
end

local function CollectInvasionAreas(homeArea, botPos)
	local visibleSet = CollectPotentiallyVisibleSet(homeArea, VISIBLE_BFS_DEPTH)
	local invasion = {}
	local invasionSet = {}
	local homeCenter = homeArea:GetCenter()
	local homeDistBot = homeCenter:Distance(botPos)
	
	for visArea, _ in pairs(visibleSet) do
		
		if (visArea:GetCenter():Distance(botPos) > homeDistBot + BEHIND_TOLERANCE) then continue end
		
		ForEachAdjacent(visArea, function(adjArea)
			if (!adjArea || visibleSet[adjArea] || invasionSet[adjArea]) then return end
			
			local adjCenter = adjArea:GetCenter()
			if (adjCenter:Distance(botPos) > homeDistBot + BEHIND_TOLERANCE) then return end
			
			invasion[#invasion + 1] = adjArea
			invasionSet[adjArea] = true
		end)
	end
	
	return invasion
end

local function GetCachedInvasionAreas(bot, homeArea)
	local homeId = NavAreaId(homeArea)
	local cache = bot.m_invasionAreasCache
	if (cache && cache.homeId == homeId && cache.expires > CurTime() && cache.areas && #cache.areas > 0) then
		return cache.areas
	end
	
	local areas = CollectInvasionAreas(homeArea, bot:GetPos())
	bot.m_invasionAreasCache = { homeId = homeId, expires = CurTime() + INVASION_CACHE_TTL, areas = areas }
	return areas
end

local function WouldGazeLookAtHiddenEnemy(bot, gazeSpot, ent)
	if (!IsValid(ent)) then return false end
	
	if (bot.m_Vision:IsLineOfSightClear(ent)) then return false end
	
	if (gazeSpot:Distance(ent:GetPos()) < GAZE_ENEMY_REJECT_DIST) then return true end
	
	local eye = bot.m_Body:GetEyePosition()
	local aimDir = (gazeSpot - eye)
	local threatDir = (ent:WorldSpaceCenter() - eye)
	if (aimDir:LengthSqr() < 1 || threatDir:LengthSqr() < 1) then return false end
	
	aimDir:Normalize()
	threatDir:Normalize()
	
	--print("gaze", aimDir:Dot(threatDir))
	if (aimDir:Dot(threatDir) <= GAZE_AIM_DOT_REJECT) then return false end
	
	local tr = util.TraceLine({ start = eye, endpos = ent:WorldSpaceCenter(), filter = bot, mask = MASK_SOLID_BRUSHONLY })
	return tr.Fraction < 0.99
end

local function FilterInvasionAreasForTarget(bot, homeArea, invasionAreas, targetPos, minGazeRange)
	if (#invasionAreas == 0) then return invasionAreas end
	
	local botPos = bot:GetPos()
	local homeCenter = homeArea:GetCenter()
	local homeToTarget = homeCenter:Distance(targetPos)
	local dirToTarget = targetPos - botPos
	dirToTarget.z = 0
	local hasDir = dirToTarget:LengthSqr() > 64
	if (hasDir) then
		dirToTarget:Normalize()
	end
	
	local enemyArea = navmesh.GetNearestNavArea(targetPos, false, 200, false, true)
	
	local filtered = {}
	local n = #invasionAreas
	for i = 1, n do
		local area = invasionAreas[i]
		if (enemyArea && area == enemyArea) then continue end
		
		local center = area:GetCenter()
		if (center:Distance(botPos) <= minGazeRange) then continue end
		
		if (center:Distance(targetPos) + 50 < homeToTarget) then continue end
		
		if (hasDir) then
			local toArea = center - botPos
			toArea.z = 0
			if (toArea:LengthSqr() > 1) then
				toArea:Normalize()
				if (toArea:Dot(dirToTarget) < 0.2) then continue end
			end
		end
		
		filtered[#filtered + 1] = area
	end
	
	if (#filtered > 0) then return filtered end
	return invasionAreas
end

local function TryPickInvasionGaze(bot, invasionAreas, focusEnt, minGazeRange)
	for _ = 1, 10 do
		local area = invasionAreas[math.random(#invasionAreas)]
		local gazeSpot = NavAreaGazeSpot(area)
		if (!gazeSpot) then continue end
		if (bot:GetPos():Distance(gazeSpot) <= minGazeRange) then continue end
		if (!bot.m_Vision:IsLineOfSightClearPos(gazeSpot)) then continue end
		if (focusEnt && WouldGazeLookAtHiddenEnemy(bot, gazeSpot, focusEnt)) then continue end
		return gazeSpot
	end
	return nil
end

function CMasterBotAddonLookAround.UpdateLookingAroundForIncomingPlayers(bot, lookForEnemies)
	if (!bot.m_lookAtInvasionAreasTime) then
		bot.m_lookAtInvasionAreasTime = 0
	end
	
	if (bot.m_lookAtInvasionAreasTime > CurTime()) then return end
	
	bot.m_lookAtInvasionAreasTime = CurTime() + math.Rand(0.333, 1.0)
	
	local homeArea = GetLastKnownArea(bot)
	if (!homeArea) then return end
	
	local invasionAreas = GetCachedInvasionAreas(bot, homeArea)
	if (#invasionAreas == 0) then return end
	
	local minGazeRange = bot.m_isSighting and 750 or 150
	local candidates = CollectSphereTargets(bot, lookForEnemies)
	local retryCount = 20
	
	for _ = 1, retryCount do
		local focusEnt
		local targetPos = homeArea:GetCenter()
		
		if (#candidates > 0) then
			focusEnt = candidates[math.random(#candidates)]
			targetPos = focusEnt:GetPos()
		end
		
		local filtered = FilterInvasionAreasForTarget(bot, homeArea, invasionAreas, targetPos, minGazeRange)
		local gazeSpot = TryPickInvasionGaze(bot, filtered, focusEnt, minGazeRange)
		
		if (gazeSpot) then
			bot.m_Body:AimHeadTowardsPos(gazeSpot, CMasterBotBody.INTERESTING, 1.0, lookForEnemies and "Looking toward likely enemy approach" or "Looking toward teammate approach")
			break
		end
	end
end

function CMasterBotAddonLookAround.UpdateLookingAroundForEnemies(bot)
	if (!bot.m_isLookingAroundForEnemies && !bot.m_sniperIsLookingAroundForEnemies) then return end
	
	local known = bot.m_Vision:GetPrimaryKnownThreat(false)
	if (known) then
		local threatEnt = known:GetEntity()
		
		if (known:IsVisibleInFOVNow() && IsValid(threatEnt)) then
			bot.m_Body:AimHeadTowardsEnt(threatEnt, CMasterBotBody.CRITICAL, 1.0, "Aiming at a visible threat")
			return
		end
		
		if (IsValid(threatEnt) && IsLineOfSightClearEntityIgnoreActors(bot, threatEnt)) then
			local toThreat = threatEnt:GetPos() - bot:GetPos()
			local threatRange = toThreat:Length()
			if (threatRange > 0.01) then
				toThreat:Normalize()
				threatRange = toThreat:Length()
				
				local err = threatRange * math.sin(AIM_ERROR_RAD)
				
				local imperfectAimSpot = threatEnt:WorldSpaceCenter()
				imperfectAimSpot.x = imperfectAimSpot.x + math.Rand(-err, err)
				imperfectAimSpot.y = imperfectAimSpot.y + math.Rand(-err, err)
				
				bot.m_Body:AimHeadTowardsPos(imperfectAimSpot, CMasterBotBody.IMPORTANT, 1.0, "Turning around to find threat out of our FOV")
				return
			end
		end
		
		if (!bot.m_isSniper) then
			local lastPos = known:GetLastKnownPosition()
			if (lastPos) then
				local closeArea = FindClosestVisibleAreaNearPos(bot, lastPos)
				if (closeArea) then
					for _ = 1, 10 do
						local gazeSpot = NavAreaGazeSpot(closeArea)
						if (gazeSpot && IsLineOfSightClearPos(bot, gazeSpot)) then
							bot.m_Body:AimHeadTowardsPos(gazeSpot, CMasterBotBody.IMPORTANT, 1.0, "Looking toward potentially visible area near hidden threat")
							return
						end
					end
				end
			end
			return
		end
	end
	
	CMasterBotAddonLookAround.UpdateLookingAroundForIncomingPlayers(bot, true)
end