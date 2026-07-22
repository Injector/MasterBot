MASTERBOT_BEHAVIOUR_VERSION = "1.0"

CMBAction = {}
CMBAction.__index = CMBAction

-- QueryResultType
CMBAction.ANSWER_UNDEFINED = -1 -- Не определено, спрашиваем стек ниже
CMBAction.ANSWER_YES = 1
CMBAction.ANSWER_NO = 0

-- ── EventResultPriorityType ────────────────────────────────────────────────
-- Используется в EventDesiredResult (ивенты)
-- Отличие ActionResult (Continue / ChangeTo / Done / SuspendFor) от EventDesiredResult (TryContinue / TryChangeTo / TryDone / TrySuspendFor / TrySustain)
--   ActionResult: применяется моментально в Update()
--   EventDesiredResult: накапливается при обработке ивента, и только самый высокоприоритетный результат применяется в следующем Update
-- Это избегает изменения стека под собой во время обхода ивента

-- For use in EventDesiredResult (events)
-- Difference between ActionResult (Continue / ChangeTo/ Done/ SuspendFor) from EventDesiredResult (TryContinue / TryChangeTo / TryDone / TrySuspendFor / TrySustain)
--   ActionResult: applies immdetiatly in Update()
--   EventDesiredResult: accumulates when processing an event and only high-priority result applies in next Update
-- This avoids changing the stack underneath it while traversing the event

-- Порядок приоритетов: NONE < TRY < IMPORTANT < CRITICAL
CMBAction.RESULT_NONE      = 0  -- Ивент принят, без изменений (нет мнения)
CMBAction.RESULT_TRY       = 1  -- Хотим это, но более высокий приоритет перекроет
CMBAction.RESULT_IMPORTANT = 2  -- Важный результат, перекрывается только CRITICAL
CMBAction.RESULT_CRITICAL  = 3  -- Обязательно выполнить, ничто не перекрывает

function CMBAction:New(name)
	return setmetatable({
		m_name = name or "Action",
		m_pendingEvent = nil,
	}, self)
end

local function IsEventContinue(result)
	return not result or result.t == 1
end

local function IsEventSustain(result)
	return result and result.t == 5
end

local function EventResultPriority(result)
	if not result then return CMBAction.RESULT_NONE end
	return result.priority or CMBAction.RESULT_TRY
end

local function IsRequestingChange(result)
	return result and result.t ~= 1 and result.t ~= 5
end

function CMBAction:StorePendingEventResult(result, eventName)
	if IsEventContinue(result) then
		return
	end

	local curPri = self.m_pendingEvent and (self.m_pendingEvent.priority or CMBAction.RESULT_NONE) or CMBAction.RESULT_NONE
	local newPri = result.priority or CMBAction.RESULT_TRY

	if newPri >= curPri then
		self.m_pendingEvent = result
	end
end

function CMBAction:Name() return self.m_name end
function CMBAction:GetName() return self.m_name end

function CMBAction:Continue() return { t = 1 } end
function CMBAction:ChangeTo(a, r) return { t = 2, action = a, reason = r } end
function CMBAction:SuspendFor(a, r) return { t = 3, action = a, reason = r } end
function CMBAction:Done(r) return { t = 4, reason = r } end

function CMBAction:OnStart(bot, prior) return self:Continue() end
function CMBAction:Update(bot, dt) return self:Continue() end
function CMBAction:OnEnd(bot, next) end
function CMBAction:OnResume(bot, intr) return self:Continue() end
function CMBAction:OnSuspend(bot, interruptingAction) return self:Continue() end

function CMBAction:IsSuspended()
	return self.m_isSuspended == true
end

