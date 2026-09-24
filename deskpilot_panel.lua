-- Native, local-only slide-out interface. All actions resolve fresh Space UUIDs.
local model = require('deskpilot_panel_model')
local Guard = require('deskpilot_panel_guard')
local Previews = require('deskpilot_previews')
local M = {}
local ignored = { ['org.hammerspoon.Hammerspoon'] = true, ['com.apple.dock'] = true,
  ['com.apple.controlcenter'] = true, ['com.apple.notificationcenterui'] = true,
  ['com.apple.WindowManager'] = true, ['com.apple.wallpaper.agent'] = true }

function M.new(ctx)
  local self = { visible = false, ready = false, icons = {}, lastError = nil,
    previews = Previews.new(hs, ctx.capturePreview), previewChoices = {}, captureQueue = {}, captureGeneration = 0,
    previewEnabled = hs.settings.get('deskpilot.previews.enabled.v1') == true }
  local function icon(bundle)
    if not bundle or bundle == '' then return nil end
    if self.icons[bundle] == nil then
      local ok, value = pcall(function()
        local image = hs.image.imageFromAppBundle(bundle)
        return image and image:setSize({ w = 48, h = 48 }):encodeAsURLString(false, 'PNG')
      end)
      self.icons[bundle] = ok and value or false
    end
    return self.icons[bundle] or nil
  end
  local function sourceWindow()
    local window = self.source
    if window and window:id() and ctx.managed(window) then return window end
  end
  local function screenLocked()
    local ok, session = pcall(hs.caffeinate.sessionProperties)
    return not ok or type(session) ~= 'table' or session.CGSSessionScreenIsLocked == true
  end
  function self:snapshot(includeImages)
    local list, descriptions, spaceWindows, apps = ctx.workspaces(), {}, {}, {}
    for _, app in ipairs(hs.application.runningApplications()) do apps[app:pid()] = app end
    for _, item in ipairs(ctx.metadata() or {}) do
      local id, app = item.kCGWindowNumber, apps[item.kCGWindowOwnerPID]
      local bundle = app and app:bundleID()
      if ignored[bundle] or item.kCGWindowLayer ~= 0 then descriptions[id] = false
      else
        local bounds = item.kCGWindowBounds
        descriptions[id] = {
          frame = bounds and { x = bounds.X, y = bounds.Y, w = bounds.Width, h = bounds.Height },
          -- Chrome can expose its CG windows before AX discovers their profile.
          -- Authorize the picture by the running owner's PID and bundle, not
          -- by a page title or profile name. Assignment remains separate.
          bundle = bundle, pid = item.kCGWindowOwnerPID, previewAllowed = bundle == 'com.google.Chrome',
          label = ctx.metadataLabel(id, item.kCGWindowOwnerPID, bundle)
            or (app and app:name()) or item.kCGWindowOwnerName or 'Okno', icon = icon(bundle) }
      end
    end
    for _, window in ipairs(ctx.windows()) do
      pcall(function()
        local id, app = window:id(), window:application()
        if not id or not app then return end
        local bundle = app:bundleID()
        if ignored[bundle] then descriptions[id] = false; return end
        local subrole = window:subrole()
        if subrole ~= 'AXStandardWindow' then
          if subrole then descriptions[id] = false end
          return
        end
        descriptions[id] = { frame = window:frame(), label = ctx.label(window),
          icon = icon(bundle), minimized = window:isMinimized(), bundle = bundle, pid = app:pid(),
          previewAllowed = ctx.previewAllowed(window), axStandard = true }
      end)
    end
    local prepared = {}
    for _, ws in ipairs(list) do
      if ws.spaceID and ws.screen and ws.screenUUID then
        local entry = {}
        for key, value in pairs(ws) do entry[key] = value end
        entry.screenFrame = ws.screen:fullFrame()
        prepared[#prepared + 1] = entry
        local ok, ids = pcall(hs.spaces.windowsForSpace, ws.spaceID)
        spaceWindows[ws.spaceID] = ok and type(ids) == 'table' and ids or nil
      end
    end
    local source = sourceWindow()
    local monitors = model.build(prepared, descriptions, spaceWindows, hs.spaces.activeSpaces() or {})
    -- Rendering and diagnostics only read the cache. Capture has its own finite
    -- queue, so status polling and hover cannot start another screenshot.
    local permission = self.previews:beginFrame(self.previewEnabled, self.visible, false)
    for _, monitor in ipairs(monitors) do for _, candidate in ipairs(monitor.spaces) do
      local representative, chosen, largest, largestArea
      for index = #candidate.windows, 1, -1 do
        local window = candidate.windows[index]
        local desc = descriptions[window.id]
        local preview = self.previews:get(window.id, desc.pid, desc.bundle,
          desc.previewAllowed == true, hs.timer.secondsSinceEpoch())
        if not preview.protected then
          if not representative and desc.axStandard then representative = window end
          local area = window.w * window.h
          if not largestArea or area > largestArea then largest, largestArea = window, area end
        end
        if window.id == self.previewChoices[candidate.id] then chosen = window end
        if includeImages and self.visible then
          window.previewImage, window.previewAt = preview.image, preview.at
          window.protected, window.previewUnavailable = preview.protected, preview.unavailable
        end
      end
      -- Chrome's CG list also contains narrow helper windows. AX standard
      -- windows are authoritative; until AX arrives use the largest CG area.
      representative = chosen or representative or largest or candidate.windows[#candidate.windows]
      candidate.previewWindowID = representative and representative.id
    end end
    local display, workspace, selected
    for _, monitor in ipairs(monitors) do
      if monitor.id == (self.previewMonitor or self.preferredMonitor) then display = monitor; break end
    end
    display = display or monitors[1]
    if display then
      self.previewMonitor = display.id
      for _, candidate in ipairs(display.spaces) do
        if candidate.id == self.previewSpace then workspace = candidate; break end
      end
      if not workspace then
        for _, candidate in ipairs(display.spaces) do if candidate.active then workspace = candidate; break end end
      end
      workspace = workspace or display.spaces[1]
    end
    if workspace then
      self.previewSpace = workspace.id
      for _, window in ipairs(workspace.windows) do
        if window.id == self.previewWindow then selected = window; break end
      end
      if not selected then
        for _, window in ipairs(workspace.windows) do
          if window.id == workspace.previewWindowID then selected = window; break end
        end
      end
    end
    self.previewWindow = selected and selected.id
    self.previewDescriptions = descriptions
    return { monitors = monitors, preview = { enabled=self.previewEnabled, permission=permission,
        mode='gallery', spaceID=self.previewSpace, windowID=self.previewWindow },
      status = ctx.status(), preferredMonitor = self.preferredMonitor,
      sourceLabel = source and ctx.label(source), now = hs.timer.secondsSinceEpoch() }
  end
  local function visibleStatus(status)
    local result = {}
    for _, key in ipairs({ 'paused', 'busy', 'settling', 'missionControl', 'locked', 'lastError',
        'followNewWindows', 'followStartupQuiet', 'organizing', 'organizePending', 'organizePlanned', 'organizeDone', 'organizeMessage',
        'layoutRevision', 'layoutChangedAt', 'layoutMessage', 'metadataError', 'cleanupEnabled', 'cleaning',
        'cleanupPhase', 'cleanupPlanned', 'cleanupDone', 'cleanupPending', 'cleanupSkipped',
        'sessionPhase', 'sessionPending', 'sessionRestored', 'sessionSavedAt', 'sessionMonitorCount',
        'sessionLaunchPending', 'sessionLaunchFailed', 'sessionRestoreFailed' }) do result[key] = status[key] end
    return result
  end
  function self:refresh()
    if screenLocked() then self:hide(); return end
    if not self.visible or not self.ready then return end
    local ok, data = pcall(function() return self:snapshot(true) end)
    if not ok then self.lastError = tostring(data); return end
    self.lastData = data
    self.statusSignature = hs.json.encode(visibleStatus(data.status))
    self.layoutRevision, self.permissionLast = data.status.layoutRevision, data.preview.permission
    self.view:evaluateJavaScript('window.DeskPilotPanel.render(' .. hs.json.encode(data) .. ')', function(_, err)
      if err and err.code ~= 0 then self.lastError = hs.inspect(err) end
    end)
  end
  function self:pollStatus()
    if not self.visible or not self.ready then return end
    if screenLocked() then self:hide(); return end
    local permission = hs.screenRecordingState(false)
    local status = ctx.status()
    if permission ~= self.permissionLast or status.layoutRevision ~= self.layoutRevision then
      local permissionGranted = permission and permission ~= self.permissionLast
      if not permission then self:cancelCaptures(); self.previews:clear(); self.lastData = nil
        self.view:evaluateJavaScript('window.DeskPilotPanel.clearPreviews()') end
      self:refresh()
      if permissionGranted then self:startGallery() end
      return
    end
    local value = visibleStatus(status)
    local signature = hs.json.encode(value)
    if signature ~= self.statusSignature then
      self.statusSignature = signature
      self.view:evaluateJavaScript('window.DeskPilotPanel.updateStatus(' .. hs.json.encode(value) .. ')')
    end
  end
  function self:cancelCaptures()
    self.captureGeneration = self.captureGeneration + 1
    self.captureQueue, self.captureInFlight = {}, nil
    if self.captureTimer then self.captureTimer:stop(); self.captureTimer = nil end
  end
  function self:applyPreview(job, preview)
    local patch = { spaceID = job.spaceID, windowID = job.windowID, image = preview.image,
      at = preview.at, protected = preview.protected == true, unavailable = preview.unavailable == true }
    local retained = self.previews:cachedIDs()
    for _, monitor in ipairs(self.lastData and self.lastData.monitors or {}) do
      for _, workspace in ipairs(monitor.spaces) do for _, window in ipairs(workspace.windows) do
        if window.previewImage and not retained[window.id] then
          window.previewImage, window.previewAt = nil, nil
          self.view:evaluateJavaScript('window.DeskPilotPanel.applyPreview(' .. hs.json.encode({
            spaceID=workspace.id, windowID=window.id, protected=window.protected == true, unavailable=false }) .. ')')
        end
      end end
      for _, workspace in ipairs(monitor.spaces) do if workspace.id == job.spaceID then
        for _, window in ipairs(workspace.windows) do if window.id == job.windowID then
          window.previewImage, window.previewAt = patch.image, patch.at
          window.protected, window.previewUnavailable = patch.protected, patch.unavailable
        end end
      end end
    end
    self.view:evaluateJavaScript('window.DeskPilotPanel.applyPreview(' .. hs.json.encode(patch) .. ')')
  end
  function self:scheduleCapture()
    if self.captureTimer or self.captureInFlight or #self.captureQueue == 0 then return end
    local generation = self.captureGeneration
    self.captureTimer = hs.timer.doAfter(0.15, function()
      self.captureTimer = nil
      if generation ~= self.captureGeneration or not self.visible or not self.ready then return end
      if screenLocked() then self:hide(); return end
      local job = table.remove(self.captureQueue, 1)
      if not job then return end
      local ok, err = pcall(function()
        local data = self:snapshot(false)
        local desc = self.previewDescriptions[job.windowID]
        local present = false
        for _, monitor in ipairs(data.monitors) do if monitor.id == job.monitorID then
          for _, workspace in ipairs(monitor.spaces) do if workspace.id == job.spaceID then
            for _, window in ipairs(workspace.windows) do if window.id == job.windowID then present = true end end
          end end
        end end
        if not present or self.previewMonitor ~= job.monitorID or not desc
            or desc.pid ~= job.pid or desc.bundle ~= job.bundle then return end
        if not self.previews:beginFrame(self.previewEnabled, self.visible, true) or not self.previewEnabled then
          self:cancelCaptures(); self.previews:clear(); self.lastData = nil
          self.view:evaluateJavaScript('window.DeskPilotPanel.clearPreviews()'); return
        end
        self.captureInFlight = job
        self.previews:capture(job.windowID, desc.pid, desc.bundle, desc.previewAllowed == true,
          hs.timer.secondsSinceEpoch(), job.force, function(preview)
            if generation ~= self.captureGeneration or not self.visible then return end
            self.captureInFlight = nil
            if screenLocked() then self:hide(); return end
            self:applyPreview(job, preview)
            self:scheduleCapture()
          end)
      end)
      if not ok then self.lastError = tostring(err); self.captureInFlight = nil end
      self:scheduleCapture()
    end)
  end
  local function previewJob(workspace, monitorID, windowID, force)
    local desc = self.previewDescriptions and self.previewDescriptions[windowID]
    if not desc then return end
    return { spaceID = workspace.id, monitorID = monitorID, windowID = windowID,
      pid = desc.pid, bundle = desc.bundle, force = force == true }
  end
  function self:startGallery()
    if not self.visible or not self.ready or not self.previewEnabled then return end
    self.captureQueue = {}
    local count = 0
    for _, monitor in ipairs(self.lastData and self.lastData.monitors or {}) do
      if monitor.id == self.previewMonitor then for _, workspace in ipairs(monitor.spaces) do
        if workspace.previewWindowID and count < 32 then
          local job = previewJob(workspace, monitor.id, workspace.previewWindowID, false)
          if job and not (self.captureInFlight and self.captureInFlight.windowID == job.windowID) then
            self.captureQueue[#self.captureQueue + 1] = job; count = count + 1
          end
        end
      end end
    end
    self:scheduleCapture()
  end
  function self:requestPreview(force)
    self:refresh()
    for _, monitor in ipairs(self.lastData and self.lastData.monitors or {}) do
      for _, workspace in ipairs(monitor.spaces) do if workspace.id == self.previewSpace then
        local job = previewJob(workspace, monitor.id, self.previewWindow, force)
        if not job then return end
        for index = #self.captureQueue, 1, -1 do
          if self.captureQueue[index].spaceID == workspace.id then table.remove(self.captureQueue, index) end
        end
        table.insert(self.captureQueue, 1, job)
        self:scheduleCapture(); return
      end end
    end
  end
  function self:hide()
    self.visible = false
    self:cancelCaptures()
    self.previews:clear(); self.lastData = nil
    if self.timer then self.timer:stop(); self.timer = nil end
    if self.outside then self.outside:stop() end
    if self.keys then self.keys:stop() end
    if self.animation then self.animation:stop(); self.animation = nil end
    if self.view then
      if self.ready then self.view:evaluateJavaScript('window.DeskPilotPanel.clearPreviews()') end
      self.view:hide(0.10)
    end
  end
  local function safeAction(body)
    if type(body) ~= 'table' or type(body.action) ~= 'string' then return end
    if body.action == 'ready' then self.ready = true; self:refresh(); self:startGallery(); return end
    if not self.visible then return end
    if screenLocked() then self:hide(); return end
    local action = body.action
    if action == 'enablePreviews' then
      self.previewEnabled = true
      hs.settings.set('deskpilot.previews.enabled.v1', true)
      hs.screenRecordingState(true)
      self:refresh(); self:startGallery(); return
    end
    if action == 'disablePreviews' then
      self.previewEnabled = false; self.previews:clear(); self.lastData = nil
      self:cancelCaptures()
      hs.settings.set('deskpilot.previews.enabled.v1', false)
      self.view:evaluateJavaScript('window.DeskPilotPanel.clearPreviews()')
      self:refresh(); return
    end
    if action == 'selectMonitor' then
      if self.previewMonitor == body.id then return end
      for _, workspace in ipairs(ctx.workspaces()) do
        if workspace.screenUUID == body.id then
          self.previewMonitor = body.id; self.previewSpace = nil; self.previewWindow = nil
          self:cancelCaptures()
          self.previews:clear(); self.lastData = nil
          self.view:evaluateJavaScript('window.DeskPilotPanel.clearPreviews()')
          self:refresh(); self:startGallery(); break
        end
      end
      return
    end
    if action == 'selectSpace' or action == 'refreshPreview' then
      local target = model.resolve(body.id, ctx.workspaces())
      if not target then return end
      if self.previewSpace ~= body.id then self.previewWindow = nil end
      if self.previewMonitor ~= target.screenUUID then
        self:cancelCaptures(); self.previews:clear(); self.lastData = nil
        self.view:evaluateJavaScript('window.DeskPilotPanel.clearPreviews()')
      end
      self.previewMonitor, self.previewSpace = target.screenUUID, target.id
      if action == 'refreshPreview' then self:requestPreview(true) else self:refresh() end
      return
    end
    if action == 'selectWindow' then
      local id = tonumber(body.id)
      local data = self:snapshot(false)
      for _, monitor in ipairs(data.monitors) do for _, workspace in ipairs(monitor.spaces) do
        if workspace.id == self.previewSpace then for _, window in ipairs(workspace.windows) do
          if window.id == id then
            self.previewWindow = id; self.previewChoices[workspace.id] = id
            self:requestPreview(false); return
          end
        end end
      end end
      return
    end
    if action == 'close' then self:hide(); return end
    if action == 'pause' then ctx.pause(); self:refresh(); return end
    if action == 'resume' then ctx.resume(); self:refresh(); return end
    if action == 'settings' then self:hide(); ctx.settings(); return end
    if action == 'toggleFollow' then
      if type(ctx.toggleFollow) == 'function' then ctx.toggleFollow(); self:pollStatus() end
      return
    end
    local status = ctx.status()
    if action == 'organize' then
      if status.paused or status.locked or status.organizing or status.organizePending then
        hs.alert.show(status.paused and 'DeskPilot: wznów automatykę przed organizowaniem biurek.'
          or 'DeskPilot: organizowanie już oczekuje lub trwa.')
        self:pollStatus()
        return
      end
      if type(ctx.organize) == 'function' then ctx.organize(sourceWindow()); self:pollStatus() end
      return
    end
    if status.busy or status.missionControl or status.organizing then
      hs.alert.show('DeskPilot: poczekaj na zakończenie bieżącego ruchu.')
      return
    end
    if action == 'missionControl' then self:hide(); ctx.missionControl(); return end
    local target = model.resolve(body.id, ctx.workspaces())
    if not target then return end -- A stale card must never target a recycled number.
    if action == 'switch' then self:hide(); ctx.switch(target)
    elseif action == 'move' then
      local source = sourceWindow()
      if source then self:hide(); ctx.move(source, target) end
    elseif action == 'rename' then self:hide(); ctx.rename(target) end
  end
  function self:create(frame)
    local file = io.open(hs.configdir .. '/deskpilot_panel.html', 'r')
    if not file then error('Brak pliku deskpilot_panel.html; uruchom instalator DeskPilot.') end
    local html = file:read('*a'); file:close()
    self.controller = hs.webview.usercontent.new('deskpilot'):setCallback(function(message)
      -- Hammerspoon wraps WKScriptMessage payload in .body.
      local body = Guard.message(message, self.view)
      local ok, err = pcall(safeAction, body)
      if not ok then self.lastError = tostring(err); hs.printf('DeskPilot panel: %s', self.lastError) end
    end)
    self.view = hs.webview.new(frame, { javaScriptEnabled = true, javaScriptCanOpenWindowsAutomatically = false,
      privateBrowsing = true }, self.controller)
      :windowStyle({ 'borderless', 'nonactivating' })
      :behaviorAsLabels({ 'canJoinAllSpaces', 'transient', 'ignoresCycle' })
      :level(hs.drawing.windowLevels.floating):shadow(true):transparent(true)
      :allowTextEntry(true):allowNewWindows(false):deleteOnClose(false):windowTitle('DeskPilot — Twoje biurka')
    self.view:policyCallback(function(action, _, detail)
      if action == 'navigationAction' then
        local url = detail and detail.request and detail.request.URL
        return Guard.localURL(url)
      end
      if action == 'navigationResponse' then
        return detail and detail.response and Guard.localURL(detail.response.URL) or false
      end
      return false
    end)
    self.view:windowCallback(function(action)
      if action == 'closing' then self:hide() end
    end)
    self.view:html(html, 'about:blank')
    self.outside = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.rightMouseDown }, function(event)
      if self.visible then
        local point, bounds = event:location(), self.view:frame()
        if point.x < bounds.x or point.x > bounds.x + bounds.w or point.y < bounds.y or point.y > bounds.y + bounds.h then
          -- Menu click is handled by the toggle callback itself.
          local anchor = ctx.anchor()
          if not anchor or point.x < anchor.x or point.x > anchor.x + anchor.w or point.y < anchor.y or point.y > anchor.y + anchor.h then
            self:hide()
          end
        end
      end
      return false
    end)
    self.keys = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
      local modifiers = event:getFlags()
      if event:getKeyCode() == hs.keycodes.map.escape and self.visible
          and not modifiers.ctrl and not modifiers.alt and not modifiers.cmd then
        self:hide(); return true
      end
      return false
    end)
    self.lockWatcher = hs.caffeinate.watcher.new(function(event)
      if event == hs.caffeinate.watcher.screensDidLock then self:hide() end
    end):start()
  end
  function self:show()
    if screenLocked() then return end
    self.source = hs.window.focusedWindow()
    local screen = hs.mouse.getCurrentScreen() or hs.screen.primaryScreen()
    if not screen then return end
    self.preferredMonitor = screen:getUUID()
    local bounds = screen:frame()
    local width, height = math.min(700, bounds.w - 24), math.min(860, bounds.h - 24)
    local frame = { x = bounds.x + bounds.w - width - 12, y = bounds.y + 12, w = width, h = height }
    if not self.view then self:create(frame) end
    self.view:frame(frame)
    self.visible, self.lastError = true, nil
    self.view:show(0.15)
    -- A small slide towards the display edge, bounded inside this display.
    local start = hs.timer.secondsSinceEpoch()
    self.animation = hs.timer.doEvery(0.016, function()
      local progress = math.min(1, (hs.timer.secondsSinceEpoch() - start) / 0.18)
      self.view:topLeft({ x = frame.x + 10 * (1 - progress) ^ 3, y = frame.y })
      if progress >= 1 then self.animation:stop(); self.animation = nil end
    end)
    self.outside:start(); self.keys:start()
    self:refresh(); self:startGallery()
    -- This poll only compares tiny status fields. It does not enumerate or
    -- capture windows, serialize images, or rebuild the panel every second.
    self.timer = hs.timer.doEvery(1, function() self:pollStatus() end)
  end
  function self:toggle() if self.visible then self:hide() else self:show() end end
  function self:diagnostics()
    return { visible = self.visible, ready = self.ready, lastError = self.lastError,
      frame = self.view and self.view:frame() }
  end
  return self
end
return M
