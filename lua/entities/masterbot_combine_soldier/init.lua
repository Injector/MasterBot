AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- Различные поведения
include("pj/masterbot/behaviors/beh_escort_squad_leader.lua")
include("pj/masterbot/behaviors/beh_main.lua")
include("pj/masterbot/behaviors/beh_monitors.lua")
include("pj/masterbot/behaviors/beh_sniper_lurk.lua")
include("pj/masterbot/behaviors/beh_mvm_engineer.lua")

-- Аддоны
include("pj/masterbot/addon_look_around.lua")

hook.Add("PlayerDeath", "MasterBot_Combine_PlayerDeath", function(victim, inflictor, attacker)
	-- Мастербот убил игрока
	if (IsValid(attacker) && attacker:GetClass() == "masterbot_combine_soldier") then
		if (attacker.m_szWeaponClass && attacker.m_szBotName) then
			hook.Run("SendDeathNotice", attacker.m_szBotName, attacker.m_szWeaponClass, victim, 0)
		end
	end
	
	if (IsValid(victim)) then
		local soldiers = ents.FindByClass("masterbot_combine_soldier")
		for _, v in ipairs(soldiers) do
			-- Это чтобы после убийства цели мастербот не разворачивался в другую сторону 
			if (v.m_Vision:HasKnownEntity(victim)) then
				v.m_Body:AimHeadTowardsPos(victim:GetPos(), CMasterBotBody.INTERESTING, 0.2, "Checking dead threat")
				-- Хоть и убитые враги автоматически удаляются из памяти мастербота, навсякий случай лучше вручную тоже удалить
				v.m_Vision:ForgetEntity(victim)
			end
		end
	end
end)

hook.Add("OnNPCKilled", "MasterBot_Combine_NPCKilled", function(npc, attacker, inflictor)
	
	-- Умер наш мастербот
	if (IsValid(attacker) && IsValid(inflictor) && IsValid(npc) && npc:GetClass() == "masterbot_combine_soldier") then
		if (npc.m_szBotName) then
			hook.Run("SendDeathNotice", attacker, inflictor:GetClass(), npc.m_szBotName, 0)
		end
	end
	
	-- Мастербот убил кого-то другого
	if (IsValid(attacker) && attacker:GetClass() == "masterbot_combine_soldier") then
		if (attacker.m_szWeaponClass && attacker.m_szBotName) then
			hook.Run("SendDeathNotice", attacker.m_szBotName, attacker.m_szWeaponClass, npc, 0)
		end
	end
end)

local MASTERBOT_NO_DOOR = 0
local MASTERBOT_HANDLING_DOOR = 1

local CMasterBotCombineVision = setmetatable({}, { __index = CMasterBotVision })
CMasterBotCombineVision.__index = CMasterBotCombineVision

function CMasterBotCombineVision:New()
	local b = CMasterBotVision.New(self, CMasterBotCombineVision)
	return b
end

function CMasterBotCombineVision:IsEnemy(ent)
	if (ent:GetClass() == self:GetBot():GetClass()) then
		-- У нас могут быть куча мастерботов на базе masterbot_combine_soldier, но при этом иметь разные команды и команды-союзники
		
		-- У цели нету данных, не атакуем (чтобы не было френдли фаера между тему кого нет команды)
		if (!ent.m_iMasterBotTeam) then
			return false
		end
		
		-- У нас нету данных, не атакуем (причина выше)
		if (!self:GetBot().m_iMasterBotTeam) then return false end
		
		-- У мастербота другая команда, проверяем, союзники ли мы с этой командой
		if (ent.m_iMasterBotTeam != self:GetBot().m_iMasterBotTeam) then
			local isEnemy = true
			
			if (self:GetBot().m_iMasterBotTeamAllies) then
				-- Союзники, не трогаем
				local n = #self:GetBot().m_iMasterBotTeamAllies
				for i = 1, n do
					if (ent.m_iMasterBotTeam == self:GetBot().m_iMasterBotTeamAllies[i]) then
						isEnemy = false
						break
					end
				end
			end
			
			return isEnemy
		else -- Одна и та же команда, значит мы союзники
			return false
		end
	end
	
	if (ent:IsPlayer()) then
		if (self:GetBot().m_playersAlly) then return false end
		
		if (self:GetBot().m_playersNeutral) then
			return self:GetBot():IsEntityEnemy(ent)
		end
	end
	
	-- Остальные энтити для нас враги
	return true
end

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

local OBSTACLE_CHECK_DIST = 120
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

-- Кеширует результат один раз каждый тик, затем оно будет очищено в следующем Think
function ENT:GetEnemy()
	if (self.m_cachedEnemyThisTick != nil) then
		-- false = нет врага (чтобы было отличие от "ещё не проверяли врага")
		if self.m_cachedEnemyThisTick == false then return nil end
		if IsValid(self.m_cachedEnemyThisTick) then return self.m_cachedEnemyThisTick end
	end

	local enemy = self.m_Vision:GetPrimaryKnownThreat()
	if (enemy != nil) then
		local ent = enemy:GetEntity()
		if (!IsValid(ent)) then
			self.m_cachedEnemyThisTick = false
			return nil 
		end
		self.m_lastEnemyPos             = ent:GetPos()
		self.m_cachedEnemyThisTick      = ent
		return ent
	end

	self.m_cachedEnemyThisTick = false
	return nil
end

function ENT:SetEnemy(ent)
	self.m_Vision:AddKnownEntity(ent)
	
    if (IsValid(ent)) then self.m_lastEnemyPos = ent:GetPos() end
end

function ENT:DoMelee(target)
    if not IsValid(target) then return end
    self:EmitSound("Weapon_Crowbar.Single")
    local dmg = DamageInfo()
    dmg:SetDamage(38)
    dmg:SetAttacker(self)
    dmg:SetInflictor(self)
    dmg:SetDamageType(DMG_CLUB)
    dmg:SetDamageForce((target:GetPos() - self:GetPos()):GetNormalized() * 5500)
    target:TakeDamageInfo(dmg)
end

function ENT:GetRandomBurst(weaponType)
	if (self.m_wpn.m_iRndBurst) then
		return math.random(self.m_wpn.m_iRndBurst[1], self.m_wpn.m_iRndBurst[2])
	end
	
	return 0
end

function ENT:GetShootRestTime(weaponType)
	if (self.m_wpn.m_flRndRest) then
		return math.random(self.m_wpn.m_flRndRest[1], self.m_wpn.m_flRndRest[2])
	end
	
	return 0
end

