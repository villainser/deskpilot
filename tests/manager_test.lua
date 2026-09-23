-- Standalone Hammerspoon regression tests; no GUI or external dependencies.
-- Run: lua mac-deskpilot/tests/manager_test.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local directory = source:match('^(.*[/\\])') or './'
package.path = directory .. '../?.lua;' .. package.path
local Manager = require('deskpilot_manager')

local passed, failed = 0, 0
local function equal(actual, expected, message)
  assert(actual == expected, (message or 'unexpected value') .. ': expected '
    .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function test(name, run)
  local ok, failure = pcall(run)
  if ok then passed = passed + 1; print('ok - ' .. name)
  else failed = failed + 1; print('FAIL - ' .. name .. ': ' .. tostring(failure)) end
end

local function fixture()
  local env = {
    now = 100, timers = {}, windows = {}, knownWindows = {}, workspaces = {},
    screens = {}, spaceWindows = {}, rawWindows = {}, rawUnavailable = false,
    rules = {}, remembered = {}, moved = {}, added = {}, removed = {},
    helperCalls = 0, attributesCalls = {}, helperMode = nil, moveMode = 'success',
    subscriptions = {}, alerts = {}, settings = { ['deskpilot.paused.v2'] = false },
    mouseButtons = {}, active = {}, refreshed = 0, framed = 0, followed = 0,
    missionControl = false, adoptedLayouts = {},
  }
  function env:addScreen(uuid)
    local screen = { uuid = uuid,
      fullRectangle = { x = #self.screens * 1920, y = 0, w = 1920, h = 1080 },
      visibleRectangle = { x = #self.screens * 1920, y = 24, w = 1920, h = 1000 } }
    function screen:getUUID() return self.uuid end
    function screen:fullFrame() return self.fullRectangle end
    function screen:frame() return self.visibleRectangle end
    self.screens[#self.screens + 1] = screen
    return screen
  end
  function env:addWorkspace(id, uuid, screen)
    local localIndex = 1
    for _, ws in ipairs(self.workspaces) do
      if ws.screenUUID == screen:getUUID() then localIndex = localIndex + 1 end
    end
    local ws = { spaceID = id, spaceUUID = uuid, screenUUID = screen:getUUID(),
      screen = screen, localIndex = localIndex, index = #self.workspaces + 1 }
    self.workspaces[#self.workspaces + 1] = ws
    self.spaceWindows[id] = {}
    return ws
  end
  function env:setLocation(window, id)
    for _, ids in pairs(self.spaceWindows) do
      for index = #ids, 1, -1 do if ids[index] == window:id() then table.remove(ids, index) end end
    end
    window.spaceID = id
    if self.spaceWindows[id] then
      table.insert(self.spaceWindows[id], window:id())
    end
    for _, ws in ipairs(self.workspaces) do if ws.spaceID == id then window.display = ws.screen end end
  end
  function env:addWindow(id, key, ws, includeInFilter, pid)
    local app = {}
    function app:bundleID() return key end
    function app:name() return key end
    function app:pid() return pid or (1000 + id) end
    local window = { windowID = id, display = ws.screen, titleText = key,
      rectangle = { x = 10, y = 20, w = 600, h = 400 }, managed = true,
      restoredScreens = 0, restoredFrames = 0 }
    function window:id() return self.windowID end
    function window:application() return app end
    function window:screen() return self.display end
    function window:frame() return self.rectangle end
    function window:moveToScreen(screen) self.display = screen; self.restoredScreens = self.restoredScreens + 1 end
    function window:setFrame(frame) self.rectangle = frame; self.restoredFrames = self.restoredFrames + 1 end
    function window:title() return self.titleText end
    self.knownWindows[id] = window
    if includeInFilter ~= false then self.windows[#self.windows + 1] = window end
    self.rawWindows[#self.rawWindows + 1] = {
      kCGWindowNumber = id, kCGWindowLayer = 0, kCGWindowOwnerPID = app:pid(),
    }
    self:setLocation(window, ws.spaceID)
    return window
  end
  function env:advance(seconds)
    local target = self.now + seconds
    while true do
      local nextIndex, nextTimer
      for index, timer in ipairs(self.timers) do
        if not timer.stopped and timer.at <= target and (not nextTimer or timer.at < nextTimer.at) then
          nextIndex, nextTimer = index, timer
        end
      end
      if not nextTimer then break end
      table.remove(self.timers, nextIndex)
      self.now = nextTimer.at
      nextTimer.callback()
    end
    self.now = target
  end
  function env:emit(event, window)
    if self.subscriptions[event] then self.subscriptions[event](window) end
  end
  local function watcher(callback)
    return { callback = callback, start = function(self) return self end, stop = function() end }
  end
  local filterAPI = { windowCreated = 'created', windowTitleChanged = 'titlechanged',
    windowFocused = 'focused', windowMoved = 'moved' }
  function filterAPI.new()
    return {
      setDefaultFilter = function(self) return self end,
      getWindows = function() return env.windows end,
      subscribe = function(self, event, callback) env.subscriptions[event] = callback; return self end,
    }
  end
  _G.hs = {
    configdir = '/test-hammerspoon',
    timer = {
      secondsSinceEpoch = function() return env.now end,
      doAfter = function(delay, callback)
        local timer = { at = env.now + delay, callback = callback,
          stop = function(self) self.stopped = true end }
        env.timers[#env.timers + 1] = timer
        return timer
      end,
      doEvery = function(_, callback) return { callback = callback, stop = function() end } end,
    },
    spaces = {
      windowSpaces = function(window) return window.spaceID and { window.spaceID } or nil end,
      spaceType = function() return 'user' end,
      windowsForSpace = function(id) return env.spaceWindows[id] end,
      moveWindowToSpace = function(window, id)
        env.moved[#env.moved + 1] = { windowID = window:id(), spaceID = id, time = env.now }
        if env.moveMode == 'success' then env:setLocation(window, id); return true end
        if env.moveMode == 'unconfirmed' then return true end
        return false, 'test backend rejected move'
      end,
      addSpaceToScreen = function(screen)
        env.added[#env.added + 1] = screen:getUUID()
        env:addWorkspace(1000 + #env.added, 'created-' .. #env.added, screen)
        return true
      end,
      removeSpace = function(id) env.removed[#env.removed + 1] = id; return true end,
      activeSpaces = function() return env.active end,
      screensHaveSeparateSpaces = function() return true end,
      watcher = { new = watcher },
    },
    screen = { allScreens = function() return env.screens end, watcher = { new = watcher } },
    window = { filter = filterAPI, focusedWindow = function() return env.focusedWindow end, list = function()
      if env.rawUnavailable then return nil end
      return env.rawWindows
    end },
    eventtap = { checkMouseButtons = function() return env.mouseButtons end,
      event = {types = {keyDown = 10, leftMouseDown = 1, rightMouseDown = 2}} },
    printf = function() end,
    alert = { show = function(message) env.alerts[#env.alerts + 1] = message end },
    fs = { attributes = function(path, attribute)
      env.attributesCalls[#env.attributesCalls + 1] = { path = path, attribute = attribute }
      return env.helperMode
    end },
    task = { new = function(...)
      env.helperCalls = env.helperCalls + 1
      if env.taskFactory then return env.taskFactory(...) end
      return nil
    end },
    settings = { get = function(key) return env.settings[key] end,
      set = function(key, value) env.settings[key] = value end },
    caffeinate = { sessionProperties = function() return { CGSSessionScreenIsLocked = env.sessionLocked == true } end,
      watcher = { new = watcher, systemDidWake = 'wake', screensDidWake = 'screensWake' } },
  }
  local function groupKey(window)
    if env.groupKey then return env.groupKey(window) end
    return window:application():bundleID()
  end
  env.context = {
    managed = function(window) return window and window.managed end,
    missionControlVisible = function() return env.missionControl end,
    layoutAdopted = function(movedSpaces) env.adoptedLayouts[#env.adoptedLayouts + 1] = movedSpaces end,
    workspaces = function() return env.workspaces end,
    groupKey = groupKey,
    isGroupedApplication = function(window)
      return env.isGroupedApplication and env.isGroupedApplication(window) or false
    end,
    rule = function(window) return env.rules[groupKey(window)] end,
    remember = function(window, ws, manual)
      env.remembered[#env.remembered + 1] = { windowID = window:id(), workspace = ws, manual = manual }
      env.rules[groupKey(window)] = {
        spaceID = ws.spaceID, spaceUUID = ws.spaceUUID, screenUUID = ws.screenUUID,
        allowShared = manual,
      }
    end,
    refresh = function() env.refreshed = env.refreshed + 1 end,
    release = function() end,
    frame = function() env.framed = env.framed + 1 end,
    follow = function() env.followed = env.followed + 1 end,
  }
  env.manager = Manager.new(env.context)
  function env:start() self.manager:start() end
  return env
end

local chromeBundle = 'com.google.Chrome'
local function chromeGroups(env)
  env.groupKey = function(window)
    if window:application():bundleID() == chromeBundle then
      return chromeBundle .. '::' .. window.profile
    end
    return window:application():bundleID()
  end
  env.isGroupedApplication = function(window)
    return window:application():bundleID() == chromeBundle
  end
end

local function metadataFixture(expectedJSON)
  local e = fixture()
  e.helperMode, e.tasks, e.decodeInputs = 'file', {}, {}
  e.encodedPayload = string.rep('A', math.ceil(#expectedJSON / 3) * 4)
  e.wireFrame = 'DESKPILOT-WINDOWS/1 ' .. #e.encodedPayload .. '\n' .. e.encodedPayload .. '\n'
  e.base64Inputs = {}
  hs.base64 = { decode = function(value)
    e.base64Inputs[#e.base64Inputs + 1] = value
    equal(value, e.encodedPayload, 'decode only a complete transport payload')
    return expectedJSON
  end }
  e.decodedWindows = { { kCGWindowNumber = 42, kCGWindowBounds = { X = 20, Y = 30, Width = 800, Height = 600 } } }
  hs.json = { decode = function(value)
    e.decodeInputs[#e.decodeInputs + 1] = value
    if value ~= expectedJSON then error('incomplete JSON') end
    return { windows = e.decodedWindows }
  end }
  e.taskFactory = function(path, terminated, streaming, arguments)
    equal(path, '/test-hammerspoon/deskpilot-move')
    equal(type(streaming), 'function', 'must stream before output fills the pipe')
    equal(arguments[1], '--windows-stream')
    local task = { running = false, terminated = false, inputs = {} }
    function task:start() self.running = true; return self end
    function task:isRunning() return self.running end
    function task:terminate() self.running = false; self.terminated = true end
    function task:setInput(value)
      self.inputs[#self.inputs + 1] = value
      if self.inputError then error('stdin unavailable') end
      return self.inputFailure ~= true and self or false
    end
    function task:stream(chunk, afterTermination)
      local currentTask = self
      if afterTermination then currentTask = nil end
      return streaming(currentTask, chunk, '')
    end
    function task:complete(code, tail)
      self.running = false; terminated(code, tail or '', '')
    end
    e.tasks[#e.tasks + 1] = task
    return task
  end
  return e
end

test('complete streamed frame is acknowledged once before exit and decoded only after successful exit', function()
  local e = metadataFixture('{"windows":[]}')
  e.manager:refreshMetadata()
  local task = e.tasks[1]
  task:stream(e.wireFrame:sub(1, 9))
  task:stream(e.wireFrame:sub(10, -2))
  equal(#task.inputs, 0)
  equal(#e.decodeInputs, 0)
  task:stream('\n')
  equal(task.inputs[1], 'DESKPILOT-ACK/1\n')
  equal(#task.inputs, 1)
  equal(#e.base64Inputs, 0)
  equal(#e.decodeInputs, 0)
  equal(e.manager.metadata, nil)
  task:stream(''); task:stream('')
  equal(#task.inputs, 1)
  task:complete(0, '')
  equal(e.manager.metadata, e.decodedWindows)
  equal(#e.decodeInputs, 1)
end)

test('large frames drain completely before the producer receives acknowledgement', function()
  local e = metadataFixture(string.rep('x', 100000))
  e.manager:refreshMetadata()
  local task = e.tasks[1]
  for start = 1, #e.wireFrame, 16384 do
    task:stream(e.wireFrame:sub(start, start + 16383))
    equal(#task.inputs, start + 16383 < #e.wireFrame and 0 or 1)
  end
  equal(#e.decodeInputs, 0)
  task:complete(0, '')
  equal(e.manager.metadata, e.decodedWindows)
end)

test('a nonzero helper exit after acknowledgement never commits a complete frame', function()
  local e = metadataFixture('{"windows":[]}')
  e.manager:refreshMetadata()
  local task = e.tasks[1]
  task:stream(e.wireFrame)
  equal(#task.inputs, 1)
  task:complete(5, '')
  equal(e.manager.metadata, nil)
  equal(#e.decodeInputs, 0)
  equal(e.manager.metadataError, 'helper-exit-5')
end)

test('acknowledgement write errors release and terminate the producer without decoding', function()
  for _, failure in ipairs({ 'inputError', 'inputFailure' }) do
    local e = metadataFixture('{"windows":[]}')
    e.manager:refreshMetadata()
    local task = e.tasks[1]; task[failure] = true
    task:stream(e.wireFrame)
    equal(task.terminated, true)
    equal(e.manager.metadataTask, nil)
    equal(e.manager.metadataError, 'helper-ack-failed')
    equal(#e.decodeInputs, 0)
    task:complete(0, '')
    equal(#e.decodeInputs, 0)
  end
end)

test('acknowledged producer still has a bounded exit timeout', function()
  local e = metadataFixture('{"windows":[]}')
  e.manager:refreshMetadata()
  local task = e.tasks[1]
  task:stream(e.wireFrame)
  e:advance(5)
  equal(task.terminated, true)
  equal(e.manager.metadataError, 'helper-exit-timeout')
  equal(#e.decodeInputs, 0)
  equal(e.manager.metadataTask, nil)
end)

test('incomplete streamed frame times out without acknowledgement or decoding', function()
  local e = metadataFixture('{"windows":[]}')
  e.manager:refreshMetadata()
  local task = e.tasks[1]
  task:stream(e.wireFrame:sub(1, -2))
  e:advance(5)
  equal(task.terminated, true)
  equal(#task.inputs, 0)
  equal(#e.decodeInputs, 0)
  equal(e.manager.metadataError, 'incomplete-frame-timeout')
end)

test('metadata continuously drains output larger than a pipe and appends termination tail', function()
  local large = '{"windows":[' .. string.rep('{"kCGWindowNumber":42,"kCGWindowBounds":{"X":20,"Y":30,"Width":800,"Height":600}},', 1200)
    .. '{"kCGWindowNumber":43}]}'
  assert(#large > 65536)
  local e = metadataFixture(large)
  e.manager:refreshMetadata()
  local task = e.tasks[1]
  for offset = 1, 80000, 16000 do equal(task:stream(e.wireFrame:sub(offset, offset + 15999)), true) end
  equal(e.manager.metadata, nil)
  task:complete(0, e.wireFrame:sub(80001))
  equal(e.manager.metadata, e.decodedWindows)
  equal(e.decodeInputs[1], large)
  equal(e.manager.metadataTask, nil)
  equal(e.manager.metadataFetch, nil)
  e:advance(6)
  equal(task.terminated, false)
end)

test('final streamed chunk arriving after termination belongs before termination tail', function()
  local e = metadataFixture('{"windows":[{"id":42}]}')
  e.manager:refreshMetadata()
  local task = e.tasks[1]
  task:stream(e.wireFrame:sub(1,25))
  task:complete(0, e.wireFrame:sub(-5))
  e:advance(0.05)
  task:stream(e.wireFrame:sub(26,-6), true)
  e:advance(0.2)
  equal(e.manager.metadata, e.decodedWindows)
  equal(e.decodeInputs[1], '{"windows":[{"id":42}]}')
  equal(e.manager.metadataTask, nil)
end)

test('delayed final output never reaches JSON parser until exact frame is complete', function()
  local e = metadataFixture('{"windows":[{"id":42}]}')
  e.manager:refreshMetadata()
  local task = e.tasks[1]
  task:stream(e.wireFrame:sub(1,25))
  task:complete(0, e.wireFrame:sub(-5))
  e:advance(1)
  equal(e.manager.metadataTask, task)
  equal(e.manager.metadata, nil)
  equal(#e.decodeInputs, 0)
  equal(#e.base64Inputs, 0)
  task:stream(e.wireFrame:sub(26,-6), true)
  e:advance(0.2)
  equal(#e.decodeInputs, 1)
  equal(e.manager.metadata, e.decodedWindows)
  equal(e.manager.metadataTask, nil)
end)

test('metadata supports output delivered entirely by termination callback', function()
  local e = metadataFixture('{"windows":[]}')
  e.manager:refreshMetadata()
  e.tasks[1]:complete(0, e.wireFrame)
  e:advance(0.2)
  equal(e.manager.metadata, e.decodedWindows)
  equal(e.manager.metadataTask, nil)
end)

test('termination tail waits for a delayed first read containing the frame header', function()
  local e = metadataFixture('{"windows":[{"name":"Łódź 東京"}]}')
  e.manager:refreshMetadata()
  local task = e.tasks[1]
  task:complete(0, e.wireFrame:sub(30))
  e:advance(0.8)
  equal(e.manager.metadataTask, task)
  equal(#e.decodeInputs, 0)
  task:stream(e.wireFrame:sub(1,29), true)
  equal(e.manager.metadata, e.decodedWindows)
  equal(#e.decodeInputs, 1)
  equal(e.manager.metadataError, nil)
end)

test('a frame header split between callbacks is never decoded prematurely', function()
  local e = metadataFixture('{"windows":[]}')
  e.manager:refreshMetadata()
  local task = e.tasks[1]
  task:stream(e.wireFrame:sub(1,4))
  task:complete(0, e.wireFrame:sub(25))
  e:advance(0.3)
  equal(#e.base64Inputs, 0)
  task:stream(e.wireFrame:sub(5,24), true)
  equal(e.manager.metadata, e.decodedWindows)
  equal(e.manager.metadataReads, 1)
end)

test('trailing frame data fails closed without any JSON decoder call', function()
  local e = metadataFixture('{"windows":[]}')
  local old = { { kCGWindowNumber = 99 } }
  e.manager.metadata, e.manager.metadataAt = old, e.now - 10
  e.manager:refreshMetadata()
  e.tasks[1]:complete(0, e.wireFrame .. 'unexpected')
  e:advance(5)
  equal(#e.decodeInputs, 0)
  equal(e.manager.metadata, old)
  equal(e.manager.metadataError, 'invalid-frame')
end)

test('oversized metadata stops the producer before buffering more input', function()
  local e = metadataFixture('{"windows":[]}')
  e.manager:refreshMetadata()
  local task = e.tasks[1]
  equal(task:stream(string.rep('A', require('deskpilot_wire').maxFrameBytes + 1)), false)
  equal(task.terminated, true)
  equal(e.manager.metadataTask, nil)
  equal(e.manager.metadataError, 'oversized-metadata')
  equal(#e.decodeInputs, 0)
  equal(task:stream(e.wireFrame, true), false)
end)

test('complete but invalid metadata is decoded once and reported without retrying that request', function()
  local e = metadataFixture('{"windows":[]}')
  local calls = 0
  hs.json.decode = function() calls=calls+1; return nil end
  e.manager:refreshMetadata()
  local task = e.tasks[1]
  task:complete(0, e.wireFrame)
  equal(calls, 1)
  equal(e.manager.metadataError, 'invalid-metadata')
  equal(e.manager.metadataTask, nil)
  equal(task:stream('', true), false)
  e:advance(5)
  equal(calls, 1)
end)

test('metadata timeout releases a stuck task and ignores old callbacks after retry', function()
  local e = metadataFixture('{"windows":[]}')
  local oldData = { { kCGWindowNumber = 1 } }
  e.manager.metadata, e.manager.metadataAt = oldData, e.now - 10
  e.manager:refreshMetadata()
  local oldTask = e.tasks[1]
  e:advance(5)
  equal(oldTask.terminated, true)
  equal(e.manager.metadataTask, nil)
  equal(e.manager.metadata, oldData)
  e.manager:refreshMetadata()
  local newTask = e.tasks[2]
  oldTask:complete(0, e.wireFrame)
  equal(oldTask:stream('', true), false)
  equal(e.manager.metadataTask, newTask)
  equal(e.manager.metadata, oldData)
  newTask:complete(0, e.wireFrame)
  e:advance(0.2)
  equal(e.manager.metadata, e.decodedWindows)
  equal(e.manager.metadataTask, nil)
end)

test('failed or malformed metadata never refreshes the age of previous occupancy data', function()
  for _, code in ipairs({ 1, 0 }) do
    local e = metadataFixture('{"windows":[]}')
    local oldData, oldAt = { { kCGWindowNumber = 1 } }, e.now - 10
    e.manager.metadata, e.manager.metadataAt = oldData, oldAt
    e.manager:refreshMetadata()
    e.tasks[1]:complete(code, code == 0 and 'broken' or e.wireFrame)
    e:advance(5)
    equal(e.manager.metadataTask, nil)
    equal(e.manager.metadata, oldData)
    equal(e.manager.metadataAt, oldAt)
    equal(e.tasks[1].terminated, false)
  end
end)

test('occupancy includes inactive windows absent from the AX filter', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local ws = e:addWorkspace(1, 'one', screen)
  e:addWindow(10, 'hidden-app', ws, false)
  e:start()
  equal(#e.manager:allWindows(), 0)
  equal(e.manager:occupancy()[1], true)
end)

test('unknown window IDs occupy a Space even without CG metadata', function()
  local e = fixture()
  e:addWorkspace(1, 'one', e:addScreen('a'))
  e.spaceWindows[1] = { 999 }
  e:start()
  equal(e.manager:occupancy()[1], true)
end)

test('known nonzero loginwindow overlays do not occupy otherwise empty Spaces', function()
  local e=fixture(); local screen=e:addScreen('a')
  e:addWorkspace(1,'one',screen); e:addWorkspace(2,'two',screen)
  e.spaceWindows[1],e.spaceWindows[2]={778},{778}
  e.rawWindows={{kCGWindowNumber=778,kCGWindowOwnerPID=467,kCGWindowLayer=2003}}
  hs.application={runningApplications=function() return {{
    bundleID=function() return 'com.apple.loginwindow' end, pid=function() return 467 end,
  }} end}
  e:start()
  equal(e.manager:occupancy()[1],false); equal(e.manager:occupancy()[2],false)
end)

test('loginwindow layer zero and AX-backed windows still occupy their Space', function()
  for _, mode in ipairs({'layer-zero','known-AX'}) do
    local e=fixture(); local ws=e:addWorkspace(1,'one',e:addScreen('a'))
    e:addWindow(778,'com.apple.loginwindow',ws,mode=='known-AX',467)
    e.rawWindows[1].kCGWindowLayer=mode=='layer-zero' and 0 or 2003
    hs.application={runningApplications=function() return {{
      bundleID=function() return 'com.apple.loginwindow' end, pid=function() return 467 end,
    }} end}
    e:start(); equal(e.manager:occupancy()[1],true)
  end
end)

test('loginwindow-looking names and unknown owner PIDs never authorize ignoring a surface', function()
  for _, mode in ipairs({'unknown-PID','different-bundle'}) do
    local e=fixture(); e:addWorkspace(1,'one',e:addScreen('a'))
    e.spaceWindows[1]={778}
    e.rawWindows={{kCGWindowNumber=778,kCGWindowOwnerPID=467,kCGWindowLayer=2003,kCGWindowOwnerName='loginwindow'}}
    hs.application={runningApplications=function() return {{
      bundleID=function() return mode=='different-bundle' and 'com.example.loginwindow' or 'com.apple.loginwindow' end,
      pid=function() return mode=='unknown-PID' and 999 or 467 end,
    }} end}
    e:start(); equal(e.manager:occupancy()[1],true)
  end
end)

test('a failed per-Space occupancy query cannot supply a free destination', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local sourceWS = e:addWorkspace(1, 'one', screen)
  local unknownWS = e:addWorkspace(2, 'two', screen)
  local freeWS = e:addWorkspace(3, 'three', screen)
  local app = e:addWindow(10, 'new-app', sourceWS)
  e:addWindow(11, 'existing-app', sourceWS)
  e.spaceWindows[unknownWS.spaceID] = nil
  e:start()
  equal(e.manager:occupancy()[2], nil)
  e.manager:apply(app, true)
  equal(e.moved[1].spaceID, freeWS.spaceID)
end)

test('failed CG query leaves occupancy unknown and cleanup refuses deletion', function()
  local e = fixture()
  local screen = e:addScreen('a')
  e:addWorkspace(1, 'one', screen)
  e:addWorkspace(2, 'two', screen)
  e.rawUnavailable = true
  e:start()
  e:advance(8)
  e.manager.emptySince = { [1] = 0, [2] = 0 }
  equal(e.manager:occupancy()[1], nil)
  equal(e.manager:occupancy()[2], nil)
  e.manager:cleanup()
  equal(#e.removed, 0)
end)

local function cleanupFixture()
  local e = fixture()
  local screen = e:addScreen('a')
  for id=1,4 do e:addWorkspace(id, 'space-'..id, screen) end
  e:addWindow(10, 'occupied', e.workspaces[1])
  e.active = { a=1 }
  e:start(); e:advance(8)
  e.manager.emptySince = { [2]=e.now-20, [3]=e.now-20, [4]=e.now-20 }
  e.mcOpened, e.mcClosed, e.released = 0, 0, {}
  hs.spaces.openMissionControl = function()
    e.mcOpened=e.mcOpened+1; e.missionControl=true
  end
  hs.spaces.closeMissionControl = function()
    e.mcClosed=e.mcClosed+1; e.missionControl=false
  end
  hs.spaces.removeSpace = function(id, closeMC)
    equal(closeMC, false, 'batch must retain its single Mission Control session')
    equal(e.missionControl, true)
    e.removed[#e.removed+1]=id
    if e.failRemove == id then return nil, 'test removal rejected' end
    if e.unconfirmedRemove == id then return true end
    for index=#e.workspaces,1,-1 do
      if e.workspaces[index].spaceID==id then table.remove(e.workspaces,index) end
    end
    e.spaceWindows[id]=nil
    for index, ws in ipairs(e.workspaces) do ws.localIndex=index end
    return true
  end
  e.context.release=function(target) e.released[#e.released+1]=target.spaceUUID end
  e.manager:cleanup() -- The whole plan is observed before its eight-second grace.
  equal(e.mcOpened,0)
  e:advance(8)
  return e
end

test('all detected empty Spaces are removed in one verified Mission Control session', function()
  local e=cleanupFixture()
  e.manager:cleanup()
  equal(e.mcOpened,1); equal(e.mcClosed,0); equal(e.manager.busy,true)
  equal(e.manager:status().cleanupPlanned,3)
  e:advance(0.4)
  equal(#e.removed,1); equal(e.removed[1],4); equal(e.manager.busy,true)
  e:advance(3)
  equal(#e.removed,3); equal(e.removed[2],3); equal(e.removed[3],2)
  equal(#e.workspaces,1); equal(#e.released,3)
  equal(e.mcOpened,1); equal(e.mcClosed,1); equal(e.manager.busy,false)
  equal(e.manager:status().cleanupDone,3); equal(e.manager:status().cleanupPending,0)
  equal(e.manager.cleanupPhase,'done')
end)

test('a newly empty Space delays the whole plan until all candidates mature', function()
  local e=cleanupFixture(); e.manager.emptySince[2]=e.now
  e.manager:cleanup(); equal(e.mcOpened,0); equal(e.manager.cleanupPhase,'detecting')
  equal(e.manager.cleanupPlanned,3)
  e:advance(7.9); e.manager:cleanup(); equal(e.mcOpened,0)
  e:advance(0.1); e.manager:cleanup(); equal(e.mcOpened,1)
  e:advance(3); equal(#e.removed,3); equal(e.mcClosed,1)
end)

test('a changed candidate order must be stable before any Mission Control session', function()
  local e=cleanupFixture()
  e.workspaces[2].localIndex, e.workspaces[4].localIndex=4,2
  e.manager:cleanup(); equal(e.mcOpened,0)
  e:advance(7.9); e.manager:cleanup(); equal(e.mcOpened,0)
  e:advance(0.1); e.manager:cleanup(); equal(e.mcOpened,1)
  e:advance(3); equal(#e.removed,3); equal(e.mcClosed,1)
end)

test('a later candidate receiving a window is skipped using fresh occupancy', function()
  local e=cleanupFixture(); e.manager:cleanup(); e:advance(0.4)
  e:addWindow(99,'new-window',e.workspaces[3])
  e:advance(3)
  equal(#e.removed,2); equal(e.removed[1],4); equal(e.removed[2],2)
  equal(e.manager.cleanupSkipped,1); equal(e.mcOpened,1); equal(e.mcClosed,1)
end)

test('a later candidate becoming active or reserved is preserved', function()
  for _, state in ipairs({'active','reserved'}) do
    local e=cleanupFixture(); e.manager:cleanup(); e:advance(0.4)
    if state=='active' then e.active.a=3 else e.manager.reserved[3]='another-app' end
    e:advance(3)
    equal(#e.removed,2); equal(e.removed[2],2)
    equal(e.manager.cleanupSkipped,1); equal(e.mcClosed,1)
  end
end)

test('missing active-monitor information prevents planning and aborts an ongoing batch', function()
  local e=cleanupFixture(); e.active={}
  e.manager:cleanup(); equal(e.mcOpened,0)
  e.active.a=1; e.manager:cleanup(); e:advance(0.4)
  e.active={}; e:advance(3)
  equal(#e.removed,1); equal(e.mcClosed,1)
  equal(e.manager.cleanupEnabled,false); equal(e.manager.cleanupPhase,'failed')
end)

test('failed or unconfirmed removal closes once and disables automatic retries', function()
  for _, mode in ipairs({'failRemove','unconfirmedRemove'}) do
    local e=cleanupFixture(); e[mode]=3
    e.manager:cleanup(); e:advance(4)
    equal(#e.removed,2); equal(#e.released,1)
    equal(e.mcOpened,1); equal(e.mcClosed,1); equal(e.manager.busy,false)
    equal(e.manager.cleanupEnabled,false); equal(e.manager.cleanupPhase,'failed')
    e:advance(20); e.manager:tick(); equal(e.mcOpened,1)
  end
end)

test('pause lock topology and user interaction cancel the owned session without reopening', function()
  for _, action in ipairs({'pause','lock','topology','mouse','close'}) do
    local e=cleanupFixture(); e.manager:cleanup(); e:advance(0.4)
    if action=='pause' then e.manager:pause()
    elseif action=='lock' then e.sessionLocked=true; e.manager:checkSessionLock()
    elseif action=='topology' then e:addScreen('b'); e.manager:topologyChanged()
    elseif action=='mouse' then e.mouseButtons.left=true
    else e.missionControl=false end
    e:advance(20)
    equal(#e.removed,1); equal(e.mcOpened,1); equal(e.mcClosed,(action=='lock' or action=='close') and 0 or 1)
    equal(e.manager.busy,false); equal(e.manager.cleanupPhase,'cancelled')
    if action=='mouse' or action=='close' then
      e.mouseButtons={}; e.missionControl=false
      for _=1,40 do e:advance(1); e.manager:tick() end
      equal(e.mcOpened,1); equal(e.manager.cleanupEnabled,false)
    end
  end
end)

test('user-opened Mission Control and nonseparate Spaces are never changed by cleanup', function()
  local e=cleanupFixture(); e.missionControl=true
  e.manager:cleanup(); equal(e.mcOpened,0); equal(e.mcClosed,0)
  e.missionControl=false; hs.spaces.screensHaveSeparateSpaces=function() return false end
  e.manager:cleanup(); equal(e.mcOpened,0); equal(e.mcClosed,0)
end)

test('a frozen plan cannot target a recycled Space number with another UUID', function()
  local e=cleanupFixture(); e.manager:cleanup(); e:advance(0.4)
  e.workspaces[3].spaceUUID='replacement-uuid'
  e:advance(3)
  equal(#e.removed,2); equal(e.removed[2],2)
  equal(e.manager.cleanupSkipped,1); equal(e.mcClosed,1)
end)

test('fresh monitor counts preserve its last ordinary Space after other changes', function()
  local e=cleanupFixture(); e.manager:cleanup(); e:advance(0.4)
  table.remove(e.workspaces,1); e.spaceWindows[1]=nil; e.active.a=999
  e:advance(3)
  equal(#e.removed,2); equal(e.removed[2],3)
  equal(#e.workspaces,1); equal(e.workspaces[1].spaceID,2)
  equal(e.mcClosed,1)
end)

local function entirelyEmptyThreeMonitorFixture(fullscreen)
  local e=cleanupFixture()
  e.windows, e.knownWindows, e.rawWindows = {}, {}, {}
  e.spaceWindows[1]={}
  local b, c=e:addScreen('b'), e:addScreen('c')
  for id=11,13 do e:addWorkspace(id,'space-'..id,b) end
  for id=21,22 do e:addWorkspace(id,'space-'..id,c) end
  e.active=fullscreen and {a=1001,b=1002,c=1003} or {a=4,b=13,c=22}
  for _,ws in ipairs(e.workspaces) do e.manager.emptySince[ws.spaceID]=e.now-20 end
  local remove=hs.spaces.removeSpace
  hs.spaces.removeSpace=function(id,closeMC)
    local monitor, before
    for _,ws in ipairs(e.workspaces) do if ws.spaceID==id then monitor=ws.screenUUID end end
    assert(monitor,'only an existing Space may be removed')
    before=0
    for _,ws in ipairs(e.workspaces) do if ws.screenUUID==monitor then before=before+1 end end
    assert(before>1,'cleanup must never remove a monitor\'s last ordinary Space')
    local ok,err=remove(id,closeMC)
    local after=0
    for _,ws in ipairs(e.workspaces) do if ws.screenUUID==monitor then after=after+1 end end
    assert(after>=1,'every monitor must retain an ordinary Space after each removal')
    return ok,err
  end
  e.manager:cleanup(); equal(e.mcOpened,0)
  e:advance(8)
  return e
end

for _,fullscreen in ipairs({false,true}) do
  test('three entirely empty monitors retain one Space each with '
      ..(fullscreen and 'active fullscreen Spaces' or 'their last ordinary Spaces active'), function()
    local e=entirelyEmptyThreeMonitorFixture(fullscreen)
    e.manager:cleanup()
    equal(e.manager.cleanupPlanned,6); equal(e.mcOpened,1)
    e:advance(8)
    equal(#e.removed,6); equal(#e.released,6); equal(#e.workspaces,3)
    local expected=fullscreen and {a=1,b=11,c=21} or {a=4,b=13,c=22}
    local remaining={}
    for _,ws in ipairs(e.workspaces) do
      equal(ws.spaceID,expected[ws.screenUUID]); assert(not remaining[ws.screenUUID])
      remaining[ws.screenUUID]=true
    end
    equal(remaining.a,true); equal(remaining.b,true); equal(remaining.c,true)
    equal(e.manager.cleanupDone,6); equal(e.manager.cleanupSkipped,0)
    equal(e.manager.cleanupPhase,'done'); equal(e.manager.busy,false)
    equal(e.mcOpened,1); equal(e.mcClosed,1)
    for _=1,25 do e:advance(1); e.manager:tick() end
    equal(e.mcOpened,1); equal(#e.removed,6)
  end)
end

test('a batch preserves the sole remaining Space on all three monitors after external removals', function()
  local e=entirelyEmptyThreeMonitorFixture(true)
  e.manager:cleanup(); e:advance(0.4)
  equal(#e.removed,1); equal(e.removed[1],4)
  -- These survivors were all planned for deletion. External changes remove
  -- the originally protected first Space and other neighbours on each screen.
  local survivors={a=3,b=12,c=22}
  for index=#e.workspaces,1,-1 do
    local ws=e.workspaces[index]
    if ws.spaceID~=survivors[ws.screenUUID] then
      e.spaceWindows[ws.spaceID]=nil; table.remove(e.workspaces,index)
    end
  end
  e:advance(8)
  equal(#e.removed,1); equal(#e.released,1); equal(#e.workspaces,3)
  for _,ws in ipairs(e.workspaces) do equal(ws.spaceID,survivors[ws.screenUUID]) end
  equal(e.manager.cleanupDone,1); equal(e.manager.cleanupSkipped,5)
  equal(e.manager.cleanupPhase,'done'); equal(e.manager.busy,false)
  equal(e.mcOpened,1); equal(e.mcClosed,1)
end)

test('a target relocated to another monitor is never released as deleted', function()
  local e=cleanupFixture(); local second=e:addScreen('b')
  local existing=e:addWorkspace(5,'second-screen',second)
  e:addWindow(15,'other-app',existing); e.active.b=5
  e.manager:cleanup(); e:advance(0.4)
  e:addWorkspace(44,'space-4',second)
  e:advance(3)
  equal(#e.removed,1); equal(#e.released,0); equal(e.manager.cleanupDone,0)
  equal(e.manager.cleanupPhase,'cancelled'); equal(e.mcClosed,1)
end)

test('unidentified Spaces prevent planning and incomplete verification cannot prove deletion', function()
  local e=cleanupFixture(); e.workspaces[2].spaceUUID=nil
  e.manager:cleanup(); equal(e.mcOpened,0)
  for _, invalid in ipairs({{},{{index=1}}}) do
    e=cleanupFixture(); e.manager:cleanup(); e:advance(0.4)
    e.workspaces=invalid; e:advance(3)
    equal(#e.released,0); equal(e.manager.cleanupDone,0)
    equal(e.manager.cleanupPhase,'failed'); equal(e.mcClosed,1)
  end
end)

for _, mode in ipairs({ 'rejected', 'unconfirmed' }) do
  test(mode .. ' move is never remembered and missing helper is never launched', function()
    local e = fixture()
    local screen = e:addScreen('a')
    local sourceWS = e:addWorkspace(1, 'one', screen)
    local targetWS = e:addWorkspace(2, 'two', screen)
    local app = e:addWindow(10, 'app', sourceWS)
    e.moveMode = mode
    e:start()
    equal(e.manager:move(app, targetWS, false), true)
    equal(#e.remembered, 0)
    e:advance(0.5)
    equal(#e.remembered, 0)
    equal(e.helperCalls, 0)
    assert(#e.attributesCalls >= 1)
    equal(e.attributesCalls[1].path, '/test-hammerspoon/deskpilot-move')
    equal(e.manager.paused, true)
    equal(e.manager.busy, false)
    equal(e.manager.reserved[2], nil)
    equal(app.spaceID, 1)
    equal(app.restoredFrames, 0, 'failure must not overwrite the current frame')
    equal(app.restoredScreens, 0, 'failure must not issue another blind screen move')
    equal(#e.moved, 1, 'only the original requested move is attempted')
  end)
end

test('a helper path that is a directory is not launched', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local sourceWS = e:addWorkspace(1, 'one', screen)
  local targetWS = e:addWorkspace(2, 'two', screen)
  local app = e:addWindow(10, 'app', sourceWS)
  e.moveMode, e.helperMode = 'unconfirmed', 'directory'
  e:start()
  e.manager:move(app, targetWS, false)
  e:advance(0.5)
  equal(e.helperCalls, 0)
  equal(#e.remembered, 0)
end)

test('verified move is remembered only after location confirmation', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local sourceWS = e:addWorkspace(1, 'one', screen)
  local targetWS = e:addWorkspace(2, 'two', screen)
  local app = e:addWindow(10, 'app', sourceWS)
  e:start()
  e.manager:move(app, targetWS, false)
  equal(#e.remembered, 0)
  equal(e.manager.busy, true)
  e:advance(0.5)
  equal(#e.remembered, 1)
  equal(e.remembered[1].workspace, targetWS)
  equal(e.manager.busy, false)
  equal(e.helperCalls, 0)
end)

test('manual baseline and title changes preserve user-selected Space', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local sourceWS = e:addWorkspace(1, 'one', screen)
  local targetWS = e:addWorkspace(2, 'two', screen)
  local app = e:addWindow(10, 'app', sourceWS)
  e.rules.app = sourceWS
  e:start()
  e:advance(8)
  e.manager:tick() -- Observe the existing window without applying its assignment.
  e.remembered = {}
  e:setLocation(app, targetWS.spaceID) -- Mission Control/user drag, no manager move.
  app.titleText = 'A different document title'
  e:emit('titlechanged', app)
  e.manager:tick()
  e:advance(1); e.manager:tick()
  e:advance(1); e.manager:tick()
  equal(#e.moved, 0)
  equal(app.spaceID, targetWS.spaceID)
  equal(#e.remembered, 1)
  equal(e.remembered[1].manual, true)
  equal(e.rules.app.spaceUUID, 'two')
  e:emit('titlechanged', app)
  e:advance(1); e.manager:tick()
  equal(#e.moved, 0)
  equal(#e.remembered, 1)
end)

test('a disconnected pinned app never allocates on another monitor', function()
  local e = fixture()
  local screen = e:addScreen('connected')
  local sourceWS = e:addWorkspace(1, 'one', screen)
  e:addWorkspace(2, 'two', screen)
  local app = e:addWindow(10, 'app', sourceWS)
  e.rules.app = { spaceID = 999, spaceUUID = 'disconnected-space', screenUUID = 'disconnected' }
  e:start()
  e.manager:apply(app, true)
  e:advance(1)
  equal(#e.moved, 0)
  equal(#e.added, 0)
  equal(#e.remembered, 0)
  equal(app.spaceID, sourceWS.spaceID)
end)

test('queued applications get separate destinations with serialized verification', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local sourceWS = e:addWorkspace(1, 'one', screen)
  e:addWorkspace(2, 'two', screen)
  e:addWorkspace(3, 'three', screen)
  local first = e:addWindow(10, 'first', sourceWS)
  local second = e:addWindow(11, 'second', sourceWS)
  e:addWindow(12, 'source-occupant', sourceWS, false)
  e:start()
  e.manager.cleanupEnabled = false
  e:advance(8)
  e.manager:tick() -- Existing windows are only observed at startup.
  e.manager:enqueue(first, true)
  e.manager:enqueue(second, true)
  e.manager:tick() -- Explicit placement applies the first window only.
  equal(#e.moved, 1)
  equal(e.moved[1].spaceID, 2)
  equal(e.manager.busy, true)
  equal(e.manager.reserved[2], 'first')
  e.manager:tick()
  equal(#e.moved, 1)
  equal(#e.remembered, 0)
  e:advance(0.5)
  equal(#e.remembered, 1)
  e.manager:tick()
  equal(#e.moved, 2)
  equal(e.moved[2].spaceID, 3)
  e:advance(0.5)
  equal(first.spaceID, 2)
  equal(second.spaceID, 3)
  equal(#e.remembered, 2)
  equal(#e.added, 0)
end)

test('Chrome profiles sharing a process get separate Spaces and same-profile windows reunite', function()
  local e = fixture()
  chromeGroups(e)
  local screen = e:addScreen('a')
  local sourceWS = e:addWorkspace(1, 'one', screen)
  e:addWorkspace(2, 'two', screen)
  e:addWorkspace(3, 'three', screen)
  local first = e:addWindow(10, chromeBundle, sourceWS, true, 500)
  local second = e:addWindow(11, chromeBundle, sourceWS, true, 500)
  local sibling = e:addWindow(12, chromeBundle, sourceWS, true, 500)
  first.profile, second.profile, sibling.profile = 'Profile 1', 'Profile 2', 'Profile 1'
  e:addWindow(13, 'source-occupant', sourceWS, false)
  e:start(); e.manager.cleanupEnabled = false; e:advance(8)
  e.manager:tick()
  e.manager:enqueue(first, true)
  e.manager:enqueue(second, true)
  e.manager:enqueue(sibling, true)
  e.manager:tick()
  equal(#e.moved, 1)
  equal(e.moved[1].spaceID, 2)
  equal(e.manager.reserved[2], chromeBundle .. '::Profile 1')
  e:advance(0.5); e.manager:tick()
  equal(#e.moved, 2)
  equal(e.moved[2].spaceID, 3)
  equal(e.manager.reserved[3], chromeBundle .. '::Profile 2')
  e:advance(0.5); e.manager:tick()
  equal(#e.moved, 3)
  equal(e.moved[3].spaceID, 2)
  e:advance(0.5)

  equal(first.spaceID, 2)
  equal(second.spaceID, 3)
  equal(sibling.spaceID, 2)
  equal(e.rules[chromeBundle .. '::Profile 1'].spaceID, 2)
  equal(e.rules[chromeBundle .. '::Profile 2'].spaceID, 3)
  equal(e.rules[chromeBundle], nil)
  equal(#e.added, 0)
end)

for _, includeInFilter in ipairs({ true, false }) do
  test('another Chrome profile occupies its Space with shared PID and AX visibility '
      .. tostring(includeInFilter), function()
    local e = fixture()
    chromeGroups(e)
    local screen = e:addScreen('a')
    local sourceWS = e:addWorkspace(1, 'one', screen)
    local otherWS = e:addWorkspace(2, 'two', screen)
    local app = e:addWindow(10, chromeBundle, sourceWS, true, 500)
    local other = e:addWindow(11, chromeBundle, otherWS, includeInFilter, 500)
    app.profile, other.profile = 'Profile 1', 'Profile 2'
    e:start()
    local occupied = e.manager:occupancy(app)
    equal(occupied[sourceWS.spaceID], false)
    equal(occupied[otherWS.spaceID], true)
  end)
end

test('same-profile Chrome windows may share their already occupied Space', function()
  local e = fixture()
  chromeGroups(e)
  local screen = e:addScreen('a')
  local sourceWS = e:addWorkspace(1, 'one', screen)
  local siblingWS = e:addWorkspace(2, 'two', screen)
  local app = e:addWindow(10, chromeBundle, sourceWS, true, 500)
  local sibling = e:addWindow(11, chromeBundle, siblingWS, true, 500)
  app.profile, sibling.profile = 'Profile 1', 'Profile 1'
  e:start()
  equal(e.manager:occupancy(app)[siblingWS.spaceID], false)
end)

test('ordinary applications retain PID fallback for windows outside the AX filter', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local sourceWS = e:addWorkspace(1, 'one', screen)
  local siblingWS = e:addWorkspace(2, 'two', screen)
  local app = e:addWindow(10, 'ordinary-app', sourceWS, true, 500)
  e:addWindow(11, 'ordinary-app', siblingWS, false, 500)
  e:start()
  equal(e.manager:occupancy(app)[siblingWS.spaceID], false)
end)

for _, operation in ipairs({ 'move', 'manualMove' }) do
  test(operation .. ' follows only siblings of the manually moved Chrome profile', function()
    local e = fixture()
    chromeGroups(e)
    local sourceScreen, targetScreen = e:addScreen('a'), e:addScreen('b')
    local sourceWS = e:addWorkspace(1, 'one', sourceScreen)
    local targetWS = e:addWorkspace(2, 'two', targetScreen)
    local app = e:addWindow(10, chromeBundle, sourceWS, true, 500)
    local sibling = e:addWindow(11, chromeBundle, sourceWS, true, 500)
    local other = e:addWindow(12, chromeBundle, sourceWS, true, 500)
    app.profile, sibling.profile, other.profile = 'Profile 1', 'Profile 1', 'Profile 2'
    e.rules[chromeBundle .. '::Profile 2'] = sourceWS
    e:start()
    equal(e.manager[operation](e.manager, app, targetWS, true), true)
    e:advance(0.5)
    equal(#e.manager.queue, 1)
    equal(e.manager.queue[1].id, sibling:id())
    equal(e.manager.queued[other:id()], nil)
    equal(e.rules[chromeBundle .. '::Profile 1'].spaceID, targetWS.spaceID)
    equal(e.rules[chromeBundle .. '::Profile 1'].screenUUID, 'b')
    equal(e.rules[chromeBundle .. '::Profile 2'], sourceWS)
    equal(other.spaceID, sourceWS.spaceID)
    equal(#e.remembered, 1)
    equal(e.remembered[1].manual, true)
  end)
end

test('unknown occupancy delays placement instead of creating another empty Space', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local ws = e:addWorkspace(1, 'one', screen)
  local app = e:addWindow(10, 'app', ws)
  e.rawUnavailable = true
  e:start()
  e.manager:apply(app, true)
  equal(#e.added, 0)
  equal(#e.moved, 0)
  equal(#e.manager.queue, 1)
end)

test('closing a queued window does not pause the manager', function()
  local e = fixture()
  local ws = e:addWorkspace(1, 'one', e:addScreen('a'))
  local app = e:addWindow(10, 'app', ws)
  e:start(); e:advance(8); e.manager.rebaseline = false
  e.manager:enqueue(app, true)
  app.windowID = nil; e.windows = {}
  e.manager:tick()
  equal(e.manager.paused, false)
  equal(#e.moved, 0)
  equal(#e.manager.queue, 0)
end)

test('closing a window during its move releases the operation without pausing', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local ws = e:addWorkspace(1, 'one', screen)
  local target = e:addWorkspace(2, 'two', screen)
  local app = e:addWindow(10, 'app', ws)
  e:start(); e.manager:move(app, target, false)
  app.windowID = nil; e.windows = {}
  e:advance(1)
  equal(e.manager.busy, false)
  equal(e.manager.paused, false)
  equal(#e.remembered, 0)
end)

test('topology changes cancel committing an in-flight destination', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local ws = e:addWorkspace(1, 'one', screen)
  local target = e:addWorkspace(2, 'two', screen)
  local app = e:addWindow(10, 'app', ws)
  e:start(); e.manager:move(app, target, false)
  e.manager:topologyChanged(); e:advance(1)
  equal(e.manager.busy, false)
  equal(#e.remembered, 0)
end)

test('reordering physical Spaces updates layout once without moving apps or profile rules', function()
  local e = fixture()
  chromeGroups(e)
  local screen = e:addScreen('a')
  local chromeWS = e:addWorkspace(1, 'chrome-space', screen)
  local vaultWS = e:addWorkspace(2, 'vault-space', screen)
  local chrome = e:addWindow(10, chromeBundle, chromeWS)
  chrome.profile = 'Profile 1'
  local vault = e:addWindow(11, 'com.bitwarden.desktop', vaultWS)
  e.rules[chromeBundle .. '::Profile 1'] = chromeWS
  e.rules['com.bitwarden.desktop'] = vaultWS
  e:start(); e:advance(8); e.manager:tick(); e.manager:tick()
  local chromeRule = e.rules[chromeBundle .. '::Profile 1']
  local vaultRule = e.rules['com.bitwarden.desktop']
  e.remembered = {}
  e.workspaces = { vaultWS, chromeWS }
  vaultWS.localIndex, vaultWS.index = 1, 1
  chromeWS.localIndex, chromeWS.index = 2, 2
  e.manager:tick(); equal(e.manager:status().layoutRevision, 0)
  e:advance(1); e.manager:tick()
  local status = e.manager:status()
  equal(status.layoutRevision, 1)
  equal(status.layoutChange, 'reordered')
  equal(status.layoutChangedAt, e.now)
  equal(status.layoutChangedScreens[1], 'a')
  equal(status.settling, true)
  e:advance(3); e.manager:tick()
  equal(e.manager:status().layoutRevision, 1)
  equal(#e.moved, 0); equal(#e.remembered, 0)
  equal(chrome.spaceID, 1); equal(vault.spaceID, 2)
  equal(e.rules[chromeBundle .. '::Profile 1'], chromeRule)
  equal(e.rules['com.bitwarden.desktop'], vaultRule)
end)

test('monitor enumeration order and global numbering do not count as desktop reordering', function()
  local e = fixture()
  local first = e:addWorkspace(1, 'one', e:addScreen('a'))
  local second = e:addWorkspace(2, 'two', e:addScreen('b'))
  e:start(); e:advance(8); e.manager:tick()
  e.screens = { second.screen, first.screen }
  e.workspaces = { second, first }
  first.index, second.index = 2, 1
  e.manager:tick(); e:advance(2); e.manager:tick()
  equal(e.manager:status().layoutRevision, 0)
  equal(e.manager:status().layoutChangedAt, nil)
end)

test('layout polling detects stable reordered Spaces while automation is paused', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local first = e:addWorkspace(1, 'one', screen)
  local second = e:addWorkspace(2, 'two', screen)
  e:start(); e.manager:pause()
  first.localIndex, second.localIndex = 2, 1
  e.manager:tick(); e:advance(1); e.manager:tick()
  equal(e.manager:status().paused, true)
  equal(e.manager:status().layoutChange, 'reordered')
  equal(e.manager:status().layoutRevision, 1)
  equal(#e.moved, 0)
end)

test('adding a Space is distinguished from reordering existing Spaces', function()
  local e = fixture()
  local screen = e:addScreen('a')
  e:addWorkspace(1, 'one', screen)
  e:start(); e.manager:pause()
  e:addWorkspace(2, 'two', screen)
  e.manager:tick(); e:advance(1); e.manager:tick()
  equal(e.manager:status().layoutChange, 'spaces-changed')
  equal(e.manager:status().layoutRevision, 1)
end)

test('stable whole-Space relocation reports new monitor for that exact Space identity', function()
  local e = fixture()
  local firstScreen, secondScreen = e:addScreen('a'), e:addScreen('b')
  local moved = e:addWorkspace(1, 'moved-space', firstScreen)
  e:addWorkspace(2, 'staying-space', firstScreen)
  e:addWorkspace(3, 'other-monitor-space', secondScreen)
  e:start(); e:advance(8); e.manager:tick()
  moved.screen, moved.screenUUID, moved.localIndex = secondScreen, 'b', 2
  e.manager:tick(); e:advance(1); e.manager:tick()
  equal(e.manager:status().layoutChange, 'spaces-moved')
  equal(#e.adoptedLayouts, 1)
  equal(#e.adoptedLayouts[1], 1)
  local adopted = e.adoptedLayouts[1][1]
  equal(adopted.spaceUUID, 'moved-space')
  equal(adopted.spaceID, 1)
  equal(adopted.fromScreenUUID, 'a')
  equal(adopted.toScreenUUID, 'b')
  equal(#e.moved, 0)
end)

test('Space relocation during display settling cannot rewrite its home monitor', function()
  local e = fixture()
  local firstScreen, secondScreen = e:addScreen('a'), e:addScreen('b')
  local moved = e:addWorkspace(1, 'moved-space', firstScreen)
  e:addWorkspace(2, 'staying-space', firstScreen)
  e:addWorkspace(3, 'other-monitor-space', secondScreen)
  e:start(); e:advance(8); e.manager:tick()
  e.manager:topologyChanged()
  moved.screen, moved.screenUUID, moved.localIndex = secondScreen, 'b', 2
  e.manager:tick(); e:advance(1); e.manager:tick()
  equal(e.manager:status().layoutChange, 'spaces-changed')
  equal(#e.adoptedLayouts, 0)
  e:advance(8); e.manager:tick()
  equal(#e.adoptedLayouts, 0)
end)

test('moving a whole destination Space during verification cannot apply its old monitor frame', function()
  local e = fixture()
  local firstScreen, secondScreen = e:addScreen('a'), e:addScreen('b')
  local first = e:addWorkspace(1, 'one', firstScreen)
  local target = e:addWorkspace(2, 'target', firstScreen)
  e:addWorkspace(3, 'other-monitor-space', secondScreen)
  local app = e:addWindow(10, 'app', first)
  e:start(); e.manager:move(app, target, false)
  -- Runtime workspace maps are rebuilt; the move closure still holds the old record.
  e.workspaces[2] = { spaceID = 2, spaceUUID = 'target', screenUUID = 'b',
    screen = secondScreen, localIndex = 2, index = 3 }
  e:advance(0.5)
  equal(#e.remembered, 0)
  equal(e.framed, 0)
  equal(app.restoredScreens, 0)
  equal(e.manager.busy, false)
  equal(e.manager.paused, false)
  equal(#e.manager.queue, 0, 'an existing window must not be requeued after its whole Space moved')
end)

test('Mission Control suppresses transient window locations and intermediate card order', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local first = e:addWorkspace(1, 'one', screen)
  local second = e:addWorkspace(2, 'two', screen)
  local app = e:addWindow(10, 'app', first)
  e.rules.app = first
  e:start(); e:advance(8); e.manager:tick(); e.remembered = {}
  e.missionControl = true
  first.localIndex, second.localIndex = 2, 1
  e:setLocation(app, 2)
  e.manager:tick(); e:advance(5); e.manager:tick()
  equal(e.manager:status().missionControl, true)
  equal(e.manager:status().layoutRevision, 0)
  equal(#e.remembered, 0); equal(#e.moved, 0)
  -- The user cancels the drag; temporary AX/Space states must not be persisted.
  e:setLocation(app, 1)
  first.localIndex, second.localIndex = 1, 2
  e.missionControl = false
  e.manager:tick(); e:advance(3); e.manager:tick()
  equal(e.manager:status().missionControl, false)
  equal(e.manager:status().layoutRevision, 0)
  equal(#e.remembered, 0); equal(#e.moved, 0)
  equal(e.rules.app.spaceID, 1)
end)

test('manual window drag after Mission Control wins over queued automatic placement', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local first = e:addWorkspace(1, 'one', screen)
  e:addWorkspace(2, 'two', screen)
  local app = e:addWindow(10, 'app', first)
  e:start(); e:advance(8); e.manager:tick(); e.remembered = {}
  e.manager:enqueue(app, true)
  e.missionControl = true; e:setLocation(app, 2)
  e.manager:tick(); e:advance(3); e.manager:tick()
  equal(#e.manager.queue, 1); equal(#e.remembered, 0)
  e.missionControl = false; e.manager:tick()
  e:advance(2); e.manager:tick()
  equal(#e.manager.queue, 0)
  e:advance(1); e.manager:tick(); e:advance(1); e.manager:tick()
  equal(#e.moved, 0); equal(#e.remembered, 1)
  equal(e.remembered[1].manual, true)
  equal(e.rules.app.spaceID, 2)
end)

test('Mission Control prevents automatic Space creation and deletion', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local first = e:addWorkspace(1, 'one', screen)
  local app = e:addWindow(10, 'app', first)
  e:addWindow(11, 'other', first)
  e:start(); e:advance(8); e.manager.rebaseline = false
  e.missionControl = true
  e.manager:apply(app, true)
  equal(#e.added, 0); equal(#e.moved, 0)
  e.manager.queue, e.manager.queued = {}, {}
  e:addWorkspace(2, 'empty', screen)
  e.manager.emptySince[2] = 0
  e.manager:cleanup()
  equal(#e.removed, 0)
end)

test('mouse-held drag is settled before learning a manually moved window', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local first = e:addWorkspace(1, 'one', screen)
  e:addWorkspace(2, 'two', screen)
  local app = e:addWindow(10, 'app', first)
  e:start(); e:advance(8); e.manager:tick(); e.remembered = {}
  e.mouseButtons = { left = true }; e:setLocation(app, 2)
  e.manager:tick(); e:advance(5); e.manager:tick()
  equal(#e.remembered, 0)
  e.mouseButtons = {}; e.manager:tick()
  e:advance(2); e.manager:tick()
  e:advance(1); e.manager:tick(); e:advance(1); e.manager:tick()
  equal(#e.remembered, 1); equal(e.remembered[1].manual, true)
  equal(#e.moved, 0)
end)

local function settleExistingWindows(e)
  e:start()
  e.manager.cleanupEnabled = false
  e:advance(8); e.manager:tick()
end

local function assertNoAutomaticChanges(e)
  equal(#e.moved, 0, 'existing windows must not move between Spaces')
  equal(#e.added, 0, 'existing windows must not cause Space creation')
  equal(e.framed, 0, 'automatic placement must not resize windows')
  equal(e.followed, 0, 'automatic placement must not switch focus or Space')
  equal(#e.manager.queue, 0, 'existing windows must not be queued for placement')
  for _, window in pairs(e.knownWindows) do
    equal(window.restoredFrames, 0, 'the manager must not write a window frame')
    equal(window.restoredScreens, 0, 'the manager must not reposition a window on its monitor')
  end
end

test('startup observes shared and conflicting existing windows without rearranging them', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local current = e:addWorkspace(1, 'current', screen)
  local pinned = e:addWorkspace(2, 'pinned', screen)
  e:addWorkspace(3, 'empty', screen)
  local first = e:addWindow(10, 'first', current)
  e:addWindow(11, 'second', current)
  e:addWindow(12, 'pinned-occupant', pinned)
  e.rules.first = pinned
  e.focusedWindow = first
  settleExistingWindows(e)
  e:advance(2); e.manager:tick()
  assertNoAutomaticChanges(e)
  equal(first.spaceID, current.spaceID)
  equal(e.rules.first, pinned, 'observing must not rewrite a saved assignment')
  equal(#e.remembered, 0)
end)

test('resume preserves positions chosen while paused without applying old assignments', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local old = e:addWorkspace(1, 'old', screen)
  local chosen = e:addWorkspace(2, 'chosen', screen)
  local app = e:addWindow(10, 'app', old)
  e.rules.app = old
  settleExistingWindows(e)
  e.manager:pause()
  e:setLocation(app, chosen.spaceID)
  e.manager:resume()
  e:advance(3); e.manager:tick()
  e:advance(3); e.manager:tick()
  assertNoAutomaticChanges(e)
  equal(app.spaceID, chosen.spaceID)
  equal(#e.remembered, 0)
end)

test('display settling never pushes an existing window back to its previous monitor', function()
  local e = fixture()
  local firstScreen, secondScreen = e:addScreen('a'), e:addScreen('b')
  local old = e:addWorkspace(1, 'old', firstScreen)
  local current = e:addWorkspace(2, 'current', secondScreen)
  local app = e:addWindow(10, 'app', old)
  e.rules.app = old
  settleExistingWindows(e)
  e:setLocation(app, current.spaceID)
  e.manager:topologyChanged()
  e:advance(9); e.manager:tick()
  e:advance(2); e.manager:tick()
  assertNoAutomaticChanges(e)
  equal(app.spaceID, current.spaceID)
  equal(app:screen(), secondScreen)
  equal(#e.remembered, 0)
end)

test('discovering an existing off-Space window through windowCreated does not move it', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local current = e:addWorkspace(1, 'current', screen)
  local pinned = e:addWorkspace(2, 'pinned', screen)
  local app = e:addWindow(10, 'app', current, false)
  e.rules.app = pinned
  settleExistingWindows(e)
  e.manager.births:observe(e.rawWindows, false, e.now)
  e.windows = { app }
  e:emit('created', app) -- Hammerspoon emits this while discovering old Spaces.
  e.manager:tick()
  e:advance(2); e.manager:tick()
  assertNoAutomaticChanges(e)
  equal(app.spaceID, current.spaceID)
  equal(#e.remembered, 0)
end)

test('an AX creation event alone cannot authorize moving an unverified window', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local current = e:addWorkspace(1, 'current', screen)
  e:addWorkspace(2, 'empty', screen)
  e:addWindow(11, 'occupant', current)
  settleExistingWindows(e)
  local app = e:addWindow(10, 'unverified', current)
  e:emit('created', app)
  e.manager:tick()
  assertNoAutomaticChanges(e)
  equal(app.spaceID, current.spaceID)
end)

test('temporary AX disappearance preserves an existing window identity without placement', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local current = e:addWorkspace(1, 'current', screen)
  local pinned = e:addWorkspace(2, 'pinned', screen)
  local app = e:addWindow(10, 'app', current)
  e.rules.app = pinned
  settleExistingWindows(e)
  local observed = e.manager.observed[app:id()]
  e.windows = {}
  e:advance(1); e.manager:tick()
  equal(e.manager.observed[app:id()], observed, 'temporary filter omission is not destruction')
  e.windows = { app }
  e:emit('created', app)
  e:advance(1); e.manager:tick()
  assertNoAutomaticChanges(e)
  equal(app.spaceID, current.spaceID)
end)

test('recognizing a Chrome profile later does not rearrange its existing window', function()
  local e = fixture()
  chromeGroups(e)
  local screen = e:addScreen('a')
  local current = e:addWorkspace(1, 'current', screen)
  local pinned = e:addWorkspace(2, 'pinned', screen)
  local app = e:addWindow(10, chromeBundle, current, true, 500)
  app.profile = 'unresolved'
  e.rules[chromeBundle .. '::Profile 1'] = pinned
  settleExistingWindows(e)
  app.profile = 'Profile 1'
  e:advance(1); e.manager:tick()
  assertNoAutomaticChanges(e)
  equal(app.spaceID, current.spaceID)
end)

for _, sameSpace in ipairs({ true, false }) do
  test('automatic assignment preserves geometry and focus with same Space ' .. tostring(sameSpace), function()
    local e = fixture()
    local screen = e:addScreen('a')
    local source = e:addWorkspace(1, 'source', screen)
    local target = sameSpace and source or e:addWorkspace(2, 'target', screen)
    local app = e:addWindow(10, 'app', source)
    e.focusedWindow = app
    local originalFrame = app:frame()
    e:start()
    e.manager:move(app, target, false)
    e:advance(0.5)
    equal(app.spaceID, target.spaceID)
    equal(e.framed, 0)
    equal(e.followed, 0)
    equal(app:frame(), originalFrame)
    equal(app.restoredFrames, 0)
    equal(app.restoredScreens, 0)
  end)
end

test('a proven CG birth places only the newly opened window', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local source = e:addWorkspace(1, 'source', screen)
  local target = e:addWorkspace(2, 'target', screen)
  local existing = e:addWindow(10, 'existing', source)
  settleExistingWindows(e)
  e.manager.births:observe(e.rawWindows, false, e.now)
  local opened = e:addWindow(11, 'new-app', source)
  e.focusedWindow = opened
  e.manager.births:observe(e.rawWindows, true, e.now)
  e:emit('created', opened)
  e.manager:tick(); e:advance(0.5)
  equal(#e.moved, 1)
  equal(e.moved[1].windowID, opened:id())
  equal(opened.spaceID, target.spaceID)
  equal(existing.spaceID, source.spaceID)
  equal(e.framed, 0); equal(e.followed, 0)
  e.manager:tick(); e:advance(1); e.manager:tick()
  equal(#e.moved, 1, 'a birth can be consumed only once')
end)

test('a proven new window waits across unavailable Space readings and is placed exactly once', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local source = e:addWorkspace(1, 'source', screen)
  local target = e:addWorkspace(2, 'target', screen)
  local existing = e:addWindow(10, 'existing', source)
  settleExistingWindows(e)
  e.manager.births:observe(e.rawWindows, false, e.now)
  local opened = e:addWindow(11, 'new-app', source)
  opened.spaceID = nil -- Accessibility discovery precedes the Space assignment.
  e.manager.births:observe(e.rawWindows, true, e.now)
  e:emit('created', opened)
  for _ = 1, 3 do
    e.manager:tick(); e:advance(1)
    equal(#e.moved, 0)
    equal(#e.manager.queue, 0)
    assert(e.manager.births.pending[opened:id()], 'temporary missing location must retain the birth')
  end
  opened.spaceID = source.spaceID
  e.manager:tick(); e:advance(0.5)
  equal(#e.moved, 1)
  equal(e.moved[1].windowID, opened:id())
  equal(opened.spaceID, target.spaceID)
  equal(existing.spaceID, source.spaceID)
  equal(e.framed, 0); equal(e.followed, 0)
  e.manager:tick(); e:advance(1); e.manager:tick()
  equal(#e.moved, 1, 'resolved location must not repeat automatic placement')
end)

test('new Chrome profile siblings join their assignment without moving existing profiles', function()
  local e = fixture()
  chromeGroups(e)
  local screen = e:addScreen('a')
  local source = e:addWorkspace(1, 'source', screen)
  local profileSpace = e:addWorkspace(2, 'profile', screen)
  local other = e:addWindow(10, chromeBundle, source, true, 500)
  local sibling = e:addWindow(11, chromeBundle, profileSpace, true, 500)
  other.profile, sibling.profile = 'Profile 2', 'Profile 1'
  e.rules[chromeBundle .. '::Profile 1'] = profileSpace
  settleExistingWindows(e)
  e.manager.births:observe(e.rawWindows, false, e.now)
  local opened = e:addWindow(12, chromeBundle, source, true, 500)
  opened.profile = 'Profile 1'
  e.manager.births:observe(e.rawWindows, true, e.now)
  e:emit('created', opened)
  e.manager:tick(); e:advance(0.5)
  equal(#e.moved, 1)
  equal(e.moved[1].windowID, opened:id())
  equal(opened.spaceID, profileSpace.spaceID)
  equal(sibling.spaceID, profileSpace.spaceID)
  equal(other.spaceID, source.spaceID)
end)

test('pausing discards a pending birth instead of moving that old window on resume', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local source = e:addWorkspace(1, 'source', screen)
  e:addWorkspace(2, 'empty', screen)
  e:addWindow(10, 'existing', source)
  settleExistingWindows(e)
  e.manager.births:observe(e.rawWindows, false, e.now)
  local opened = e:addWindow(11, 'new-app', source)
  e.manager.births:observe(e.rawWindows, true, e.now)
  e.manager:pause()
  e.manager:resume()
  e:advance(3); e.manager:tick()
  e:advance(2); e.manager:tick()
  assertNoAutomaticChanges(e)
  equal(opened.spaceID, source.spaceID)
end)

test('manual placement of a queued new window cancels its pending automatic assignment', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local source = e:addWorkspace(1, 'source', screen)
  local pinned = e:addWorkspace(2, 'pinned', screen)
  local chosen = e:addWorkspace(3, 'chosen', screen)
  settleExistingWindows(e)
  local app = e:addWindow(10, 'app', source)
  e.rules.app = pinned
  e.manager:enqueue(app, true)
  e:setLocation(app, chosen.spaceID)
  e.manager:tick()
  e:advance(1); e.manager:tick()
  e:advance(1); e.manager:tick()
  assertNoAutomaticChanges(e)
  equal(app.spaceID, chosen.spaceID)
  equal(e.rules.app.spaceID, chosen.spaceID)
  equal(#e.remembered, 1)
  equal(e.remembered[1].manual, true)
end)

test('manual drag after AX creation wins before a genuine birth is first consumed', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local source = e:addWorkspace(1, 'source', screen)
  local pinned = e:addWorkspace(2, 'pinned', screen)
  local chosen = e:addWorkspace(3, 'chosen', screen)
  settleExistingWindows(e)
  e.manager.births:observe(e.rawWindows, false, e.now)
  local app = e:addWindow(10, 'app', source)
  e.rules.app = pinned
  e.manager.births:observe(e.rawWindows, true, e.now)
  e:emit('created', app)
  e:setLocation(app, chosen.spaceID)
  e.manager:tick()
  e:advance(1); e.manager:tick()
  e:advance(1); e.manager:tick()
  assertNoAutomaticChanges(e)
  equal(app.spaceID, chosen.spaceID)
  equal(e.rules.app.spaceID, chosen.spaceID)
  equal(#e.remembered, 1)
  equal(e.remembered[1].manual, true)
end)

for _, guard in ipairs({ 'mouse click', 'Mission Control', 'layout settling' }) do
  test('native birth during ' .. guard .. ' waits then places only the new window', function()
    local e = metadataFixture('{"windows":[]}')
    chromeGroups(e)
    local screen = e:addScreen('a')
    local source = e:addWorkspace(1, 'source', screen)
    local target = e:addWorkspace(2, 'target', screen)
    local existing = e:addWindow(10, chromeBundle, source, true, 500)
    existing.profile = 'Profile 1'
    e.decodedWindows = e.rawWindows
    e:start()
    e.tasks[#e.tasks]:complete(0, e.wireFrame); e:advance(0.2)
    e:advance(9); e.manager:tick()
    e.tasks[#e.tasks]:complete(0, e.wireFrame); e:advance(0.2)

    local opened = e:addWindow(11, chromeBundle, source, true, 500)
    opened.profile = 'Profile 2'
    e:emit('created', opened)
    e:advance(2)
    if guard == 'mouse click' then e.mouseButtons = { left = true }
    elseif guard == 'Mission Control' then e.missionControl = true
    else e.manager.layoutGuardUntil = e.now + 4 end
    e.manager:tick()
    e.tasks[#e.tasks]:complete(0, e.wireFrame); e:advance(0.2)
    equal(#e.moved, 0, 'interaction must delay placement')
    equal(opened.spaceID, source.spaceID)

    e.mouseButtons, e.missionControl = {}, false
    e.manager:tick(); e:advance(4); e.manager:tick(); e:advance(0.5)
    equal(#e.moved, 1, 'a native birth must survive the delivery guard')
    equal(e.moved[1].windowID, opened:id())
    equal(opened.spaceID, target.spaceID)
    equal(existing.spaceID, source.spaceID)
    equal(e.framed, 0); equal(e.followed, 0)
    e.manager:tick(); e:advance(1); e.manager:tick()
    equal(#e.moved, 1, 'the new window is placed only once')
  end)
end

test('locked sessions discard pending work and block all placement and cleanup entry points', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local source = e:addWorkspace(1, 'source', screen)
  local target = e:addWorkspace(2, 'target', screen)
  local existing = e:addWindow(10, 'existing', source)
  settleExistingWindows(e)
  e.manager.births:observe(e.rawWindows, false, e.now)
  local opened = e:addWindow(11, 'new-app', source)
  e.manager.births:observe(e.rawWindows, true, e.now)
  e.manager:enqueue(opened, true)
  e.manager.emptySince[target.spaceID] = e.now - 30
  local generation = e.manager.generation
  e.sessionLocked = true
  e.manager:tick()
  equal(e.manager:status().locked, true)
  equal(e.manager.generation, generation + 1)
  equal(#e.manager.queue, 0); equal(next(e.manager.queued), nil)
  equal(next(e.manager.births.pending), nil); equal(next(e.manager.emptySince), nil)
  e.manager:move(opened, target, false)
  e.manager:manualMove(opened, target)
  e.manager:apply(opened, true)
  e.manager:enqueue(opened, true)
  e.manager:cleanup()
  e:setLocation(existing, target.spaceID)
  e:advance(10); e.manager:tick()
  equal(e.manager.generation, generation + 1, 'remaining locked does not repeatedly cancel generations')
  equal(#e.manager.queue, 0)
  equal(#e.moved, 0); equal(#e.added, 0); equal(#e.removed, 0); equal(#e.remembered, 0)
  equal(e.settings['deskpilot.paused.v2'], false)
end)

for _, paused in ipairs({ false, true }) do
  test('unlock baselines existing windows and preserves pause setting ' .. tostring(paused), function()
    local e = fixture()
    e.settings['deskpilot.paused.v2'] = paused
    local screen = e:addScreen('a')
    local original = e:addWorkspace(1, 'original', screen)
    local chosen = e:addWorkspace(2, 'chosen', screen)
    local existing = e:addWindow(10, 'existing', original)
    e.rules.existing = original
    settleExistingWindows(e)
    e.sessionLocked = true; e.manager:tick()
    e:setLocation(existing, chosen.spaceID)
    local opened = e:addWindow(11, 'new-app', chosen)
    e.manager:tick()
    e.sessionLocked = false
    local unlockTime, generation = e.now, e.manager.generation
    if paused then e.manager:topologyChanged() else e.manager:tick() end
    equal(e.manager.generation, generation + 1, 'unlock cancels the old generation once')
    equal(e.manager:status().locked, false)
    equal(e.manager.guardUntil, unlockTime + 8)
    equal(e.manager.rebaseline, true)
    e:advance(7); e.manager:tick()
    equal(e.manager.rebaseline, true)
    e:advance(2); e.manager:tick()
    e:advance(2); e.manager:tick()
    assertNoAutomaticChanges(e)
    equal(existing.spaceID, chosen.spaceID); equal(opened.spaceID, chosen.spaceID)
    equal(#e.remembered, 0)
    equal(e.manager.paused, paused); equal(e.settings['deskpilot.paused.v2'], paused)
  end)
end

test('locking before move verification cancels without launching a helper or pausing', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local source = e:addWorkspace(1, 'source', screen)
  local target = e:addWorkspace(2, 'target', screen)
  local existing = e:addWindow(10, 'existing', source)
  settleExistingWindows(e)
  e.moveMode, e.helperMode = 'unconfirmed', 'file'
  e.manager:move(existing, target, false)
  e.sessionLocked = true
  e:advance(0.5) -- Callback must detect lock even before the next polling tick.
  equal(#e.moved, 1); equal(e.helperCalls, 0)
  equal(e.manager.busy, false); equal(next(e.manager.reserved), nil)
  equal(#e.remembered, 0); equal(#e.alerts, 0); equal(e.manager.lastError, nil)
  equal(e.manager.paused, false); equal(e.settings['deskpilot.paused.v2'], false)
end)

test('locking terminates an in-flight native move and its callback does not report failure', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local source = e:addWorkspace(1, 'source', screen)
  local target = e:addWorkspace(2, 'target', screen)
  local existing = e:addWindow(10, 'existing', source)
  settleExistingWindows(e)
  local terminations = 0
  e.taskFactory = function(_, callback)
    return { start = function(self) return self end,
      terminate = function() terminations = terminations + 1; callback(1, '', '') end }
  end
  e.moveMode, e.helperMode = 'unconfirmed', 'file'
  e.manager:move(existing, target, false); e:advance(0.5)
  equal(e.helperCalls, 1)
  e.sessionLocked = true; e.manager:tick(); e:advance(0.5)
  equal(terminations, 1)
  equal(e.manager.busy, false); equal(e.manager.nativeTask, nil)
  equal(#e.remembered, 0); equal(#e.alerts, 0); equal(e.manager.lastError, nil)
  equal(e.manager.paused, false); equal(e.settings['deskpilot.paused.v2'], false)
end)

test('a Dock workarea notification preserves new births and queued placement', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local source = e:addWorkspace(1, 'source', screen)
  local target = e:addWorkspace(2, 'target', screen)
  local existing = e:addWindow(10, 'existing', source)
  settleExistingWindows(e)
  e.manager.births:observe(e.rawWindows, false, e.now)
  local opened = e:addWindow(11, 'new-app', source)
  e.manager.births:observe(e.rawWindows, true, e.now)
  e.manager:enqueue(opened, true)
  local generation, guard = e.manager.generation, e.manager.guardUntil
  screen.visibleRectangle.x, screen.visibleRectangle.w = 65, 1855
  e.manager.screenWatcher.callback()
  screen.visibleRectangle.x, screen.visibleRectangle.w = 64, 1856
  e.manager.screenWatcher.callback()
  equal(e.manager.generation, generation)
  equal(e.manager.guardUntil, guard)
  equal(e.manager.rebaseline, false)
  equal(#e.manager.queue, 1)
  assert(e.manager.births.pending[opened:id()], 'Dock size changes must preserve the genuine birth')
  e.manager:tick(); e:advance(0.5)
  equal(#e.moved, 1); equal(e.moved[1].windowID, opened:id())
  equal(opened.spaceID, target.spaceID); equal(existing.spaceID, source.spaceID)
end)

for _, change in ipairs({ 'added monitor', 'changed full frame' }) do
  test('a screen notification for ' .. change .. ' cancels placement and rebaselines once', function()
    local e = fixture()
    local screen = e:addScreen('a')
    local source = e:addWorkspace(1, 'source', screen)
    e:addWorkspace(2, 'target', screen)
    e:addWindow(10, 'existing', source)
    settleExistingWindows(e)
    e.manager.births:observe(e.rawWindows, false, e.now)
    local opened = e:addWindow(11, 'new-app', source)
    e.manager.births:observe(e.rawWindows, true, e.now)
    e.manager:enqueue(opened, true)
    local generation = e.manager.generation
    if change == 'added monitor' then e:addScreen('b')
    else screen.fullRectangle.w = 2560 end
    e.manager.screenWatcher.callback()
    equal(e.manager.generation, generation + 1)
    equal(e.manager.guardUntil, e.now + 8)
    equal(e.manager.rebaseline, true)
    equal(#e.manager.queue, 0); equal(next(e.manager.births.pending), nil)
    e.manager:tick(); e.manager.screenWatcher.callback()
    equal(e.manager.generation, generation + 1, 'the same physical change must not reset twice')
    equal(#e.moved, 0)
  end)
end

test('polling a monitor change before its screen notification does not rebaseline again', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local source = e:addWorkspace(1, 'source', screen)
  local target = e:addWorkspace(2, 'target', screen)
  local existing = e:addWindow(10, 'existing', source)
  settleExistingWindows(e)
  e.manager.births:observe(e.rawWindows, false, e.now)
  local generation = e.manager.generation
  e:addWorkspace(3, 'other-monitor', e:addScreen('b'))
  e.manager:tick() -- Polling notices the physical change before the watcher fires.
  equal(e.manager.generation, generation + 1)
  local guard = e.manager.guardUntil
  e:advance(9); e.manager:tick()
  e:advance(2); e.manager:tick()
  equal(e.manager.rebaseline, false)
  local opened = e:addWindow(11, 'new-app', source)
  e.manager.births:observe(e.rawWindows, true, e.now)
  e.manager:enqueue(opened, true)
  e.manager.screenWatcher.callback() -- A delayed notification describes the same display state.
  equal(e.manager.generation, generation + 1)
  equal(e.manager.guardUntil, guard)
  equal(e.manager.rebaseline, false)
  equal(#e.manager.queue, 1)
  assert(e.manager.births.pending[opened:id()], 'duplicate notification must preserve a later new window')
  e.manager:tick(); e:advance(0.5)
  equal(#e.moved, 1); equal(e.moved[1].windowID, opened:id())
  equal(opened.spaceID, target.spaceID); equal(existing.spaceID, source.spaceID)
end)

test('session occupancy ignores known participants but keeps unknown windows occupied', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local ws = e:addWorkspace(1, 'target', screen)
  e:addWindow(10, 'participant', ws)
  settleExistingWindows(e)
  equal(e.manager:occupancy()[1], true)
  equal(e.manager:occupancy(nil, { participant = true })[1], false)
  e.spaceWindows[1][#e.spaceWindows[1] + 1] = 999
  equal(e.manager:occupancy(nil, { participant = true })[1], true)
  e.context.groupKeyForWindowID = function(id, pid)
    if id == 999 and pid == 77 then return 'participant' end
  end
  e.rawWindows[#e.rawWindows + 1] = { kCGWindowNumber = 999, kCGWindowOwnerPID = 77, kCGWindowLayer = 0 }
  equal(e.manager:occupancy(nil, { participant = true })[1], false)
end)

test('restoration owns claimed windows including previously queued windows', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local ws = e:addWorkspace(1, 'source', screen)
  e:addWorkspace(2, 'target', screen)
  local window = e:addWindow(10, 'restored', ws)
  settleExistingWindows(e)
  e.manager:enqueue(window, true)
  equal(#e.manager.queue, 1)
  e.manager.session = { claims = function(_, key) return key == 'restored' end }
  e.manager:apply(window, true)
  e.manager.queue, e.manager.queued = {}, {}
  e.manager:enqueue(window, true)
  equal(#e.manager.queue, 0); equal(#e.moved, 0); equal(#e.added, 0)
end)

test('a restored window remains a known participant after AX disappears, with exact PID binding', function()
  local e = fixture()
  local ws = e:addWorkspace(1, 'target', e:addScreen('a'))
  local window = e:addWindow(10, 'participant', ws)
  settleExistingWindows(e)
  e.windows = {} -- Inactive desktop no longer exposes the moved window via AX.
  equal(e.manager:occupancy()[1], true, 'known windows still prevent empty desktop cleanup')
  equal(e.manager:occupancy(nil, { participant = true })[1], false)
  e.windows = { window }
  e.groupKey = function() return 'different-profile' end
  equal(e.manager:occupancy(nil, { participant = true })[1], true, 'live AX group overrides old observation')
  e.windows = {}
  e.rawWindows[1].kCGWindowOwnerPID = window:application():pid() + 1
  equal(e.manager:occupancy(nil, { participant = true })[1], true, 'reused ID cannot inherit a group')
end)

test('unknown physical monitor roles defer assignment without creating Spaces', function()
  local e = fixture()
  local screen = e:addScreen('a')
  local ws = e:addWorkspace(1, 'source', screen)
  local window = e:addWindow(10, 'app', ws)
  settleExistingWindows(e)
  e.context.preferredScreen = function() return false end
  e.manager:apply(window, true)
  equal(#e.manager.queue, 1); equal(#e.moved, 0); equal(#e.added, 0)
end)

test('a role-based destination overrides an old monitor without automatic resize or focus', function()
  local e = fixture()
  local source = e:addWorkspace(1, 'old', e:addScreen('external'))
  local target = e:addWorkspace(2, 'new', e:addScreen('builtin'))
  local window = e:addWindow(10, 'utility', source)
  settleExistingWindows(e)
  e.rules.utility = { spaceUUID = source.spaceUUID, screenUUID = source.screenUUID }
  e.context.preferredScreen = function() return 'builtin' end
  e.manager:apply(window, true); e:advance(0.5)
  equal(window.spaceID, target.spaceID); equal(#e.added, 0)
  equal(e.framed, 0); equal(e.followed, 0); equal(window.restoredFrames, 0)
end)

test('cancelled system shutdown can resume without persisting a paused startup preference', function()
  local e = fixture()
  e:addWorkspace(1, 'target', e:addScreen('a'))
  settleExistingWindows(e)
  local frozen, thawed = 0, 0
  e.manager.session = { freeze = function() frozen = frozen + 1 end,
    thaw = function() thawed = thawed + 1 end }
  e.manager:shutdown()
  equal(frozen, 1); equal(e.manager.shuttingDown, true); equal(e.manager.paused, true)
  equal(e.settings['deskpilot.paused.v2'], false)
  e.manager:resume()
  equal(thawed, 1); equal(e.manager.shuttingDown, false); equal(e.manager.paused, false)
  equal(e.manager.rebaseline, true)
end)

local function installFollowSpy(e)
  e.followPreparations, e.followCompletions, e.followCancellations = {}, {}, 0
  e.context.prepareFollow = function(window)
    local prepared = { window = window, before = 0, completed = false }
    e.followPreparations[#e.followPreparations + 1] = prepared
    return {
      beforeMove = function()
        prepared.before = prepared.before + 1
        return true
      end,
      complete = function(_, target)
        equal(prepared.completed, false, 'follow must complete at most once')
        assert(prepared.before > 0, 'follow must be checked before the move')
        equal(window.spaceID, target.spaceID, 'follow only after confirmed placement')
        prepared.completed = true
        e.followed = e.followed + 1
        e.followCompletions[#e.followCompletions + 1] = { windowID = window:id(), target = target }
      end,
      cancel = function() e.followCancellations = e.followCancellations + 1 end,
    }
  end
end

local function followFixture(noFreeSpace)
  local e = fixture()
  local screen = e:addScreen('a')
  e.source = e:addWorkspace(1, 'source', screen)
  if not noFreeSpace then e.target = e:addWorkspace(2, 'target', screen) end
  e.existing = e:addWindow(10, 'existing', e.source)
  settleExistingWindows(e)
  e.manager.followQuietUntil = 0 -- These cases represent ordinary work after startup.
  e.manager.births:observe(e.rawWindows, false, e.now)
  installFollowSpy(e)
  return e
end

local function publishFollowBirth(e, focused)
  local opened = e:addWindow(11, 'new-app', e.source)
  e.focusedWindow = focused == false and e.existing or opened
  e.manager.births:observe(e.rawWindows, true, e.now)
  e:emit('created', opened)
  return opened
end

test('a foreground CG birth after user input follows exactly once without changing its frame', function()
  local e = followFixture()
  local opened = publishFollowBirth(e)
  local originalFrame = opened:frame()
  e.manager:noteUserInput()
  e.manager:tick(); e:advance(0.5)
  equal(#e.moved, 1); equal(e.moved[1].windowID, opened:id())
  equal(opened.spaceID, e.target.spaceID); equal(e.existing.spaceID, e.source.spaceID)
  equal(#e.followPreparations, 1); equal(e.followed, 1)
  equal(e.followCompletions[1].windowID, opened:id())
  equal(e.followCompletions[1].target.spaceID, e.target.spaceID)
  equal(opened:frame(), originalFrame); equal(opened.restoredFrames, 0)
  equal(opened.restoredScreens, 0); equal(e.framed, 0)
  e.manager:tick(); e:advance(1); e.manager:tick()
  equal(#e.moved, 1); equal(#e.followPreparations, 1); equal(e.followed, 1)
end)

test('a background CG birth is placed without preparing a follow even after recent input', function()
  local e = followFixture()
  local opened = publishFollowBirth(e, false)
  e.manager:noteUserInput()
  e.manager:tick(); e:advance(0.5)
  equal(opened.spaceID, e.source.spaceID); equal(#e.moved, 0, 'allow delayed AX focus before background placement')
  e:advance(1); e.manager:tick(); e:advance(0.5)
  equal(opened.spaceID, e.target.spaceID); equal(#e.moved, 1)
  equal(#e.followPreparations, 0); equal(e.followed, 0)
end)

test('a focused CG birth without user input never follows', function()
  local e = followFixture()
  local opened = publishFollowBirth(e)
  e.manager:tick(); e:advance(0.5)
  equal(opened.spaceID, e.target.spaceID); equal(#e.moved, 1)
  equal(#e.followPreparations, 0); equal(e.followed, 0)
end)

test('the startup quiet guard prevents follow despite a focused birth and recent input', function()
  local e = followFixture()
  local opened = publishFollowBirth(e)
  e.manager.followQuietUntil = e.now + 60
  e.manager:noteUserInput()
  e.manager:tick(); e:advance(0.5)
  equal(opened.spaceID, e.target.spaceID); equal(#e.moved, 1)
  equal(#e.followPreparations, 0); equal(e.followed, 0)
  e:advance(61); e.manager:tick()
  equal(#e.followPreparations, 0, 'startup suppression must not become a delayed follow')
end)

test('direct moves and enqueues without birth intent never prepare follow', function()
  for _, operation in ipairs({ 'move', 'enqueue' }) do
    local e = followFixture()
    local window = e:addWindow(11, 'new-app', e.source)
    e.focusedWindow = window
    e.manager:noteUserInput()
    if operation == 'move' then e.manager:move(window, e.target, false)
    else e.manager:enqueue(window, true); e.manager:tick() end
    e:advance(0.5)
    equal(window.spaceID, e.target.spaceID); equal(#e.moved, 1)
    equal(#e.followPreparations, 0, operation .. ' requires explicit birth intent')
    equal(e.followed, 0)
  end
end)

for _, interruption in ipairs({ 'input', 'focus' }) do
  test('a delayed birth queue loses follow intent after another ' .. interruption, function()
    local e = followFixture()
    local opened = publishFollowBirth(e)
    local holdQueue = true
    e.manager.session = {
      claims = function() return false end,
      isAutoLaunchPending = function() return false end,
      tick = function() return holdQueue end,
    }
    e.manager:noteUserInput()
    e.manager:tick()
    equal(#e.manager.queue, 1); equal(#e.moved, 0)
    equal(#e.followPreparations, 0, 'a waiting item must not arm the focus adapter')
    if interruption == 'input' then e.manager:noteUserInput()
    else e.focusedWindow = e.existing end
    holdQueue = false
    e.manager:tick(); e:advance(0.5)
    equal(opened.spaceID, e.target.spaceID); equal(#e.moved, 1)
    equal(#e.followPreparations, 0); equal(e.followed, 0)
  end)
end

test('creating a new Space retains only the genuine foreground birth follow intent', function()
  local e = followFixture(true)
  local opened = publishFollowBirth(e)
  e.manager:noteUserInput()
  e.manager:tick()
  equal(#e.added, 1); equal(#e.moved, 0); equal(e.followed, 0)
  e:advance(1.1)
  equal(#e.added, 1); equal(#e.moved, 1)
  equal(opened.spaceID, 1001); equal(e.existing.spaceID, e.source.spaceID)
  equal(#e.followPreparations, 1); equal(e.followed, 1)
  equal(e.followCompletions[1].target.spaceID, 1001)
  equal(opened.restoredFrames, 0); equal(e.framed, 0)
  e.manager:tick(); e:advance(1); e.manager:tick()
  equal(#e.added, 1); equal(#e.moved, 1); equal(e.followed, 1)
end)

test('Chrome profiles sharing a PID follow only their newly focused window to its profile Space', function()
  local e = fixture()
  chromeGroups(e)
  local screen = e:addScreen('a')
  local source = e:addWorkspace(1, 'source', screen)
  local target = e:addWorkspace(2, 'profile', screen)
  local other = e:addWindow(10, chromeBundle, source, true, 500)
  local sibling = e:addWindow(11, chromeBundle, target, true, 500)
  other.profile, sibling.profile = 'Profile 2', 'Profile 1'
  e.rules[chromeBundle .. '::Profile 1'] = target
  settleExistingWindows(e)
  e.manager.followQuietUntil = 0
  e.manager.births:observe(e.rawWindows, false, e.now)
  installFollowSpy(e)
  local opened = e:addWindow(12, chromeBundle, source, true, 500)
  opened.profile = 'Profile 1'
  e.focusedWindow = opened
  e.manager.births:observe(e.rawWindows, true, e.now)
  e:emit('created', opened)
  e.manager:noteUserInput()
  e.manager:tick(); e:advance(0.5)
  equal(#e.moved, 1); equal(e.moved[1].windowID, opened:id())
  equal(#e.added, 0); equal(opened.spaceID, target.spaceID)
  equal(sibling.spaceID, target.spaceID); equal(other.spaceID, source.spaceID)
  equal(#e.followPreparations, 1); equal(e.followPreparations[1].window, opened)
  equal(e.followed, 1); equal(e.followCompletions[1].windowID, opened:id())
end)

test('Space creation arms follow before its own Mission Control changes focus without user input', function()
  local e = followFixture(true)
  local opened = publishFollowBirth(e)
  local prepare, addSpace = e.context.prepareFollow, hs.spaces.addSpaceToScreen
  e.context.prepareFollow = function(window)
    local guard = prepare(window)
    local beforeMove = guard.beforeMove
    guard.beforeMove = function(self)
      beforeMove(self)
      return e.focusedWindow == window
    end
    return guard
  end
  hs.spaces.addSpaceToScreen = function(screen)
    equal(#e.followPreparations, 1, 'follow must be prepared before opening Mission Control')
    equal(e.followPreparations[1].before, 1, 'follow must be armed while the new window still has focus')
    e.focusedWindow = e.existing -- System-caused focus change; there is no user-input event.
    return addSpace(screen)
  end
  e.manager:noteUserInput()
  local serial = e.manager.inputSerial
  e.manager:tick(); e:advance(1.1)
  equal(e.manager.inputSerial, serial)
  equal(#e.added, 1); equal(#e.moved, 1); equal(opened.spaceID, 1001)
  equal(e.followPreparations[1].before, 1, 'own create/move sequence must not require a second focus check')
  equal(e.followCancellations, 0); equal(e.followed, 1)
  equal(e.followCompletions[1].windowID, opened:id())
  equal(e.framed, 0); equal(opened.restoredFrames, 0)
end)

test('follow waits for its Space creation Mission Control animation to close after the move confirms', function()
  local e=followFixture(true); local opened=publishFollowBirth(e)
  local addSpace=hs.spaces.addSpaceToScreen
  hs.spaces.addSpaceToScreen=function(screen)
    e.missionControl=true
    return addSpace(screen)
  end
  e.manager:noteUserInput(); e.manager:tick(); e:advance(1.1)
  equal(#e.moved,1); equal(opened.spaceID,1001); equal(e.followed,0)
  e:advance(.4); equal(e.followed,0)
  e.missionControl=false; e:advance(.15)
  equal(e.followed,1); equal(#e.followCompletions,1)
  e:advance(2); equal(e.followed,1); equal(#e.added,1)
end)

test('a topology change cancels follow while waiting for the creation animation to close', function()
  local e=followFixture(true); publishFollowBirth(e)
  local addSpace=hs.spaces.addSpaceToScreen
  hs.spaces.addSpaceToScreen=function(screen)
    e.missionControl=true
    return addSpace(screen)
  end
  e.manager:noteUserInput(); e.manager:tick(); e:advance(1.1)
  equal(#e.moved,1); equal(e.followed,0)
  e.manager:topologyChanged(); e.missionControl=false; e:advance(2)
  equal(e.followed,0); equal(e.followCancellations,1)
end)

test('the own Space switch flag ignores only Mission Control and retains every manager follow guard', function()
  for _, block in ipairs({'none','disabled','paused','locked','shutdown','startup','mouse','organizing'}) do
    local e=followFixture(); e.missionControl=true
    if block=='disabled' then e.manager.followEnabled=false
    elseif block=='paused' then e.manager.paused=true
    elseif block=='locked' then e.sessionLocked=true
    elseif block=='shutdown' then e.manager.shuttingDown=true
    elseif block=='startup' then e.manager.followQuietUntil=e.now+60
    elseif block=='mouse' then e.mouseButtons.left=true
    elseif block=='organizing' then e.manager.organizing=true end
    equal(e.manager:followBlocked(false),true,block)
    equal(e.manager:followBlocked(true),block~='none',block)
  end
end)

test('an autolaunched session claim cannot follow even when its new window is focused after input', function()
  local e = followFixture()
  local opened = publishFollowBirth(e)
  local cancellations = 0
  e.manager.session = {
    claims = function(_, key) return key == 'new-app' end,
    isAutoLaunchPending = function(_, key) return key == 'new-app' end,
    cancelGroup = function() cancellations = cancellations + 1 end,
    tick = function() return false end,
  }
  e.manager:noteUserInput()
  e.manager:tick(); e:advance(0.5)
  equal(cancellations, 0, 'autolaunch must retain its restoration claim')
  equal(opened.spaceID, e.source.spaceID); equal(#e.moved, 0)
  equal(#e.manager.queue, 0); equal(#e.followPreparations, 0); equal(e.followed, 0)
end)

test('a user-opened new window supersedes a historical session claim and can follow normally', function()
  local e = followFixture()
  local opened = publishFollowBirth(e)
  local claimed, cancellations = true, 0
  e.manager.session = {
    claims = function(_, key) return claimed and key == 'new-app' end,
    isAutoLaunchPending = function() return false end,
    cancelGroup = function(_, key)
      equal(key, 'new-app'); claimed = false; cancellations = cancellations + 1
    end,
    tick = function() return false end,
  }
  e.manager:noteUserInput()
  e.manager:tick(); e:advance(0.5)
  equal(cancellations, 1, 'manual opening must first release the historical restore claim')
  equal(claimed, false); equal(opened.spaceID, e.target.spaceID); equal(#e.moved, 1)
  equal(#e.followPreparations, 1); equal(e.followed, 1)
end)

test('input older than ten seconds cannot authorize following a focused new window', function()
  local e = followFixture()
  e.manager:noteUserInput(); e:advance(10.01)
  local opened = publishFollowBirth(e)
  e.manager:tick(); e:advance(0.5)
  equal(opened.spaceID, e.target.spaceID); equal(#e.moved, 1)
  equal(#e.followPreparations, 0); equal(e.followed, 0)
end)

test('a focused window with the same ID but another PID cannot authorize birth follow', function()
  local e = followFixture()
  local opened = publishFollowBirth(e)
  e.focusedWindow = {
    id = function() return opened:id() end,
    application = function() return { pid = function() return opened:application():pid() + 1 end } end,
  }
  e.manager:noteUserInput()
  e.manager:tick(); e:advance(0.5)
  equal(opened.spaceID, e.target.spaceID); equal(#e.moved, 1)
  equal(#e.followPreparations, 0); equal(e.followed, 0)
end)

test('follow startup quiet time begins on a new OS session and survives reload without renewal', function()
  local e = fixture()
  equal(e.settings['deskpilot.followSession.v1'], nil)
  e.manager:configureFollowSession('session-a')
  equal(e.manager.followQuietUntil, 0, 'first installation in an existing session need not suppress work')
  equal(e.settings['deskpilot.followSession.v1'].sessionID, 'session-a')
  e:advance(5)
  e.manager:configureFollowSession('session-b')
  local deadline = e.now + 60
  equal(e.manager.followQuietUntil, deadline)
  equal(e.settings['deskpilot.followSession.v1'].quietUntil, deadline)
  e:advance(20)
  local reloaded = Manager.new(e.context)
  reloaded:configureFollowSession('session-b')
  equal(reloaded.followQuietUntil, deadline, 'reload preserves the original deadline')
  equal(e.settings['deskpilot.followSession.v1'].quietUntil, deadline)
  e:advance(41)
  local laterReload = Manager.new(e.context)
  laterReload:configureFollowSession('session-b')
  equal(laterReload.followQuietUntil, deadline, 'expired suppression must not be extended')
  assert(laterReload.followQuietUntil < e.now, 'follow is no longer suppressed after the original minute')
end)

test('an unidentified OS session blocks follow without overwriting the last identified session', function()
  local e = fixture()
  e.manager:configureFollowSession('session-a')
  local saved = e.settings['deskpilot.followSession.v1']
  e.manager:configureFollowSession(nil)
  equal(e.manager.followQuietUntil, math.huge)
  equal(e.settings['deskpilot.followSession.v1'], saved)
end)

test('a new window whose AX focus arrives after the birth tick follows once after becoming focused', function()
  local e=followFixture(); local opened=publishFollowBirth(e,false)
  e.manager:noteUserInput(); e.manager:tick()
  equal(#e.moved,0); equal(#e.manager.queue,1); equal(#e.followPreparations,0)
  e:advance(.5); e.focusedWindow=opened; e:emit('focused',opened)
  e.manager:tick(); e:advance(.5)
  equal(#e.moved,1); equal(opened.spaceID,e.target.spaceID); equal(e.followed,1)
  equal(e.followCompletions[1].windowID,opened:id())
end)

test('disabling follow clears queued intent and persists without changing startup quiet time', function()
  local e=followFixture(); local opened=publishFollowBirth(e)
  local hold=true
  e.manager.session={claims=function() return false end,tick=function() return hold end}
  e.manager:noteUserInput(); e.manager:tick(); equal(#e.manager.queue,1)
  e.manager:configureFollowSession('session-a'); e.manager:configureFollowSession('session-b')
  local quietUntil=e.manager.followQuietUntil
  equal(e.manager:setFollowEnabled(false),false)
  equal(e.settings['deskpilot.followNewWindows.v1'],false); equal(e.manager.queue[1].follow,nil)
  local reloaded=Manager.new(e.context); equal(reloaded.followEnabled,false)
  reloaded:configureFollowSession('session-b'); equal(reloaded.followQuietUntil,quietUntil)
  equal(reloaded:setFollowEnabled(true),true); equal(e.settings['deskpilot.followNewWindows.v1'],true)
  equal(reloaded.followQuietUntil,quietUntil,'enabling follow must not shorten startup protection')
  hold=false; e.manager:tick(); e:advance(.5)
  equal(opened.spaceID,e.target.spaceID); equal(e.followed,0); equal(#e.followPreparations,0)
end)

test('typing into the queued new window preserves its existing follow intent', function()
  local e=followFixture(); local opened=publishFollowBirth(e)
  local hold=true
  e.manager.session={claims=function() return false end,tick=function() return hold end}
  e.manager:noteUserInput(); e.manager:tick(); equal(#e.manager.queue,1)
  local event={getType=function() return hs.eventtap.event.types.keyDown end}
  e.manager:noteUserInput(event); e.manager:noteUserInput(event)
  equal(e.manager.queue[1].follow.inputSerial,e.manager.inputSerial)
  hold=false; e.manager:tick(); e:advance(.5)
  equal(opened.spaceID,e.target.spaceID); equal(e.followed,1)
  equal(#e.followPreparations,1)
end)

test('typing in another window cancels queued follow rather than refreshing its permission', function()
  local e=followFixture(); local opened=publishFollowBirth(e)
  local hold=true
  e.manager.session={claims=function() return false end,tick=function() return hold end}
  e.manager:noteUserInput(); e.manager:tick()
  e.focusedWindow=e.existing
  e.manager:noteUserInput({getType=function() return hs.eventtap.event.types.keyDown end})
  e.focusedWindow=opened; hold=false; e.manager:tick(); e:advance(.5)
  equal(opened.spaceID,e.target.spaceID); equal(e.followed,0); equal(#e.followPreparations,0)
end)

test('focus leaving and returning to a queued new window does not resurrect follow intent', function()
  local e=followFixture(); local opened=publishFollowBirth(e)
  local hold=true
  e.manager.session={claims=function() return false end,tick=function() return hold end}
  e.manager:noteUserInput(); e.manager:tick()
  e.focusedWindow=e.existing; e:emit('focused',e.existing)
  equal(e.manager.queue[1].follow,nil)
  e.focusedWindow=opened; e:emit('focused',opened)
  hold=false; e.manager:tick(); e:advance(.5)
  equal(opened.spaceID,e.target.spaceID); equal(e.followed,0); equal(#e.followPreparations,0)
end)

local function organizationFixture(options)
  options=options or {}
  local e=fixture(); local screen=e:addScreen('a')
  e.source=e:addWorkspace(1,'shared',screen)
  if options.free~=false then e.target=e:addWorkspace(2,'free-a',screen) end
  local external=e:addScreen('b')
  e.other=e:addWorkspace(10,'free-b',external)
  e.keeper=e:addWindow(10,'com.Keeper',e.source)
  e.moving=e:addWindow(11,'com.Moving',e.source,true,500)
  if options.multi then e.sibling=e:addWindow(12,'com.Moving',e.source,true,500) end
  e.focusedWindow=e.keeper
  e.active={a=e.source.spaceID,b=e.other.spaceID}
  settleExistingWindows(e); installFollowSpy(e)
  e.organized={}
  e.context.organized=function(window,target)
    e.organized[#e.organized+1]={id=window:id(),target=target.spaceID}
    local key=e.groupKey and e.groupKey(window) or window:application():bundleID()
    if e.rules[key] then e.rules[key].allowShared=false end
  end
  return e
end

local function runOrganization(e)
  for _=1,80 do
    e.manager:tick(); e:advance(.5)
    if not e.manager.organizing and not e.manager.busy then return end
  end
  error('organization did not finish within the test time bound')
end

test('explicit organization separates two sharing apps using a free Space on the same monitor', function()
  local e=organizationFixture(); local keeperFrame,movingFrame=e.keeper:frame(),e.moving:frame()
  assert(e.manager:organize(e.keeper)); equal(e.manager.organizePlanned,1)
  runOrganization(e)
  equal(e.keeper.spaceID,e.source.spaceID); equal(e.moving.spaceID,e.target.spaceID)
  equal(#e.moved,1); equal(#e.added,0); equal(e.manager.organizeDone,1)
  equal(e.organized[1].id,e.moving:id()); equal(e.rules['com.Moving'].allowShared,false)
  equal(e.keeper:frame(),keeperFrame); equal(e.moving:frame(),movingFrame)
  equal(e.active.a,e.source.spaceID); equal(e.active.b,e.other.spaceID)
  equal(#e.followPreparations,0); equal(e.followed,0); equal(e.framed,0)
end)

test('organization creates locally only when full and waits three seconds after confirming the new Space', function()
  local e=organizationFixture({free=false})
  assert(e.manager:organize(e.keeper)); e.manager:tick()
  equal(#e.added,1); equal(e.added[1],'a'); equal(#e.moved,0)
  e:advance(.6); local createdAt=e.manager.organization.createdAt; assert(createdAt)
  e.manager:tick(); e:advance(2); e.manager:tick(); equal(#e.moved,0)
  runOrganization(e)
  equal(#e.added,1); equal(#e.moved,1); equal(e.moving.spaceID,1001)
  assert(e.moved[1].time-createdAt>=3,'new Space metadata must settle before moving')
  equal(e.keeper.spaceID,e.source.spaceID); equal(e.active.b,e.other.spaceID)
  equal(#e.followPreparations,0); equal(e.followed,0)
end)

test('organization moves every window of one group serially to its single destination', function()
  local e=organizationFixture({multi=true})
  assert(e.manager:organize(e.keeper)); e.manager:tick()
  equal(#e.moved,1); equal(e.sibling.spaceID,e.source.spaceID)
  e.manager:tick(); equal(#e.moved,1,'wait for verification before the next window')
  e:advance(.5); e.manager:tick(); equal(#e.moved,2)
  e:advance(.5)
  equal(e.moving.spaceID,e.target.spaceID); equal(e.sibling.spaceID,e.target.spaceID)
  equal(e.manager.organizeDone,1); equal(#e.organized,2); equal(e.manager.organizing,false)
  equal(#e.followPreparations,0); equal(e.followed,0); equal(#e.added,0)
end)

test('organization separates Chrome profile groups sharing a PID while preserving profile siblings', function()
  local e=fixture(); chromeGroups(e)
  local screen=e:addScreen('a'); local shared=e:addWorkspace(1,'shared',screen); local target=e:addWorkspace(2,'free',screen)
  local keep=e:addWindow(10,chromeBundle,shared,true,500); keep.profile='Profile 1'
  local move=e:addWindow(11,chromeBundle,shared,true,500); move.profile='Profile 2'
  local sibling=e:addWindow(12,chromeBundle,shared,true,500); sibling.profile='Profile 2'
  e.focusedWindow=keep; settleExistingWindows(e); installFollowSpy(e)
  assert(e.manager:organize(keep)); runOrganization(e)
  equal(keep.spaceID,shared.spaceID); equal(move.spaceID,target.spaceID); equal(sibling.spaceID,target.spaceID)
  equal(#e.moved,2); equal(#e.added,0); equal(e.manager.organizeDone,1)
  equal(e.followed,0); equal(#e.followPreparations,0)
end)

for _, unknown in ipairs({'CG read','Space membership'}) do
  test('organization refuses an incomplete '..unknown..' before any desktop operation', function()
    local e=organizationFixture()
    if unknown=='CG read' then e.rawUnavailable=true else e.spaceWindows[e.target.spaceID]=nil end
    equal(e.manager:organize(e.keeper),false)
    equal(#e.moved,0); equal(#e.added,0); equal(#e.removed,0)
    equal(e.manager.organization,nil); equal(#e.followPreparations,0)
  end)
end

for _, interruption in ipairs({'input','pause','lock','topology'}) do
  test('organization '..interruption..' cancels an in-flight creation without moving afterward', function()
    local e=organizationFixture({free=false}); assert(e.manager:organize(e.keeper)); e.manager:tick()
    equal(#e.added,1); equal(e.manager.busy,true)
    if interruption=='input' then e.manager:noteUserInput(); e.manager:tick()
    elseif interruption=='pause' then e.manager:pause()
    elseif interruption=='lock' then e.sessionLocked=true; e.manager:tick()
    else e.manager:topologyChanged() end
    e:advance(1); e.manager:tick()
    equal(e.manager.organizing,false); equal(e.manager.organization,nil)
    equal(e.manager.busy,false); equal(#e.moved,0); equal(#e.added,1)
    equal(e.keeper.spaceID,e.source.spaceID); equal(e.moving.spaceID,e.source.spaceID)
    equal(e.followed,0); equal(#e.organized,0)
  end)
end

test('a foreign occupant appearing at the selected target aborts the remaining group windows', function()
  local e=organizationFixture({multi=true}); assert(e.manager:organize(e.keeper))
  e.manager:tick(); e:advance(.5); equal(#e.moved,1)
  e:addWindow(30,'com.Foreign',e.target)
  e.manager:tick()
  equal(e.manager.organizing,false); equal(#e.moved,1); equal(#e.added,0)
  equal(e.sibling.spaceID,e.source.spaceID); equal(e.moving.spaceID,e.target.spaceID)
  equal(e.manager.organizeDone,0)
  assert(e.manager.organizeMessage:find('zajęte',1,true))
end)

for _, change in ipairs({'window ID','PID','source Space','source UUID','target UUID'}) do
  test('organization rejects stale '..change..' instead of continuing its saved plan', function()
    local e=organizationFixture({multi=change=='target UUID'})
    assert(e.manager:organize(e.keeper))
    local expectedMoves=0
    if change=='window ID' then e.moving.windowID=999
    elseif change=='PID' then
      local old=e.moving:application()
      e.moving.application=function() return {pid=function() return old:pid()+1 end,
        bundleID=function() return old:bundleID() end,name=function() return old:name() end} end
    elseif change=='source Space' then e:setLocation(e.moving,e.other.spaceID)
    elseif change=='source UUID' then e.source.spaceUUID='recycled-source'
    else
      e.manager:tick(); e:advance(.5); expectedMoves=1
      e.target.spaceUUID='recycled-target'
    end
    e.manager:advanceOrganization()
    equal(e.manager.organizing,false); equal(#e.moved,expectedMoves); equal(#e.added,0)
    equal(e.followed,0); equal(#e.followPreparations,0)
  end)
end

test('an explicit manual move cancels the outstanding bulk plan and records only the manual choice', function()
  local e=organizationFixture(); assert(e.manager:organize(e.keeper))
  assert(e.manager:manualMove(e.moving,e.other)); e:advance(.5)
  equal(e.manager.organizing,false); equal(e.moving.spaceID,e.other.spaceID)
  equal(#e.moved,1); equal(#e.organized,0); equal(e.remembered[1].manual,true)
  equal(e.followed,0); equal(#e.followPreparations,0)
end)

test('organization removes affected queued assignments and never uses their follow intent', function()
  local e=organizationFixture()
  e.manager:noteUserInput(); e.manager:enqueue(e.moving,true,{id=e.moving:id(),pid=e.moving:application():pid(),
    key='com.Moving',generation=e.manager.generation,inputSerial=e.manager.inputSerial,time=e.now,focused=true})
  equal(#e.manager.queue,1); assert(e.manager:organize(e.keeper)); equal(#e.manager.queue,0)
  runOrganization(e); equal(e.moving.spaceID,e.target.spaceID)
  equal(#e.followPreparations,0); equal(e.followed,0)
end)

test('organization refuses an active session restore even between native move operations', function()
  local e=organizationFixture()
  e.manager.session={isRestoring=function() return true end}
  equal(e.manager.busy,false)
  equal(e.manager:organize(e.keeper),false)
  equal(e.manager.organization,nil); equal(#e.moved,0); equal(#e.added,0)
end)

test('organization stops if the contested source Space changes monitor before an off-source sibling moves', function()
  local e=organizationFixture({multi=true})
  e:setLocation(e.sibling,e.other.spaceID)
  assert(e.manager:organize(e.keeper)); e.manager:tick(); e:advance(.5)
  equal(#e.moved,1); equal(e.moving.spaceID,e.target.spaceID)
  e.source.screenUUID,e.source.screen=e.other.screenUUID,e.other.screen
  e.manager:advanceOrganization()
  equal(e.manager.organizing,false); equal(#e.moved,1)
  equal(e.sibling.spaceID,e.other.spaceID); equal(e.manager.organizeDone,0)
end)

for _, knowledge in ipairs({'observed identity','plain app PID'}) do
  test('organization skips the whole group with a missing AX sibling identified by '..knowledge, function()
    local e=organizationFixture({multi=knowledge=='observed identity'})
    if knowledge=='observed identity' then
      e.windows={e.keeper,e.moving}
    else
      e.sibling=e:addWindow(12,'com.Moving',e.source,false,500)
    end
    assert(e.manager:organize(e.keeper))
    equal(e.manager.organizeSkipped,1); equal(e.manager.organizePlanned,0)
    equal(e.manager.organization,nil); equal(#e.moved,0); equal(#e.added,0)
    equal(e.moving.spaceID,e.source.spaceID); equal(e.sibling.spaceID,e.source.spaceID)
  end)
end

for _, missingProfile in ipairs({'Profile 1','Profile 2','unidentified profile'}) do
  test('missing AX Chrome '..missingProfile..' does not inherit another profile from their shared PID', function()
    local e=fixture(); chromeGroups(e)
    local screen=e:addScreen('a'); local shared=e:addWorkspace(1,'shared',screen)
    local target=e:addWorkspace(2,'free',screen)
    local keeper=e:addWindow(10,chromeBundle,shared,true,500); keeper.profile='Profile 1'
    local moving=e:addWindow(11,chromeBundle,shared,true,500); moving.profile='Profile 2'
    local missing
    if missingProfile~='unidentified profile' then
      missing=e:addWindow(12,chromeBundle,shared,true,500); missing.profile=missingProfile
    end
    e.focusedWindow=keeper; settleExistingWindows(e); installFollowSpy(e)
    if missing then e.windows={keeper,moving}
    else missing=e:addWindow(12,chromeBundle,shared,false,500) end
    assert(e.manager:organize(keeper))
    if missingProfile=='Profile 2' then
      equal(e.manager.organizeSkipped,1); equal(e.manager.organizePlanned,0)
      equal(moving.spaceID,shared.spaceID); equal(#e.moved,0)
    else
      equal(e.manager.organizeSkipped,0); runOrganization(e)
      equal(moving.spaceID,target.spaceID); equal(#e.moved,1)
    end
    equal(keeper.spaceID,shared.spaceID); equal(missing.spaceID,shared.spaceID)
    equal(#e.added,0); equal(#e.followPreparations,0)
  end)
end

test('organization cancels historical restore claims for both the moved group and the keeper', function()
  local e=organizationFixture()
  local claims={['com.Keeper']=true,['com.Moving']=true,['com.Unrelated']=true}
  e.manager.session={isRestoring=function() return false end,
    claims=function(_,key) return claims[key]==true end,
    cancelGroup=function(_,key) claims[key]=false end,
    tick=function() return false end}
  assert(e.manager:organize(e.keeper))
  equal(claims['com.Keeper'],false); equal(claims['com.Moving'],false)
  equal(claims['com.Unrelated'],true)
  runOrganization(e)
  equal(e.keeper.spaceID,e.source.spaceID); equal(e.moving.spaceID,e.target.spaceID)
  equal(e.manager.organizeDone,1); equal(#e.followPreparations,0)
end)

print('Manager tests: ' .. passed .. ' passed, ' .. failed .. ' failed')
if failed > 0 then os.exit(1) end
