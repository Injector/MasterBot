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

-- Example how to override base CMasterBotVision to replace default functions
local CMasterBotVisionNew = setmetatable({}, { __index = CMasterBotVision })
CMasterBotVisionNew.__index = CMasterBotVisionNew

function CMasterBotVisionNew:New()
	local b = CMasterBotVision.New(self, CMasterBotVisionNew)
	return b
end

-- Here you can add custom logic to define if that entity is an enemy
function CMasterBotVisionNew:IsEnemy(ent)
	-- Same class name, not an enemy
	if (ent:GetClass() == self.m_bot:GetClass()) then
		return false
	end
	
	return true
end

-- ============================

local BehKleinerTaunt = setmetatable({}, { __index = CMBAction })
BehKleinerTaunt.__index = BehKleinerTaunt

function BehKleinerTaunt:New(seq, dur, snd, gesture)
	local b = CMBAction.New(self, "KleinerTaunt")
	b.m_wait = CurTime() + dur
	b.m_seq = seq
	b.m_snd = snd
	b.m_gestureSeq = gesture
	return b
end

function BehKleinerTaunt:OnStart(bot, prior)
	-- Lock animations, so our custom animation will not be overriden by a move animation
	bot.m_Body:LockAnimations(true)
	bot:EmitSound(self.m_snd, 75, 100, 1, CHAN_VOICE)
	
	local act = bot:GetSequenceActivity(bot:LookupSequence(self.m_seq))
	if (act) then
		bot:StartActivity(act)
	end
	
	-- We can still add gestures despite LockAnimations
	if (self.m_gestureSeq) then
		local gestureSeq = bot:LookupSequence(self.m_gestureSeq)
		if (gestureSeq) then
			bot:AddGestureSequence(gestureSeq, true)
		end
	end
	
	return self:Continue()
end

function BehKleinerTaunt:Update(bot, dt)
	local enemy = bot:GetEnemy()
	if (!IsValid(enemy)) then
		return self:Done("No threat")
	end
	
	if (CurTime() > self.m_wait) then
		return self:Done("Sucessfully taunted")
	end
	
	bot.m_Locomotion:Stop()
	
	-- MANDATORY will override CRITICAL aim in ThinkFace
	bot.m_Body:AimHeadTowardsEnt(enemy, CMasterBotBody.MANDATORY, 1.0, "Aiming at a threat")
	
	return self:Continue()
end

function BehKleinerTaunt:OnEnd(bot, nextAction)
	bot.m_isTaunting = false
	bot.m_Body:LockAnimations(false)
	bot.m_Locomotion:NavClear()
	return self:Continue()
end

local BehExampleChildAction = setmetatable({}, { __index = CMBAction })
BehExampleChildAction.__index = BehExampleChildAction

-- Our example child action: first BehExampleAction will be executed, then ExampleChildAction. Based on BehExampleAction result (Continue)
-- ExampleAction -> ExampleChildAction aka ExampleAction ( ExampleChildAction )
function BehExampleChildAction:New()
	local b = CMBAction.New(self, "ExampleChildAction")
	return b
end

function BehExampleChildAction:OnStart(bot, prior)
	return self:Continue()
end

-- We will run to our threat and say Hi to them
function BehExampleChildAction:Update(bot, dt)
	local enemy = bot:GetEnemy()
	
	if (IsValid(enemy)) then
		local shouldRun = false
		
		local distToStartRun = 300.0 * 300.0
		local distToTaunt = 75.0 * 75.0
		local dist = bot:GetPos():DistToSqr(enemy:GetPos())
		
		if (dist > distToStartRun) then
			shouldRun = true
			
			-- Instead giving speed via second argument in NavMove
			-- We can define speed in m_Locomotion via m_Locomotion:SetWalkSpeed() and m_Locomotion:SetRunSpeed()
			-- In that case, we use shift button to force run
			bot.m_Body:PressShiftButton()
		elseif (dist <= distToTaunt) then
			return self:SuspendFor(BehKleinerTaunt:New("idle_all_01", 3, "vo/k_lab/kl_gordongo.wav", "gesture_wave"), "Saying hello")
		end
		
		bot.m_Locomotion:NavMove(enemy:GetPos(), shouldRun and 200 or 100)
	end
	
	return self:Continue()
