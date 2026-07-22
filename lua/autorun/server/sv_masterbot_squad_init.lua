MASTERBOT_SQUAD_VERSION = "1.0"

local m_squads = {}

CMasterBotSquadManager = {}

function CMasterBotSquadManager:Create()
	local id = 1
	while m_squads[id] do id = id + 1 end
	m_squads[id] = { id = id, members = {}, leader = nil }
	return m_squads[id]
end

function CMasterBotSquadManager:Join(soldier, squad)
	if (!squad) then squad = CMasterBotSquadManager:Create() end
	soldier.m_squadId = squad.id
	soldier.m_bIsLeader = false
	table.insert(squad.members, soldier)
	if (!IsValid(squad.leader)) then
		squad.leader = soldier
		soldier.m_bIsLeader = true
	end
	return squad
end

function CMasterBotSquadManager:Leave(soldier)
	local squad = self:Get(soldier.m_squadId)
	if (!squad) then return end
	
	for i, m in ipairs(squad.members) do
		if (m == soldier) then
			table.remove(squad.members, i)
			break
		end
	end
	
	local highestPriority = -1
	local bestCandidat = NULL
	
	if (squad.leader == soldier) then
		squad.leader = nil
		soldier.m_bIsLeader = false
		
		for _, m in ipairs(squad.members) do
			if (m.m_iCommanderPriority && m.m_iCommanderPriority > highestPriority) then
				bestCandidat = m
				highestPriority = m.m_iCommanderPriority
			end
		end
	end
	
	if (!IsValid(bestCandidat)) then
		bestCandidat = squad.members[math.random(#squad.members)]
	end
	
	if (IsValid(bestCandidat)) then
		squad.leader = bestCandidat
		bestCandidat.m_bIsLeader = true
	end
	
	soldier.m_bIsLeader = false
	soldier.m_squadId = nil
	
	if (#squad.members == 0) then m_squads[squad.id] = nil end
end

function CMasterBotSquadManager:Get(id)
	return id && m_squads[id]
end

function CMasterBotSquadManager:GetBotSquadMembers(soldier)
	local squad = self:Get(soldier.m_squadId)
	return squad && squad.members || {}
end

function CMasterBotSquadManager:IsInSquad(soldier)
	return soldier.m_squadId != nil
end

function CMasterBotSquadManager:IsLeader(soldier)
	return soldier.m_bIsLeader
end

function CMasterBotSquadManager:GetLeader(id)
	local squad = m_squads[id]
	
	if (!squad) then return nil end
	
	-- У лидера может быть не индекс 1, из-за m_iCommanderPriority
	-- Если в индексе 1 будет m_iCommanderPriority 1 а в индексе 5 будет m_iCommanderPriority 2 то лидером будет тот, у кого индекс 5
	for _, m in ipairs(squad.members) do
		if (m.m_bIsLeader) then return m end
	end
	
	return nil
end

function CMasterBotSquadManager:GetMaxSquadFormationError()
	local maxError = 0.0
	local er = 0.0
	
	for _, m in ipairs(squad.members) do
		if (m.m_formationError) then
			er = m.m_formationError
			if (er > maxError) then
				maxError = er
			end
		end
	end
	
	return maxError
end

function CMasterBotSquadManager:ShouldLeaderWaitForFormation(squad)
	for _, m in ipairs(squad.members) do
		if (m.m_brokenFormation) then continue end
		
		if (m.m_formationError && m.m_formationError >= 1.0 && !m.m_brokenFormation) then
			return true
		end
	end
	
	return false
end

function CMasterBotSquadManager:IsInFormation(squad)
	for _, m in ipairs(squad.members) do
		if (m.m_brokenFormation) then continue end
		
		if (m.m_formationError && m.m_formationError > 0.75) then
			return false
		end
	end
	
	return true
end