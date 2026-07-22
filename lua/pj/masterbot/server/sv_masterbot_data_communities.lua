-- Группировки
-- name - Имя
-- relations - Отношения между другими группировками
-- default_relation - Отношение по умолчанию к группировке, которая отсутствует в relations

-- TODO: Закончить
CMasterBot.Communities = 
{
	["default"] = {
		name = "default",
		relations =
		{
			["combine"] = -5000,
			["default"] = 0,
			["zombie"] = -5000,
			["rebels"] = 0,
		},
		cached_team = 0,
		default_relation = -5000,
		player_default_relation = 0,
	},
	
	-- Группировки из халф лайф
	["combine"] = {
		name = "combine",
		relations =
		{
			["combine"] = 5000,
			["default"] = -5000,
			["zombie"] = -5000,
			["rebels"] = -5000,
		},
		cached_team = 0,
		default_relation = -5000,
		player_default_relation = -5000,
	},
	["zombie"] = {
		name = "zombie",
		relations =
		{
			["combine"] = -5000,
			["default"] = -5000,
			["zombie"] = 0,
			["rebels"] = -5000,
		},
		cached_team = 0,
		default_relation = -5000,
		player_default_relation = -5000,
	},
	["rebels"] = {
		name = "rebels",
		relations =
		{
			["combine"] = -5000,
			["default"] = 0,
			["zombie"] = -5000,
			["rebels"] = 5000,
		},
		cached_team = 0,
		default_relation = -5000,
		player_default_relation = 0,
	},
	
	-- Группировки из Сталкера
	["stalker"] = {
		name = "stalker",
		relations =
		{
			["combine"] = -5000,
			["default"] = 0,
			["zombie"] = -5000,
			["rebels"] = 5000,
			
			["stalker"] = 0,
			["monolith"] = -5000,
			["military"] = -5000,
			["killer"] = -5000,
			["ecolog"] = 0,
			["dolg"] = 0,
			["freedom"] = 0,
			["bandit"] = -5000,
			["zombied"] = -5000,
			["stanger"] = 0,
			["trader"] = 0,
			["arena_emey"] = -5000,
		},
		cached_team = 0,
		default_relation = -5000,
		player_default_relation = 0,
	},
	["bandit"] = {
		name = "stalker",
		relations =
		{
			["combine"] = -5000,
			["default"] = 0,
			["zombie"] = -5000,
			["rebels"] = 5000,
			
			["stalker"] = -5000,
			["monolith"] = -5000,
			["military"] = -5000,
			["killer"] = 0,
			["ecolog"] = -5000,
			["dolg"] = -5000,
			["freedom"] = -5000,
			["bandit"] = 0,
			["zombied"] = -5000,
			["stanger"] = -5000,
			["trader"] = 0,
			["arena_emey"] = -5000,
		},
		cached_team = 0,
		default_relation = -5000,
		player_default_relation = -5000,
	},
	["military"] = {
		name = "stalker",
		relations =
		{
			["combine"] = -5000,
			["default"] = -5000,
			["zombie"] = -5000,
			["rebels"] = -5000,
			
			["stalker"] = -5000,
			["monolith"] = -5000,
			["military"] = 5000,
			["killer"] = -5000,
			["ecolog"] = 0,
			["dolg"] = -5000,
			["freedom"] = -5000,
			["bandit"] = -5000,
			["zombied"] = -5000,
			["stanger"] = 0,
			["trader"] = 0,
			["arena_emey"] = -5000,
		},
		cached_team = 0,
		default_relation = -5000,
		player_default_relation = -5000,
	},
}