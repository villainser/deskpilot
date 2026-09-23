-- Serialized, verified window placement. Numeric desktop labels are UI only.
local policy = require('deskpilot_policy')
local Births = require('deskpilot_births')
local Wire = require('deskpilot_wire')
local M = {}

function M.new(ctx)
  local self = { paused = true, busy = false, queue = {}, queued = {}, observed = {},
    reserved = {}, emptySince = {}, guardUntil = 0, lastError = nil, topology = nil,
    cleanupEnabled = true, lastCleanup = 0, generation = 0, timers = {},
    layoutRevision = 0, layoutGuardUntil = 0, missionControl = false, locked = false, births = Births.new(),
    inputSerial = 0, followQuietUntil = 0 }
  local now = hs.timer.secondsSinceEpoch
  local spaces = hs.spaces
  local function later(delay, fn)
    local timer
    timer = hs.timer.doAfter(delay, function() self.timers[timer] = nil
      local ok, err = pcall(fn)
      if not ok then
        self.busy = false; self.reserved = {}; self:pause()
        self.lastError = tostring(err); hs.printf('DeskPilot async: %s', tostring(err))
      end end)
    self.timers[timer] = true
    return timer
  end
  local function screenPresent(uuid)
    for _, screen in ipairs(hs.screen.allScreens()) do
      if screen:getUUID() == uuid then return screen end
    end
  end
  local function appKey(window)
    if ctx.groupKey then return ctx.groupKey(window) end
    local app = window:application()
    return app and (app:bundleID() or app:name())
  end
  local function location(window)
    local ids = spaces.windowSpaces(window)
    if ids and #ids == 1 and spaces.spaceType(ids[1]) == 'user' then return ids[1] end
  end
  local function windows()
    return self.filter and self.filter:getWindows() or {}
  end
  local function stamp(window)
    local id = window:id()
    local app = window:application()
    if id then self.observed[id] = { spaceID = location(window), app = appKey(window), pid = app and app:pid() } end
  end
  local function mouseDown()
    for _, down in pairs(hs.eventtap.checkMouseButtons()) do if down then return true end end
    return false
  end
  function self:noteUserInput()
    -- Only timing is retained; no keys, text or click positions are recorded.
    self.lastUserInputAt, self.inputSerial = now(), self.inputSerial + 1
  end
  function self:configureFollowSession(sessionID)
    if type(sessionID) ~= 'string' or sessionID == '' then
      self.followQuietUntil = math.huge; return
    end
    local previous = hs.settings.get('deskpilot.followSession.v1')
    local quietUntil = 0
    if type(previous) == 'table' and type(previous.sessionID) == 'string' then
      if previous.sessionID ~= sessionID then quietUntil = now() + 60
      elseif type(previous.quietUntil) == 'number' and previous.quietUntil == previous.quietUntil then
        quietUntil = math.max(0, math.min(now() + 60, previous.quietUntil))
      end
    end
    self.followQuietUntil = quietUntil
    hs.settings.set('deskpilot.followSession.v1', { sessionID = sessionID, quietUntil = quietUntil })
  end
  local function focusedIdentity(window)
    local focused = hs.window.focusedWindow()
    local app, focusedApp = window and window:application(), focused and focused:application()
    return focused and window and focused:id() == window:id()
      and app and focusedApp and app:pid() == focusedApp:pid()
  end
  local function followIntent(window)
    if not ctx.prepareFollow or self.paused or now() < self.followQuietUntil
        or not self.lastUserInputAt or now() - self.lastUserInputAt > 10
        or now() < self.lastUserInputAt or not focusedIdentity(window) then return nil end
    local app = window:application()
    return { id = window:id(), pid = app:pid(), key = appKey(window),
      generation = self.generation, inputSerial = self.inputSerial, time = now() }
  end
  local function validFollow(window, intent)
    local app = window and window:application()
    return intent and app and not self.paused and not self.shuttingDown
      and now() >= self.followQuietUntil and now() >= intent.time and now() - intent.time < 10
      and intent.id == window:id() and intent.pid == app:pid() and intent.key == appKey(window)
      and intent.generation == self.generation and intent.inputSerial == self.inputSerial
      and focusedIdentity(window)
  end
  local function screenSignature()
    local ids = {}
    for _, screen in ipairs(hs.screen.allScreens()) do ids[#ids + 1] = screen:getUUID() end
    table.sort(ids)
    return table.concat(ids, '|')
  end
  local function screenGeometrySignature()
    local entries = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
      local ok, frame = pcall(function() return screen:fullFrame() end)
      if not ok or not frame then return nil end
      local dimensions = {}
      for _, field in ipairs({ 'x', 'y', 'w', 'h' }) do
        local value = frame[field]
        if type(value) ~= 'number' or value ~= value or math.abs(value) == math.huge then return nil end
        dimensions[#dimensions + 1] = tostring(value)
      end
      entries[#entries + 1] = screen:getUUID() .. ':' .. table.concat(dimensions, ',')
    end
    if #entries == 0 then return nil end
    table.sort(entries)
    return table.concat(entries, '|')
  end
  function self:checkSessionLock()
    if not hs.caffeinate or not hs.caffeinate.sessionProperties then return self.locked end
    local ok, properties = pcall(hs.caffeinate.sessionProperties)
    if not ok or type(properties) ~= 'table' then return self.locked end
    local locked = properties.CGSSessionScreenIsLocked == true
    local changed = locked ~= self.locked
    if changed then
      self.locked = locked
      if locked then
        if self.sessionCreateToken then self.sessionCreateToken = nil; self.busy = false end
        if self.cleanupBatch then self:cancelCleanup('locked') end
        self.generation = self.generation + 1
        self.queue, self.queued, self.reserved, self.emptySince = {}, {}, {}, {}
        self.births:resetPending()
        self.rebaseline, self.interacting, self.pendingLayout = true, false, nil
        -- A helper already in flight must not continue working on inaccessible
        -- windows; its eventual callback belongs to the cancelled generation.
        if self.nativeTask then pcall(function() self.nativeTask:terminate() end) end
      else
        self:topologyChanged()
      end
    end
    return self.locked, changed
  end
  -- Read the same Dock AX group used by hs.spaces, without opening Mission
  -- Control. Space/window locations can be transient while its cards are dragged.
  local dockElement
  local function missionControlVisible(strict)
    if ctx.missionControlVisible then return ctx.missionControlVisible() end
    if not hs.axuielement or not hs.application or not hs.application.applicationsForBundleID then
      return false
    end
    local ok, visible = pcall(function()
      if not dockElement or not dockElement:isValid() then
        local dock = hs.application.applicationsForBundleID('com.apple.dock')[1]
        if not dock then return false end
        dockElement = hs.axuielement.applicationElement(dock)
      end
      for _, element in ipairs(dockElement) do
        if element.AXIdentifier == 'mc' then return true end
      end
      return false
    end)
    -- A briefly stale AX object should not end an already detected interaction.
    if not ok then
      dockElement = nil
      if strict then return false end
      return self.missionControl
    end
    return visible
  end
  local function layoutSnapshot()
    local byScreen, screenIDs, identities, locations = {}, {}, {}, {}
    for position, ws in ipairs(ctx.workspaces()) do
      if ws.screenUUID and ws.spaceID then
        if not byScreen[ws.screenUUID] then
          byScreen[ws.screenUUID] = {}; screenIDs[#screenIDs + 1] = ws.screenUUID
        end
        local identity = ws.spaceUUID and ('uuid:' .. ws.spaceUUID) or ('id:' .. tostring(ws.spaceID))
        identities[#identities + 1] = identity
        locations[identity] = { spaceUUID = ws.spaceUUID, spaceID = ws.spaceID, screenUUID = ws.screenUUID }
        local list = byScreen[ws.screenUUID]
        list[#list + 1] = { identity = identity, order = ws.localIndex or position }
      end
    end
    if #screenIDs == 0 then return nil end -- Never adopt an incomplete empty query.
    table.sort(screenIDs)
    local signatures, membership = {}, {}
    for _, screenID in ipairs(screenIDs) do
      local list, ids = byScreen[screenID], {}
      table.sort(list, function(a, b) return a.order < b.order end)
      for _, item in ipairs(list) do
        ids[#ids + 1] = item.identity
        membership[#membership + 1] = screenID .. ':' .. item.identity
      end
      byScreen[screenID] = table.concat(ids, '|')
      signatures[#signatures + 1] = screenID .. '=' .. byScreen[screenID]
    end
    table.sort(membership)
    table.sort(identities)
    return { signature = table.concat(signatures, '\n'), membership = table.concat(membership, '\n'),
      screens = byScreen, screenSignature = table.concat(screenIDs, '|'),
      identities = table.concat(identities, '\n'), locations = locations }
  end
  function self:observeLayout(interacting)
    if self:checkSessionLock() then return end
    local current = layoutSnapshot()
    if not current then return end
    if not self.layout then self.layout = current; return end
    if current.signature == self.layout.signature then self.pendingLayout = nil; return end
    local pending = self.pendingLayout
    if not pending or pending.snapshot.signature ~= current.signature then
      pending = { snapshot = current, since = now() }; self.pendingLayout = pending
    end
    self.layoutGuardUntil = now() + 1.5
    if interacting or now() - pending.since < 1 then return end
    local changedScreens = {}
    for uuid, signature in pairs(current.screens) do
      if self.layout.screens[uuid] ~= signature then changedScreens[#changedScreens + 1] = uuid end
    end
    for uuid in pairs(self.layout.screens) do
      if not current.screens[uuid] then changedScreens[#changedScreens + 1] = uuid end
    end
    table.sort(changedScreens)
    local movedSpaces = {}
    if current.identities == self.layout.identities and current.screenSignature == self.layout.screenSignature
        and now() >= self.guardUntil and not self.rebaseline then
      for identity, destination in pairs(current.locations) do
        local source = self.layout.locations[identity]
        if source and source.screenUUID ~= destination.screenUUID then
          movedSpaces[#movedSpaces + 1] = { spaceID = destination.spaceID,
            spaceUUID = destination.spaceUUID, fromScreenUUID = source.screenUUID,
            toScreenUUID = destination.screenUUID }
        end
      end
    end
    self.layoutChange = current.membership == self.layout.membership and 'reordered'
      or (#movedSpaces > 0 and 'spaces-moved' or 'spaces-changed')
    self.layoutMessage = self.layoutChange == 'reordered'
      and 'Wykryto nową kolejność biurek — aplikacje zachowują swoje biurka.'
      or (self.layoutChange == 'spaces-moved'
        and 'Wykryto przeniesienie biurka na inny monitor.' or 'Zaktualizowano układ biurek macOS.')
    self.layoutChangedAt, self.layoutChangedScreens = now(), changedScreens
    self.layoutRevision = self.layoutRevision + 1
    self.layout, self.pendingLayout, self.emptySince = current, nil, {}
    if #movedSpaces > 0 and ctx.layoutAdopted then ctx.layoutAdopted(movedSpaces) end
    -- Do not rebaseline or enqueue here: an order change does not move a window
    -- to another Space and must not overwrite profile/app assignments.
  end
  local function report(message)
    self.lastError = message
    hs.printf('DeskPilot: %s', message)
    hs.alert.show('DeskPilot: ' .. message)
  end
  function self:followBlocked()
    return self.shuttingDown or self:checkSessionLock() or self.paused
      or now() < self.followQuietUntil or mouseDown() or missionControlVisible()
  end
  function self:allWindows() return windows() end
  function self:enqueue(window, allowAutoDock, intent)
    if self:checkSessionLock() then return end
    local id = window and window:id()
    if not id or not ctx.managed(window) then return end
    if self.session and self.session:claims(appKey(window)) then return end
    if not self.queued[id] then
      if not self.observed[id] then stamp(window) end
      self.queued[id] = true
      self.queue[#self.queue + 1] = { window = window, id = id, auto = allowAutoDock ~= false, follow = intent }
    elseif intent then
      for _, item in ipairs(self.queue) do if item.id == id then item.follow = intent; break end end
    end
  end
  function self:refreshMetadata()
    local helper = hs.configdir .. '/deskpilot-move'
    if self.metadataTask or (self.metadataAt and now() - self.metadataAt < 2)
        or hs.fs.attributes(helper, 'mode') ~= 'file' then return end
    local request = { chunks = {}, tail = '', bytes = 0, done = false }
    self.metadataFetch = request
    local function cancel(timer)
      if timer then timer:stop(); self.timers[timer] = nil end
    end
    local function finish(reason)
      request.done = true
      cancel(request.timeoutTimer)
      if reason then self.metadataError = reason end
      if self.metadataFetch == request then self.metadataTask, self.metadataFetch = nil, nil end
    end
    local function tryComplete()
      if request.done or self.metadataFetch ~= request then return end
      if request.exitCode ~= nil and request.exitCode ~= 0 then
        finish('helper-exit-' .. tostring(request.exitCode)); return
      end
      local encoded, reason = Wire.payload(table.concat(request.chunks) .. request.tail)
      if not encoded then
        -- Even the first streamed read can arrive after termination. Its
        -- prefix can make a currently invalid-looking tail into a valid frame.
        request.frameReason = reason
        return
      end
      if request.exitCode == nil then
        if not request.acknowledged then
          -- The producer waits for this exact line before it may exit. All
          -- output is therefore already drained when hs.task reads its tail.
          request.acknowledged = true
          local sentOK, sent = pcall(function() return request.task:setInput('DESKPILOT-ACK/1\n') end)
          if not sentOK or not sent then
            finish('helper-ack-failed')
            if request.task:isRunning() then request.task:terminate() end
          end
        end
        return
      end
      local decodedOK, jsonBytes = pcall(hs.base64.decode, encoded)
      if not decodedOK or type(jsonBytes) ~= 'string' then finish('invalid-base64'); return end
      local ok, data = pcall(hs.json.decode, jsonBytes)
      if ok and type(data) == 'table' and type(data.windows) == 'table' then
        -- AX windowCreated also means an old window was discovered on another
        -- Space. Only a new identity in the global CG list authorizes auto-dock.
        -- A click or Mission Control delays delivery in tick(), not birth
        -- evidence. Baseline-only observation would permanently lose windows
        -- opened during that interaction and erase already pending births.
        local acceptNew = not self:checkSessionLock() and not self.paused and not self.rebaseline
          and now() >= self.guardUntil
        self.births:observe(data.windows, acceptNew, now())
        self.metadata, self.metadataAt = data.windows, now()
        self.displays = type(data.displays) == 'table' and data.displays or nil
        self.metadataError = nil
        self.metadataReads = (self.metadataReads or 0) + 1
        finish()
      else
        finish('invalid-metadata')
      end
    end
    local function acceptBytes(chunk)
      request.bytes = request.bytes + #chunk
      if request.bytes <= Wire.maxFrameBytes then return true end
      finish('oversized-metadata')
      if request.task and request.task:isRunning() then request.task:terminate() end
      return false
    end
    self.metadataTask = hs.task.new(helper, function(code, stdout)
      if request.done or self.metadataFetch ~= request then return end
      request.exitCode, request.tail = code, stdout or ''
      if acceptBytes(request.tail) then tryComplete() end
    end, function(_, stdout)
      if request.done or self.metadataFetch ~= request then return false end
      if stdout and stdout ~= '' then
        if not acceptBytes(stdout) then return false end
        request.chunks[#request.chunks + 1] = stdout
      end
      tryComplete()
      return true -- Drain continuously so output larger than the pipe cannot block.
    end, { '--windows-stream' })
    request.task = self.metadataTask
    if not request.task or not request.task:start() then finish('helper-start-failed'); return end
    if request.done then return end
    request.timeoutTimer = later(5, function()
      if request.done then return end
      finish(request.acknowledged and 'helper-exit-timeout'
        or request.frameReason == 'invalid' and 'invalid-frame'
        or request.frameReason == 'oversized' and 'oversized-frame' or 'incomplete-frame-timeout')
      if request.task:isRunning() then request.task:terminate() end
    end)
    -- ASCII framing prevents split UTF-8 characters from being discarded.
    -- The ACK keeps hs.task's termination reader from racing its streaming
    -- reader; finalization still requires a successful helper exit.
  end
  -- CG metadata plus the private per-Space ID list, not just visible AX windows.
  -- An unknown ID is an occupant. Hidden/minimized windows are never discarded.
  function self:occupancy(ignoreWindow, allowedGroups)
    local ax, cg, occupied = {}, {}, {}
    for _, window in ipairs(windows()) do ax[window:id()] = window end
    local raw = hs.window.list(true)
    if hs.fs.attributes(hs.configdir .. '/deskpilot-move', 'mode') == 'file' then
      raw = self.metadataAt and now() - self.metadataAt < 5 and self.metadata or nil
    end
    if type(raw) ~= 'table' then return occupied end
    for _, item in ipairs(raw) do cg[item.kCGWindowNumber] = item end
    local ignoreKey = ignoreWindow and appKey(ignoreWindow)
    local ignoreApp = ignoreWindow and ignoreWindow:application()
    local ignorePID = ignoreApp and ignoreApp.pid and ignoreApp:pid()
    if ignoreWindow and ctx.isGroupedApplication and ctx.isGroupedApplication(ignoreWindow) then
      ignorePID = nil -- Chrome profiles share a PID; ignore only proven same-profile windows.
    end
    local systemPIDs = {}
    for _, app in ipairs(hs.application and hs.application.runningApplications() or {}) do
      local bundle = app:bundleID() or ''
      if bundle == 'com.apple.dock' or bundle == 'com.apple.notificationcenterui'
          or bundle == 'com.apple.controlcenter' or bundle == 'com.apple.universalaccessd'
          or bundle == 'com.apple.AccessibilityUIServer' or bundle == 'com.apple.WindowManager' or bundle == 'com.apple.wallpaper.agent'
          or bundle == 'com.apple.loginwindow'
          or bundle == 'org.hammerspoon.Hammerspoon' then systemPIDs[app:pid()] = true end
    end
    for _, ws in ipairs(ctx.workspaces()) do
      local ids = spaces.windowsForSpace(ws.spaceID)
      if ids then
        occupied[ws.spaceID] = false
        for _, id in ipairs(ids) do
          local window, item = ax[id], cg[id]
          local knownGroup = item and ctx.groupKeyForWindowID
            and ctx.groupKeyForWindowID(id, item.kCGWindowOwnerPID)
          local observed = self.observed[id]
          if not window and not knownGroup and item and observed and type(observed.pid) == 'number'
              and observed.pid > 0 and observed.pid == item.kCGWindowOwnerPID
              and type(observed.app) == 'string' and observed.app ~= '' then
            -- Moving to an inactive Space can remove the AX row immediately.
            -- Retain only the group proven for this exact window/process pair.
            knownGroup = observed.app
          end
          local ignoredOwn = (window and ignoreKey and appKey(window) == ignoreKey)
            or (ignoreKey and knownGroup == ignoreKey)
            or (item and ignorePID and item.kCGWindowOwnerPID == ignorePID)
            or (window and allowedGroups and allowedGroups[appKey(window)] == true)
            or (knownGroup and allowedGroups and allowedGroups[knownGroup] == true)
          local systemSurface = item and not window and type(item.kCGWindowLayer) == 'number'
            and item.kCGWindowLayer ~= 0 and (systemPIDs[item.kCGWindowOwnerPID]
              or item.kCGWindowOwnerName == 'Window Server')
          if not ignoredOwn and not systemSurface then
            occupied[ws.spaceID] = true
            break
          end
        end
      end
    end
    return occupied
  end
  local function targetFor(window, rule)
    local list = ctx.workspaces()
    local preferred = ctx.preferredScreen and ctx.preferredScreen(window, rule)
    if preferred == false then return nil, 'unknown' end
    local uuid = preferred or (rule and rule.screenUUID) or (window:screen() and window:screen():getUUID())
    if not uuid or not screenPresent(uuid) then return nil, 'disconnected' end
    local occupied = self:occupancy(window)
    local pinned = rule and policy.resolve(rule, list)
    if pinned and pinned.screenUUID == uuid and (rule.allowShared or occupied[pinned.spaceID] == false)
        and (not self.reserved[pinned.spaceID] or self.reserved[pinned.spaceID] == appKey(window)) then
      return pinned
    end
    local reserved = {}
    for id, key in pairs(self.reserved) do if key ~= appKey(window) then reserved[id] = true end end
    local free = policy.firstFree(list, uuid, occupied, reserved)
    if free then return free end
    for _, item in ipairs(list) do
      if item.screenUUID == uuid and occupied[item.spaceID] == nil then return nil, 'unknown' end
    end
    return nil, 'full', uuid
  end
  local function record(window, ws, manual)
    if manual and self.session then self.session:cancelGroup(appKey(window)) end
    ctx.remember(window, ws, manual)
    stamp(window)
    if manual then
      for _, other in ipairs(windows()) do
        if other:id() ~= window:id() and appKey(other) == appKey(window) then self:enqueue(other, true) end
      end
    end
  end
  function self:move(window, ws, manual, done)
    if self:checkSessionLock() or self.busy or not window or not window:id() or not ws then return false end
    local list = ctx.workspaces()
    local live = policy.resolve(ws, list)
    if not live then return false end
    ws = live
    local id, key, generation = window:id(), appKey(window), self.generation
    local sourceID = location(window)
    self.busy = true
    self.reserved[ws.spaceID] = key
    local finished = false
    local function finish(ok)
      if finished then return end
      finished = true
      self.reserved[ws.spaceID] = nil
      self.busy = false
      if self:checkSessionLock() or generation ~= self.generation then return end
      if not window:id() then stamp(window); return end
      if ok then
        local currentTarget = policy.resolve(ws, ctx.workspaces())
        if not currentTarget then
          -- A Space itself may have been dragged to another monitor while
          -- this move was being verified. Never apply its old screen/frame.
          stamp(window)
          if done then done(false) end
          return
        end
        ws = currentTarget
        record(window, ws, manual)
      else
        -- Stop rather than issuing another unverified move or restoring a
        -- stale frame over a position the user may have just chosen.
        self:pause()
        report('ruch okna niepotwierdzony; automatyka wstrzymana (menu: Wznow automatyke)')
        stamp(window)
      end
      if done then done(ok) end
    end
    if sourceID == ws.spaceID then finish(true); return true end
    -- Move to Space first. Changing screen/frame first can strand a window.
    local ok, err = spaces.moveWindowToSpace(window, ws.spaceID)
    if not ok then hs.printf('DeskPilot move: %s', tostring(err)) end
    later(0.45, function()
      if self:checkSessionLock() or generation ~= self.generation or not window:id() then finish(false); return end
      if location(window) == ws.spaceID then finish(true); return end
      local helper = hs.configdir .. '/deskpilot-move'
      if hs.fs.attributes(helper, 'mode') == 'file' then
        self.nativeTask = hs.task.new(helper, function(exitCode, stdout, stderr)
          self.nativeTask = nil
          later(0.35, function()
            if self:checkSessionLock() or generation ~= self.generation then finish(false); return end
            if exitCode ~= 0 then hs.printf('DeskPilot helper: %s %s', stdout or '', stderr or '') end
            finish(window:id() ~= nil and location(window) == ws.spaceID)
          end)
        end, { tostring(id), tostring(ws.spaceID) })
        if not self.nativeTask or not self.nativeTask:start() then finish(false) end
      else finish(false) end
    end)
    return true
  end
  function self:apply(window, allowAutoDock, intent)
    if self:checkSessionLock() or not ctx.managed(window) then return end
    if self.session and self.session:claims(appKey(window)) then return end
    if missionControlVisible() then self:enqueue(window, allowAutoDock, intent); return end
    -- Sticky and fullscreen windows are user exceptions, never forced apart.
    if not location(window) then stamp(window); return end
    local rule = ctx.rule(window)
    if not rule and not allowAutoDock then stamp(window); return end
    local ws, reason, uuid = targetFor(window, rule)
    if reason == 'disconnected' then stamp(window); return end
    if reason == 'unknown' then self:enqueue(window, allowAutoDock, intent); return end
    if not ws and reason ~= 'full' then return end
    local follow, followArmed
    if validFollow(window, intent) and (not ws or location(window) ~= ws.spaceID) then
      follow = ctx.prepareFollow(window)
    end
    local function cancelFollow() if follow then follow:cancel(); follow = nil end end
    local function armFollow()
      if follow and not followArmed then
        followArmed = follow:beforeMove()
        if not followArmed then cancelFollow() end
      end
    end
    local function moveAndFollow(target)
      armFollow()
      local accepted = self:move(window, target, false, function(ok)
        if follow then
          if ok then follow:complete(target) else cancelFollow() end
        end
      end)
      if not accepted then cancelFollow() end
    end
    if ws then moveAndFollow(ws); return end
    -- Creating a Space opens Mission Control and can itself drop focus. Arm
    -- once before our own create/move sequence; input still cancels the guard.
    armFollow()
    self.busy = true
    local screen = screenPresent(uuid)
    local before = {}
    for _, item in ipairs(ctx.workspaces()) do before[item.spaceID] = true end
    local ok, err = spaces.addSpaceToScreen(screen)
    if not ok then
      cancelFollow()
      self.busy = false; self:pause()
      report('nie mozna utworzyc biurka: ' .. tostring(err)); return
    end
    local generation = self.generation
    later(0.6, function()
      self.busy = false
      if self:checkSessionLock() or generation ~= self.generation then cancelFollow(); return end
      ctx.refresh()
      local added
      for _, item in ipairs(ctx.workspaces()) do
        if item.screenUUID == uuid and not before[item.spaceID] then added = item; break end
      end
      if added then moveAndFollow(added)
      else cancelFollow(); self:pause(); report('nowe biurko nie zostalo potwierdzone; automatyka wstrzymana') end
    end)
  end
  function self:manualMove(window, ws)
    if self:checkSessionLock() then return end
    if self.busy then report('poczekaj na zakonczenie ruchu okna'); return end
    if self.session then self.session:cancelGroup(appKey(window)) end
    return self:move(window, ws, true, function(ok)
      if ok then
        for _, other in ipairs(windows()) do
          if other:id() ~= window:id() and appKey(other) == appKey(window) then self:enqueue(other, true) end
        end
      end
    end)
  end
  function self:cancelCleanup(reason)
    local batch = self.cleanupBatch
    if batch then batch.finish('cancelled', reason) end
  end
  local function activeSnapshot(list)
    local raw = spaces.activeSpaces()
    if type(raw) ~= 'table' then return end
    local active = {}
    for _, workspace in ipairs(list) do
      local id = raw[workspace.screenUUID]
      if type(id) ~= 'number' or id <= 0 then return end
      active[id] = true
    end
    return active
  end
  local function validCleanupSnapshot(list, topology)
    if type(list) ~= 'table' or #list == 0 then return false end
    local seen, ids = {}, {}
    for _, workspace in ipairs(list) do
      if type(workspace.spaceID) ~= 'number' or workspace.spaceID <= 0
          or type(workspace.spaceUUID) ~= 'string' or workspace.spaceUUID == ''
          or type(workspace.screenUUID) ~= 'string' or workspace.screenUUID == '' then return false end
      if not seen[workspace.screenUUID] then
        seen[workspace.screenUUID] = true; ids[#ids + 1] = workspace.screenUUID
      end
    end
    table.sort(ids)
    return table.concat(ids, '|') == topology
  end
  function self:cleanup()
    if self.shuttingDown or (self.session and self.session:isRestoring()) then return end
    if self:checkSessionLock() or self.paused or self.busy or now() < self.guardUntil or now() < self.layoutGuardUntil
        or mouseDown() or missionControlVisible() or #self.queue > 0 or spaces.screensHaveSeparateSpaces() ~= true then return end
    local list = ctx.workspaces()
    if not validCleanupSnapshot(list, screenSignature()) then return end
    local active = activeSnapshot(list)
    if not active then return end
    local occupied = self:occupancy()
    for _, workspace in ipairs(list) do
      local id = workspace.spaceID
      if occupied[id] == false then self.emptySince[id] = self.emptySince[id] or now()
      else self.emptySince[id] = nil end
    end
    -- Detect the entire prospective plan before opening Mission Control. A
    -- newly empty Space delays older empty ones, preventing successive waves.
    local candidates = policy.cleanupCandidates(list, occupied, self.reserved, active, self.emptySince, now(), 0)
    self.cleanupPhase, self.cleanupPlanned, self.cleanupDone = #candidates > 0 and 'detecting' or nil, #candidates, 0
    self.cleanupPending, self.cleanupSkipped = #candidates, 0
    if #candidates == 0 then self.cleanupDetection = nil; return end
    if #candidates > 128 then
      self.cleanupEnabled, self.cleanupPhase = false, 'failed'
      report('sprzatanie wstrzymane: plan przekracza bezpieczny limit 128 biurek')
      return
    end
    local identities = {}
    for _, candidate in ipairs(candidates) do
      identities[#identities + 1] = candidate.screenUUID .. ':'
        .. (candidate.spaceUUID or ('id-' .. tostring(candidate.spaceID)))
    end
    local signature = table.concat(identities, '|')
    if not self.cleanupDetection or self.cleanupDetection.signature ~= signature then
      self.cleanupDetection = { signature = signature, since = now() }
    end
    if now() - self.cleanupDetection.since < 8 then return end
    for _, candidate in ipairs(candidates) do
      if now() - self.emptySince[candidate.spaceID] < 8 then return end
    end
    local batch = { plan = {}, index = 1, generation = self.generation,
      topology = screenSignature(), openedAt = now(), ownedMC = false,
      deadline = now() + math.max(30, #candidates * 2) }
    for _, candidate in ipairs(candidates) do
      batch.plan[#batch.plan + 1] = { spaceID = candidate.spaceID,
        spaceUUID = candidate.spaceUUID, screenUUID = candidate.screenUUID }
    end
    self.cleanupBatch, self.busy, self.cleaning = batch, true, true
    batch.finish = function(phase, reason)
      if batch.finished then return end
      batch.finished = true
      if batch.timer then batch.timer:stop(); self.timers[batch.timer] = nil end
      self.cleanupBatch, self.busy, self.cleaning = nil, false, false
      self.cleanupPhase, self.lastCleanup = phase, now()
      if batch.ownedMC then
        batch.ownedMC = false
        if not self.locked and reason ~= 'locked' and missionControlVisible(true) then
          local closed, err = pcall(spaces.closeMissionControl)
          if not closed then phase, reason = 'failed', tostring(err); self.cleanupPhase = phase end
        end
      end
      if phase == 'failed' then
        self.cleanupEnabled = false
        report('sprzatanie wstrzymane: ' .. tostring(reason))
      elseif phase == 'cancelled' then
        -- A new detection period follows interruption, never an immediate
        -- reopening of the Mission Control session the user just interrupted.
        self.emptySince = {}
        self.cleanupDetection = nil
        if reason == 'mission-control-closed' or reason == 'user-interaction' then self.cleanupEnabled = false end
      end
    end
    local function guard()
      if batch.finished then return false end
      if now() >= batch.deadline then batch.finish('failed', 'przekroczony czas sprzatania'); return false end
      if self:checkSessionLock() then batch.finish('cancelled', 'locked'); return false end
      if self.paused or batch.generation ~= self.generation or batch.topology ~= screenSignature() then
        batch.finish('cancelled', 'paused-or-topology'); return false
      end
      if mouseDown() or #self.queue > 0 then
        batch.finish('cancelled', 'user-interaction'); return false
      end
      if not missionControlVisible() then
        batch.finish('cancelled', 'mission-control-closed'); return false
      end
      return true
    end
    local step
    local function nextCandidate(skipped)
      if skipped then self.cleanupSkipped = self.cleanupSkipped + 1 end
      batch.index = batch.index + 1
      self.cleanupPending = math.max(0, #batch.plan - batch.index + 1)
      if batch.index > #batch.plan then batch.finish('done')
      else batch.timer = later(0.1, step) end
    end
    step = function()
      if not guard() then return end
      local target = batch.plan[batch.index]
      local liveList = ctx.workspaces()
      if not validCleanupSnapshot(liveList, batch.topology) then
        batch.finish('failed', 'niepelny odczyt biurek'); return
      end
      local live = policy.resolve(target, liveList)
      if not live then nextCandidate(true); return end
      local activeNow = activeSnapshot(liveList)
      if not activeNow then batch.finish('failed', 'nieznane aktywne biurka'); return end
      local count = 0
      for _, workspace in ipairs(liveList) do if workspace.screenUUID == live.screenUUID then count = count + 1 end end
      local isOccupied = self:occupancy()[live.spaceID]
      if isOccupied == nil then batch.finish('failed', 'nieznana zajetosc biurka'); return end
      if count <= 1 or activeNow[live.spaceID] or self.reserved[live.spaceID] or isOccupied ~= false then
        self.emptySince[live.spaceID] = nil
        nextCandidate(true); return
      end
      self.cleanupPhase = 'removing'
      local called, ok, err = pcall(spaces.removeSpace, live.spaceID, false)
      if batch.finished then return end
      if not called then batch.finish('failed', tostring(ok)); return end
      self.cleanupPhase = 'verifying'
      local deadline = now() + 1.5
      local function verify()
        if not guard() then return end
        ctx.refresh()
        local verifiedList = ctx.workspaces()
        if not validCleanupSnapshot(verifiedList, batch.topology) then
          batch.finish('failed', 'niepelny odczyt po usunieciu biurka'); return
        end
        if not policy.resolve(target, verifiedList) then
          for _, workspace in ipairs(verifiedList) do
            if workspace.spaceUUID == target.spaceUUID then
              batch.finish('cancelled', 'target-relocated'); return
            end
          end
          self.emptySince[target.spaceID] = nil
          ctx.release(target)
          self.cleanupDone = self.cleanupDone + 1
          nextCandidate(false)
        elseif now() < deadline and ok then batch.timer = later(0.25, verify)
        else batch.finish('failed', err or 'macOS nie potwierdzil usuniecia biurka') end
      end
      batch.timer = later(0.35, verify)
    end
    if self:checkSessionLock() or self.paused or batch.generation ~= self.generation
        or batch.topology ~= screenSignature() or missionControlVisible() or mouseDown() then
      batch.finish('cancelled', self.locked and 'locked' or 'user-interaction'); return
    end
    self.cleanupPhase, batch.ownedMC = 'opening', true
    local opened, err = pcall(spaces.openMissionControl)
    if not opened then batch.finish('failed', tostring(err)); return end
    local function awaitOpen()
      if batch.finished then return end
      if self:checkSessionLock() or self.paused or batch.generation ~= self.generation
          or batch.topology ~= screenSignature() then
        batch.finish('cancelled', 'opening-interrupted'); return
      end
      if mouseDown() then batch.finish('cancelled', 'user-interaction'); return end
      if missionControlVisible() then step()
      elseif now() - batch.openedAt >= 1.5 then batch.finish('failed', 'Mission Control nie zostalo otwarte')
      else batch.timer = later(0.15, awaitOpen) end
    end
    batch.timer = later(0.35, awaitOpen)
  end
  function self:topologyChanged()
    local locked, changed = self:checkSessionLock()
    if locked or changed then return end -- Unlock already established its new baseline.
    if self.sessionCreateToken then self.sessionCreateToken = nil; self.busy = false end
    self.screenGeometry = screenGeometrySignature() or self.screenGeometry
    self:cancelCleanup('topology-changed')
    self.generation = self.generation + 1
    self.guardUntil = now() + 8
    self.emptySince = {}
    self.queue, self.queued = {}, {}
    self.births:resetPending()
    self.rebaseline = true
    ctx.refresh()
  end
  function self:tick()
    if self.shuttingDown then return end
    if self:checkSessionLock() then return end
    self:refreshMetadata()
    local uuids = {}
    for _, screen in ipairs(hs.screen.allScreens()) do uuids[#uuids + 1] = screen:getUUID() end
    table.sort(uuids)
    local topology = table.concat(uuids, '|')
    if self.topology ~= topology then self.topology = topology; self:topologyChanged() end
    self.missionControl = missionControlVisible()
    local interacting = self.missionControl or mouseDown()
    if interacting or self.interacting then
      self.layoutGuardUntil = now() + 1.5
      for _, prior in pairs(self.observed) do prior.candidate = nil; prior.samples = 0 end
    end
    self.interacting = interacting
    -- Mission Control does not emit a Space-switch event for every reorder.
    -- Poll native identity/order even when paused or while a move is finishing.
    self:observeLayout(interacting)
    if interacting or now() < self.guardUntil or now() < self.layoutGuardUntil or self.busy then return end
    local learningMove = false
    for _, window in ipairs(windows()) do
      if ctx.managed(window) then
        local id, spaceID, key = window:id(), location(window), appKey(window)
        local app = window:application()
        local pid = app and app:pid()
        local prior = self.observed[id]
        local locationChanged = prior and prior.pid == pid and spaceID and prior.spaceID and spaceID ~= prior.spaceID
        if self.rebaseline then
          stamp(window)
        elseif not prior or prior.app ~= key or prior.pid ~= pid then
          stamp(window)
        elseif locationChanged then
          learningMove = true
          if self.session then self.session:cancelGroup(key) end
          -- A user drag takes precedence over an assignment that was waiting
          -- in the queue when Mission Control opened.
          if self.queued[id] then
            self.queued[id] = nil
            for index = #self.queue, 1, -1 do
              if self.queue[index].id == id then table.remove(self.queue, index) end
            end
          end
          if prior.candidate == spaceID and not mouseDown() then
            prior.samples = (prior.samples or 0) + 1
            if prior.samples >= 2 then
              local rule = ctx.rule(window)
              -- Disconnects/fullscreen transitions must not rewrite the home monitor.
              if not self.paused and (not rule or not rule.screenUUID or screenPresent(rule.screenUUID)) then
                for _, ws in ipairs(ctx.workspaces()) do
                  if ws.spaceID == spaceID then record(window, ws, true); break end
                end
              else stamp(window) end
            end
          else prior.candidate = spaceID; prior.samples = 0 end
        elseif not spaceID or not prior.spaceID then stamp(window)
        else prior.candidate = nil; prior.samples = 0 end
        if self.paused or self.rebaseline or locationChanged then
          self.births:take(id, pid, now()) -- Baselines and manual moves cancel pending placement.
        elseif spaceID and self.births:take(id, pid, now()) then
          -- A new AX window can arrive before its Space is readable. Keep its
          -- birth pending until that location is available, within the same TTL.
          local intent = followIntent(window)
          if intent and self.session and self.session:claims(key) then
            if self.session:isAutoLaunchPending(key) then intent = nil
            else self.session:cancelGroup(key) end
          end
          self:enqueue(window, true, intent)
        end
      end
    end
    self.rebaseline = false
    -- Keep identity history when AX temporarily omits a Space/window. Returning
    -- to a desktop is discovery, not permission to arrange its existing windows.
    if self.paused or learningMove or mouseDown() or not spaces.screensHaveSeparateSpaces() then return end
    if self.session and self.session:tick() then return end
    local nextItem = table.remove(self.queue, 1)
    if nextItem then
      self.queued[nextItem.id] = nil
      if nextItem.window:id() then self:apply(nextItem.window, nextItem.auto, nextItem.follow) end
      return
    end
    local occupied = self:occupancy()
    for id, isOccupied in pairs(occupied) do
      if isOccupied == false then self.emptySince[id] = self.emptySince[id] or now()
      else self.emptySince[id] = nil end
    end
    for id in pairs(self.emptySince) do if occupied[id] ~= false then self.emptySince[id] = nil end end
    if self.cleanupEnabled and now() - self.lastCleanup > 3 then self.lastCleanup = now(); self:cleanup() end
  end
  function self:resume()
    if self.shuttingDown then
      self.shuttingDown = false
      if self.session then self.session:thaw() end
    end
    self.paused = false; self.lastError = nil; self.cleanupEnabled = true
    if self.inputWatcher then self.inputWatcher:start() end
    self.guardUntil = now() + 2; self.rebaseline = true
    self.births:resetPending()
    hs.settings.set('deskpilot.paused.v2', false)
  end
  function self:pause()
    if self.sessionCreateToken then self.sessionCreateToken = nil; self.busy = false end
    self:cancelCleanup('paused')
    self.paused = true
    self.generation = self.generation + 1
    self.queue, self.queued = {}, {}
    self.births:resetPending()
    hs.settings.set('deskpilot.paused.v2', true)
  end
  function self:status()
    local locked = self:checkSessionLock()
    local status = { paused = self.paused, busy = self.busy, queued = #self.queue, locked = locked,
      lastError = self.lastError, cleanupEnabled = self.cleanupEnabled,
      cleaning = self.cleaning == true, cleanupPhase = self.cleanupPhase,
      cleanupPlanned = self.cleanupPlanned or 0, cleanupDone = self.cleanupDone or 0,
      cleanupPending = self.cleanupPending or 0, cleanupSkipped = self.cleanupSkipped or 0,
      metadataError = self.metadataError, metadataReads = self.metadataReads or 0,
      separateSpaces = spaces.screensHaveSeparateSpaces(),
      placementMode = 'new-windows-only', automaticResize = false, automaticFocus = ctx.prepareFollow ~= nil,
      followNewWindows = ctx.prepareFollow ~= nil, followStartupQuiet = now() < self.followQuietUntil,
      settling = now() < self.guardUntil or now() < self.layoutGuardUntil,
      missionControl = self.missionControl, layoutRevision = self.layoutRevision,
      layoutChangedAt = self.layoutChangedAt, layoutChange = self.layoutChange,
      layoutMessage = self.layoutMessage, layoutChangedScreens = self.layoutChangedScreens }
    if self.session then
      for key, value in pairs(self.session:status()) do status[key] = value end
    end
    return status
  end
  function self:shutdown()
    self.shuttingDown = true
    -- Keep the saved auto-start preference. An explicit resume can recover if
    -- macOS shutdown was cancelled by an application's unsaved-document prompt.
    self.paused = true
    if self.inputWatcher then self.inputWatcher:stop() end
    if self.sessionCreateToken then self.sessionCreateToken = nil; self.busy = false end
    if self.session then self.session:freeze() end
    self.generation = self.generation + 1
    self:cancelCleanup('shutdown')
    self.queue, self.queued = {}, {}
    self.births:resetPending()
    if self.nativeTask then pcall(function() self.nativeTask:terminate() end) end
  end
  function self:start()
    -- Accessibility cannot enumerate never-visited Spaces. Discover their
    -- existing windows on each Space visit and retain them in the filter.
    hs.window.filter.forceRefreshOnSpaceChange = true
    self.filter = hs.window.filter.new(false):setDefaultFilter({ allowRoles = 'AXStandardWindow' })
    if hs.eventtap.new and hs.eventtap.event then
      local events = hs.eventtap.event.types
      self.inputWatcher = hs.eventtap.new({ events.leftMouseDown, events.rightMouseDown,
        events.keyDown }, function() self:noteUserInput(); return false end):start()
    end
    self.filter:subscribe(hs.window.filter.windowCreated, function(window)
      if self:checkSessionLock() then return end
      local id = window and window:id()
      if not id then return end
      local prior, app = self.observed[id], window:application()
      if ctx.forgetWindow and prior and app and prior.pid ~= app:pid() then ctx.forgetWindow(window:id()) end
      if not prior or (app and prior.pid ~= app:pid()) then stamp(window) end
      -- Native metadata and tick() decide whether this is genuinely new.
    end)
    self.screenGeometry = screenGeometrySignature()
    self.screenWatcher = hs.screen.watcher.new(function()
      -- Launching an app can resize the Dock and trigger a screen notification.
      -- Only physical display identity/full geometry requires a new baseline.
      local geometry = screenGeometrySignature()
      if not geometry or geometry == self.screenGeometry then return end
      local hadGeometry = self.screenGeometry ~= nil
      self.screenGeometry = geometry
      if hadGeometry then
        self.topology = screenSignature() -- The polling tick must not reset it a second time.
        self:topologyChanged()
      end
    end):start()
    self.spaceWatcher = hs.spaces.watcher.new(function() ctx.refresh() end):start()
    self.wakeWatcher = hs.caffeinate.watcher.new(function(event)
      if hs.caffeinate.watcher.systemWillPowerOff and event == hs.caffeinate.watcher.systemWillPowerOff then
        self:shutdown(); return
      end
      if event == hs.caffeinate.watcher.systemDidWake or event == hs.caffeinate.watcher.screensDidWake then
        self:topologyChanged()
      end
    end):start()
    self.paused = hs.settings.get('deskpilot.paused.v2') ~= false
    self.timer = hs.timer.doEvery(1, function()
      local ok, err = pcall(function() self:tick() end)
      if not ok then self:pause(); report(tostring(err)) end
    end)
    self:tick()
  end
  return self
end
return M
