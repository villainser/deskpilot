-- Hammerspoon boundary for persistent layouts. Stored data contains neither
-- window titles/content nor process/window IDs.
local Session = require('deskpilot_session')
local DisplayPolicy = require('deskpilot_display_policy')
local M = {}
local storeKey = 'deskpilot.sessionLayouts.v1'
local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

function M.attach(api, manager, helpers)
  local function now() return api.timer.secondsSinceEpoch() end
  local function mouseDown()
    for _, down in pairs(api.eventtap.checkMouseButtons()) do if down then return true end end
    return false
  end
  local function sessionIdentity()
    local properties = api.caffeinate.sessionProperties()
    local identity = properties and properties.CGSSessionUniqueSessionUUID
    if type(identity) == 'string' and identity ~= '' then return identity end
    local output, ok = api.execute('/usr/sbin/sysctl -n kern.bootsessionuuid')
    if ok and type(output) == 'string' and output:match('%S') then
      return output:gsub('%s+', '') .. ':' .. tostring(properties and properties.kCGSSessionAuditIDKey or '')
    end
  end
  local identity = sessionIdentity()
  if not identity then return nil, 'Nie można odczytać tożsamości sesji macOS.' end
  local function screens()
    local result = {}
    if type(manager.displays) ~= 'table' then return nil end
    for _, screen in ipairs(api.screen.allScreens()) do
      local frame = screen:frame()
      if not frame or not finite(frame.x) or not finite(frame.y) or not finite(frame.w)
          or not finite(frame.h) or frame.w <= 0 or frame.h <= 0 then return nil end
      local physical
      for _, display in ipairs(manager.displays) do
        if display.id == screen:id() and display.uuid == screen:getUUID() and type(display.builtIn) == 'boolean' then
          physical = display; break
        end
      end
      if not physical then return nil end
      result[#result + 1] = { uuid = screen:getUUID(), builtIn = physical.builtIn,
        frame = { x = frame.x, y = frame.y, w = frame.w, h = frame.h } }
    end
    return #result > 0 and result or nil
  end
  local function workspaces()
    local list, found = helpers.workspaces(), {}
    if type(list) ~= 'table' then return nil end
    for _, ws in ipairs(list) do
      if not ws.spaceUUID or not ws.screenUUID or not ws.spaceID then return nil end
      found[ws.screenUUID] = true
    end
    local current = screens()
    if not current then return nil end
    local count = 0
    for _ in pairs(found) do count = count + 1 end
    if count ~= #current then return nil end
    for _, screen in ipairs(current) do if not found[screen.uuid] then return nil end end
    return list
  end
  local function completeState()
    if not manager.metadataAt or now() - manager.metadataAt >= 5 then return nil end
    local list = workspaces()
    if not list then return nil end
    local occupancy = manager:occupancy()
    for _, ws in ipairs(list) do if type(occupancy[ws.spaceID]) ~= 'boolean' then return nil end end
    return list
  end
  local function blocked()
    return manager.shuttingDown or manager:checkSessionLock() or manager.paused or manager.busy
      or manager.missionControl or mouseDown() or now() < manager.guardUntil
      or now() < manager.layoutGuardUntil or api.spaces.screensHaveSeparateSpaces() ~= true
  end
  local knownMembers = {}
  local function rows()
    if not completeState() then return nil end
    local result = {}
    for _, window in ipairs(manager:allWindows()) do
      if helpers.managed(window) then
        local info = helpers.identity(window)
        local ids = api.spaces.windowSpaces(window)
        local app, frame = window:application(), window:frame()
        if info and app and frame and window:id() and ids and #ids == 1
            and api.spaces.spaceType(ids[1]) == 'user' then
          local title = window:title()
          local keyMembers = knownMembers[info.key] or {}
          knownMembers[info.key] = keyMembers
          keyMembers[window:id()] = app:pid()
          result[#result + 1] = { window = window, id = window:id(), pid = app:pid(),
            key = info.key, bundleID = info.bundleID, profileDirectory = info.profileDirectory,
            titleHash = type(title) == 'string' and title ~= '' and api.hash.SHA256(title) or nil,
            spaceID = ids[1], frame = { x = frame.x, y = frame.y, w = frame.w, h = frame.h } }
        end
      end
    end
    return result
  end
  local function isGroupRunning(group)
    local apps = api.application.applicationsForBundleID(group.bundleID)
    if #apps == 0 then return false end
    local key = group.bundleID .. (group.profileDirectory and ('::' .. group.profileDirectory) or '')
    local members = knownMembers[key]
    if not members then return nil end -- An unvisited background Space can omit AX windows.
    local live = {}
    for _, item in ipairs(manager.metadata or {}) do live[item.kCGWindowNumber] = item.kCGWindowOwnerPID end
    local present = false
    for id, pid in pairs(members) do
      if live[id] == pid then present = true else members[id] = nil end
    end
    return present
  end
  local function removeQueued(id)
    manager.queued[id] = nil
    for index = #manager.queue, 1, -1 do
      if manager.queue[index].id == id then table.remove(manager.queue, index) end
    end
  end
  local function currentTarget(target)
    for _, ws in ipairs(workspaces() or {}) do
      if ws.spaceUUID == target.spaceUUID and ws.screenUUID == target.screenUUID then return ws end
    end
  end
  local function validWindow(row)
    local window = row.window
    if not window or window:id() ~= row.id then return false end
    local app = window:application()
    local info = helpers.identity(window)
    return app and app:pid() == row.pid and info and info.key == row.key and helpers.managed(window)
  end
  local function applyFrame(row, target, normalized)
    if not normalized then return true end
    local screen
    for _, candidate in ipairs(api.screen.allScreens()) do
      if candidate:getUUID() == target.screenUUID then screen = candidate; break end
    end
    if not screen then return false end
    local frame = screen:frame()
    local width = math.max(math.min(100, frame.w), math.min(frame.w, normalized.w * frame.w))
    local height = math.max(math.min(80, frame.h), math.min(frame.h, normalized.h * frame.h))
    local x = frame.x + math.max(0, math.min(frame.w - width, normalized.x * frame.w))
    local y = frame.y + math.max(0, math.min(frame.h - height, normalized.y * frame.h))
    row.window:setFrame({ x = x, y = y, w = width, h = height }, 0)
    return true
  end
  local launchTasks = {}
  local function canLaunch(group)
    local applicationPath = api.application.pathForBundleID(group.bundleID)
    if type(applicationPath) ~= 'string' or applicationPath == '' then return false end
    local apps = api.application.applicationsForBundleID(group.bundleID)
    if group.bundleID ~= 'com.google.Chrome' then return #apps == 0 end
    if not group.profileDirectory or not helpers.knownProfile or not helpers.knownProfile(group.profileDirectory) then return false end
    for _, app in ipairs(apps) do
      for _, window in ipairs(app:allWindows()) do
        if window:subrole() == 'AXStandardWindow' then
          local info = helpers.identity(window)
          if not info or info.profileDirectory == group.profileDirectory then return false end
        end
      end
    end
    return true
  end
  local ctx = {
    now = now, sessionID = identity, screens = screens, workspaces = workspaces,
    rows = rows, blocked = blocked, generation = function() return manager.generation end,
    load = function() return api.settings.get(storeKey) end,
    save = function(value) api.settings.set(storeKey, value); return true end,
    adaptLayout = function(layouts, current) return DisplayPolicy.adapt(layouts, current, now()) end,
    canLaunch = canLaunch,
    isGroupRunning = isGroupRunning,
    launch = function(group, done)
      if blocked() or not completeState() or not canLaunch(group) then done(false); return end
      local args = { '-g', '-b', group.bundleID }
      if group.bundleID == 'com.google.Chrome' then
        args = { '-g', '-n', '-b', group.bundleID, '--args',
          '--profile-directory=' .. group.profileDirectory, '--restore-last-session' }
      end
      local task, timeout, finished
      local function finish(ok)
        if finished then return end
        finished = true
        if timeout then timeout:stop() end
        if task then launchTasks[task] = nil end
        done(ok)
      end
      task = api.task.new('/usr/bin/open', function(code) finish(code == 0) end, args)
      if not task then finish(false); return end
      launchTasks[task] = true
      if not task:start() then finish(false); return end
      timeout = api.timer.doAfter(8, function()
        finish(false)
        if task:isRunning() then task:terminate() end
      end)
    end,
    canUse = function(_, id, allowedGroups)
      return manager:occupancy(nil, allowedGroups)[id] == false
    end,
    move = function(row, target, normalized, done)
      if blocked() or not validWindow(row) or not currentTarget(target) then done(false); return end
      local generation = manager.generation
      local inputSeen, inputExpired, inputWatcher = false, false, nil
      if normalized then
        inputWatcher = api.eventtap.new({ api.eventtap.event.types.leftMouseDown,
          api.eventtap.event.types.rightMouseDown, api.eventtap.event.types.leftMouseDragged },
          function() inputSeen = true; return false end):start()
      end
      local function completed(ok)
        if inputWatcher then inputWatcher:stop(); inputWatcher = nil end
        done(ok)
      end
      removeQueued(row.id)
      manager.births:take(row.id, row.pid, now())
      local accepted = manager:move(row.window, target, false, function(ok)
        if not ok or blocked() or manager.generation ~= generation or not validWindow(row) then completed(false); return end
        local live = currentTarget(target)
        local ids = api.spaces.windowSpaces(row.window)
        if not live or not ids or #ids ~= 1 or ids[1] ~= live.spaceID then completed(false); return end
        -- A click during this asynchronous operation gives the user priority.
        if inputSeen or inputExpired then completed(false); return end
        local called, frameOK = pcall(applyFrame, row, live, normalized)
        completed(called and frameOK)
      end)
      if not accepted then completed(false) end
      -- The manager intentionally suppresses stale callbacks after disconnects.
      -- Always release this short-lived input observer even in that case.
      if inputWatcher then api.timer.doAfter(3, function()
        if inputWatcher then inputExpired = true; inputWatcher:stop(); inputWatcher = nil end
      end) end
    end,
    create = function(uuid, done)
      if blocked() then done(nil, 'operation-blocked'); return end
      local beforeList = completeState()
      if not beforeList then done(nil, 'incomplete-state'); return end
      local screen, before = nil, {}
      for _, candidate in ipairs(api.screen.allScreens()) do
        if candidate:getUUID() == uuid then screen = candidate; break end
      end
      if not screen then done(nil, 'monitor-disconnected'); return end
      for _, ws in ipairs(beforeList) do before[ws.spaceUUID] = true end
      local generation = manager.generation
      local token = {}
      manager.sessionCreateToken = token
      manager.busy = true
      local called, ok, reason = pcall(api.spaces.addSpaceToScreen, screen)
      if not called or not ok then
        if manager.sessionCreateToken == token then manager.sessionCreateToken = nil; manager.busy = false end
        done(nil, tostring(reason or ok)); return
      end
      api.timer.doAfter(0.6, function()
        if generation ~= manager.generation or manager.sessionCreateToken ~= token then
          if manager.sessionCreateToken == token then manager.sessionCreateToken = nil end
          done(nil, 'operation-interrupted'); return
        end
        manager.sessionCreateToken = nil
        manager.busy = false
        if manager:checkSessionLock() or manager.paused or manager.shuttingDown or generation ~= manager.generation then
          done(nil, 'operation-interrupted'); return
        end
        helpers.refresh()
        local result
        for _, ws in ipairs(workspaces() or {}) do
          if ws.screenUUID == uuid and not before[ws.spaceUUID] then
            if result then done(nil, 'ambiguous-new-space'); return end
            result = ws
          end
        end
        if result then done(result) else done(nil, 'new-space-not-confirmed') end
      end)
    end,
  }
  local session = Session.new(ctx)
  manager.session = session
  manager.sessionToken = identity
  manager.preferredSessionScreen = function(window, rule)
    local current, info = screens(), helpers.identity(window)
    if not current or not info then return false end
    if rule and rule.manualMonitorSessionID == identity then
      for _, screen in ipairs(current) do if screen.uuid == rule.screenUUID then return rule.screenUUID end end
    end
    info.screenUUID = rule and rule.screenUUID or (window:screen() and window:screen():getUUID())
    local loads, seen = {}, {}
    for _, row in ipairs(rows() or {}) do
      if not seen[row.key] then
        seen[row.key] = true
        for _, ws in ipairs(workspaces() or {}) do
          if row.spaceID == ws.spaceID then loads[ws.screenUUID] = (loads[ws.screenUUID] or 0) + 1; break end
        end
      end
    end
    return DisplayPolicy.preferredScreen(info, current, loads)
  end
  local priorShutdown = api.shutdownCallback
  api.shutdownCallback = function()
    manager:shutdown()
    if priorShutdown then priorShutdown() end
  end
  return session
end
return M
