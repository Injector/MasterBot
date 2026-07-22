hook.Add("EntityFireBullets", "MasterBot_Server_OnWeaponFired", function(whoFired, weapon)
	if (IsValid(whoFired) && (whoFired:IsNextBot() || whoFired:IsPlayer() || whoFired:IsNPC())) then
		whoFired.m_flWeaponFired = CurTime()
		
		local activeWeapon = NULL
		if (whoFired:IsPlayer() || whoFired:IsNPC()) then
			activeWeapon = whoFired:GetActiveWeapon()
		end
		
		for i = 1, #CMasterBot.MasterBots do
			local bot = CMasterBot.MasterBots[i]
			if (IsValid(bot)) then
				if (bot.m_Intention) then
					bot.m_Intention:OnWeaponFired(whoFired, activeWeapon)
				end
				if (bot.m_Behavior) then
					bot.m_Behavior:ProcessEvent("OnWeaponFired", whoFired, activeWeapon)
				end
				if (bot.Event_MasterBot_OnWeaponFired) then
					bot:Event_MasterBot_OnWeaponFired(whoFired, activeWeapon)
				end
			end
		end
	end
end)

local function OnOtherKilled(victim, attacker, inflictor)
	for i = 1, #CMasterBot.MasterBots do
		local bot = CMasterBot.MasterBots[i]
		if (IsValid(bot)) then
			-- if (bot.m_Intention) then
			-- end
			-- Для этого есть ENT:OnOtherKilled так что не знаю, есть ли смысл
			-- if (bot.m_Behavior) then
				-- bot.m_Behavior:ProcessEvent("OnOtherKilled", victim, attacker, inflictor)
			-- end
			if (bot.Event_MasterBot_OnOtherKilled) then
				bot:Event_MasterBot_OnOtherKilled(attacker, inflictor)
			end
		end
	end
end

hook.Add("OnNPCKilled", "MasterBot_Server_OnNPCKilled", function(npc, attacker, inflictor)
	if (IsValid(npc)) then
		OnOtherKilled(npc, attacker, inflictor)
	end
end)

hook.Add("PlayerDeath", "MasterBot_Server_PlayerDeath", function(victim, inflictor, attacker)
	if (IsValid(victim)) then
		OnOtherKilled(victim, attacker, inflictor)
	end
end)

hook.Add("EntityEmitSound", "MasterBot_Server_EntityEmitSound", function(data)
	for i = 1, #CMasterBot.MasterBots do
		local bot = CMasterBot.MasterBots[i]
		if (IsValid(bot)) then
			if (bot.m_Behavior) then
				bot.m_Behavior:ProcessEvent("OnSound", data.Entity, data.Pos, data)
			end
		end
	end
end)

hook.Add("EntityTakeDamage", "MasterBot_Server_EntityTakeDamage_PlayerDmgFalloff", function(target, dmginfo)
	if (!IsValid(target)) then return end
	
	if (target:IsPlayer()) then
		local attacker = dmginfo:GetAttacker()
		if (!IsValid(attacker)) then return end
		
		if (!attacker:IsMasterBot() || !attacker.m_bDamageFalloff) then return end
		
		-- Только с пулями
		-- Only bullets
		if (dmginfo:IsDamageType(DMG_BULLET)) then
			local iNewDamage = CMasterBot.GetDistanceDamage(dmginfo:GetDamage(), target, attacker)
			if (iNewDamage && iNewDamage > 0) then
				dmginfo:SetDamage(iNewDamage)
			end
		end
	end
end)

hook.Add("Initialize", "MasterBot_Server_MapMemoryInit", function()
	CMasterBot.MapIO = {}
	CMasterBot.MapIO.Buttons = {}
	CMasterBot.MapFogs = {}
end)

hook.Add("EntityKeyValue", "MasterBot_Server_MapMemoryButtons", function(ent, key, val)
	if (ent:GetClass() == "func_button") then
		if (key == "OnPressed") then
			-- IO KV format: entityESCinput nameESCargumentsESCdelay in secodsESCnum of fires (-1 - infinite)
			-- 27 is a ESC symbol
			local t = string.Split(val, "\27")
			
			--print(ent, val)
			
			local szName = t[1]
			local szInput = t[2]
			
			if (szInput && (szInput == "Open" || szInput == "Toggle")) then
				local d = { Doors = {}, }
				
				local doorEnt = NULL
				
				-- Несколько энтити могут иметь одно название
				-- Some entities may have a single name
				for _, v in ents.Iterator() do
					if (v:GetName() == szName) then
						d.Door = v
						d.Doors[#d.Doors + 1] = v
					end
				end
				
				d.Button = ent
				CMasterBot.MapIO.Buttons[#CMasterBot.MapIO.Buttons + 1] = d
				
				--print("Found and packed", d.Button, d.Door, val)
			end
		end
	end
end)

hook.Add("OnEntityCreated", "MasterBot_Server_OnEntityCreated_Fog", function(ent)
	if (ent:GetClass() != "env_fog_controller") then return end
	
	-- На карте может быть несколько туманов
	CMasterBot.MapFogs[#CMasterBot.MapFogs + 1] = ent
end)

hook.Add("OnEntityCreated", "MasterBot_Server_OnEntityCreated", function(ent)
	-- Устанавливаем NWBool чтобы клиенты знали что этот NextBot на деле MasterBot
	-- Set NWBool to let clients know that this NextBot is actually MasterBot
	if (ent:IsMasterBot()) then
		ent:SetNWBool("MasterBot", true)
	end
end)