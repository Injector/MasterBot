local m_CVar_debug = nil

util.AddNetworkString("CMasterBot::DebugConColorMsg")

CMasterBot = {}
CMasterBot.EASY = 0
CMasterBot.NORMAL = 1
CMasterBot.HARD = 2
CMasterBot.EXPERT = 3

CMasterBot.MasterBots = {}

local dir = "pj/masterbot/server/"

include(dir .. "sv_masterbot_events.lua")
include(dir .. "sv_masterbot_sound_data.lua")
include(dir .. "sv_masterbot_sound_footsteps.lua")
include(dir .. "sv_masterbot_sound_gear.lua")
include(dir .. "sv_masterbot_data_communities.lua")

function CMasterBot.RegisterMasterBot(ent)
	CMasterBot.MasterBots[#CMasterBot.MasterBots + 1] = ent
end

function CMasterBot.UnregisterMasterBot(ent)
	for i = #CMasterBot.MasterBots, 1, -1 do
		if (CMasterBot.MasterBots[i] == ent) then
			local n = #CMasterBot.MasterBots
			CMasterBot.MasterBots[i] = CMasterBot.MasterBots[n]
			CMasterBot.MasterBots[n] = nil
		end
	end
end

-- Кешируем число для сравнений (сравнение чисел будет быстрее чем сравнение строк)
function CMasterBot.InitializeCommunities()
	local iTeam = 0
	for _, v in pairs(CMasterBot.Communities) do
		v.cached_team = iTeam
		iTeam = iTeam + 1
	end
end

function CMasterBot.IsDebug()
	if (!m_CVar_debug) then
		m_CVar_debug = GetConVar("mb_debug")
	end
	return m_CVar_debug:GetInt() == 1
end

function CMasterBot.FormatDebugIdentifier(bot)
	return bot:GetClass() .. "(#" .. tostring(bot:EntIndex()) .. ")"
end

function CMasterBot.DebugConColorMsg(debugType, color, str, ...)
	local strF = string.format(str, ...)
	net.Start("CMasterBot::DebugConColorMsg")
		net.WriteColor(color)
		net.WriteString(strF)
	net.Broadcast()
end

-- Метод для установления конечной точки, чтобы клиент мог провести у себя спрайт лазера между начальной и конечной точкой
-- Нужно, если лазер или фонарик активен (фонарик: для угла направления, лазер: выше написано)
function CMasterBot.ThinkLaser(bot)
	local bShouldDraw = (bot.GetDrawLaser() and bot:GetDrawLaser()) or (bot.GetDrawFlashlight and bot:GetDrawFlashlight())
	
	if (!bShouldDraw) then return end
	if (!bot.m_wpn || !IsValid(bot.m_wpn.m_hModel)) then return end
	
	local traceFilter = { bot }
	local tr = util.TraceHull({ start = bot.m_Body:GetEyePosition(), endpos = bot.m_Body:GetEyePosition() + bot.m_Body:GetViewVector() * 8000.0, filter = traceFilter, mask = MASK_SOLID + CONTENTS_HITBOX,
		mins = Vector(-1, -1, -1), maxs = Vector(1, 1, 1) })
	
	bot:SetLaserEndPos(tr.HitPos)
	
	if (bot.GetCurEyeAngles) then
		bot:SetCurEyeAngles(bot.m_Body.m_angCurrentAngles)
	end
end

-- Регистрируем новую группировку
function CMasterBot.RegisterCommunity(name, defaultRelation, relations)
	
end

function CMasterBot.IsCommunityEnemy(bot, otherBot)
	if (!bot.m_iMasterTeam || !otherBot.m_iMasterTeam) then
		return false
	end
	
	if (bot.m_iMasterTeam != otherBot.m_iMasterTeam) then
		local data = CMasterBot.Communities[bot.m_szMasterBotCommunity]
		if (data) then
			local iRelation = data.relations[otherBot.m_szMasterBotCommunity]
			if (iRelation) then
				if (iRelation <= -500) then
					return true
				else
					return false
				end
			else
				if (data.default_relation <= -500) then
					return true
				else
					return false
				end
			end
		end
	else
		return false
	end
	
	return true
end

local function SimpleSpline(value)
	local sqr = value * value
	
	return (3 * sqr - 2 * sqr * value)
end

local function SimpleSplineRemapValClamped(val, A, B, C, D)
	if (A == B) then
		return B and D or C
	end
	
	local cVal = (val - A) / (B - A)
	cVal = math.Clamp(cVal, 0.0, 1.0)
	return C + (D - C) * SimpleSpline(cVal)
end

local function RemapValClamped(val, A, B, C, D)
	if (A == B) then
		return B and D or C
	end
	
	local cVal = (val - A) / (B - A)
	cVal = math.Clamp(cVal, 0.0, 1.0)
	
	return C + (D - C) * cVal
end

function CMasterBot.GetDistanceDamage(damage, victim, attacker, doShortRangeIncrease, doLongRangeDecrease)
	local attackerPos = attacker:WorldSpaceCenter()
	local flOptimalDistance = 512.0
	
	local flDistance = math.max(1.0, (victim:WorldSpaceCenter() - attackerPos):Length())
	
	local flRandomDamage = damage * 0.5
	local flRandomDamageSpread = 0.10
	local flMin = 0.5 - flRandomDamageSpread
	local flMax = 0.5 + flRandomDamageSpread
	
	if (attacker.m_bSentry) then
		attackerPos = attacker:WorldSpaceCenter()
		flOptimalDistance = 1400.0
	end
	
	local bDoShortRangeDistanceIncrease = doShortRangeIncrease or true
	local bDoLongRangeDistanceDecrease = doLongRangeDecrease or true
	
	local flCenter = RemapValClamped(flDistance / flOptimalDistance, 0.0, 2.0, 1.0, 0.0)
	if ((flCenter > 0.5 && bDoShortRangeDistanceIncrease) || flCenter <= 0.5) then
		flMin = math.max(0.0, flCenter - flRandomDamageSpread)
		flMax = math.min(1.0, flCenter + flRandomDamageSpread)
	end
	
	--local flMin = math.max(0.0, flCenter - flRandomDamageSpread)
	local flRandomRangeVal = flMin + flRandomDamageSpread
	
	local flDmgVariance = SimpleSplineRemapValClamped(flRandomRangeVal, 0, 1, -flRandomDamage, flRandomDamage)
	
	if ((bDoShortRangeDistanceIncrease && flDmgVariance > 0.0) || bDoLongRangeDistanceDecrease) then
		--flDamage = flDamage + flDmgVariance
	end
	
	--print("dist", (victim:WorldSpaceCenter() - attackerPos):Length(), "cur flDmgVariance", flDmgVariance, "base", damage, "final", damage + flDmgVariance)
	
	return damage + flDmgVariance
end

hook.Run("CMasterBot.Initialize")

-- TODO: Доделать
-- concommand.Add("mb_stats", function(ply, cmd, args)
	-- local gAnimate = 0
	-- local gBehavior = 0
	-- local gBody = 0
	-- local gMove = 0
	-- local gVision = 0
	
	-- for i = 1, #CMasterBot.MasterBots do
		-- local bot = CMasterBot.MasterBots[i]
		
		-- local animate = bot.m_statAnimateThink or 0
		-- local behavior = bot.m_statBehaviorThink or 0
		-- local body = bot.m_statBodyThink or 0
		-- local move = bot.m_statMoveThink or 0
		-- local vision = bot.m_statVisionThink or 0
		
		-- ply:PrintMessage(HUD_PRINTCONSOLE, "MasterBot")
		-- ply:PrintMessage(HUD_PRINTCONSOLE, string.format("CMBBehavior:Update() : %.6f ms", behavior))
		-- ply:PrintMessage(HUD_PRINTCONSOLE, string.format("CMasterBotVision:Update() : %.6f ms", vision))
		-- ply:PrintMessage(HUD_PRINTCONSOLE, string.format("CMasterBotBody:Upkeep() : %.6f ms", body))
		-- ply:PrintMessage(HUD_PRINTCONSOLE, string.format("CMasterBotLocomotion:Upkeep() : %.6f ms", move))
		-- ply:PrintMessage(HUD_PRINTCONSOLE, string.format("CMasterBotBody:UpdateAnimation() : %.6f ms", animate))
		
		-- gAnimate = gAnimate + animate
		-- gBehavior = gBehavior + behavior
		-- gBody = gBody + body
		-- gMove = gMove + move
		-- gVision = gVision + vision
	-- end
	
	-- ply:PrintMessage(HUD_PRINTCONSOLE, "MasterBot - Total")
	-- ply:PrintMessage(HUD_PRINTCONSOLE, string.format("CMBBehavior:Update() : %.6f ms", gBehavior))
	-- ply:PrintMessage(HUD_PRINTCONSOLE, string.format("CMasterBotVision:Update() : %.6f ms", gVision))
	-- ply:PrintMessage(HUD_PRINTCONSOLE, string.format("CMasterBotBody:Upkeep() : %.6f ms", gBody))
	-- ply:PrintMessage(HUD_PRINTCONSOLE, string.format("CMasterBotLocomotion:Upkeep() : %.6f ms", gMove))
	-- ply:PrintMessage(HUD_PRINTCONSOLE, string.format("CMasterBotBody:UpdateAnimation() : %.6f ms", gAnimate))


-- end, nil, "Get MasterBots stats", FCVAR_ARCHIVE)