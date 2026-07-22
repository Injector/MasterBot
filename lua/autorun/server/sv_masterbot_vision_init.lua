CKnownEntity = {}
CKnownEntity.__index = CKnownEntity

function CKnownEntity:new(who)
	local NewClass = 
	{
		m_who = who,
		m_whenLastSeen = -1.0,
		m_whenLastBecameVisible = -1.0,
		m_isVisible = false,
		m_whenBecameKnown = CurTime(),
		m_hasLastKnownPositionBeenSeen = false,
		m_sightOnce = false
	}

	setmetatable(NewClass, CKnownEntity)
	
	NewClass:UpdatePosition()
	
	return NewClass
end

function CKnownEntity:UpdatePosition()
	if (self.m_who != nil && IsValid(self.m_who)) then
		self.m_lastKnownPosition = self.m_who:GetPos()
		self.m_whenLastKnown = CurTime()
	end
end

function CKnownEntity:GetEntity()
	return self.m_who
end

function CKnownEntity:GetLastKnownPosition()
	return self.m_lastKnownPosition
end

function CKnownEntity:GetTimeSinceLastKnown()
	return CurTime() - self.m_whenLastKnown
end

function CKnownEntity:GetTimeSinceBecameKnown()
	return CurTime() - self.m_whenBecameKnown
end

function CKnownEntity:UpdateVisibilityStatus(visible)
	if (visible) then
		if (!self.m_isVisible) then
			self.m_whenLastBecameVisible = CurTime()
		end
		
		self.m_whenLastSeen = CurTime()
	end
	
	self.m_isVisible = visible
end

function CKnownEntity:IsVisibleInFOVNow()
	return self.m_isVisible
end

function CKnownEntity:IsVisibleRecently()
	if (self.m_isVisible) then return true end
	
	if (self:WasEverVisible() && self:GetTimeSinceLastKnown() < 3.0) then return true end
	
	return false
end

function CKnownEntity:GetTimeSinceBecameVisible()
	return CurTime() - self.m_whenLastBecameVisible
end

function CKnownEntity:GetTimeWhenBecameVisible()
	return self.m_whenLastBecameVisible
end

function CKnownEntity:GetTimeSinceLastSeen()
	return CurTime() - self.m_whenLastSeen
end

function CKnownEntity:WasEverVisible()
	return self.m_whenLastSeen > 0.0
end

-- TODO: Добавить возможность переопределения больше 10 секунд памяти
function CKnownEntity:IsObsolete()
	if (self == nil) then return true end
	
	return self:GetEntity() == nil || 
	!IsValid(self:GetEntity()) || 
	!self:GetEntity():Alive() || 
	self:GetTimeSinceLastKnown() > 10.0
end

function CKnownEntity:IsSightedOnce()
	return self.m_sightOnce
end

function CKnownEntity:SightOnce()
	self.m_sightOnce = true
end

setmetatable(CKnownEntity, { __call = CKnownEntity.new })

CMasterBotVision = {}
CMasterBotVision.__index = CMasterBotVision

local function PointWithinViewAngle(srcPos, targetPos, lookDir, cosHalfFOV)
	local delta = targetPos - srcPos
	local cosDiff = lookDir:Dot(delta)
	
	if (cosDiff < 0.0) then return false end
	
	local leng = delta:LengthSqr()
	
	return cosDiff * cosDiff > leng * cosHalfFOV * cosHalfFOV
end

function CMasterBotVision.New(bot, cls)
	cls = cls or CMasterBotVision

	local b = setmetatable({}, cls)
	
	b.m_knownEntities = {}
	b.m_lastVisionUpdateTimestamp = 0
	b.m_nextVisionUpdate = 0
	b.m_primaryThreat = nil
	b.m_cachedPrimaryThreat = nil  -- cache, updates in Update()
	b.m_FOV = 75
	b.m_cosHalfFOV = math.cos(0.5 * b.m_FOV * math.pi / 180)
	b.m_bot = bot
	b.m_maxVisionRange = 6000.0
	b.m_maxVisionRangeSqr = 6000.0 * 6000.0
	b.m_vecHullMins = Vector(-1, -1, -1)
	b.m_vecHullMaxs = Vector(1, 1, 1)
	b.m_notVisibleTimer = {}
	
	return b