-- Обработчики ивентов (возвращают EventDesiredResult)
-- По умолчанию идут вниз по стеку
-- 
--   self:TryContinue(), self:TryContinue(priority) - продолжить дальше, с помощью задания приоритета можно запретить менять действия (TrySuspendFor, TryChangeTo, TryDone), но идти вниз дальше
--   self:TryChangeTo(action, priority, reason) - заменить текущее действие на другое
--   self:TrySuspendFor(action, priority, reason) - преврать текущее действие на другое (помещается в верх стека)
--   self:TryDone(priority, reason) - завершить текущее действие
--   self:TrySustain(), self:TrySustain(priority, reason) -- заблокировать дальнешний проход по стеку ниже, в зависимости от приоритета
-- Результаты накапливаются при обходе стека, у кого более высший приоритет выигрывает
-- и применяется в начале следующего Update()
--
-- Event handlers (returns EventDesiredResult)
-- По умолчанию идут вниз по стеку
-- 
--   self:TryContinue(), self:TryContinue(priority) - continue to the next action, it's possibly to forbid change actions (TrySuspendFor, TryChangeTo, TryDone), via priority, and continue move down
--   self:TryChangeTo(action, priority, reason) - replace current action
--   self:TrySuspendFor(action, priority, reason) - pause current action to another (puts on the top of the stack)
--   self:TryDone(priority, reason) - stop current action
--   self:TrySustain(), self:TrySustain(priority, reason) -- block further traversal of the stack below, depending on priority
-- Результаты накапливаются при обходе стека, у кого более высший приоритет выигрывает
-- и применяется в начале следующего Update()
function CMBAction:OnSight(bot, ent) 								return self:TryContinue() end
function CMBAction:OnLostSight(bot, ent) 							return self:TryContinue() end
function CMBAction:OnInjured(bot, info) 							return self:TryContinue() end
function CMBAction:OnContact(bot, other) 							return self:TryContinue() end
function CMBAction:OnKilled(bot, info) 								return self:TryContinue() end
function CMBAction:OnStuck(bot) 									return self:TryContinue() end
function CMBAction:OnOtherKilled(bot, victim, attacker, inflictor) 	return self:TryContinue() end
function CMBAction:OnSightOnce(bot, ent) 							return self:TryContinue() end
function CMBAction:OnLeaveGround(bot, ground) 						return self:TryContinue() end
function CMBAction:OnLandOnGround(bot, ground) 						return self:TryContinue() end
function CMBAction:OnStuck(bot) 									return self:TryContinue() end
function CMBAction:OnUnStuck(bot) 									return self:TryContinue() end
function CMBAction:OnIgnite(bot) 									return self:TryContinue() end
function CMBAction:OnWeaponFired(bot, whoFired, weapon)				return self:TryContinue() end

function CMBAction:OnSound(bot, source, pos, data)					return self:TryContinue() end
function CMBAction:OnMoveToSuccess(bot, path)						return self:TryContinue() end
function CMBAction:OnMoveToFailure(bot, path, reason)				return self:TryContinue() end

function CMBAction:OnCommandAttack(bot, victim) 					return self:TryContinue() end
function CMBAction:OnCommandApproach(bot, pos) 						return self:TryContinue() end
function CMBAction:OnCommandApproachEnt(bot, target)				return self:TryContinue() end
function CMBAction:OnCommandRetreat(bot, threat, range) 			return self:TryContinue() end
function CMBAction:OnCommandPause(bot, duration) 					return self:TryContinue() end
function CMBAction:OnCommandResume(bot) 							return self:TryContinue() end
function CMBAction:OnCommandString(bot, command) 					return self:TryContinue() end
function CMBAction:OnCommand(bot, command, data)					return self:TryContinue() end

-- EventDesiredResult — конструкторы 

-- Принять ивент без изменения состояния
function CMBAction:TryContinue(priority)
    return { t = 1, priority = priority or CMBAction.RESULT_TRY }
end

-- Сменить текущее действие на action (заменяет себя в стеке)
function CMBAction:TryChangeTo(action, priority, reason)
    return { t = 2, action = action, priority = priority or CMBAction.RESULT_TRY, reason = reason }
end

-- Приостановиться, поставив action на вершину стека
-- в котором активно текущее действие (или обработчик ивента в suspend-стеке)
function CMBAction:TrySuspendFor(action, priority, reason)
    return { t = 3, action = action, priority = priority or CMBAction.RESULT_TRY, reason = reason }
end

-- Завершить текущее действие
function CMBAction:TryDone(priority, reason)
    return { t = 4, priority = priority or CMBAction.RESULT_TRY, reason = reason }
end

-- Для ивентов, способ сказать "Важно продолжать делать то, что я щас делаю"
-- После этого вызова другие ивенты не будут вызываться в зависимости от заданного приоритета
function CMBAction:TrySustain(priority, reason)
	return { t = 5, priority = priority or CMBAction.RESULT_TRY, reason = reason }