end

function BehExampleChildAction:OnEnd(bot, nextAction)
	bot.m_Locomotion:NavClear()
	return self:Continue()
end

function BehExampleChildAction:OnSuspend(bot, interruptingAction)
	return self:Continue()
end

-- Since we got TryContinue, we will move to BehExampleAction:OnInjured and explode, despite BehExampleAction is inactive
-- You can use self:TryContinue(CMBAction.RESULT_IMPORTANT) to block TrySuspendFor, TryChangeTo and TryDone based on TryContinue priority
-- If we use TrySustain(CMBAction.RESULT_CRITICAL), we will skip BehExampleAction:OnInjured because it has CMBAction.RESULT_TRY
function BehExampleChildAction:OnInjured(bot, info)
	return self:TryContinue()
end

local BehKleinerExplode = setmetatable({}, { __index = CMBAction })
BehKleinerExplode.__index = BehKleinerExplode

function BehKleinerExplode:New()
	local b = CMBAction.New(self, "KleinerExplode")
	return b
end

function BehKleinerExplode:OnStart(bot, prior)
	
	local hExplosion = ents.Create("env_explosion")
	if (IsValid(hExplosion)) then
		hExplosion:SetPos(bot:GetPos())
		hExplosion:SetKeyValue("iMagnitude", "9999")
		hExplosion:SetKeyValue("iRadiusOverride", "500")
		
		hExplosion:Spawn()
		hExplosion:Fire("Explode")
		
		timer.Simple(0.2, function()
			if (IsValid(hExplosion)) then
				hExplosion:Remove()
			end
		end)
	end
	
	bot:Remove()
	
	return self:Continue()
end

local BehExampleAction = setmetatable({}, { __index = CMBAction })
BehExampleAction.__index = BehExampleAction

function BehExampleAction:New()
	local b = CMBAction.New(self, "ExampleAction")
	b.m_nextTauntTime = 0
	return b
end

function BehExampleAction:InitialContainedAction(bot)
	return BehExampleChildAction:New()
end

function BehExampleAction:OnStart(bot, prior)
	self.m_nextTauntTime = CurTime() + 10
end

function BehExampleAction:Update(bot, dt)
	if (CurTime() > self.m_nextTauntTime) then
		-- We're taunting, better next time
		if (bot.m_isTaunting) then
			self.m_nextTauntTime = CurTime() + 10
			return self:Continue()
		end
		return self:SuspendFor(BehKleinerTaunt:New("taunt_laugh", 5, "vo/citadel/br_laugh01.wav"), "Taunting to a threat")
	end
	
	return self:Continue()
end

function BehExampleAction:OnEnd(bot, nextAction)
end

function BehExampleAction:OnSuspend(bot, interruptingAction)
end

function BehExampleAction:OnResume(bot, interruptingAction)
	self.m_nextTauntTime = CurTime() + 10.0
end

function BehExampleAction:ShouldAttack(bot, them)
	return CMBAction.ANSWER_YES
end

-- Since our child action tolds ANSWER_UNDEFINED, we will always get ANSWER_NO
function BehExampleAction:ShouldRetreat(bot)
	return CMBAction.ANSWER_NO
end

-- Here you can override bot's position for aiming
-- By default, bot will shot in subject's WorldSpaceCenter
function BehExampleAction:SelectTargetPoint(bot, subject)
	-- Always aim for subject's eyes
	--return subject:EyePosition()
end

