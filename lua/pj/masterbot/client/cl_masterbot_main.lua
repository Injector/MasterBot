CMasterBotClientside = {}

CMasterBotClientside.LocalPlayer = nil

-- For avoiding ents.Iterator in HUDPaint hooks
CMasterBotClientside.MasterBots = {}

function CMasterBotClientside.FastListRemove(tbl, index)
	local lastIndex = #tbl
	if (index != lastIndex) then
		tbl[index] = tbl[lastIndex]
	end
	tbl[lastIndex] = nil
end