end

-- Если Action возвращает дочернее действие здесь, то при старте этого Action
-- создаётся отдельный вложенный CMBBehavior (m_childBehavior)
--
-- Порядок: сначала обновляется дочерний, потом Update() самого Action
-- Пример: Это позволяет TacticalMonitor запускаться после ScenarioMonitor (MainAction > TacticalMonitor > ScenarioMonitor)
-- И независимо прерывать его через SuspendFor, не зная что именно щас активно в ScenarioMonitor
function CMBAction:InitialContainedAction(bot) return nil end

function CMBAction:ShouldPickUp(bot, item) return CMBAction.ANSWER_UNDEFINED end
function CMBAction:IsHindrance(bot, blocker) return CMBAction.ANSWER_UNDEFINED end

function CMBAction:ShouldAttack(bot, enemy) return CMBAction.ANSWER_UNDEFINED end
function CMBAction:ShouldRetreat(bot) return CMBAction.ANSWER_UNDEFINED end
function CMBAction:ShouldHurry(bot) return CMBAction.ANSWER_UNDEFINED end
function CMBAction:SelectTargetPoint(bot, subject) return nil end
function CMBAction:SelectMoreDangerousThreat(bot, t1, t2) return nil end

CMBBehavior = {}
CMBBehavior.__index = CMBBehavior

function CMBBehavior:New(initialAction, bot)
    local b = setmetatable({ m_stack = {}, m_bot = bot }, self)
    b:_Push(initialAction, nil)
    return b
end

