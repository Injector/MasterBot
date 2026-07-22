hook.Add("InitPostEntity", "MasterBot_Clientside_LocalPlayerCache", function()
	CMasterBotClientside.LocalPlayer = LocalPlayer()
end)

hook.Add("OnEntityCreated", "MasterBot_Clientside_List_Add", function(ent)
	if (ent:IsNextBot() && (ent:GetNWBool("MasterBot", false) || string.find(ent:GetClass(), "masterbot"))) then
		CMasterBotClientside.MasterBots[#CMasterBotClientside.MasterBots + 1] = ent
	end
end)

hook.Add("EntityRemoved", "MasterBot_Clientside_List_Remove", function(ent, fullUpdate)
	if (fullUpdate) then return end
	
	-- TODO: Заменить на [ent:EntIndex()]?
	for i = 1, #CMasterBotClientside.MasterBots do 
		if (CMasterBotClientside.MasterBots[i] == ent) then
			CMasterBotClientside.FastListRemove(CMasterBotClientside.MasterBots, i)
		end
	end
	
	if (IsValid(ent.m_hProjTex)) then
		ent.m_hProjTex:Remove()
	end
end)