function ENT:KeyValue(key, value)
	key = string.lower(key)
	if (key == "model") then
		self.m_szKVModelName = value
	elseif (key == "health") then
		self.m_iKVHealth = tonumber(value)
	elseif (key == "skin") then
		self.m_iKVSkin = tonumber(value)
	elseif (key == "body") then
		self.m_iKVBody = tonumber(value)
	elseif (key == "weapon_id") then
		self.m_iKVWeaponID = tonumber(value)
	elseif (key == "commander_priority") then
		self.m_iCommanderPriority = tonumber(value)
	elseif (key == "skill") then
		self.m_iBotSkill = tonumber(value)
	elseif (key == "team") then
		self.m_iMasterBotTeam = tonumber(value) -- TODO: Заменить на текст
	elseif (key == "team_allies") then
		local allies = string.Split(value, " ")
		for i = 1, #allies do
			allies[i] = tonumber(allies[i]) -- TODO: Заменить на текст
		end
		
		-- local allies = string.ToTable(value)
		-- for _, v in ipairs(allies) do
			-- print("allies", v)
		-- end
		self.m_iMasterBotTeamAllies = allies
	elseif (key == "anim_combat_idle") then
		self.m_szAnimCombatIdle = value
	elseif (key == "anim_combat_run") then
		self.m_szAnimCombatRun = value
	elseif (key == "anim_combat_walk") then
		self.m_szAnimCombatWalk = value
	elseif (key == "anim_run") then
		self.m_szAnimRun = value
	elseif (key == "anim_walk") then
		self.m_szAnimWalk = value
	elseif (key == "anim_idle") then
		self.m_szAnimIdle = value
	elseif (key == "anim_reload") then
		self.m_szAnimReload = value
	elseif (key == "anim_reload_is_gesture") then
		self.m_animReloadIsGesture = tonumber(value) > 0
	elseif (key == "anim_reload_loop") then
		self.m_szAnimReloadLoop = value
	elseif (key == "anim_reload_end") then
		self.m_szAnimReloadEnd = value
	elseif (key == "anim_gesture_shoot") then
		self.m_szAnimGestureShoot = value
	elseif (key == "maxvisionrange") then
		self.m_flOverrideMaxVisionRange = tonumber(value)
	elseif (key == "name") then
		self.m_szBotName = value
	elseif (key == "weapon_class" || key == "kill_icon") then
		self.m_szWeaponClass = value
	elseif (key == "weapons") then
		
	elseif (key == "player_ally") then
		self.m_playersAlly = tonumber(value) > 0
	elseif (key == "player_neutral") then
		self.m_playersNeutral = tonumber(value) > 0
	elseif (key == "sound_enemy") then
		self.m_tblSoundsEnemy = string.Split(value, ",")
	elseif (key == "sound_flank") then
		self.m_tblSoundsFlank = string.Split(value, ",")
	elseif (key == "sound_hit") then
		self.m_tblSoundsHit = string.Split(value, ",")
	elseif (key == "sound_death") then
		self.m_tblSoundsDeath = string.Split(value, ",")
	elseif (key == "flag_aggressive") then
		self.m_flagAggressive = tonumber(value) > 0
	elseif (key == "flag_combatanims") then
		self.m_flagCombatAnims = tonumber(value) > 0
	elseif (key == "flag_dont_flank") then
		self.m_flagDontFlank = tonumber(value) > 0
	elseif (key == "flag_dont_strafe") then
		self.m_flagDontStrafe = tonumber(value) > 0
	elseif (key == "speed_base") then
		self.m_overrideNavSpeed = tonumber(value)
	elseif (key == "speed_chase") then
		self.m_overrideNavSpeedChase = tonumber(value)
	elseif (key == "speed_strafe") then
		self.m_overrideNavSpeedStrafe = tonumber(value)
	elseif (key == "sound_table") then
		self.m_szSoundTable = value
	elseif (key == "footstep_sound_table") then
		self.m_szFootstepSoundTable = value
	elseif (key == "voice_pitch") then
		self.m_iVoicePitch = tonumber(value)
	elseif (key == "sniper") then
		self.m_isSniper = tonumber(value) > 0
		--self.m_sniperIsLookingAroundForEnemies = tonumber(value) > 0
	end
	
	self:InternalKeyValue(key, value)
	
	self:MasterBotKeyValue(key, value)
end

function ENT:InternalKeyValue(key, value)
end

function ENT:MasterBotKeyValue(key, value)
end

-- ============================================================
-- Сам мастербот
-- ============================================================
function ENT:Initialize()
	self:SetIK(false)
	self:SetModel(self.m_szKVModelName or "models/combine_soldier.mdl")
	self:SetIK(false)
	
	self:SetHealth(self.m_iKVHealth or 50)
	self:SetMaxHealth(self:Health())
	
	self:SetSkin(self.m_iKVSkin or 0)
	self:SetSaveValue("m_nBody", self.m_iKVBody or 0)
	
	self:SetLagCompensated(true)
	self.Entity:SetCollisionBounds(Vector(-10,-10, 0), Vector(10,10,82))
	
	--self:AddFlags(FL_OBJECT)
	--self:AddFlags(67108864)
	--self.HullType = HULL_HUMAN
	
	self:SetCollisionGroup(COLLISION_GROUP_NPC)
	self:SetSolid(SOLID_BBOX)
	
	self.m_Intention = CMasterBotIntention.New(self)
	self.m_Body = CMasterBotBody.New(self)
	self.m_Vision = CMasterBotCombineVision.New(self)
	self.m_Locomotion = CMasterBotLocomotion.New(self)
	
	self.m_Body:SetEyePosition(Vector(0, 0, 30))
	
	self.m_iBotSkill = self.m_iBotSkill or 1
	
	self.m_flVisionUpdate = CurTime() + 0.1
	
	self.m_iCommanderPriority = self.m_iCommanderPriority or 0
	
	if (self.m_flOverrideMaxVisionRange) then
		self.m_Vision.m_maxVisionRange = self.m_flOverrideMaxVisionRange
		self.m_Vision.m_maxVisionRangeSqr = self.m_flOverrideMaxVisionRange * self.m_flOverrideMaxVisionRange
	end
	
	self.m_customHandleOnOtherKilled = true
	self.m_customHandleOnInjured = true
	
	-- Боевое состояние
	self.m_ammo = self.m_ammo or MAG_SIZE
	self.m_isReloading = false
	self.m_lastShoot = 0
	self.m_meleeCooldown = 0
	
	-- Тактика
	self.m_flagAggressive = self.m_flagAggressive or false
	self.m_coverAt = nil
	self.m_canRetreatAfterDamage = self.m_canRetreatAfterDamage or true
	
	-- Отряд
	self.m_bIsLeader = false
	self.m_squadId = nil
	self.m_pendingFlank = false
	self.m_pendingFlankEnemy = nil
	
	-- Сопровождение командира отряда (BehEscortSquadLeader BehWaitForFormation)
	self.m_formationError  = 0      -- ошибка позиции в построении
	self.m_brokenFormation = false  -- путь к слоту слишком длинный
	
	-- Враг
	self.m_lastEnemyPos = nil
	
	timer.Simple(0.4, function() 
		if (IsValid(self)) then self:TryJoinSquad() end
	end)
	
	-- Устанавливаем здесь чтобы в MasterBotInitialContainedAction вернул уникальное поведение для снайпера
	self.m_isSniper = self.m_isSniper or false
	
	-- Запуск первого действия
	local newAct = self:MasterBotInitialContainedAction() or BehELOF:New()
	
	self.m_Behavior = CMBBehavior:New(newAct, self)
	
	-- Оружие
	self.m_wpn = {}
	self.m_wpn.m_flFireRange = FIRE_RANGE
	self.m_wpn.m_flFireRate = FIRE_RATE
	self.m_wpn.m_iClip1 = MAG_SIZE
	self.m_wpn.m_iDamage = 8
	self.m_wpn.m_flSpread = 0.022
	self.m_wpn.m_iBulletsNum = 1
	
	self.m_fireRestTime = 0
	self.m_fireShootNum = 0
	
	self:SelectBotWeapon(self.m_iKVWeaponID or 1)
	
	-- Прочее
	self.m_flFootstep = CurTime()
	self.m_iFootstepIndex = 1
	self.m_flHitTime = CurTime()
	self.m_tblRememberEnemies = {}
	self.m_playersAlly = self.m_playersAlly or false
	self.m_playersNeutral = self.m_playersNeutral or false
	
	self.m_flDmgTime = CurTime()
	
	self.m_szFootstepSoundTable = self.m_szFootstepSoundTable or "combine"
	self.m_szGearSoundTable = self.m_szGearSoundTable or ""
	
	self.m_nextThinkLaser = CurTime()
	self.m_nextThinkDoor = CurTime()
	self.m_nextThinkShoot = CurTime()
	
	self.m_steadyTimer = 0

	-- Кеш
	self.m_cachedEnemyThisTick = nil

	-- Регистрируем в глобальном реестре
	--MasterBot_Register(self)
	CMasterBot.RegisterMasterBot(self)
	
	self:InternalInitialize()

	self:MasterBotInitialize()
