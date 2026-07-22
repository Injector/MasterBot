MASTERBOT = true

CreateConVar("mb_debug", "0", { FCVAR_REPLICATED }, "Debug mode for MasterBots")

local entMeta = FindMetaTable("Entity")

function entMeta:IsMasterBot()
	if (!IsValid(self)) then return end
	
	return self:IsNextBot() && (self.m_Behavior || self.m_Intention || self.m_Locomotion || self.m_Body || self.m_Vision || self:GetNWBool("MasterBot"))
end