function CMBBehavior:Active()
    return self.m_stack[#self.m_stack]
end

function CMBBehavior:ActiveName()
    local a = self:Active()
    return a and a:Name() or "None"
end

function CMBBehavior:CurrentActive()
	local a = self:Active()
	if not a then return "None" end
	
	local b = a
	
	while (b && b.m_childBehavior) do
		b = b.m_childBehavior:Active()
	end
	
	return b
end

function CMBBehavior:CurrentActiveName()
	local a = self:CurrentActive()
	return a and a:Name() or "None"
end

function CMBBehavior:DeepActive()
	return self:CurrentActive()
end

function CMBBehavior:DeepActiveName()
	return self:CurrentActiveName()
end

function CMBBehavior:GetActionBuriedUnder(action)
	if (action) then
		local n = #self.m_stack
		for i = 1, n do
			if (self.m_stack[i] == action) then
				return self.m_stack[i - 1]
			end
		end
	end
	
	return nil
end

function CMBBehavior:GetActionCovering(action)
	if (action) then
		local n = #self.m_stack
		for i = 1, n do
			if (self.m_stack[i] == action) then
				return self.m_stack[i + 1]
			end
		end
	end
	
	return nil
end

function CMBBehavior:GetActiveChild(action)
	if (action) then
		local n = #self.m_stack
		for i = 1, n do
			if (self.m_stack[i] == action) then
				return self.m_stack[i + 1]
			end
		end
	end
	
	return nil
end

function CMBBehavior:DebugString()
	local a = self:Active()
	if (!a) then return "None" end
	local name = a:Name()
	
	-- local buried = self:GetActionBuriedUnder(a)
	-- if (buried) then
		-- name = name .. "<<" .. buried:Name()
	-- end
	
	local n = #self.m_stack - 1
	for i = n, 1, -1 do
		if (self.m_stack[i]) then
			name = name .. "<<" .. self.m_stack[i]:Name()
		end
	end
	
	if a.m_childBehavior then
		name = name .. " ( " .. a.m_childBehavior:DebugString() .. " )"
	end
	
	return name
end

function CMBBehavior:ActiveNameFull()
    local a = self:Active()
    if not a then return "None" end
    local name = a:Name()
    if a.m_childBehavior then
        name = name .. " > " .. a.m_childBehavior:ActiveNameFull()
    end
    return name
end

-- Сначала pending активного действия, затем SUSPEND_FOR у погребённых в suspend-стеке
function CMBBehavior:ProcessPendingEvents()
	local active = self:Active()
	if not active then return false end

	if active.m_pendingEvent and IsRequestingChange(active.m_pendingEvent) then
		local ev = active.m_pendingEvent
		active.m_pendingEvent = nil
		self:_Apply(ev, active)
		return true
	end

	for i = #self.m_stack - 1, 1, -1 do
		local under = self.m_stack[i]
		if under.m_pendingEvent and under.m_pendingEvent.t == 3 then
			local ev = under.m_pendingEvent
			under.m_pendingEvent = nil
			self:_Apply(ev, under)
			return true
		end
	end

	return false
end

function CMBBehavior:Update(bot, dt)
    self.m_bot = bot

    local active = self:Active()
    if not active then return end

    -- Вызывается ProcessPendingEvents до Update дочернего/своего действия
    self:ProcessPendingEvents()
    active = self:Active()
    if not active then return end

    -- Дочерний стек обновляется первым
    if active.m_childBehavior then
        active.m_childBehavior:Update(bot, dt)
    end

    active = self:Active()
    if not active then return end

    local result = active:Update(bot, dt)
    if result then self:_Apply(result, active) end
end

function CMBBehavior:_ActionOnStack(action)
	for i = 1, #self.m_stack do
		if self.m_stack[i] == action then
			return true
		end
	end
	return false
end

-- Выбрать более приоритетный EventDesiredResult (если глубже, то в cur при ничьей)
function CMBBehavior:_MergeEventPick(curResult, curAction, newResult, newAction)
	if not newResult or IsEventContinue(newResult) then
		return curResult, curAction
	end
	if not curResult or IsEventContinue(curResult) then
		return newResult, newAction
	end
	if EventResultPriority(newResult) > EventResultPriority(curResult) then
		return newResult, newAction
	end
	return curResult, curAction
end

function CMBBehavior:_StoreEventResultIfLocal(eventMethod, result, action)
	if not action or not result or IsEventContinue(result) then return end
	if not self:_ActionOnStack(action) then return end
	action:StorePendingEventResult(result, eventMethod)
	self:DProcessEvent(eventMethod, result, action)
end

-- Порядок
-- 1. Сначало m_childBehavior
-- 2. Потом suspend-стек этого CMBBehavior сверху вниз (active -> buried)
-- 3. TryContinue - спрашиваем дальше по списку, иначе результат участвует в _MergeEventPick через приоритет priority
-- 4. TrySustain (для остановки прохождения ниже по стеку) сравнивается по priority с TryChangeTo / TrySuspendFor / TryDone
--    низкий TrySustain не блокирует ответы выше по иерархии или ниже в suspend-стеке
-- 5. StorePendingEventResult только на действии из этого стека
function CMBBehavior:FireEvent(eventMethod, ...)
	local active = self:Active()
	if not active then return nil, nil end

	local bestResult, bestAction

	if active.m_childBehavior then
		bestResult, bestAction = active.m_childBehavior:FireEvent(eventMethod, ...)
	end

	for i = #self.m_stack, 1, -1 do
		local action = self.m_stack[i]
		local fn = action[eventMethod]
		if fn then
			local result = fn(action, self.m_bot, ...)
			if not IsEventContinue(result) then
				bestResult, bestAction = self:_MergeEventPick(bestResult, bestAction, result, action)
			end
		end
	end

	self:_StoreEventResultIfLocal(eventMethod, bestResult, bestAction)
	return bestResult, bestAction
end

-- Пример: вызывать из ENT:OnTakeDamage, ENT:OnContact и тд
-- self.m_Behavior:ProcessEvent("OnInjured", dmginfo)
function CMBBehavior:ProcessEvent(eventMethod, ...)
	self:FireEvent(eventMethod, ...)
end

function CMBBehavior:_TearDownChildBehavior(action)
	if not action.m_childBehavior then return end
	local childActive = action.m_childBehavior:Active()
	while childActive do
		self:DInvokeOnEnd(childActive)
		childActive:OnEnd(self.m_bot, nil)
		action.m_childBehavior:_Remove(childActive)
		childActive = action.m_childBehavior:Active()
	end
	action.m_childBehavior = nil
end

function CMBBehavior:_StartAction(action, priorAction, buriedUnderMeAction)
	self:DInvokeOnStart(action)

	action.m_buriedUnderMe = buriedUnderMeAction
	if buriedUnderMeAction then
		buriedUnderMeAction.m_coveringMe = action
	end
	action.m_coveringMe = nil
	action.m_isSuspended = false

	table.insert(self.m_stack, action)

	local childAction = action:InitialContainedAction(self.m_bot)
	if childAction then
		self:DInvokeChangeTo(childAction, childAction, "Starting child action")
		
		action.m_childBehavior = CMBBehavior:New(childAction, self.m_bot)
	end

	local r = action:OnStart(self.m_bot, priorAction)
	if r and r.t ~= 1 then
		self:_Apply(r, action)
	end
end

function CMBBehavior:_Push(action, priorAction)
	self:_StartAction(action, priorAction, nil)
end

-- Верхнее действие suspend-стека (зеркало обхода m_coveringMe в ApplyResult SUSPEND_FOR)
function CMBBehavior:GetTopSuspendAction(from)
	local top = from or self:Active()
	while top and top.m_coveringMe do
		top = top.m_coveringMe
	end
	return top
end

function CMBBehavior:InvokeOnSuspend(action, interruptingAction)
	if not action then return nil end

	if action.m_childBehavior then
		local childActive = action.m_childBehavior:Active()
		if childActive then
			action.m_childBehavior:InvokeOnSuspend(childActive, interruptingAction)
		end
	end

	action.m_isSuspended = true
	self:DInvokeOnSuspend(action)

	local result = action:OnSuspend(self.m_bot, interruptingAction)
	if result and result.t == 4 then
		self:DInvokeOnEnd(action)
		action:OnEnd(self.m_bot, nil)
		self:_TearDownChildBehavior(action)

		local buried = self:GetActionBuriedUnder(action)
		self:_Remove(action)

		action.m_isSuspended = false
		action.m_buriedUnderMe = nil
		action.m_coveringMe = nil

		if buried then
			buried.m_coveringMe = nil
		end

		return buried
	end

	return action
end

-- Рекурсивно возобновляет m_childBehavior, затем вызывает OnResume на action
function CMBBehavior:InvokeOnResume(action, interruptingAction)
	if not action then return self:ContinueResult() end

	if not action.m_isSuspended then
		return self:ContinueResult()
	end

	if action.m_pendingEvent and IsRequestingChange(action.m_pendingEvent) then
		return self:ContinueResult()
	end

	action.m_isSuspended = false
	action.m_coveringMe = nil

	if action.m_childBehavior then
		local childActive = action.m_childBehavior:Active()
		if childActive then
			local childResult = action.m_childBehavior:InvokeOnResume(childActive, interruptingAction)
			if childResult and childResult.t ~= 1 then
				action.m_childBehavior:_Apply(childResult, childActive)
			end
		end
	end

	self:DInvokeOnResume(action)
	return action:OnResume(self.m_bot, interruptingAction) or self:ContinueResult()
end

function CMBBehavior:ContinueResult()
	return { t = 1 }
end

function CMBBehavior:_PushSuspend(interruptingAction, buriedAction)
	self:_StartAction(interruptingAction, buriedAction, buriedAction)
end

function CMBBehavior:_Remove(action)
    for i = #self.m_stack, 1, -1 do
        if self.m_stack[i] == action then
            table.remove(self.m_stack, i)
            return
        end
    end
end

function CMBBehavior:_Apply(result, from)
    local t = result.t
    if t == 1 then
        return
    elseif t == 2 then  -- CHANGE_TO
		self:DInvokeChangeTo(nil, result.action, result.reason)

		-- _Push() обнуляет buriedUnderMe и ломает m_coveringMe у приостановленного родителя
		local buriedUnderMe = from.m_buriedUnderMe

		self:DInvokeOnEnd(self:Active())
        from:OnEnd(self.m_bot, result.action)
        self:_TearDownChildBehavior(from)
        self:_Remove(from)

		from.m_buriedUnderMe = nil
		from.m_coveringMe = nil

		self:_StartAction(result.action, from, buriedUnderMe)
    elseif t == 3 then  -- SUSPEND_FOR
		local interruptingAction = result.action
		local topAction = self:GetTopSuspendAction(from)

		self:DSuspendFor(from, topAction, interruptingAction, result.reason)

		topAction = self:InvokeOnSuspend(topAction, interruptingAction)

		-- Дочерний стек паузируется автоматически:
		-- пока buried action не является Active(), его m_childBehavior не обновляется
		self:_PushSuspend(interruptingAction, topAction)
    elseif t == 4 then  -- DONE
		self:DInvokeOnEnd(nil)
        from:OnEnd(self.m_bot, nil)
        self:_TearDownChildBehavior(from)

		local debugPrior = self:Active()
		local resumed = from.m_buriedUnderMe

        self:_Remove(from)

        if resumed then
			self:DDone(debugPrior, resumed, result.reason)

			local resumeResult = self:InvokeOnResume(resumed, from)
			if resumeResult and resumeResult.t ~= 1 then
				self:_Apply(resumeResult, resumed)
			end
		else
			self:DDone(debugPrior, nil, result.reason)
		end
    end
end

-- Опрос стека для контекстных запросов, возвращающих ANSWER_* (число)
-- Спрашивает с вершины вниз; первый НЕ-UNDEFINED ответ выигрывает
-- Если всё UNDEFINED - возвращаем defaultAnswer
function CMBBehavior:QueryAnswer(method, defaultAnswer, ...)
    for i = #self.m_stack, 1, -1 do
        local action = self.m_stack[i]
        local fn     = action[method]
        if fn then
            local result = fn(action, self.m_bot, ...)
            if result ~= ANSWER_UNDEFINED then return result end
        end
    end
    return defaultAnswer
end

-- Опрос стека для запросов, возвращающих объект (Vector / Entity) или nil
-- Первый НЕ-nil ответ выигрывает.
function CMBBehavior:QueryValue(method, ...)
    for i = #self.m_stack, 1, -1 do
        local action = self.m_stack[i]
        local fn     = action[method]
        if fn then
            local result = fn(action, self.m_bot, ...)
            if result ~= nil then return result end
        end
    end
    return nil
end

function CMBBehavior:QueryAnswerDeep(method, defaultAnswer, ...)
	-- Сначала идём вглубь дочерней иерархии (наиболее специфичный ответ)
	local active = self:Active()
	if active and active.m_childBehavior then
		local r = active.m_childBehavior:QueryAnswerDeep(method, CMBAction.ANSWER_UNDEFINED, ...)
		if r ~= CMBAction.ANSWER_UNDEFINED then return r end
	end
	-- Затем опрашиваем собственный стек (от вершины вниз)
	return self:QueryAnswer(method, defaultAnswer, ...)
end

function CMBBehavior:QueryValueDeep(method, ...)
	-- Сначала идём вглубь дочерней иерархии (наиболее специфичный ответ)
	local active = self:Active()
	if active and active.m_childBehavior then
		local r = active.m_childBehavior:QueryValueDeep(method, ...)
		if r ~= nil then return r end
	end
	-- Затем опрашиваем собственный стек (от вершины вниз)
	return self:QueryValue(method, ...)
end

function CMBBehavior:SelectTargetPoint(subject)
	if (!IsValid(subject)) then return nil end
	
	local answer = self:QueryValueDeep("SelectTargetPoint", subject)
	
	if (answer) then return answer end
	
	return nil
end

function CMBBehavior:SelectMoreDangerousThreat(t1, t2)
	local answer = self:QueryValueDeep("SelectMoreDangerousThreat", t1, t2)
	if answer then return answer end
	
	return nil
end

function CMBBehavior:DInvokeOnStart(action)
	if CMasterBot.IsDebug() then
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 150, 255), "%3.2f: %s:%s: ", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), self:ActiveName())
		CMasterBot.DebugConColorMsg(1, Color(0, 255, 0, 255), " STARTING ")
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), action:Name())
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), "\n")
	end