end

function CMasterBotVision:SetFOV(fov)
	self.m_FOV = fov
	self.m_cosHalfFOV = math.cos(0.5 * self.m_FOV * math.pi / 180.0)
end

function CMasterBotVision:GetBot()
	return self.m_bot
end

-- Игнорируем если есть флаг FL_NOTARGET или игрок в ноуклипе
-- Ignores if ent has FL_NOTARGET or player in noclip
function CMasterBotVision:IsIgnored(ent)
	if (ent:IsFlagSet(FL_NOTARGET) || (ent:IsPlayer() && ent:GetMoveType() == MOVETYPE_NOCLIP && !ent:InVehicle())) then return true end
	
	return false
end

function CMasterBotVision:IsEnemy(ent)
	if (ent:GetClass() == self:GetBot():GetClass()) then return false end
	
	return true
end

function CMasterBotVision:GetMinRecognizeTime()
	local skill = self:GetBot().m_iBotSkill
	if (skill) then
		if (skill == 0) then return 1.0
		elseif (skill == 1) then return 0.5
		elseif (skill == 2) then return 0.3
		elseif (skill == 3) then return 0.2 end
	end
	
	return 1.0
end

function CMasterBotVision:IsAwareOf(known)
	return known:GetTimeSinceBecameKnown() >= self:GetMinRecognizeTime()
end

---@param bool onlyVisible Should only visible primary threat? default false
---@return CKnownEntity Return CKnownEntity of our primary threat
function CMasterBotVision:GetPrimaryKnownThreat(onlyVisible)
	if (onlyVisible) then
		-- onlyVisible is very rare, we can skip cache
		return self:ComputePrimaryKnownThreat(true)
	end
	return self.m_cachedPrimaryThreat
end

