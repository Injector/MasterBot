local m_hFlareMaterial = Material("sprites/laserflare.vmt")

local m_flLastFOV = 0
local m_flCosFOV = 0

local function HandleBotFlashlight(bot, startPos, hitPos)
	local localPlayer = CMasterBotClientside.LocalPlayer
	
	local tr = util.TraceLine({ start = localPlayer:EyePos(), endpos = startPos, filter = { bot, localPlayer }, mask = MASK_SOLID })
	
	local dir = bot:GetAngles():Forward()
	local viewDir = localPlayer:EyePos() - startPos
	viewDir:Normalize()
	local dotProduct = dir:Dot(viewDir)
	
	if (m_flLastFOV != localPlayer:GetFOV()) then
		m_flLastFOV = localPlayer:GetFOV()
		m_flCosFOV = math.cos(math.rad(m_flLastFOV / 2))
	end
	
	local pFov = localPlayer:GetFOV()
	local cosFov = m_flCosFOV
	local isInFov = localPlayer:EyeAngles():Forward():Dot(viewDir) < cosFov
	
	if (dotProduct >= 0.98 && !tr.Hit && isInFov) then
		local distToCam = (startPos - localPlayer:EyePos()):Length()
		local size = dotProduct * (2000 * distToCam / 1000)
		render.SetMaterial(m_hFlareMaterial)
		render.DrawSprite(startPos, size, size, color_white)
	end
	
	if (IsValid(bot.m_hProjTex)) then
		local dir = hitPos - startPos
		dir:Normalize()
		dir = dir:Angle()
		bot.m_hProjTex:SetPos(startPos)
		bot.m_hProjTex:SetAngles(dir)
		bot.m_hProjTex:Update()
	else
		bot.m_hProjTex = ProjectedTexture()
		bot.m_hProjTex:SetTexture("effects/flashlight001")
		bot.m_hProjTex:SetFarZ(600)
		--bot.m_hProjTex:SetEnableShadows(false)
		
		local dir = hitPos - startPos
		dir:Normalize()
		dir = dir:Angle()
		
		bot.m_hProjTex:SetPos(startPos)
		bot.m_hProjTex:SetAngles(dir)
		bot.m_hProjTex:Update()
	end
end

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