end

function CMBBehavior:DInvokeOnEnd(action)
	if CMasterBot.IsDebug() then
		if (!action) then
			action = self:Active()
		end
		
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 150, 255), "%3.2f: %s:%s: ", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), self:ActiveName())
		CMasterBot.DebugConColorMsg(1, Color(255, 0, 0, 255), " ENDING ")
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), action:Name())
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), "\n")
	end
end

function CMBBehavior:DInvokeOnSuspend(action)
	if CMasterBot.IsDebug() then
		if (!action) then
			action = self:Active()
		end
		
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 150, 255), "%3.2f: %s:%s: ", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), self:ActiveName())
		CMasterBot.DebugConColorMsg(1, Color(255, 0, 255, 255), " SUSPENDING ")
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), action:Name())
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), "\n")
	end
end

function CMBBehavior:DInvokeOnResume(action)
	if CMasterBot.IsDebug() then
		if (!action) then
			action = self:Active()
		end
		
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 150, 255), "%3.2f: %s:%s: ", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), self:ActiveName())
		CMasterBot.DebugConColorMsg(1, Color(255, 0, 255, 255), " RESUMING ")
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), action:Name())
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), "\n")
	end
end

function CMBBehavior:DInvokeChangeTo(action, newAction, reason)
	if CMasterBot.IsDebug() then
		if (!action) then
			action = self:Active()
		end
		
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 150, 255), "%3.2f: %s:%s: ", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), self:ActiveName())
		if (action == newAction) then
			CMasterBot.DebugConColorMsg(1, Color(255, 0, 0, 255), "START ")
			CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), newAction:Name())
		else
			CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), action:Name())
			CMasterBot.DebugConColorMsg(1, Color(255, 0, 0, 255), " CHANGE_TO ")
			CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), newAction:Name())
		end
		
		if (reason) then
			CMasterBot.DebugConColorMsg(1, Color(150, 255, 150, 255), "  (%s)\n", reason)
		else
			CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), "\n")
		end
	end