-- Обновление текущего противника, вызывается либо из Update() либо onlyVisible = true
-- Updates our current enemy, calls from Update() or onlyVisible = true
function CMasterBotVision:ComputePrimaryKnownThreat(onlyVisible)
	local ke = self.m_knownEntities
	if (#ke == 0) then
		self.m_primaryThreat       = nil
		self.m_cachedPrimaryThreat = nil
		return nil
	end

	local threat = nil
	local i = 1

	for m = 1, #ke do
		local firstThreat = ke[m]
		if (self:IsAwareOf(firstThreat) && !firstThreat:IsObsolete() && !self:IsIgnored(firstThreat:GetEntity()) && self:IsEnemy(firstThreat:GetEntity())) then
			if (!onlyVisible || firstThreat:IsVisibleRecently()) then
				threat = firstThreat
				i = m
				break
			end
		end
	end

	if (threat == nil) then
		self.m_primaryThreat       = nil
		self.m_cachedPrimaryThreat = nil
		return nil
	end

	if (#ke > 1) then
		local bot = self:GetBot()
		for k = i + 1, #ke do
			local newThreat = ke[k]
			if (self:IsAwareOf(newThreat) && !newThreat:IsObsolete() && !self:IsIgnored(newThreat:GetEntity()) && self:IsEnemy(newThreat:GetEntity())) then
				if (!onlyVisible || newThreat:IsVisibleRecently()) then
					-- Два противника, выбираем какой из них наиболее опасный
					-- Two enemies, select which one of them is dangerous
					threat = bot.m_Intention:SelectMoreDangerousThreat(bot, threat, newThreat)
				end
			end
		end
	end

	self.m_primaryThreat       = threat
	self.m_cachedPrimaryThreat = threat
	return threat
end

--- Add an entity to our memory. Entity's current position will be known and will be updated when we see it
---@param Entity v The entity to known (player, NPC, NextBot, etc)
function CMasterBotVision:AddKnownEntity(v)
	if (v == nil || !IsValid(v)) then return end
	if (!self:IsEnemy(v) || self:IsIgnored(v)) then return end
	
	local idx = v:EntIndex()
	if (!self:HasKnownEntity(v)) then
		local known = CKnownEntity(v)
		known:UpdatePosition()
		known:UpdateVisibilityStatus(true)
		self.m_knownEntities[#self.m_knownEntities + 1] = known
	end
end

--- Forget an entity
--- Useful when we reached the entity's last known position, but we didn't found it
---@param Entity forgetMe The entity to forget about
function CMasterBotVision:ForgetEntity(forgetMe)
	local idx = forgetMe:EntIndex()
	if (!self:HasKnownEntity(forgetMe)) then return end

	local ke = self.m_knownEntities
	for i = #ke, 1, -1 do
		if (ke[i]:GetEntity() == forgetMe) then
			ke[i] = ke[#ke]
			ke[#ke] = nil
			break
		end
	end
end

function CMasterBotVision:HasKnownEntity(ent)
	local ke = self.m_knownEntities
	for i = 1, #ke do
		if (ke[i]:GetEntity() == ent) then return true end
	end
	
	return false
end

function CMasterBotVision:GetKnown(ent)
	local ke = self.m_knownEntities
	for i = 1, #ke do
		if (ke[i] == ent) then return ke[i] end
	end
	
	return nil
end

-- Вызывать функцию не больше каждые 0.1 секунд, иначе это может сломать вызов OnSight а так же систему реакций: 
-- если у бота-эксперта задержка реакции 0.2, и функция вызывается каждые 1 секунд
-- То бот увидит цель только спустя секунду, а не через 0.2 мс
-- ============
-- Call this function once in 0.1 seconds, no more. Otherwise it could break OnSight call and system of reacions:
-- for example, if a bot-expert see threat reaction 0.2, and function calls every 1 second
-- Then bot will see threat only after 1 second, not after 0.2 ms
function CMasterBotVision:UpdateKnownEntities()
	local now = CurTime()

	local bot      = self.m_bot
	local botIdx   = bot:EntIndex()
	local botPos   = bot:GetPos()
	local maxRange = self.m_maxVisionRange
	local minRecog = self:GetMinRecognizeTime()

	-- Используем FindInSphere вместо Iterator во благо оптимизации
	local nearby    = ents.FindInSphere(botPos, maxRange)
	local visibleSet = {}   -- [entIndex] = ent, для O(1) пересечения
	
	-- Добавляем в visibleSet только тех, кого мы видим в FOV
	for i = 1, #nearby do
		local ent = nearby[i]
		if not (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) then continue end

		local idx = ent:EntIndex()
		if (idx == botIdx) then continue end
		if (!ent:Alive()) then continue end
		if (self:IsIgnored(ent)) then continue end

		if (self:IsAbleToSee(ent, true)) then
			visibleSet[idx] = ent
		end
	end

	-- Обновляем уже известные энтити
	local ke = self.m_knownEntities

	local i = #ke
	while i >= 1 do
		local known = ke[i]
		local ent   = known:GetEntity()

		if (known:IsObsolete()) then
			ke[i] = ke[#ke]
			ke[#ke] = nil
			i = i - 1
			continue
		end

		local entIdx = ent:EntIndex()

		if (visibleSet[entIdx]) then
			-- Энтити видима
			local wasVisible = known:IsVisibleInFOVNow()
			known:UpdatePosition()
			known:UpdateVisibilityStatus(true)
			
			local t = now - known:GetTimeWhenBecameVisible() >= minRecog
			local t2 = self.m_lastVisionUpdateTimestamp - known:GetTimeWhenBecameVisible() < minRecog
			
			-- FIXME: Иногда может вызываться дважды?
			if (t && t2) then
				bot.m_Behavior:ProcessEvent("OnSight", ent)
				
				if (!known:IsSightedOnce()) then
					known:SightOnce()
					bot.m_Behavior:ProcessEvent("OnSightOnce", ent)
				end
			end

			visibleSet[entIdx] = nil -- Помечаем как обработанную
			
			-- TODO: Заменить 1 на команду Team
			self.m_notVisibleTimer[1] = CurTime()
		else
			-- Энтити щас не видима
			if (known:IsVisibleInFOVNow()) then
				known:UpdateVisibilityStatus(false)
				bot.m_Behavior:ProcessEvent("OnLostSight", ent)
			end
		end

		i = i - 1
	end
	
	-- Добавляем новые видимые энтити 
	-- visibleSet тепер содержит только те, кого ещё нет в m_knownEntities
	for idx, ent in pairs(visibleSet) do
		local known = CKnownEntity(ent)
		known:UpdatePosition()
		known:UpdateVisibilityStatus(true)
		ke[#ke + 1] = known
	end
end

function CMasterBotVision:Update()
	self:UpdateKnownEntities()
	self.m_lastVisionUpdateTimestamp = CurTime()
	self:ComputePrimaryKnownThreat(false)
end

function CMasterBotVision:GetMaxVisionRange()
	return self.m_maxVisionRange
end

-- TODO: Сделать проверку по командам
function CMasterBotVision:GetClosestTarget(radius)
	local _ents = ents.FindInSphere(self:GetBot():GetPos(), radius)
	
	local flDistanceSqr = math.huge
	local hEnemy = nil
	local botPos = self:GetBot():GetPos()
	
	local n = #_ents
	for i = 1, n do
		local v = _ents[i]
		if ((v:IsPlayer() || v:IsNPC() || v:IsNextBot()) && v:Alive() && v:GetMoveType() != 8) then
			local dSqr = botPos:DistToSqr(v:GetPos())
			if dSqr < flDistanceSqr then
				flDistanceSqr = dSqr
				hEnemy = v
			end
		end
	end
	
	return hEnemy
end

function CMasterBotVision:IsVisibleEntityNoticed(threat) return true end

---@param Entity subject The entity to check against FOV
---@return bool Returns true if the subject in bot's FOV
function CMasterBotVision:IsInFieldOfViewEnt(subject)
	local pos = subject:WorldSpaceCenter()
	
	if (self:IsInFieldOfViewPos(pos)) then return true end
	
	pos = subject:EyePos()
	
	return self:IsInFieldOfViewPos(pos)
end

---@param Vector pos The position to check against FOV
---@return bool Returns true if the position in bot's FOV
function CMasterBotVision:IsInFieldOfViewPos(pos)
	local eyePos = self:GetBot().m_Body:GetEyePosition()
	local viewDir = self:GetBot().m_Body.m_angCurrentAngles:Forward()
	
	return PointWithinViewAngle(eyePos, pos, viewDir, self.m_cosHalfFOV)
end

---@param Vector pos The position to check is bot is able to see
---@param bool checkFov Check in FOV, false by default
---@return bool Returns true if the bot is able to see position (in FOV or out FOV by checkFov)
function CMasterBotVision:IsAbleToSeePos(pos, checkFOV)
	if (self:GetBot():GetRangeTo(pos) > self:GetMaxVisionRange()) then return false end

	if (checkFOV && !self:IsInFieldOfViewPos(pos)) then return false end

	if (!self:IsLineOfSightClearPos(pos)) then return false end
	
	return true
end

---@param Entity threat The entity to check is bot is able to see it
---@param bool checkFov Check in FOV, false by default
---@return bool Returns true if the bot is able to see threat (in FOV or out FOV by checkFov)
function CMasterBotVision:IsAbleToSee(threat, checkFOV)
	local distSqr = self.m_bot:GetPos():DistToSqr(threat:GetPos())
	if distSqr > self.m_maxVisionRangeSqr then return false end
	
	if (checkFOV && !self:IsInFieldOfViewEnt(threat)) then return false end
	
	if (!self:IsLineOfSightClear(threat)) then return false end
	
	return self:IsVisibleEntityNoticed(threat)
end

---@param Entity threat The entity to check bot
---@param Vector pos The entity's position to check (eye position, worldspacecenter, etc...)
---@param bool useHull Use TraceHull instead of TraceLine
---@return bool Return true if the ray to the given entity's point is unobstructed
function CMasterBotVision:IsLineOfSightClearEntPos(threat, pos, useHull)
	if (!useHull) then useHull = true end
	
	local me = self:GetBot()
	local traceFilter = { me }
	
	local traceConfig = { start = me.m_Body:GetEyePosition(), endpos = pos, filter = traceFilter, mask = bit.bor(MASK_BLOCKLOS_AND_NPCS, CONTENTS_IGNORE_NODRAW_OPAQUE) }
	
	if (useHull) then
		traceConfig = { start = me.m_Body:GetEyePosition(), endpos = pos, filter = traceFilter, mask = bit.bor(MASK_BLOCKLOS_AND_NPCS, CONTENTS_IGNORE_NODRAW_OPAQUE),
			mins = self.m_vecHullMins, maxs = self.m_vecHullMaxs }
	end
	
	local tr = nil
	
	if (useHull) then
		tr = util.TraceHull(traceConfig)
	else
		tr = util.TraceLine(traceConfig)
	end
	
	return tr.Entity == threat
end

---@param Vector pos The position to check
---@param bool useHull Use TraceHull instead of TraceLine
---@return bool Return true if the ray to the given point is unobstructed
function CMasterBotVision:IsLineOfSightClearPos(pos, useHull)
	local me = self:GetBot()
	local traceFilter = { me }
	
	local traceConfig = { start = me.m_Body:GetEyePosition(), endpos = pos, filter = traceFilter, mask = bit.bor(MASK_BLOCKLOS_AND_NPCS, CONTENTS_IGNORE_NODRAW_OPAQUE) }
	
	if (useHull) then
		traceConfig = { start = me.m_Body:GetEyePosition(), endpos = pos, filter = traceFilter, mask = bit.bor(MASK_BLOCKLOS_AND_NPCS, CONTENTS_IGNORE_NODRAW_OPAQUE),
			mins = self.m_vecHullMins, maxs = self.m_vecHullMaxs }
	end
	
	local tr = nil
	
	if (useHull) then
		tr = util.TraceHull(traceConfig)
	else
		tr = util.TraceLine(traceConfig)
	end
	
	return tr.Fraction >= 0.96 && !tr.StartSolid
end

---@param Vector pos The position to check
---@return bool Return true if the ray to the given point is unobstructed (no windows, fences, etc)
function CMasterBotVision:IsLineOfFireClearPos(pos)
	local see = self:IsLineOfSightClearPos(pos)
	
	if (!see) then return false end
	
	return true
end

---@param Entity threat The entity to check
---@return bool Return true if the ray to the given point is unobstructed (no windows, fences, etc)
function CMasterBotVision:IsLineOfFireClear(threat)
	local seeHim, seePos, blocker = self:IsLineOfSightClearEx(threat)
	
	if (!seeHim && !IsValid(blocker)) then return false end
	
	-- Мы можем это сломать, продолжаем стрелять
	-- We can break it, continue shooting
	if (IsValid(blocker) && (blocker:GetClass() == "func_breakable" || blocker:GetClass() == "prop_physics") && blocker:Health() > 0) then return true end
	
	return true
end

-- Используем TraceHull вместо TraceLine, как как линия будет искать хитбоксы цели, а не огромную коробку колизии
-- Может получиться такая ситуация: если мы целимся линией в глаза цели EyePos(), и у него анимация физгана, то он будет фейлиться потому-что хитбокс головы находится не на уровне глаз EyePos()
-- Если же у него анимация пистолета, то он не будет фейлиться, потому-что хитбокс головы находится точно на уровне глаз EyePos()
-- We use TraceHull, not TraceLine, because line will search for hitboxes, not a big collision box
-- Example: if we aimg at threat's eye position and he's with physics gun animation, then TraceLine would fail because head's hitbox wouldn't be located on EyePos()
-- If he's with pistol animation, then it will not fail because head's hitbox will be located right in EyePos()

---@param Entity threat The entity to check if bot can clearly see it (nothing blocks bot's vision)
---@return bool Returns true and position that we can see of entity
function CMasterBotVision:IsLineOfSightClear(threat)
	local me = self:GetBot()
	local traceFilter = { me }
	local trConfig = { start = me.m_Body:GetEyePosition(), endpos = threat:WorldSpaceCenter(), filter = traceFilter, mask = MASK_SOLID + CONTENTS_HITBOX,
		mins = self.m_vecHullMins, maxs = self.m_vecHullMaxs }
	
	local tr = util.TraceHull(trConfig)
	
	if (tr.Entity == threat) then
		return true, threat:WorldSpaceCenter()
	end
	
	trConfig.endpos = threat:EyePos()
	tr = util.TraceHull(trConfig)
	
	if (tr.Entity == threat) then
		return true, threat:EyePos()
	end
	
	trConfig.endpos = threat:GetPos()
	tr = util.TraceHull(trConfig)
	
	if (tr.Entity == threat) then
		return true, threat:GetPos()
	end
	
	return false, vector_origin
end

-- Same as IsLineOfSightClear, but with blocker entity
function CMasterBotVision:IsLineOfSightClearEx(threat)
	local me = self:GetBot()
	local traceFilter = { me }
	local trConfig = { start = me.m_Body:GetEyePosition(), endpos = threat:WorldSpaceCenter(), filter = traceFilter, mask = MASK_SOLID + CONTENTS_HITBOX,
		mins = self.m_vecHullMins, maxs = self.m_vecHullMaxs }
	
	local tr = util.TraceHull(trConfig)
	
	if (tr.Entity == threat) then
		return true, threat:WorldSpaceCenter(), NULL
	end
	
	trConfig.endpos = threat:EyePos()
	tr = util.TraceHull(trConfig)
	
	if (tr.Entity == threat) then
		return true, threat:EyePos(), NULL
	end
	
	trConfig.endpos = threat:GetPos()
	tr = util.TraceHull(trConfig)
	
	if (tr.Entity == threat) then
		return true, threat:GetPos(), NULL
	end
	
	return false, vector_origin, tr.Entity
end

function CMasterBotVision:GetTimeSinceVisible(team)
	if (!team) then
		local minTime = 9999999999.9
		
		local teamTimer = self.m_notVisibleTimer[1] or 0
		if (minTime != 0 && minTime > CurTime() - teamTimer) then
			minTime = CurTime() - teamTimer
		end
		
		return minTime
	end
	
	if (team && team >= 0 && self.m_notVisibleTimer[team]) then
		return self.m_notVisibleTimer[team]
	end
	
	return 0
end

function CMasterBotVision:IsHiddenByFogPos(target)
	return self:IsHiddenByFog(self:GetBot().m_Body:GetEyePosition() - target)
end

function CMasterBotVision:IsHiddenByFogEnt(target)
	return self:IsHiddenByFog(self:GetBot().m_Body:GetEyePosition() - target:WorldSpaceCenter())
end

function CMasterBotVision:IsHiddenByFog(range)
	if (self:GetFogObscuredRatio(range) >= 1.0) then return true end
	
	return false
end

function CMasterBotVision:GetFogObscuredRatioPos(target)
	return self:GetFogObscuredRatio(self:GetBot().m_Body:GetEyePosition() - target)
end

function CMasterBotVision:GetFogObscuredRatioEnt(target)
	return self:GetFogObscuredRatio(self:GetBot().m_Body:GetEyePosition() - target:WorldSpaceCenter())
end

function CMasterBotVision:GetFogObscuredRatio(range)
	
	local fogEnable = false
	local fogStart = 0
	local fogEnd = 0
	local fogMaxDensity = 0
	
	CMasterBot.MapFogs[#CMasterBot.MapFogs + 1] = ent
	
	local n = #CMasterBot.MapFogs
	for i = 1, n do
		local fog = CMasterBot.MapFogs[i]
		
		-- Переопределять если стоит Master
		if (fogEnable && fog:GetInternalVariable("m_spawnflags") != 1) then
			continue
		end
		
		if (fog:GetInternalVariable("m_fog.enable")) then
			fogEnable = true
			fogStart = fog:GetInternalVariable("m_fog.start")
			fogEnd = fog:GetInternalVariable("m_fog.end")
			fogMaxDensity = fog:GetInternalVariable("m_fog.maxdensity")
		end
	end
	
	-- for _, ent in ents.Iterator() do
		-- if (ent:GetClass() == "env_fog_controller") then
			-- if (ent:GetInternalVariable("m_fog.enable")) then
				-- fogEnable = true
				-- fogStart = ent:GetInternalVariable("m_fog.start")
				-- fogEnd = ent:GetInternalVariable("m_fog.end")
				-- fogMaxDensity = ent:GetInternalVariable("m_fog.maxdensity")
			-- end
		-- end
	-- end
	
	if (!fogEnable) then return 0.0 end
	if (range <= fogStart) then return 0.0 end
	if (range >= fogEnd) then return 1.0 end
	
	local ratio = (range - fogStart) / (fogEnd - fogStart)
	ratio = math.min(ratio, fogMaxDensity)
	
	return ratio
	
	--return 0.0
end

function CMasterBotVision:GetTraceFilterIgnoreFriends()
	
end