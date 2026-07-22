ENT.Type      = "nextbot"
ENT.Base      = "base_nextbot"
ENT.PrintName = "Kleiner MasterBot"
ENT.Author    = "Bloomstorm"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.AutomaticFrameAdvance = true

function ENT:SetupDataTables()
	-- Various debug variables for multiplayer via mb_debug
	-- We doing this by defining NetworkVar rather than SetNW* for saving network messages slot (util.AddNetworkString and NW has 4095 limit)

	-- DebugText for displaying current behaviour layer display: ExampleAction ( ExampleChildAction )
	self:NetworkVar("String", "DebugText")
	
	-- DebugTextLookAt for displaying current aim data
	self:NetworkVar("String", "DebugTextLookAt")
	
	-- Draw laser where is our bot aiming at
	self:NetworkVar("Bool", "DebugLaser")
	self:NetworkVar("Float", "DebugLaserThickness")
	self:NetworkVar("Int", "DebugLaserColorR")
	self:NetworkVar("Int", "DebugLaserColorG")
	self:NetworkVar("Int", "DebugLaserColorB")
	self:NetworkVar("Vector", "DebugLaserEndPos")
	self:NetworkVar("Vector", "DebugLaserStartPos")
	
	-- Laser thickness:
	-- Thick - the head is not steady (the head is fast moving)
	-- Thin - the head is steady (the head does not make any sudden movements)
	
	-- Laser colors:
	-- Blue - no aim target
	-- Pink - is sighted in (mostly with AimHeadTowardsPos)
	-- Cyan - has an aim target, but it's not on target (move that 11.5 degrees away from aiming straight) (mostly with AimHeadTowardsEnt)
	-- White - aimed at (AimHeadTowardsEnt)
	if CLIENT then	
		self:NetworkVarNotify("DebugLaserColorR", function(ent, name, old, new)
			ent.m_clrDebugLaser = Color(new, self:GetDebugLaserColorG(), self:GetDebugLaserColorB(), 255)
		end)
		self:NetworkVarNotify("DebugLaserColorG", function(ent, name, old, new)
			ent.m_clrDebugLaser = Color(self:GetDebugLaserColorR(), new, self:GetDebugLaserColorB(), 255)
		end)
		self:NetworkVarNotify("DebugLaserColorB", function(ent, name, old, new)
			ent.m_clrDebugLaser = Color(self:GetDebugLaserColorR(), self:GetDebugLaserColorG(), new, 255)
		end)
	end
end


list.Set("NPC", "masterbot_example", { 
	Name = "Example", Class = "masterbot_example", Category = "MasterBots", 
	KeyValues = 
	{
	} 
})