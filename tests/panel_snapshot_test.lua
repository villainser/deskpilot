local source = debug.getinfo(1, 'S').source:sub(2)
local directory = source:match('^(.*[/\\])') or './'
package.path = directory .. '../?.lua;' .. package.path
local Panel = require('deskpilot_panel')
local passed = 0
local jpeg = 'data:image/jpeg;base64,YWJjZA=='

local function equal(actual, expected, message)
  assert(actual == expected, (message or 'unexpected value') .. ': expected '
    .. tostring(expected) .. ', got ' .. tostring(actual))
end

local function test(name, run)
  run(); passed = passed + 1; print('ok - ' .. name)
end

local function fixture(options)
  options = options or {}
  local e = { captures = {}, windows = {}, now = 100, status = {layoutRevision=0}, metadataCalls=0, scripts={}, timers={}, permission=true, patches={} }
  local app = {
    pid = function() return 100 end,
    bundleID = function() return options.bundle or 'com.google.Chrome' end,
    name = function() return 'Application' end,
  }
  local image = {
    size = function() return { w = 320, h = 200 } end,
    encodeAsURLString = function(_, scale, format)
      equal(scale, false); equal(format, 'JPEG'); return jpeg
    end,
  }
  local frame = { x = 20, y = 30, w = 320, h = 200 }
  if options.ax then
    e.windows[1] = {
      id = function() return options.axID or 1 end,
      application = function() return app end,
      subrole = function() return options.subrole or 'AXStandardWindow' end,
      frame = function() return frame end,
      isMinimized = function() return false end,
      title = function() return 'Page without a profile suffix' end,
    }
  end
  hs = {
    settings = { get = function() return true end },
    application = { runningApplications = function() return options.unknownPID and {} or { app } end },
    image = { imageFromAppBundle = function() return nil end },
    spaces = {
      windowsForSpace = function(spaceID)
        local count = options.multiple and 3 or 1
        local first = (spaceID / 10 - 1) * count + 1
        local ids = {}; for id=first,first+count-1 do ids[#ids+1]=id end
        return ids
      end,
      activeSpaces = function() return { monitor = 10 } end,
    },
    timer = { secondsSinceEpoch = function() return e.now end,
      doAfter = function(delay, callback)
        local timer = { at=e.now+delay, callback=callback, stop=function(self) self.stopped=true end }
        e.timers[#e.timers+1]=timer; return timer
      end },
    caffeinate = { sessionProperties = function() return { CGSSessionScreenIsLocked=e.locked } end },
    json = { encode = function(value)
      if value.spaceID and value.windowID then e.patches[#e.patches+1]=value end
      local fields={}; for k,v in pairs(value) do fields[#fields+1]=k..'='..tostring(v) end
      table.sort(fields); return table.concat(fields,',')
    end },
    screenRecordingState = function(prompt) equal(prompt, false); return e.permission end,
    window = { snapshotForID = function(id, transparency)
      equal(transparency, false)
      e.captures[#e.captures + 1] = id
      return image
    end },
  }
  e.context = {
    workspaces = function()
      local spaces = {}
      for index=1,(options.spaces or 1) do
        spaces[#spaces+1]={ id=index==1 and 'space-one' or ('space-'..index),
          spaceID=index*10, screenUUID='monitor', name='Desktop '..index, index=index, localIndex=index,
          screen={fullFrame=function() return {x=0,y=0,w=1000,h=800} end} }
      end
      return spaces
    end,
    metadata = function()
      e.metadataCalls = e.metadataCalls + 1
      local rows={}; for id=1,(options.multiple and 3 or 1)*(options.spaces or 1) do
      rows[#rows+1]={ kCGWindowNumber = id, kCGWindowOwnerPID = 100,
        kCGWindowOwnerName = 'Google Chrome', kCGWindowLayer = options.layer or 0,
        kCGWindowBounds = { X=frame.x, Y=frame.y, Width=frame.w, Height=options.rawHeights and options.rawHeights[id] or frame.h } }
      end; return rows
    end,
    windows = function() return e.windows end,
    metadataLabel = function() return nil end,
    label = function() return 'Chrome · nierozpoznany profil' end,
    previewAllowed = function(window) return window:application() ~= nil end,
    status = function() return e.status end,
  }
  e.panel = Panel.new(e.context)
  e.panel.visible, e.panel.ready, e.panel.preferredMonitor = true, true, 'monitor'
  e.panel.view={hide=function() end,evaluateJavaScript=function(_,script,callback)
    e.scripts[#e.scripts+1]=script
    if callback then callback(nil,{code=0}) end
  end}
  function e:snapshot(includeImages)
    return self.panel:snapshot(includeImages).monitors[1].spaces[1]
  end
  function e:advance(seconds)
    local target = self.now + seconds
    while true do
      local nextTimer
      for _, timer in ipairs(self.timers) do
        if not timer.stopped and timer.at <= target and (not nextTimer or timer.at < nextTimer.at) then nextTimer=timer end
      end
      if not nextTimer then break end
      self.now=nextTimer.at; nextTimer.stopped=true; nextTimer.callback()
    end
    self.now=target
  end
  function e:capture()
    self.panel:requestPreview(false); self:advance(0.2)
    return self:snapshot(true)
  end
  return e
end

test('Chrome metadata receives a preview when Accessibility omits its window', function()
  local e = fixture()
  local window = e:capture().windows[1]
  equal(window.previewImage, jpeg)
  equal(window.protected, false)
  equal(#e.captures, 1); equal(e.captures[1], 1)
end)

test('a Chrome owner name without a known owner PID cannot authorize a preview', function()
  local e = fixture({ unknownPID = true })
  local window = e:capture().windows[1]
  equal(window.previewImage, nil); equal(window.protected, true)
  equal(#e.captures, 0)
end)

test('a Chrome owner name cannot override a different application bundle', function()
  local e = fixture({ bundle = 'com.example.Editor' })
  local window = e:capture().windows[1]
  equal(window.previewImage, nil); equal(window.protected, true)
  equal(#e.captures, 0)
end)

test('password manager images remain blocked even with Accessibility eligibility', function()
  local e = fixture({ bundle = 'com.bitwarden.desktop', ax = true })
  local window = e:capture().windows[1]
  equal(window.previewImage, nil); equal(window.protected, true)
  equal(#e.captures, 0)
end)

test('nonstandard WindowServer layers are excluded from Chrome previews', function()
  local e = fixture({ layer = 25 })
  local workspace = e:capture()
  equal(#workspace.windows, 0); equal(workspace.windowCount, 0)
  equal(#e.captures, 0)
end)

test('default diagnostics never capture or expose existing preview images', function()
  local e = fixture()
  equal(e:snapshot().windows[1].previewImage, nil)
  equal(#e.captures, 0)
  equal(e:capture().windows[1].previewImage, jpeg)
  local window = e:snapshot().windows[1]
  equal(window.previewImage, nil); equal(window.previewAt, nil)
  equal(#e.captures, 1)
end)

test('Accessibility Chrome previews do not require a recognizable profile suffix', function()
  local e = fixture({ ax = true })
  local window = e:capture().windows[1]
  equal(window.label, 'Chrome · nierozpoznany profil')
  equal(window.previewImage, jpeg); equal(window.protected, false)
  equal(#e.captures, 1)
end)

test('only the selected window is captured, even when a desktop has several Chrome windows', function()
  local e=fixture({multiple=true})
  local ws=e:capture()
  equal(#e.captures,1); equal(e.captures[1],1)
  local images=0; for _,w in ipairs(ws.windows) do if w.previewImage then images=images+1 end end
  equal(images,1)
  e.panel.previewWindow=2
  e:capture()
  equal(#e.captures,2); equal(e.captures[2],2)
end)

test('an idle open panel does not capture, enumerate windows or resend HTML image data', function()
  local e=fixture(); e.panel.ready=true
  e.panel:requestPreview(false); e:advance(0.2)
  local metadata,scripts=e.metadataCalls,#e.scripts
  for index=1,30 do e.now=e.now+10; e.panel:pollStatus() end
  equal(#e.captures,1); equal(e.metadataCalls,metadata); equal(#e.scripts,scripts)
end)

test('status-only changes send a small status update without snapshots or metadata scans', function()
  local e=fixture(); e.panel.ready=true; e.panel:requestPreview(false); e:advance(0.2)
  local metadata=e.metadataCalls
  e.status.paused=true; e.panel:pollStatus()
  equal(#e.captures,1); equal(e.metadataCalls,metadata)
  assert(e.scripts[#e.scripts]:find('DeskPilotPanel.updateStatus',1,true))
end)

test('layout refresh reuses the current image without capturing again', function()
  local e=fixture(); e.panel.ready=true; e.panel:requestPreview(false); e:advance(0.2)
  e.now=e.now+300; e.status.layoutRevision=1; e.panel:pollStatus()
  equal(#e.captures,1)
  equal(e.panel.lastData.monitors[1].spaces[1].windows[1].previewImage,jpeg)
end)

test('rendering cached snapshots never initiates a screenshot', function()
  local e=fixture({spaces=2,multiple=true})
  e.panel:snapshot(true); e.panel:refresh(); e.panel:snapshot(true)
  equal(#e.captures,0)
end)

test('one gallery pass captures each Space representative sequentially and then stops', function()
  local e=fixture({spaces=2,multiple=true})
  e.panel:refresh(); e.panel:startGallery()
  equal(#e.captures,0)
  e:advance(0.15); equal(#e.captures,1); equal(e.captures[1],1)
  e:advance(0.15); equal(#e.captures,2); equal(e.captures[2],4)
  equal(#e.patches,2)
  equal(e.patches[1].spaceID,'space-one'); equal(e.patches[2].spaceID,'space-2')
  local scripts, scans=#e.scripts,e.metadataCalls
  e:advance(60); e.panel:pollStatus()
  equal(#e.captures,2); equal(#e.scripts,scripts); equal(e.metadataCalls,scans)
  equal(e.panel.captureTimer,nil); equal(#e.panel.captureQueue,0)
end)

test('gallery pictures survive Space and window selection and explicit refresh affects only selection', function()
  local e=fixture({spaces=2,multiple=true})
  e.panel:refresh(); e.panel:startGallery(); e:advance(0.4)
  e.panel.previewSpace='space-2'; e.panel.previewWindow=4
  e.panel:requestPreview(false); e:advance(0.2); equal(#e.captures,2)
  e.panel.previewWindow=5; e.panel.previewChoices['space-2']=5
  e.panel:requestPreview(false); e:advance(0.2); equal(#e.captures,3)
  e.panel:requestPreview(true); e:advance(0.2); equal(#e.captures,4); equal(e.captures[4],5)
  local data=e.panel:snapshot(true)
  equal(data.monitors[1].spaces[1].windows[3].previewImage,jpeg)
  equal(data.monitors[1].spaces[2].previewWindowID,5)
end)

test('AX standard Chrome windows outrank raw auxiliary window rectangles', function()
  local e=fixture({multiple=true,ax=true,axID=2,rawHeights={[1]=700,[3]=700}})
  e.panel:refresh(); e.panel:startGallery(); e:advance(0.2)
  equal(e.captures[1],2)
end)

test('without AX the largest Chrome window is the representative instead of a narrow helper', function()
  local e=fixture({multiple=true,rawHeights={[1]=35,[2]=600,[3]=90}})
  e.panel:refresh(); e.panel:startGallery(); e:advance(0.2)
  equal(e.captures[1],2)
end)

test('known nonstandard AX windows are removed from gallery candidates', function()
  local e=fixture({multiple=true,ax=true,subrole='AXDialog'})
  e.panel:refresh(); e.panel:startGallery(); e:advance(0.2)
  equal(e.captures[1],2)
  equal(e.panel.lastData.monitors[1].spaces[1].windowCount,2)
end)

test('hiding or losing permission cancels queued gallery work', function()
  for _, action in ipairs({'hide','permission','lock'}) do
    local e=fixture({spaces=2})
    e.panel:refresh(); e.panel:startGallery()
    if action=='hide' then e.panel:hide()
    elseif action=='permission' then e.permission=false; e.panel:pollStatus()
    else e.locked=true end
    e:advance(1)
    equal(#e.captures,0); equal(#e.panel.captureQueue,0)
    equal(e.panel.captureTimer,nil)
  end
end)

test('gallery returns explicit protected state without capturing password managers', function()
  local e=fixture({bundle='com.bitwarden.desktop',ax=true})
  e.panel:refresh(); e.panel:startGallery(); e:advance(0.2)
  equal(#e.captures,0); equal(e.patches[1].protected,true)
end)

local function installActionBridge(e)
  hs.configdir = directory .. '..'
  e.actions, e.alerts = { organize = 0, toggleFollow = 0, pause = 0 }, {}
  hs.alert = { show = function(message) e.alerts[#e.alerts + 1] = message end }
  hs.printf = function() end
  local view = e.panel.view
  for _, method in ipairs({ 'windowStyle', 'behaviorAsLabels', 'level', 'shadow', 'transparent',
      'allowTextEntry', 'allowNewWindows', 'deleteOnClose', 'windowTitle', 'policyCallback', 'windowCallback', 'html' }) do
    view[method] = function(self) return self end
  end
  hs.webview = {
    usercontent = { new = function()
      return { setCallback = function(self, callback) e.callback = callback; return self end }
    end },
    new = function() return view end,
  }
  hs.drawing = { windowLevels = { floating = 1 } }
  hs.eventtap = { event = { types = { leftMouseDown = 1, rightMouseDown = 2, keyDown = 3 } },
    new = function() return { start = function(self) return self end, stop = function() end } end }
  hs.caffeinate.watcher = { screensDidLock = 'lock', new = function()
    return { start = function(self) return self end, stop = function() end }
  end }
  e.context.toggleFollow = function()
    e.actions.toggleFollow = e.actions.toggleFollow + 1
    e.status.followNewWindows = not e.status.followNewWindows
  end
  e.context.organize = function(sourceWindow)
    e.actions.organize = e.actions.organize + 1
    e.organizeSource = sourceWindow
    e.status.organizePending, e.status.organizing = true, false
    e.status.organizeMessage = 'Zlecenie przyjęte. Czekam na gotowy układ.'
    return true
  end
  e.context.pause = function()
    e.actions.pause = e.actions.pause + 1
    e.status.paused, e.status.organizing, e.status.organizePending = true, false, false
  end
  e.panel:create({ x = 0, y = 0, w = 700, h = 860 })
  function e:send(action)
    self.callback({ name = 'deskpilot', webView = self.panel.view,
      frameInfo = { mainFrame = true, request = { URL = 'about:blank' } }, body = { action = action } })
    equal(self.panel.lastError, nil, 'bridge action must complete without an exception')
  end
end

test('the follow preference action works while paused and updates status without captures or scans', function()
  local e = fixture()
  installActionBridge(e)
  e.status.paused, e.status.followNewWindows = true, true
  e.panel:refresh()
  local scans, captures = e.metadataCalls, #e.captures
  e:send('toggleFollow')
  equal(e.actions.toggleFollow, 1); equal(e.status.followNewWindows, false)
  assert(e.scripts[#e.scripts]:find('followNewWindows=false', 1, true))
  assert(e.scripts[#e.scripts]:find('DeskPilotPanel.updateStatus', 1, true))
  equal(e.metadataCalls, scans); equal(#e.captures, captures); equal(e.actions.organize, 0)
  e:send('toggleFollow')
  equal(e.status.followNewWindows, true); equal(e.actions.toggleFollow, 2)
end)

test('organization is an explicit action and its progress uses status-only updates', function()
  local e = fixture({ ax = true })
  installActionBridge(e)
  e.panel.source = e.windows[1]
  e.context.managed = function(window) return window == e.windows[1] end
  e.panel:refresh(); e.panel:pollStatus()
  equal(e.actions.organize, 0, 'opening or polling the panel must never organize desktops')
  local scans, captures = e.metadataCalls, #e.captures
  e:send('organize')
  equal(e.actions.organize, 1)
  equal(e.organizeSource, e.windows[1], 'organization receives the window focused before opening the panel')
  assert(e.scripts[#e.scripts]:find('organizePending=true', 1, true))
  equal(e.panel.visible, true, 'an accepted pending request remains visible until actual execution')
  e:send('organize')
  equal(e.actions.organize, 1, 'an accepted pending request cannot be launched twice')
  e.status.organizePending, e.status.organizing, e.status.organizePlanned, e.status.organizeDone = false, true, 2, 1
  e.panel:pollStatus()
  assert(e.scripts[#e.scripts]:find('organizing=true', 1, true))
  assert(e.scripts[#e.scripts]:find('organizePlanned=2', 1, true))
  assert(e.scripts[#e.scripts]:find('organizeDone=1', 1, true))
  e.status.organizing, e.status.organizeMessage = false, 'Biurka są już rozdzielone.'
  e.panel:pollStatus()
  assert(e.scripts[#e.scripts]:find('organizeMessage=Biurka są już rozdzielone.', 1, true))
  equal(e.metadataCalls, scans); equal(#e.captures, captures)
end)

test('organization refuses paused or duplicate requests while pause cancels pending and running work', function()
  for _, key in ipairs({ 'paused', 'locked', 'organizing', 'organizePending' }) do
    local e = fixture()
    installActionBridge(e)
    e.status[key] = true
    e:send('organize')
    equal(e.actions.organize, 0, key .. ' must block organization')
    equal(#e.alerts, 1)
  end
  for _, key in ipairs({ 'organizing', 'organizePending' }) do
    local e = fixture()
    installActionBridge(e)
    e.status[key] = true
    e:send('pause')
    equal(e.actions.pause, 1); equal(e.status.paused, true)
    equal(e.status.organizing, false); equal(e.status.organizePending, false)
  end
end)

test('transient settling busy Mission Control or restoration accepts organization into pending status', function()
  for _, key in ipairs({ 'settling', 'busy', 'missionControl', 'sessionPhase' }) do
    local e = fixture()
    installActionBridge(e)
    e.status[key] = key == 'sessionPhase' and 'restoring' or true
    e.panel:refresh()
    local scans, captures = e.metadataCalls, #e.captures
    e:send('organize')
    equal(e.actions.organize, 1, key .. ' must defer execution rather than discard the request')
    equal(e.status.organizePending, true); equal(e.panel.visible, true)
    equal(#e.alerts, 0)
    assert(e.scripts[#e.scripts]:find('organizePending=true', 1, true))
    equal(e.metadataCalls, scans); equal(#e.captures, captures)
  end
end)

test('a rejected organization request leaves its explanation visible in the open panel', function()
  local e = fixture()
  installActionBridge(e)
  e.status.lastError = 'Earlier AX error'
  e.context.organize = function()
    e.actions.organize = e.actions.organize + 1
    e.status.organizeMessage = 'Nie można rozpocząć: brak gotowego odczytu monitorów.'
    return false
  end
  e.panel:refresh()
  local scans = e.metadataCalls
  e:send('organize')
  equal(e.actions.organize, 1); equal(e.panel.visible, true)
  assert(e.scripts[#e.scripts]:find('organizeMessage=Nie można rozpocząć: brak gotowego odczytu monitorów.', 1, true))
  equal(e.metadataCalls, scans); equal(#e.captures, 0)
end)

test('failed or malformed Space window queries produce unavailable cards without crashing the panel', function()
  for _, failure in ipairs({ 'exception', 'string', 'false' }) do
    local e = fixture()
    hs.spaces.windowsForSpace = function()
      if failure == 'exception' then error('axuielement unavailable') end
      if failure == 'string' then return 'axuielement unavailable' end
      return false
    end
    local card = e:snapshot(true)
    equal(card.unavailable, true, failure .. ' cannot be treated as an empty desktop')
    equal(#card.windows, 0); equal(#e.captures, 0)
    e.panel:refresh()
    equal(e.panel.lastError, nil)
  end
end)

test('hidden or locked panels cannot start organization or change the follow preference', function()
  for _, blocked in ipairs({ 'hidden', 'locked' }) do
    for _, action in ipairs({ 'organize', 'toggleFollow' }) do
      local e = fixture()
      installActionBridge(e)
      if blocked == 'hidden' then e.panel.visible = false else e.locked = true end
      e:send(action)
      equal(e.actions.organize, 0); equal(e.actions.toggleFollow, 0)
    end
  end
end)

print(string.format('%d panel snapshot tests passed', passed))