end

function CMBBehavior:DSuspendFor(action, topAction, newAction, reason)
	if CMasterBot.IsDebug() then
		if (!action) then
			action = self:Active()
		end
		
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 150, 255), "%3.2f: %s:%s: ", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), self:ActiveName())
		
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), action:Name())
		CMasterBot.DebugConColorMsg(1, Color(255, 0, 255, 255), " caused ")
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), topAction:Name())
		CMasterBot.DebugConColorMsg(1, Color(255, 0, 255, 255), " to SUSPEND_FOR ")
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), newAction:Name())
		
		if (reason) then
			CMasterBot.DebugConColorMsg(1, Color(150, 255, 150, 255), "  (%s)\n", reason)
		else
			CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), "\n")
		end
	end
end

function CMBBehavior:DDone(action, resumedAction, reason)
	if CMasterBot.IsDebug() then
		if (!action) then
			action = self:Active()
		end
		
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 150, 255), "%3.2f: %s:%s: ", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), self:ActiveName())
		
		if (resumedAction) then
			CMasterBot.DebugConColorMsg(1, Color(0, 255, 0, 255), " DONE, RESUME ")
			CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), resumedAction:Name())
		else
			CMasterBot.DebugConColorMsg(1, Color(0, 255, 0, 255), " DONE.")
		end
		
		if (reason) then
			CMasterBot.DebugConColorMsg(1, Color(150, 255, 150, 255), "  (%s)\n", reason)
		else
			CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), "\n")
		end
	end
