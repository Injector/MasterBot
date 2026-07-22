ENT.Type      = "nextbot"
ENT.Base      = "base_nextbot"
ENT.PrintName = "Combine Soldier (MasterBot)"
ENT.Author    = "Bloomstorm"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.AutomaticFrameAdvance = true

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "DrawFlashlight")
	self:NetworkVar("Bool", 1, "DrawLaser")
	self:NetworkVar("Vector", 0, "LaserEndPos")
	self:NetworkVar("Int", 0, "LaserColorR")
	self:NetworkVar("Int", 1, "LaserColorG")
	self:NetworkVar("Int", 2, "LaserColorB")
	self:NetworkVar("Entity", 0, "MBWeaponModel")
	self:NetworkVar("Bool", 2, "DebugLaser")
	self:NetworkVar("Angle", 0, "CurEyeAngles")
	self:NetworkVar("String", 0, "DebugText")
	self:NetworkVar("String", 1, "DebugTextLookAt")
	
	-- Debug
	self:NetworkVar("Float", "DebugLaserThickness")
	self:NetworkVar("Int", "DebugLaserColorR")
	self:NetworkVar("Int", "DebugLaserColorG")
	self:NetworkVar("Int", "DebugLaserColorB")
	self:NetworkVar("Vector", "DebugLaserEndPos")
	self:NetworkVar("Vector", "DebugLaserStartPos")
	--self:NetworkVar("Vector", "DebugGroundMotion")
	--self:NetworkVar("Vector", "DebugMotion")
	
	if CLIENT then
		self:NetworkVarNotify("LaserColorR", function(ent, name, old, new)
			ent.m_clrLaser = Color(new, self:GetLaserColorG(), self:GetLaserColorB(), 255)
		end)
		
		self:NetworkVarNotify("LaserColorG", function(ent, name, old, new)
			ent.m_clrLaser = Color(self:GetLaserColorR(), new, self:GetLaserColorB(), 255)
		end)
		
		self:NetworkVarNotify("LaserColorB", function(ent, name, old, new)
			ent.m_clrLaser = Color(self:GetLaserColorR(), self:GetLaserColorG(), new, 255)
		end)
		
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

list.Set("NPC", "nextbot_combine_smg", { 
	Name = "Combine SMG", Class = "masterbot_combine_soldier", Category = "MasterBots", 
	KeyValues = 
	{ 
		model = "models/combine_soldier.mdl",
		skin = 0,
		health = 50,
		weapon_id = 2,
		name = "Combine Soldier",
		kill_icon = "weapon_smg1",
	} 
})

list.Set("NPC", "CmbShot", { 
	Name = "Combine Shotgun", Class = "masterbot_combine_soldier", Category = "MasterBots", 
	KeyValues = 
	{ 
		model = "models/combine_soldier.mdl",
		skin = 1,
		health = 50,
		weapon_id = 3,
		commander_priority = 1,
		name = "Shotgun Soldier",
		kill_icon = "weapon_shotgun",
	} 
})
	
list.Set("NPC", "nextbot_combine_ar2", { 
	Name = "Combine AR2", Class = "masterbot_combine_soldier", Category = "MasterBots", 
	KeyValues = 
	{ 
		model = "models/combine_soldier.mdl",
		skin = 0,
		health = 50,
		weapon_id = 4,
		name = "Combine Soldier",
		kill_icon = "weapon_ar2",
	} 
})
	
list.Set("NPC", "nextbot_combine_shotgunauto", { 
	Name = "Combine Auto-Shotgun", Class = "masterbot_combine_soldier", Category = "MasterBots", 
	KeyValues = 
	{ 
		model = "models/combine_soldier.mdl",
		skin = 1,
		health = 50,
		weapon_id = 5,
		commander_priority = 1,
		name = "Auto-shotgun Soldier",
		kill_icon = "weapon_shotgun",
	} 
})

list.Set("NPC", "nextbot_combine_sniper", { 
	Name = "Combine Sniper", Class = "masterbot_combine_soldier", Category = "MasterBots", 
	KeyValues = 
	{ 
		model = "models/combine_soldier.mdl",
		skin = 0,
		health = 50,
		weapon_id = 17,
		name = "Combine Soldier Sniper",
		kill_icon = "weapon_ar2",
		sniper = 1,
	} 
})