-- Keep in mind, threat1 and threat2 are NOT Entities, they're CKnownEntity
-- To get CKnownEntity's entity, use :GetEntity()
-- Return nil to move to default SelectMoreDangerousThreat behaviour (see CMasterBotIntention)
function BehExampleAction:SelectMoreDangerousThreat(bot, threat1, threat2)
	if (threat1 == nil) then return threat2 end
	if (threat2 == nil) then return threat1 end
	
	local range1 = (self:GetBot():GetPos() - threat1:GetEntity():GetPos()):LengthSqr()
	local range2 = (self:GetBot():GetPos() - threat2:GetEntity():GetPos()):LengthSqr()
	
	if (range1 < range2) then return threat1 end
	
	return threat2
end

-- You can define you damage code in OnTakeDamage, and you also can add damage code in actions
function BehExampleAction:OnInjured(bot, info)
	-- Priorities: RESULT_TRY, RESULT_IMPORTANT, RESULT_CRITICAL
	return self:TrySuspendFor(BehKleinerExplode:New(), CMBAction.RESULT_CRITICAL, "Got injured, exploding!")
end

-- =============================

function ENT:GetEnemy()
	local enemy = self.m_Vision:GetPrimaryKnownThreat()
	if (enemy && IsValid(enemy:GetEntity())) then return enemy:GetEntity() end
	return NULL
end

function ENT:SetEnemy(ent)
	self.m_Vision:AddKnownEntity(ent)
end

function ENT:Initialize()
	self:SetModel("models/player/kleiner.mdl")
	self:SetHealth(5000)
	self:SetColor(Color(200, 200, 200, 256))
	
	self:SetLagCompensated(true)
	self:SetCollisionBounds(Vector(-10, -10, 0), Vector(10, 10, 82))
	
	self:SetCollisionGroup(COLLISION_GROUP_NPC)
	self:SetSolid(SOLID_BBOX)
	
	-- Initializing MasterBot components
	self.m_Intention = CMasterBotIntention.New(self)
	self.m_Body = CMasterBotBody.New(self)
	self.m_Vision = CMasterBotVisionNew.New(self)
	self.m_Locomotion = CMasterBotLocomotion.New(self)
	
	-- Set our eye position a little bit up for line sights checks
	self.m_Body:SetEyePosition(Vector(0, 0, 30))
	
	self.m_Locomotion:SetWalkSpeed(100)
	self.m_Locomotion:SetRunSpeed(300)
	self.m_Locomotion:SetControlSpeedByButtons(true)
	
	-- Aim tracking interval on subjects and reaction time depens on bot's skill level (EASY, NORMAL, HARD, EXPERT)
	self.m_iBotSkill = CMasterBot.NORMAL
	
	self.m_szAnimCombatIdle = "idle_all_01"
	self.m_szAnimCombatRun = "run_all_01"
	self.m_szAnimCombatWalk = "walk_all"
	
	self.m_szAnimIdle = "idle_all_01"
	self.m_szAnimRun = "run_all_01"
	self.m_szAnimWalk = "walk_all"
	
	self.m_flVisionUpdate = CurTime() + 0.1
	
	-- Commander priority for squads
	self.m_iCommanderPriority = 0
	
	-- Set to true to make bot look around for enemies
	self.m_isLookingAroundForEnemies = false
	
	if (self.m_flOverrideMaxVisionRange) then
		self.m_Vision.m_maxVisionRange = self.m_flOverrideMaxVisionRange
		self.m_Vision.m_maxVisionRangeSqr = self.m_flOverrideMaxVisionRange * self.m_flOverrideMaxVisionRange
	end

	-- Initialize behavior with our first action
	local newAct = BehExampleAction:New()
	
	self.m_Behavior = CMBBehavior:New(newAct, self)
	
	-- Register our bot for events
	CMasterBot.RegisterMasterBot(self)
end

