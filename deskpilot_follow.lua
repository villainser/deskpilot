-- Follow one newly created, originally focused window after a verified move.
-- Restoring a session must never call this module. No frames or app launches.
local M = {}

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end
local function identity(value)
  return finite(value) and value > 0 and value % 1 == 0
end
local function text(value) return type(value) == 'string' and value ~= '' end

function M.new(api, ctx)
  assert(type(api) == 'table' and type(ctx) == 'table', 'follow requires an API and context')
  for _, name in ipairs({'blocked', 'generation', 'resolve', 'managed'}) do
    assert(type(ctx[name]) == 'function', 'follow requires ctx.' .. name)
  end
  local owner = {}

  function owner.begin(first, second)
    local window = first == owner and second or first
    local guard = { active = true, armed = false, completed = false, timers = {} }
    function guard:cancel()
      if not guard.active then return false end
      guard.active = false
      if guard.tap then pcall(function() guard.tap:stop() end); guard.tap = nil end
      for timer in pairs(guard.timers) do
        pcall(function() timer:stop() end)
        guard.timers[timer] = nil
      end
      return true
    end
    local function protected(fn, failure)
      local ok, result = pcall(fn)
      if not ok then guard:cancel(); return failure end
      return result
    end
    local function now()
      local value = api.timer.secondsSinceEpoch()
      if not finite(value) then error('invalid clock') end
      return value
    end
    local function buttonsDown()
      local buttons = api.eventtap.checkMouseButtons()
      if type(buttons) ~= 'table' then return true end
      for _, down in pairs(buttons) do if down then return true end end
      return false
    end
    local function windowIdentity(candidate)
      if not candidate then return nil end
      local id, app = candidate:id(), candidate:application()
      local pid = app and app:pid()
      if not identity(id) or not identity(pid) then return nil end
      return id, pid
    end
    local function sameWindow(candidate)
      local id, pid = windowIdentity(candidate)
      return id == guard.id and pid == guard.pid
    end
    local function focused()
      return sameWindow(api.window.focusedWindow())
    end
    local function activeSpaces()
      local raw = api.spaces.activeSpaces()
      if type(raw) ~= 'table' then return nil end
      local result, count = {}, 0
      for uuid, id in pairs(raw) do
        if not text(uuid) or not identity(id) then return nil end
        result[uuid], count = id, count + 1
      end
      return count > 0 and result or nil
    end
    local function activeAllowed(current, target)
      if not current then return false end
      -- Once the expected destination has been observed, returning even to
      -- the original Space is a new user/system navigation, not move fallout.
      if target and guard.reachedTarget and current[target.screenUUID] ~= target.spaceID then return false end
      local count, previousCount = 0, 0
      for uuid, initial in pairs(guard.initialSpaces) do
        previousCount = previousCount + 1
        local value = current[uuid]
        if value ~= initial and not (target and uuid == target.screenUUID and value == target.spaceID) then return false end
      end
      for _ in pairs(current) do count = count + 1 end
      if count ~= previousCount then return false end
      if target and current[target.screenUUID] == target.spaceID then guard.reachedTarget = true end
      return true
    end
    local function valid()
      if type(api.eventtap.isSecureInputEnabled) == 'function' and api.eventtap.isSecureInputEnabled() == true then return false end
      if guard.tap and type(guard.tap.isEnabled) == 'function' and guard.tap:isEnabled() ~= true then return false end
      local currentTime = now()
      local ownSpaceSwitch = guard.gotoSent == true and guard.followStartedAt ~= nil
        and currentTime >= guard.followStartedAt and currentTime - guard.followStartedAt < 2
      -- gotoSpace returns when AXPress starts the transition; its own Mission
      -- Control can still be closing. The adapter may ignore only that MC
      -- state, never lock/pause/input/startup protection, during this bounded poll.
      return guard.active and ctx.generation() == guard.generation and not ctx.blocked(ownSpaceSwitch)
        and not buttonsDown() and sameWindow(window) and ctx.managed(window) == true
        and currentTime >= guard.startedAt and currentTime - guard.startedAt < 12
    end
    local function liveTarget()
      local target = guard.target
      if not target then return nil end
      local live = ctx.resolve(target)
      if type(live) ~= 'table' or live.screenUUID ~= target.screenUUID
        or live.spaceUUID ~= target.spaceUUID or not identity(live.spaceID)
        or not guard.initialSpaces[live.screenUUID] then return nil end
      local ids = api.spaces.windowSpaces(window)
      if type(ids) ~= 'table' or #ids ~= 1 or ids[1] ~= live.spaceID then return nil end
      return live
    end
    local function later(delay, fn)
      local timer
      timer = api.timer.doAfter(delay, function()
        if timer then guard.timers[timer] = nil end
        if guard.active then protected(fn, false) end
      end)
      if not timer then error('timer unavailable') end
      guard.timers[timer] = true
      return timer
    end

    function guard:beforeMove()
      return protected(function()
        if guard.armed or guard.completed or not valid() or not focused()
          or not activeAllowed(activeSpaces()) then guard:cancel(); return false end
        guard.armed = true
        return true
      end, false)
    end

    function guard:complete(target)
      return protected(function()
        if not guard.armed or guard.completed or not valid() or type(target) ~= 'table'
          or not text(target.screenUUID) or not text(target.spaceUUID) then guard:cancel(); return false end
        guard.target = { screenUUID = target.screenUUID, spaceUUID = target.spaceUUID, spaceID = target.spaceID }
        local live = liveTarget()
        local current = activeSpaces()
        if not live or not activeAllowed(current, live) then guard:cancel(); return false end
        guard.completed = true
        guard.followStartedAt = now()
        guard.finalFocusSent = current[live.screenUUID] == live.spaceID
        later(2, function() guard:cancel() end)
        -- Activating the exact window normally switches its Space without
        -- opening Mission Control. gotoSpace is a single bounded fallback.
        window:focus()
        if not guard.active then return false end
        local function poll()
          if not valid() or now() - guard.followStartedAt >= 2 then guard:cancel(); return false end
          local destination = liveTarget()
          local active = activeSpaces()
          if not destination or not activeAllowed(active, destination) then guard:cancel(); return false end
          if active[destination.screenUUID] == destination.spaceID then
            if focused() then guard:cancel(); return true end
            if not guard.finalFocusSent then
              guard.finalFocusSent = true
              window:focus()
              -- The focus operation itself may invoke observers/input hooks.
              if not valid() or not activeAllowed(activeSpaces(), destination) then guard:cancel(); return false end
              if focused() then guard:cancel(); return true end
            end
          elseif not guard.gotoSent and now() - guard.followStartedAt >= .2 then
            guard.gotoSent = true
            local ok = api.spaces.gotoSpace(destination.spaceID)
            if ok ~= true then guard:cancel(); return false end
            if not valid() or not activeAllowed(activeSpaces(), destination) then guard:cancel(); return false end
          end
          if guard.active then later(.1, poll) end
          return true
        end
        return poll()
      end, false)
    end

    return protected(function()
      guard.id, guard.pid = windowIdentity(window)
      guard.generation, guard.startedAt = ctx.generation(), now()
      guard.initialSpaces = activeSpaces()
      if not guard.id or not guard.initialSpaces or not valid() or not focused() then guard:cancel(); return nil end
      local types, events = api.eventtap.event.types, {}
      for _, name in ipairs({'leftMouseDown', 'rightMouseDown', 'otherMouseDown',
          'leftMouseDragged', 'rightMouseDragged', 'otherMouseDragged', 'scrollWheel', 'keyDown'}) do
        if types[name] then events[#events + 1] = types[name] end
      end
      if not types.leftMouseDown or not types.rightMouseDown or not types.leftMouseDragged
        or not types.scrollWheel or not types.keyDown then guard:cancel(); return nil end
      guard.tap = api.eventtap.new(events, function() guard:cancel(); return false end)
      if not guard.tap or not guard.tap:start() then guard:cancel(); return nil end
      if type(guard.tap.isEnabled) == 'function' and guard.tap:isEnabled() ~= true then guard:cancel(); return nil end
      later(12, function() guard:cancel() end)
      return guard
    end, nil)
  end
  return owner
end
return M