end

function CMBBehavior:DProcessEvent(method, result, responder)
	if CMasterBot.IsDebug() then
		if not result or IsEventContinue(result) then return end

		CMasterBot.DebugConColorMsg(1, Color(255, 255, 0, 255), "%3.2f: %s:%s: ", CurTime(), CMasterBot.FormatDebugIdentifier(self.m_bot), self:ActiveName())

		local resultStr = "CONTINUE"
		if result.t == 2 then
			resultStr = "CHANGE_TO"
		elseif result.t == 3 then
			resultStr = "SUSPEND_FOR"
		elseif result.t == 4 then
			resultStr = "DONE"
		elseif result.t == 5 then
			resultStr = "SUSTAIN"
		end

		local targetName = result.action and result.action:Name() or ""
		local responderName = responder and responder:Name() or "Unknown"

		CMasterBot.DebugConColorMsg(1, Color(255, 255, 255, 255), "%s ", responderName)
		CMasterBot.DebugConColorMsg(1, Color(255, 255, 0, 255), "responded to EVENT %s with ", method)
		CMasterBot.DebugConColorMsg(1, Color(255, 0, 0, 255), "%s %s ", resultStr, targetName)
		if result.reason then
			CMasterBot.DebugConColorMsg(1, Color(0, 255, 0, 255), "%s\n", result.reason)
		else
			CMasterBot.DebugConColorMsg(1, Color(0, 255, 0, 255), "\n")
		end
	end
end