function ENT:Think()
	-- Update bot's camera for aim tracking, make sure it's done in Think for smooth aim tracking
	self.m_Body:Upkeep()
	
	-- Update bot's virtual keyboard
	self.m_Body:UpdateVKeyboard()
	
	-- Update bot's animations
	self.m_Body:AnimationUpkeep()
	
	self:ThinkFace()
	
	-- Set debug string for mb_debug
	if (CurTime() > (self.m_nextThinkLaser or 0)) then
		if CMasterBot:IsDebug() then
			self:SetDebugText(self.m_Behavior:DebugString())
		end
	end
	
	-- Update vision every 0.1 s
	if (CurTime() > self.m_flVisionUpdate) then
		self.m_flVisionUpdate = CurTime() + 0.1
		self.m_Vision:Update()
	end
	
	local dirPos = self.m_Body:GetEyePosition() + self.loco:GetVelocity():Angle():Forward() * 100
	
	-- Aim somewhere, or else our bot will aim into the ground
	if (self.loco:GetVelocity():Length() <= 5) then
		dirPos = self.m_Body:GetEyePosition() + self:GetAngles():Forward() * 100
	end
	
	-- Aim our camera to the pos, depends on priority (BORING, INTERESTING, IMPORTANT, CRITICAL, MANDATORY)
	-- Any AimHeadTowardsPos or AimHeadTowardsEnt with higher priority will override this
	self.m_Body:AimHeadTowardsPos(dirPos, CMasterBotBody.BORING, 0.1, "Body facing")
	
	-- Force it to update every tick for smooth camera update and navigation
	self:NextThink(CurTime())
	
	return true
end

function ENT:ThinkFace()
    local enemy    = self:GetEnemy()
    local curYaw   = self:GetAngles().y
    local wantYaw
	
	if (self.m_isLookingAroundForEnemies) then
		CMasterBotAddonLookAround.UpdateLookingAroundForEnemies(self)
	end
	
	wantYaw = self.m_Body.m_angCurrentAngles.y
	
	-- If we have an enemy, aim on it. CRITICAL will override BORING body facing look
    if IsValid(enemy) then
		if (!self.m_isLookingAroundForEnemies) then
			self.m_Body:AimHeadTowardsEnt(enemy, CMasterBotBody.CRITICAL, 1.0, "Aiming at threat")
		end
    end

	
    if wantYaw and math.abs(math.AngleDifference(wantYaw, curYaw)) > 3.0 then
        self:SetAngles(Angle(0, wantYaw, 0))
    end
end

function ENT:ThinkAnimate()
	self.m_Body:AnimationUpkeep()
end

function ENT:ThinkMove()
	self.m_Locomotion:Upkeep()
end

function ENT:BehaveUpdate(interval)
	self.m_Behavior:Update(self, interval)
	coroutine.resume(self.BehaveThread)
end

-- Run ThinkMove (m_Locomotion:Upkeep()) here for smooth navigation in multiplayer
function ENT:RunBehaviour()
	while (true) do
		self:ThinkMove()
		coroutine.wait(0.01)
	end
end

function ENT:BodyUpdate()
	self:FrameAdvance()
end

function ENT:OnTakeDamage(dmginfo)
    local hp = self:Health() - dmginfo:GetDamage()

    if hp <= 0 then
        self:Die(dmginfo)
        return
    end
end

function ENT:Die(dmginfo)
    CMasterBotSquadManager:Leave(self)

    self:Remove()
end

function ENT:OnRemove()
	CMasterBot.UnregisterMasterBot(self)
    if (self.m_squadId) then
		CMasterBotSquadManager:Leave(self)
	end
end

function ENT:OnKilled(dmginfo)
	hook.Run("OnNPCKilled", self, dmginfo:GetAttacker(), dmginfo:GetInflictor() )

	self:BecomeRagdoll(dmginfo)
	
	self.m_Behavior:ProcessEvent("OnKilled", dmginfo)
end

-- Base NextBot callbacks

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

function ENT:CommandMoveToPoint(pos)
	
	self.m_Behavior:ProcessEvent("OnCommandApproach", pos)
end

function ENT:CommandEscort(subject)
	self.m_Behavior:ProcessEvent("OnCommandApproachEnt", subject)
end

function ENT:Command(command, data)
	self.m_Behavior:ProcessEvent("OnCommand", command, data)
end