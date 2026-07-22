local m_hLaserMaterial = Material("effects/taclaser2.vmt")
local m_hSpriteMaterial = Material("effects/blueflare1.vmt")

local m_clrDefault = Color(255, 0, 0, 255)

local function HandleBotLaser(bot, startPos, hitPos)
	local color = bot.m_clrLaser or m_clrDefault
	
	render.SetMaterial(m_hLaserMaterial)
	render.DrawBeam(startPos, hitPos, 2.0, 0, 1, color)
	
	render.SetMaterial(m_hSpriteMaterial)
	render.DrawSprite(hitPos, 8, 8, color)
end

hook.Add("PostDrawTranslucentRenderables", "MasterBot_Clientside_Laser", function()
	local n = #CMasterBotClientside.MasterBots
	
	for i = 1, n do
		local bot = CMasterBotClientside.MasterBots[i]
		if (IsValid(bot) && bot.GetDrawLaser) then
			if (bot:GetDrawLaser()) then
				if (bot.GetMBWeaponModel) then
					local hWpn = bot:GetMBWeaponModel()
					if (IsValid(hWpn)) then
						local startPos = bot:GetMBWeaponModel():GetPos()
						HandleBotLaser(bot, startPos, bot:GetLaserEndPos())
					end
				end
			end
		end
	end
end)