end

-- Для Мастерботов на основе masterbot_combine_soldier
-- For Masterbots based on masterbot_combine_soldier
function ENT:MasterBotInitialContainedAction()
	return BehMainAction:New()
end

function ENT:InternalInitialContainedAction()
	return nil
end

function ENT:MasterBotInitialize()
end

function ENT:InternalInitialize()
end

function ENT:TryJoinSquad()
	local soldiers = ents.FindByClass(self:GetClass())
	for _, ent in ipairs(soldiers) do
		if (!IsValid(ent) || ent:EntIndex() == self:EntIndex() || !ent.m_squadId) then continue end
		
		if (self:GetPos():Distance(ent:GetPos()) <= 700) then
			local squad = CMasterBotSquadManager:Get(ent.m_squadId)
			if (squad && #squad.members < 8) then
				
				-- Чтобы враждующие между собой противники не заходили в один отряд
				local leader = CMasterBotSquadManager:GetLeader(ent.m_squadId)
				if (leader && leader.m_iMasterBotTeam && self.m_iMasterBotTeam && leader.m_iMasterBotTeam != self.m_iMasterBotTeam) then break end
				
				CMasterBotSquadManager:Join(self, squad)
				
				-- Если игрок заспаунил бота в разгар битвы, даем присоединившеемуся информацию о текущем противнике, которого знает лидер отряда
				-- Остальную информацию о других противника он узнает сам в ходе битвы
				timer.Simple(0.1, function()
					if (IsValid(leader) && IsValid(self)) then
						local enemy = leader.m_Vision:GetPrimaryKnownThreat()
						if (enemy) then
							self.m_Vision:AddKnownEntity(enemy:GetEntity())
						end
					end
				end)
				return
			end
		end
	end
	local squad = CMasterBotSquadManager:Join(self, nil)
end

function ENT:Think()
	-- Инвалидируем кеш, оно будет пересчитываеться один раз за тик
	self.m_cachedEnemyThisTick = nil

	if (IsValid(self:GetEnemy())) then
		self.m_lastEnemyPos = self:GetEnemy():GetPos()
	end
	
	local bRecordStats = self.m_bRecordStats
	local startTime = 0
	local endTime = 0
	
	if (bRecordStats) then
		startTime = SysTime()
	end
	self.m_Body:Upkeep()
	if (bRecordStats) then
		endTime = SysTime()
		
		self.m_statBodyThink = (endTime - startTime)
	end
	
	self.m_Body:UpdateVKeyboard()
	
	if (CurTime() > (self.m_nextThinkShoot or 0)) then
		self:FireWeaponAtEnemy()
		self.m_nextThinkShoot = CurTime() + 0.1
	end
	
	self:ThinkFace()
	if (self.m_Body.m_btnFire) then
		self:ThinkShoot()
	end
	
	if (bRecordStats) then
		startTime = SysTime()
	end
	self:ThinkAnimate()
	if (bRecordStats) then
		endTime = SysTime()
		
		self.m_statAnimateThink = (endTime - startTime)
	end
	
	if (self.m_Body.m_btnCrouch) then
		self.m_isCrouching = true
	else
		self.m_isCrouching = false
	end
	
	if (CurTime() > self.m_flVisionUpdate) then
		if (bRecordStats) then
			startTime = SysTime()
		end
		self.m_Vision:Update()
		if (bRecordStats) then
			endTime = SysTime()
			
			self.m_statVisionThink = (endTime - startTime)
		end
		self.m_flVisionUpdate = CurTime() + 0.1
	end
	
	-- Наводимся на наш путь
	-- Его перекроет наводка с более высшим приоритетом чем BORING
	--local dirPos = self.m_Body:GetEyePosition() + self:GetAngles():Forward() * 100
	--self.m_Body:AimHeadTowardsPos(dirPos, CMasterBotBody.BORING, 0.1, "Body facing")
	
	local dirPos = self.m_Body:GetEyePosition() + self.loco:GetVelocity():Angle():Forward() * 100
	
	-- Чтобы пр прибытии на точку он не смотрел в пол
	if (self.loco:GetVelocity():Length() <= 5) then
		dirPos = self.m_Body:GetEyePosition() + self:GetAngles():Forward() * 100
	end
	
	--local dirPos = self.m_Body:GetEyePosition() + self.loco:GetVelocity():Angle():Forward() * 100
	self.m_Body:AimHeadTowardsPos(dirPos, CMasterBotBody.BORING, 0.1, "Body facing")
	--self.loco:FaceTowards(dirPos)
	
	-- Трейс лазера и фонарика для клиента
	if (CurTime() > self.m_nextThinkLaser) then
		self.m_nextThinkLaser = CurTime() + 0.05
		CMasterBot.ThinkLaser(self)
		
		if CMasterBot:IsDebug() then
			self:SetDebugText(self.m_Behavior:DebugString())
		end
	end
	
	if (CurTime() > self.m_nextThinkDoor) then
		self.m_nextThinkDoor = CurTime() + 0.2
		self:DetectDoor()
	end
	
	if (self.m_wpn && self.m_wpn.m_bReloadByPart) then
		if (self.m_wpn.m_iClip1 < self.m_wpn.m_iMaxClip1 && !self.m_Body.m_btnFire) then
			self.m_Body:PressReloadButton()
		end
		
		if (self.m_Vision:GetTimeSinceVisible() > 1.0 && self.m_wpn.m_iClip1 < self.m_wpn.m_iMaxClip1 && !self.m_Body.m_btnFire) then
			self.m_Body:PressReloadButton()
		end
	end
	
	self.m_isReloading = self.m_Body.m_btnReload
	
	if (self.m_Body.m_btnReload) then
		if (self.m_wpn && self.m_wpn.m_bReloadByPart) then
			if (self.m_wpn.m_iClip1 < self.m_wpn.m_iMaxClip1 && CurTime() > (self.m_reloadNextTime or 0)) then
				self.m_reloadNextTime = CurTime() + (self.m_wpn.m_iClip1 <= 0 and self.m_wpn.m_flReloadDurFirst or self.m_wpn.m_flReloadDur)
				self.m_wpn.m_iClip1 = self.m_wpn.m_iClip1 + 1
				self.m_ammo = self.m_ammo + 1
			end
		end
	end
	
	self:NextThink(CurTime())
	
	return true
end

-- Наводка тела
-- FIXME: Это пиздец, я ненавижу мультиплеер гмода
-- Если менять разворот некстбота через SetAngles или FaceTowards, то во время передвижения он будет дерганно двигаться
-- Лучше бы вместо роблокс пародии (s&box) занялись проблемой интерполяции некстботов, максимально раздражает
--
-- Я заметил, что если двигать некстбота не поворачивая его и не вызывая SetAngles и FaceTowards, то вроде как он нормально двигается в мультиплеере
-- Возможно это мелкое ограничение как то поможет
local ANGLE_UPDATE_THRESHOLD = 3.0  -- градусы

function ENT:ThinkFace()
	if (self.m_dontFace) then return end
	
    local enemy    = self:GetEnemy()
    local curYaw   = self:GetAngles().y
    local wantYaw
	
	if (self.m_isLookingAroundForEnemies || self.m_sniperIsLookingAroundForEnemies) then
		CMasterBotAddonLookAround.UpdateLookingAroundForEnemies(self)
	end
	
    if IsValid(enemy) then
        --wantYaw = (enemy:GetPos() - self:GetPos()):Angle().y
		wantYaw = self.m_Body.m_angCurrentAngles.y
		
		-- m_isLookingAroundForEnemies есть своя наводка на цель
		if (!self.m_isLookingAroundForEnemies && !self.m_sniperIsLookingAroundForEnemies && !self.m_dontLookAtThreat) then
			self.m_Body:AimHeadTowardsEnt(enemy, CMasterBotBody.CRITICAL, 1.0, "Aiming at threat")
		end
    else
        local vel = self.loco:GetVelocity()
        if vel:Length() > 20 then
            wantYaw = vel:Angle().y
			
			--if (self.m_isLookingAroundForEnemies || self.m_sniperIsLookingAroundForEnemies) then
				wantYaw = self.m_Body.m_angCurrentAngles.y
			--end
        else
			wantYaw = self.m_Body.m_angCurrentAngles.y
		end
    end

    -- SetAngles только при изменении угла выше порога.
    -- Между обновлениями клиент плавно интерполирует угол через LerpAngle в cl_init.
    if wantYaw and math.abs(math.AngleDifference(wantYaw, curYaw)) > ANGLE_UPDATE_THRESHOLD then
        self:SetAngles(Angle(0, wantYaw, 0))
    end
end

function ENT:FireWeaponAtEnemy()
	if (self.m_wpn) then
		if (self.m_flagFireUntilFullReload) then
			if (self.m_wpn.m_bReloadByPart && self.m_wpn.m_iClip1 <= 0) then
				self.m_isWaitingForFullReload = true
			end
			
			if (self.m_isWaitingForFullReload) then
				if (self.m_wpn.m_iClip1 < self.m_wpn.m_iMaxClip1) then
					return
				end
				
				self.m_isWaitingForFullReload = false
			end
		end
		
		if (self.m_wpn.m_bIsMinigun) then
			if (self.m_Intention:ShouldHurry() != CMBAction.ANSWER_YES) then
				if (self.m_Vision:GetTimeSinceVisible() < 3.0) then
					self.m_Body:PressAltFireButton(1.0)
				end
			end
		end
	end
	
	local enemy = self:GetEnemy()
	if (!IsValid(enemy)) then return end
	if (!self.m_Vision:IsLineOfFireClear(enemy)) then return end
	if (self.m_Body.m_lookAtSubject != enemy) then return end
	if (!self.m_Body:IsHeadAimingOnTarget()) then return end
	--if (self.m_Behavior:QueryAnswerDeep("ShouldAttack", CMBAction.ANSWER_YES, enemy) == CMBAction.ANSWER_NO) then return end
	if (self.m_Intention:ShouldAttack() == CMBAction.ANSWER_NO) then return end
	local dist = self:GetPos():DistToSqr(enemy:GetPos())
	if dist > self.m_wpn.m_flFireRange * self.m_wpn.m_flFireRange then return end
	if (self.m_ammo <= 0) then return end
	
	if (self.m_isSniper && self.m_isSighting) then
		local sniperShouldFire = false
		
		if (self.m_sniperUseSteady && self.m_steadyTimer) then
			local reactionTime = 0.2
			
			if (self.m_steadyTimer != 0 && CurTime() - self.m_steadyTimer > reactionTime) then
				sniperShouldFire = true
			end
		else
			sniperShouldFire = true
		end
		
		if (sniperShouldFire) then
			
			-- Иногда при смене цели через AimHeadTowards m_isSightedIn может стоять все еще true, но при этом мы еще даже не навелись 100% на цель
			-- Так же точка наведения 0.98 не 100% гарантия что мы навелись на цель, оно нужно для оружия с разбросом
			local tr = util.TraceHull({ start = self.m_Body:GetEyePosition(), endpos = self.m_Body:GetEyePosition() + 9000.0 * self.m_Body.m_angCurrentAngles:Forward(), 
				filter = self, mask = MASK_SHOT, mins = Vector(-1, -1, -1), maxs = Vector(1, 1, 1) })
			
			-- 100% навелись, стреляем
			if (tr.Entity == enemy) then
				-- Режим наводки снайпера 2
				-- Стреляем только когда цель на мушке больше 0.25 секунд
				if (self.m_sniperUseAltSteady) then
					if (!self.m_altSteadyTimer || self.m_altSteadyTimer == 0) then
						self.m_altSteadyTimer = CurTime()
					end
					
					if (CurTime() - self.m_altSteadyTimer > 0.25) then
						self.m_Body:PressFireButton()
					end
				else
					self.m_Body:PressFireButton()
				end
			else
				self.m_altSteadyTimer = 0
			end
		end
		
		return
	end
	
	self.m_Body:PressFireButton(0.2)
end

-- Логика стрельбы
function ENT:ThinkShoot()
	if (self.m_dontShoot) then return end
	
	if (self.m_isReloading) then return end
	if (self.m_ammo <= 0) then return end
	if (CurTime() < self.m_lastShoot + self.m_wpn.m_flFireRate + self.m_fireRestTime) then return end
	
	self.m_fireRestTime = 0
	self.m_fireShootNum = self.m_fireShootNum - 1
	
	if (self.m_fireShootNum <= 0) then
		
		if (!self.m_flagNoRestShooting) then
			local iShootBurst = self:GetRandomBurst(self.m_iKVWeaponID or 1)
			
			if (iShootBurst > 0) then
				self.m_fireShootNum = iShootBurst
			else
				self.m_fireShootNum = 0
			end
		
			local flRest = self:GetShootRestTime(self.m_iKVWeaponID or 1)
			if (flRest > 0) then
				self.m_fireRestTime = flRest
			end
		else
			self.m_fireShootNum = 0
			self.m_fireRestTime = 0
		end
	end

    self.m_lastShoot = CurTime()
    self.m_ammo      = self.m_ammo - 1
	
	self.m_wpn.m_iClip1 = self.m_wpn.m_iClip1 - 1

	local src = self.m_Body:GetEyePosition()
	
	self:FireBullets({
		Num = self.m_wpn.m_iBulletsNum,
		Src = src,
		Dir = self.m_Body.m_angCurrentAngles:Forward(),
		Spread = Vector(self.m_wpn.m_flSpread, self.m_wpn.m_flSpread, 0),
		Tracer = 1,
		Force = 2,
		Damage = self.m_wpn.m_iDamage,
		AmmoType = "AR2",
	})
	
	self:EmitSound(self.m_wpn.m_szFireSound)
	
	-- Дерганье затвора (снайперские винтовки или цевье дробовика)
	if (self.m_wpn.m_szWpnSlide && self.m_wpn.m_flSlidePreSound) then
		timer.Create("masterbot_"..self:EntIndex().."_slide", self.m_wpn.m_flSlidePreSound, 1, function()
			if (IsValid(self)) then
				self:EmitSound(self.m_wpn.m_szWpnSlide)
			end
		end)
	end
	
	-- Анимация стрельбы
	local szGestureShoot = self.m_szAnimGestureShoot
	
	if (szGestureShoot) then
		--self:RemoveAllGestures()
		self.m_Body:ReplayGesture(self.m_Body:GetSeq(szGestureShoot))
	end
    --self:EmitSound("Weapon_AR2.Single")
end

-- Ограничение анимации для оптимизации
local ANIMATE_RATE = 0.02 

-- TODO: Сделать нормальную систему анимаций
-- Если выбрана анимация атаки (она проигрывается один раз, а не постоянно как ходьба и тд), то она проиграется один раз из-за проверки на GetActivity()
-- Возможно можно сделать таймер, по истечении которого оно сменит act или еще что нибудь
function ENT:ThinkAnimate()
    local speed = self.loco:GetVelocity():Length()
    
	self.m_Body:AnimationUpkeep()
	
	if speed > 20 and CurTime() > self.m_flFootstep then
		local tbl = CMasterBot.SoundFootstepTable[self.m_szFootstepSoundTable]
		if tbl then
			local tblSound = tbl[self.m_iFootstepIndex]
			if tblSound then
				local snd = tblSound[math.random(#tblSound)]
				if snd then
					self:EmitSound(snd, SNDLVL_NORM, math.random(95, 105), 1, CHAN_BODY)
				end
			end
			self.m_iFootstepIndex = self.m_iFootstepIndex == 1 and 2 or 1
		end
		
		if (self.m_szGearSoundTable && self.m_szGearSoundTable != "") then
			tbl = CMasterBot.SoundGearTable[self.m_szGearSoundTable]
			if tbl then
				local snd = tbl[math.random(#tbl)]
				if snd then
					self:EmitSound(snd, SNDLVL_NORM, math.random(95, 105), 0.75, CHAN_ITEM)
				end
			end
		end
		
		-- Изменять кулдаун в зависимости от скорости
		self.m_flFootstep = CurTime() + 0.5
	end
end


function ENT:ThinkMove()
	self.m_Locomotion:Upkeep()
end

function ENT:BehaveUpdate(interval)
    if self.m_Behavior then
		local bRecordStats = self.m_bRecordStats
		
		local startTime = 0
		local endTime = 0
		
		if (bRecordStats) then
			startTime = SysTime()
		end
        self.m_Behavior:Update(self, interval)
		if (bRecordStats) then
			endTime = SysTime()
			
			self.m_statBehaviorThink = (endTime - startTime)
		end
    end
	coroutine.resume(self.BehaveThread)
end

-- FIXME: Костыль из-за мультиплеера гмода
-- Вроде как передвижение работает получше в короутине чем в Think, наверно (хотя что тут оно каждые 0.0152 обновляется, что в Think)
-- ATTENTION ATTENTION ATTENTION
-- Если произойдет хоть малейшая lua ошибка в ThinkMove и последующих функциях, то мастербот застревает навсегда на месте
-- из-за lua ошибки, которая не будет логироваться, и из-за этого true loop уничтожается, и ThinkMove больше не вызывается
-- Если мастербот застревает в какой-то момент, то нужно закомментировать весь код RunBehavior и переместить в Think() функцию чтобы найти ошибку
-- Либо расставить pcall
function ENT:RunBehaviour()
	while (true) do
		local bRecordStats = self.m_bRecordStats
		local startTime = 0
		local endTime = 0
		
		if (bRecordStats) then
			startTime = SysTime()
		end
		self:ThinkMove()
		if (bRecordStats) then
			endTime = SysTime()
			
			self.m_statMoveThink = (endTime - startTime)
		end
		coroutine.wait(0.01)
	end
end

function ENT:BodyUpdate()
    self:FrameAdvance()
end

function ENT:MasterBotSound(sound)
	
	local tblSounds = nil
	
	if (sound == "Contact") then
		tblSounds = self.m_tblSoundsEnemy
	elseif (sound == "Enemy") then
		tblSounds = self.m_tblSoundsEnemy
	elseif (sound == "Flank") then
		tblSounds = self.m_tblSoundsFlank
	elseif (sound == "Death") then
		tblSounds = self.m_tblSoundsDeath
	elseif (sound == "Hit") then
		tblSounds = self.m_tblSoundsHit
	end
		
	if (tblSounds) then
		local sound = tblSounds[math.random(#tblSounds)]
		
	end
end

-- ============================================================
-- SECTION 17 - УРОН И СМЕРТЬ
-- ============================================================

function ENT:OnTakeDamage(dmginfo)
	
	 local attacker = dmginfo:GetAttacker()
	
	-- Исключаем френдли файр среди наших
	-- No friendly fire between allies (same m_iMasterBotTeam)
	if (IsValid(attacker) && attacker:GetClass() == self:GetClass()) then
		if (!self.m_Vision:IsEnemy(attacker)) then return 0 end
	end
	
    local hp = self:Health() - dmginfo:GetDamage()
	
	-- Custom function for override
	local response = self:MasterBotOnTakeDamage(dmginfo)
	
	if (response) then
		return response
	end

    if hp <= 0 then
        self:Die(dmginfo)
        return
    end

	-- Меня атаковал игрок, я теперь не нейтрален к нему, а негативно настроен
	-- TODO: Протестить, если враждебный бот атакует нейтрального бота, которому все равно на враждебного бота
	if (self.m_playersNeutral && IsValid(attacker)) then
		self:RememberEntityAsEnemy(attacker)
	end
	
	if (IsValid(attacker) && self.m_playersAlly && attacker:IsPlayer()) then return 0 end

    if not self.m_flagAggressive and not self.m_coverAt then
        self.m_coverAt = CurTime() + COVER_DELAY
    end
	
    if (IsValid(attacker) && (attacker:IsPlayer() || attacker:IsNPC() || attacker:IsNextBot())) then
        self:SetEnemy(attacker)
        for _, m in ipairs(CMasterBotSquadManager:GetBotSquadMembers(self)) do
            if (IsValid(m) && m:EntIndex() != self:EntIndex() && !IsValid(m:GetEnemy())) then
				if (m.m_iMasterBotTeam && self.m_iMasterBotTeam && self.m_iMasterBotTeam == m.m_iMasterBotTeam) then 
					m:SetEnemy(attacker)
				
					-- TODO: Нужна ли вообще проверка на игрока? Я думаю это будет работать на некстботов, мастерботов и нпс
					if (m.m_playersNeutral && attacker:IsPlayer()) then
						m:RememberEntityAsEnemy(attacker)
					end
				end
            end
        end
    end
	
	if (CurTime() > self.m_flDmgTime) then
		self.m_flDmgTime = CurTime() + math.random(2.0, 5.0)
		self:EmitMasterBotSound("Hit")
	end
	
	-- В аддон LookAround есть свой метод наводки на обидчика, если мы о нем не в курсе
	if (!self.m_isLookingAroundForEnemies && !self.m_sniperIsLookingAroundForEnemies && !IsValid(self:GetEnemy()) && !self.m_Vision:IsInFieldOfViewEnt(attacker)) then
		
		local toThreat = attacker:GetPos() - self:GetPos()
		toThreat:Normalize()
		local threatRange = toThreat:Length()
		
		local err = threatRange * math.sin(math.pi / 6)
		
		local imperfectAimSpot = attacker:WorldSpaceCenter()
		imperfectAimSpot.x = imperfectAimSpot.x + math.Rand(-err, err)
		imperfectAimSpot.y = imperfectAimSpot.y + math.Rand(-err, err)
		
		self.m_Body:AimHeadTowardsPos(imperfectAimSpot, CMasterBotBody.IMPORTANT, 1.0, "Something hurt me!")
	end
end

function ENT:MasterBotOnTakeDamage(info)

end

function ENT:Die(dmginfo)
    CMasterBotSquadManager:Leave(self)
	
	self:EmitMasterBotSound("Death")

    -- local rag = ents.Create("prop_ragdoll")
    -- if IsValid(rag) then
        -- rag:SetModel(self:GetModel())
        -- rag:SetPos(self:GetPos())
        -- rag:SetAngles(self:GetAngles())
		-- rag:SetSkin(self:GetSkin())
		-- rag:SetSaveValue("m_nBody", self:GetInternalVariable("m_nBody"))
		-- rag:SetCollisionGroup(COLLISION_GROUP_DEBRIS) --COLLISION_GROUP_WORLD
        -- rag:Spawn()
        -- local phys = rag:GetPhysicsObject()
        -- if IsValid(phys) then
            -- phys:SetVelocity(dmginfo:GetDamageForce() * 2.0 + Vector(0, 0, 90))
        -- end
    -- end

    self:Remove()
end

function ENT:OnRemove()
	-- Убираем из реестра чтобы event-хуки не обращались к удалённому боту
	CMasterBot.UnregisterMasterBot(self)
    if self.m_squadId then
		CMasterBotSquadManager:Leave(self)
	end
end

function ENT:OnKilled(dmginfo)
	hook.Run("OnNPCKilled", self, dmginfo:GetAttacker(), dmginfo:GetInflictor() )

	self:BecomeRagdoll(dmginfo)
	
	self.m_Behavior:ProcessEvent("OnKilled", dmginfo)
end

function ENT:OnContact(ent)
	self.m_Behavior:ProcessEvent("OnContact", ent)
end

function ENT:OnInjured(info)
	self.m_Behavior:ProcessEvent("OnInjured", info)
end

function ENT:OnOtherKilled(victim, info)
	self.m_Behavior:ProcessEvent("OnOtherKilled", victim, info)
end

function ENT:OnLeaveGround(ent)
	self.m_Behavior:ProcessEvent("OnLeaveGround", ent)
end

function ENT:OnLandOnGround(ent)
	self.m_Behavior:ProcessEvent("OnLandOnGround", ent)
end

function ENT:OnStuck()
	self.m_Behavior:ProcessEvent("OnStuck")
end

function ENT:OnUnStuck()
	self.m_Behavior:ProcessEvent("OnUnStuck")
end

function ENT:OnNavAreaChanged(old, new)
	self.m_Behavior:ProcessEvent("OnNavAreaChanged", old, new)
end

function ENT:CommandString(command)
	self.m_Behavior:ProcessEvent("OnCommandString", command)
end

function ENT:DetectDoor()
	local pos = self:GetPos()
	local forward = self:GetForward()
	local eyePos = pos + Vector(0, 0, 40)
	
	local tr = util.TraceHull({ 
		start = eyePos, 
		endpos = eyePos + forward * 64,
		mins = HULL_MINS * 0.5,
		maxs = HULL_MAXS * 0.5,
		filter = self,
		mask = MASK_SOLID
	})
	
	if (tr.Hit && IsValid(tr.Entity) && string.find(tr.Entity:GetClass(), "_door") && CurTime() > (self.m_lastOpenDoorTime or 0)) then
		local iSpawnFlags = tr.Entity:GetInternalVariable("m_spawnflags")
		-- Правила использования энтити не расспостраняются на энтити, только на игроков
		-- 256 - Use opens
		-- 512 - NPCs cant
		if (bit.band(iSpawnFlags, 256) == 256 && bit.band(iSpawnFlags, 512) == 0) then
			tr.Entity:Use(self)
			self.m_lastOpenDoorTime = CurTime() + 5.0
		end
		
		-- FIXME: Иногда работает норм, иногда нет
		local n = #CMasterBot.MapIO.Buttons
		for i = 1, n do
			local data = CMasterBot.MapIO.Buttons[i]
			if (IsValid(data.Button) && IsValid(data.Door)) then
				
				for k = 1, #data.Doors do
					local curDoor = data.Doors[k]
					-- Открываем только если мы видим кнопку, в противном случае у нас может быть 2 кнопки (первая с другой, где бот, вторая за дверью)
					-- Из-за чего бот может выбрать не ту сторону и идти дальше в дверь
					if (curDoor:EntIndex() == tr.Entity:EntIndex() && self.m_Vision:IsAbleToSee(data.Button)) then
						self:Command("open door", { button = data.Button, door = curDoor })
						
						-- Избегание спама
						self.m_lastOpenDoorTime = CurTime() + 8.0
					end
				end
			end
		end
		
		-- Может открывать те двери, которые нужно открыть по сюжету карты
		-- if (!tr.Entity:GetInternalVariable("m_bLocked")) then
			-- tr.Entity:Input("Open")
		-- end
	end
end

-- TODO: Сделать более продвинутую систему выбора оружия
-- Например, из глобального списка оружия в луа и выбирать по классу
function ENT:SelectBotWeapon(weaponType)
	
	if (!weaponType || weaponType <= 0) then
		weaponType = 1
	end
	
	local tblWeapons =
	{
		[1] = { 
		fire_range = 1400,
		reload_duration = 2.8,
		mag_size = 30,
		fire_rate = 0.10,
		damage = 8,
		spread = 0.022,
		bullets = 1,
		model = "models/weapons/w_smg1.mdl",
		fire = "weapons/smg1/smg1_fire1.wav",
		rest_time = { 0.3, 0.6 },
		burst_num = { 2, 5 }
		},
		
		[2] = { 
		fire_range = 1400,
		reload_duration = 2.8,
		mag_size = 45,
		fire_rate = 0.05,
		damage = 4,
		spread = 0.075,
		bullets = 1,
		model = "models/weapons/w_smg1.mdl",
		fire = "weapons/smg1/smg1_fire1.wav",
		rest_time = { 0.3, 0.6 },
		burst_num = { 3, 7 }
		},
		
		[3] = { 
		fire_range = 700,
		reload_duration = 2.8,
		mag_size = 6,
		fire_rate = 1.0,
		damage = 8,
		spread = 0.0775,
		bullets = 6,
		model = "models/weapons/w_shotgun.mdl",
		fire = "weapons/shotgun/shotgun_fire6.wav",
		},
		
		[4] = { 
		fire_range = 1400,
		reload_duration = 2.8,
		mag_size = 30,
		fire_rate = 0.1,
		damage = 8,
		spread = 0.035,
		bullets = 1,
		model = "models/weapons/w_irifle.mdl",
		fire = "weapons/ar2/fire1.wav",
		rest_time = { 0.3, 0.6 },
		burst_num = { 2, 5 }
		},
		
		[5] = { 
		fire_range = 1000,
		reload_duration = 2.8,
		mag_size = 8,
		fire_rate = 0.4,
		damage = 5,
		spread = 0.0775,
		bullets = 4,
		model = "models/weapons/w_shot_xm1014.mdl",
		--fire = "weapons/shotgun/shotgun_fire6.wav",
		fire = "Weapon_XM1014.Single",
		is_shotgun = true,
		},
		
		[6] = { 
		fire_range = 1000,
		reload_duration = 2.8,
		mag_size = 2,
		fire_rate = 0.75,
		damage = 9,
		spread = 0.0775,
		bullets = 7,
		model = "models/weapons/w_annabelle.mdl",
		fire = "weapons/shotgun/shotgun_fire6.wav",
		is_shotgun = true,
		},
		
		[7] = { 
		fire_range = 1400,
		reload_duration = 1.4,
		mag_size = 15,
		fire_rate = 0.5,
		damage = 5,
		spread = 0.025,
		bullets = 1,
		model = "models/weapons/w_pistol.mdl",
		--fire = "weapons/pistol/pistol_fire3.wav",
		fire = "Weapon_Pistol.NPC_Single",
		},
		
		[8] = { 
		fire_range = 1400,
		reload_duration = 2.8,
		mag_size = 30,
		fire_rate = 0.2,
		damage = 8,
		spread = 0.035,
		bullets = 1,
		model = "models/weapons/w_rif_ak47.mdl",
		fire = "Weapon_AK47.Single",
		rest_time = { 0.3, 0.6 },
		burst_num = { 4, 8 }
		},
		
		[9] = { 
		fire_range = 1400,
		reload_duration = 2.9,
		mag_size = 40,
		fire_rate = 0.13,
		damage = 6,
		spread = 0.035,
		bullets = 1,
		model = "models/weapons/w_rif_m4a1.mdl",
		fire = "Weapon_M4A1.Single",
		rest_time = { 0.3, 0.6 },
		burst_num = { 4, 8 }
		},
		
		[10] = { 
		fire_range = 1400,
		reload_duration = 2.8,
		mag_size = 45,
		fire_rate = 0.054,
		damage = 5,
		spread = 0.065,
		bullets = 1,
		model = "models/weapons/w_smg_mp5.mdl",
		fire = "Weapon_MP5Navy.Single",
		rest_time = { 0.3, 0.6 },
		burst_num = { 2, 5 }
		},
		
		[11] = { 
		fire_range = 1400,
		reload_duration = 2.8,
		mag_size = 30,
		fire_rate = 0.052,
		damage = 6,
		spread = 0.055,
		bullets = 1,
		model = "models/weapons/w_smg_ump45.mdl",
		fire = "Weapon_UMP45.Single",
		rest_time = { 0.3, 0.6 },
		burst_num = { 2, 5 }
		},
		
		[12] = { 
		fire_range = 1400,
		reload_duration = 1.4,
		mag_size = 15,
		fire_rate = 0.45,
		damage = 5,
		spread = 0.018,
		bullets = 1,
		model = "models/weapons/w_pist_elite_single.mdl",
		--fire = "weapons/pistol/pistol_fire3.wav",
		fire = "Weapon_ELITE.Single",
		},
		
		[13] = { 
		fire_range = 1400,
		reload_duration = 2.9,
		mag_size = 40,
		fire_rate = 0.13,
		damage = 6,
		spread = 0.035,
		bullets = 1,
		model = "models/weapons/w_rif_m4a1_silencer.mdl",
		fire = "Weapon_M4A1.Single",
		rest_time = { 0.3, 0.6 },
		burst_num = { 6, 8 }
		},
		
		[14] = { 
		fire_range = 1600,
		reload_duration = 2.9,
		mag_size = 30,
		fire_rate = 0.2,
		damage = 6,
		spread = 0.028,
		bullets = 1,
		model = "models/weapons/tacint/w_g36k.mdl",
		fire = "Weapon_M4A1.Single",
		rest_time = { 0.3, 0.6 },
		burst_num = { 2, 5 }
		},
		
		[15] = { 
		fire_range = 1600,
		reload_duration = 2.9,
		mag_size = 20,
		fire_rate = 0.4,
		damage = 9,
		spread = 0.01,
		bullets = 1,
		model = "models/weapons/tacint/w_hk417.mdl",
		fire = "Weapon_M4A1.Single",
		rest_time = { 0.3, 0.4 },
		burst_num = { 3, 6 }
		},
		
		[16] = { 
		fire_range = 1400,
		reload_duration = 2.8,
		mag_size = 30,
		fire_rate = 0.2,
		damage = 3,
		spread = 0.035,
		bullets = 1,
		model = "models/weapons/w_rif_ak47.mdl",
		fire = "Weapon_AK47.Single",
		rest_time = { 0.3, 0.6 },
		burst_num = { 4, 8 }
		},
		
		[17] = {
			fire_range = 6000,
			reload_duration = 3.4,
			mag_size = 15,
			fire_rate = 1.5,
			damage = 40,
			spread = 0.0,
			bullets = 1,
			model = "models/weapons/w_snip_g3sg1.mdl",
			fire = "Weapon_G3SG1.Single",
			slide = "Weapon_G3SG1.Slide",
			slide_pre_sound = 0.5,
		},
		
		[18] = {
			fire_range = 6000,
			reload_duration = 3.8,
			mag_size = 15,
			fire_rate = 1.5,
			damage = 90,
			spread = 0.0,
			bullets = 1,
			model = "models/weapons/w_snip_awp.mdl",
			fire = "Weapon_AWP.Single",
			slide = "Weapon_AWP.Bolt",
			slide_pre_sound = 0.5,
		},
		
		[19] = {
			fire_range = 6000,
			reload_duration = 2.8,
			mag_size = 15,
			fire_rate = 1.5,
			damage = 25,
			spread = 0.0,
			bullets = 1,
			model = "models/weapons/w_snip_scout.mdl",
			fire = "Weapon_Scout.Single",
			slide = "Weapon_Scout.Bolt",
			slide_pre_sound = 0.5,
		},
		
		[20] = {
			fire_range = 6000,
			reload_duration = 3.0,
			mag_size = 15,
			fire_rate = 1.5,
			damage = 50,
			spread = 0.0,
			bullets = 1,
			model = "models/weapons/w_snip_sg550.mdl",
			fire = "Weapon_SG550.Single",
			slide = "Weapon_SG550.Boltpull",
			slide_pre_sound = 0.5,
		},
		
		[21] = { 
		fire_range = 1000,
		reload_duration = 0.7,
		reload_first_duration = 1.005,
		reload_by_part = true,
		mag_size = 6,
		fire_rate = 0.9,
		damage = 5,
		spread = 0.0775,
		bullets = 10,
		model = "models/weapons/w_models/w_shotgun.mdl",
		fire = "weapons/shotgun/shotgun_fire6.wav",
		is_shotgun = true,
		},
	}
	
	if (weaponType > #tblWeapons) then
		weaponType = #tblWeapons
	end
	
	local hProp = ents.Create("prop_dynamic")
	hProp:SetModel(tblWeapons[weaponType].model)
	hProp:SetPos(self:GetPos())
	hProp:Spawn()
	hProp:Activate()
	
	hProp:SetParent(self)
	
	hProp:SetMoveType(MOVETYPE_NONE)
	hProp:SetSolid(SOLID_NONE)
	hProp:SetLocalPos(Vector( 0, 0, 0 ))
	hProp:SetLocalAngles(Angle( 0, 0, 0 ))

	hProp:AddEffects(EF_BONEMERGE)
	
	self.m_wpn = {}
	
	self.m_wpn.m_flFireRange = tblWeapons[weaponType].fire_range
	self.m_wpn.m_flFireRate = tblWeapons[weaponType].fire_rate
	self.m_wpn.m_flReloadDur = tblWeapons[weaponType].reload_duration
	self.m_wpn.m_iClip1 = tblWeapons[weaponType].mag_size
	self.m_wpn.m_iMaxClip1 = tblWeapons[weaponType].mag_size
	self.m_wpn.m_iDamage = tblWeapons[weaponType].damage
	self.m_wpn.m_flSpread = tblWeapons[weaponType].spread
	self.m_wpn.m_iBulletsNum = tblWeapons[weaponType].bullets
	self.m_wpn.m_szFireSound = tblWeapons[weaponType].fire
	self.m_wpn.m_szWpnReload = tblWeapons[weaponType].reload
	self.m_wpn.m_iRndBurst = tblWeapons[weaponType].burst_num
	self.m_wpn.m_flRndRest = tblWeapons[weaponType].rest_time
	self.m_wpn.m_szWpnSlide = tblWeapons[weaponType].slide
	self.m_wpn.m_flSlidePreSound = tblWeapons[weaponType].slide_pre_sound
	self.m_wpn.m_bReloadByPart = tblWeapons[weaponType].reload_by_part
	self.m_wpn.m_flReloadDurFirst = tblWeapons[weaponType].reload_first_duration
	
	self.m_ammo = self.m_wpn.m_iClip1
	
	self.m_wpn.m_hModel = hProp
	
	if (self.SetMBWeaponModel) then
		self:SetMBWeaponModel(hProp)
	end
	
	-- У дробовиков нету время ожидания между выстрелами, они стрелают как только появляется возможность
	self.m_fireShootNum = not tblWeapons[weaponType].is_shotgun and 8 or 0
end

-- TODO: Является своего рода костылем, нужно продумать более гибкую и умную систему нейтралитета и отношений
-- Если мы нейтральны к игрокам и игрок нанес нам урон, то он теперь для нас враг
function ENT:RememberEntityAsEnemy(ply)
	local bFound = false
	
	for i = 1, #self.m_tblRememberEnemies do
		-- Игрок уже вышел, очищаем чтобы не было мусора
		if (self.m_tblRememberEnemies[i] == nil || !IsValid(self.m_tblRememberEnemies[i])) then 
			table.remove(self.m_tblRememberEnemies, i)
			continue
		end
		
		if (self.m_tblRememberEnemies[i]:EntIndex() == ply:EntIndex()) then 
			bFound = true
			break
		end
	end
	
	if (!IsValid(ply)) then return end
	
	if (!bFound) then
		table.insert(self.m_tblRememberEnemies, ply)
		self:MasterBotRememberEntityAsEnemySuccess(ply)
	end
end

function ENT:MasterBotRememberEntityAsEnemySuccess(ply)
end

function ENT:IsEntityEnemy(ply)
	for i = 1, #self.m_tblRememberEnemies do
		if (self.m_tblRememberEnemies[i] == nil || !IsValid(self.m_tblRememberEnemies[i])) then 
			table.remove(self.m_tblRememberEnemies, i)
			continue
		end
		
		if (self.m_tblRememberEnemies[i]:EntIndex() == ply:EntIndex()) then return true end
	end
	
	return false
end

function ENT:CommandMoveToPoint(pos)
	
	self.m_Behavior:ProcessEvent("OnCommandApproach", pos)
end

function ENT:CommandEscort(subject)
	self.m_Behavior:ProcessEvent("OnCommandApproachEnt", subject)
end

function ENT:Command(command, data)
	self.m_Behavior:ProcessEvent("OnCommand", command, data)
end

-- "Attack"
-- "Flank"
-- "Enemy"
-- "Death"
-- "Hit"
function ENT:EmitMasterBotSound(group, rnd, rndDelay)
	
	if (!self.m_szSoundTable) then return end
	
	local tbl = CMasterBot.SoundTable[self.m_szSoundTable]
	if (!tbl) then return end
	
	local tblSnd = tbl[group]
	if (!tblSnd) then return end
	
	local snd = tblSnd[math.random(#tblSnd)]
	if (!snd) then return end
	
	local bCanPlay = true
	
	if (rnd) then
		local ch = math.random(1, 100)
		if (ch > rnd) then
			return
		end
	end
	
	if (rndDelay && rndDelay[1] && rndDelay[2]) then
		local sec = math.random(rndDelay[1], rndDelay[2])
		timer.Simple(sec, function()
			if (IsValid(self)) then
				self:EmitSound(snd, 80, self.m_iVoicePitch or 100, 1, CHAN_VOICE)
			end
		end)
		
		return
	end
	
	self:EmitSound(snd, 80, self.m_iVoicePitch or 100, 1, CHAN_VOICE)
end

function ENT:Event_MasterBot_OnOtherKilled(victim, attacker, inflictor)
	if (!IsValid(victim) || !IsValid(attacker)) then return end
	if (victim:EntIndex() == self:EntIndex()) then return end
	-- Кто-то убил моего союзника, он становится врагом автоматически
	if (victim:IsNextBot() && victim.m_iMasterBotTeam && self.m_iMasterBotTeam) then
		if (victim.m_iMasterBotTeam == self.m_iMasterBotTeam) then
			if (IsValid(attacker)) then
				self.m_Vision:AddKnownEntity(attacker)
				-- Если я нейтрал, но противник убил моего союзника, то я больше не нейтрален к нему
				self:RememberEntityAsEnemy(attacker)
			end
		end
	end
end

function ENT:PlaySeqWait(seq, speed, wait)
	self.m_lockAnimate = true
	local act = self:GetSequenceActivity(self:LookupSequence(seq))
	if act then
		self:StartActivity(act)
	end
	
	if (timer.Exists("masterbot_"..self:EntIndex().."_playseqwait")) then
		timer.Remove("masterbot_"..self:EntIndex().."_playseqwait")
	end
	
	timer.Create("masterbot_"..self:EntIndex().."_playseqwait", wait, 1, function()
		self.m_lockAnimate = false
	end)
end