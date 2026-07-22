local m_CVar_debug = nil

net.Receive("CMasterBot::DebugConColorMsg", function(len)
	local clr = net.ReadColor()
	local str = net.ReadString()
	
	MsgC(clr, str)
end)

local m_clrBlack = Color(0, 0, 0, 255)
local m_clrLookAt = Color(255, 100, 0, 255)

local m_hMatLine = Material("vgui/white")

-- Courier New weight 500 size 28
surface.CreateFont("MasterBotDebug", { font = "Tahoma", size = 16, weight = 600, outline = true })

local function HandleLaser(bot)
	if (!bot.GetDebugLaserEndPos) then return end
	
	local endPos = bot:GetDebugLaserEndPos()
	local startPos = bot:WorldSpaceCenter()
	local laserColor = bot.m_clrDebugLaser or color_white
	local thickness = 2.0
	
	if (bot.GetDebugLaserThickness) then
		thickness = bot:GetDebugLaserThickness()
	end
	
	if (bot.GetDebugLaserStartPos) then
		startPos = bot:GetDebugLaserStartPos()
	end
	
	--render.DrawLine(startPos, endPos, laserColor, 
	
	render.SetMaterial(m_hMatLine)
	render.DrawBeam(startPos, endPos, thickness, 1, 1, laserColor)
end

local m_vecUp = Vector(0, 0, 1)

local function DrawDebugArrow(startPos, endPos, size, color)
    render.SetMaterial(m_hMatLine)
	render.DrawBeam(startPos, endPos, size, 1, 1, color)
	
	local dir = (endPos - startPos)
	dir:Normalize()
	--local right = dir:Cross(m_vecUp):GetNormalized()
	local right = dir:Cross(m_vecUp)
	right:Normalize()
	--local up = right:Cross(dir):GetNormalized()
	
	local arrowLength = 10
	local headEnd = endPos - (dir * arrowLength)
	
	render.DrawBeam(endPos, headEnd + (right * arrowLength), size, 1, 1, color)
	render.DrawBeam(endPos, headEnd - (right * arrowLength), size, 1, 1, color)
end

-- Бесполезная фигня 

-- local m_clrArrow = Color(100, 255, 0, 255)
-- local m_clrArrow2 = Color(255, 255, 0, 255)

local function HandleLocomotion(bot)
	-- if (!bot.GetDebugGroundMotion) then return end

	-- local vec = bot:GetDebugGroundMotion()
	
	-- DrawDebugArrow(bot:GetPos(), bot:GetPos() + 25.0 * vec, 3.0, m_clrArrow)
	
	-- if (bot.GetDebugMotion) then
		-- vec = bot:GetDebugMotion()
		-- DrawDebugArrow(bot:GetPos(), bot:GetPos() + 25.0 * vec, 5.0, m_clrArrow2)
	-- end
end

hook.Add("HUDPaint", "MasterBot_Clientside_Debug", function()
	if (!m_CVar_debug) then
		m_CVar_debug = GetConVar("mb_debug")
	end
	
	-- wtf?
	if (!m_CVar_debug) then return end
	
	if (m_CVar_debug:GetInt() != 1) then return end
	
	local n = #CMasterBotClientside.MasterBots
	for i = 1, n do
		local bot = CMasterBotClientside.MasterBots[i]
		
		if (!bot.GetDebugText) then continue end
		
		local pos = (bot._smoothPos || bot:GetPos()) + Vector(0, 0, 80)
		
		local scr = pos:ToScreen()
		
		if (scr.visible) then
			if (bot.GetDebugTextLookAt) then
				draw.SimpleText(bot:GetDebugTextLookAt(), "MasterBotDebug", scr.x, scr.y - 20, m_clrLookAt, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
			
			draw.SimpleText(bot:GetDebugText(), "MasterBotDebug", scr.x, scr.y, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end
end)

hook.Add("PostDrawTranslucentRenderables", "MasterBot_Clientside_DebugLaser", function()
	if (!m_CVar_debug) then
		m_CVar_debug = GetConVar("mb_debug")
	end
	
	-- wtf?
	if (!m_CVar_debug) then return end
	
	if (m_CVar_debug:GetInt() != 1) then return end
	
	local n = #CMasterBotClientside.MasterBots
	for i = 1, n do
		local bot = CMasterBotClientside.MasterBots[i]
		HandleLaser(bot)
		
		HandleLocomotion(bot)
	end
end)