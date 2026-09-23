-- Pure fake runtime: never opens an app, moves a real window, or reads macOS.
local source = debug.getinfo(1, 'S').source:sub(2)
package.path = (source:match('^(.*[/\\])') or './') .. '../?.lua;' .. package.path
local Session = require('deskpilot_session')
local Layout = require('deskpilot_layout')
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
local function clone(value)
  if type(value) ~= 'table' then return value end
  local out = {}; for k, v in pairs(value) do out[k] = clone(v) end; return out
end
local function env()
  local e = { now = 100, generation = 1, blocked = false, writes = 0, saved = nil,
    screens = {{uuid = 'a', builtIn = true, frame = { x = 0, y = 20, w = 1000, h = 800 }}},
    workspaces = {}, rows = {}, moves = {}, creates = {}, launches = {}, callbacks = {}, unknown = {} }
  function e:space(id, uuid, monitor, index)
    local ws = { spaceID = id, spaceUUID = uuid, screenUUID = monitor or 'a', localIndex = index or #self.workspaces + 1 }
    self.workspaces[#self.workspaces + 1] = ws; return ws
  end
  function e:row(key, id, space, hash)
    local row = { key = key, bundleID = key, id = id, pid = id * 10, window = {}, spaceID = space.spaceID,
      titleHash = hash, frame = {x = 50, y = 60, w = 700, h = 600} }
    if key:match('^com.google.Chrome::') then
      row.bundleID, row.profileDirectory = 'com.google.Chrome', key:match('::(.+)$')
    end
    self.rows[#self.rows + 1] = row; return row
  end
  function e:group(key, space, windows)
    local group = { bundleID = key, screenUUID = space.screenUUID, spaceUUID = space.spaceUUID,
      spaceIndex = space.localIndex, windows = windows or {{titleHash = 'title', frame = {x = .1, y = .2, w = .6, h = .7}}} }
    if key:match('^com.google.Chrome::') then
      group.bundleID, group.profileDirectory = 'com.google.Chrome', key:match('::(.+)$')
    end
    return group
  end
  function e:seed(groups, active)
    local layout = Layout.merge(nil, self.screens, groups, self.now - 50)
    assert(layout, 'invalid test layout')
    if active then layout.activeKeys = active end
    self.saved = { version = 1, layouts = {[layout.signature] = layout}, runs = {} }
  end
  function e:make(sessionID)
    self.ctx = {
      sessionID = sessionID or 'session-new', now = function() return self.now end,
      generation = function() return self.generation end, blocked = function() return self.blocked end,
      load = function() return self.saved end,
      save = function(store)
        self.writes = self.writes + 1
        if self.failSave then return false end
        self.saved = clone(store); return true
      end,
      screens = function() self.reads = (self.reads or 0) + 1; return self.screens end,
      workspaces = function() return not self.incomplete and self.workspaces or nil end,
      rows = function() return not self.incomplete and self.rows or nil end,
      canUse = function(_, id, allowed)
        if self.unknown[id] then return false end
        for _, row in ipairs(self.rows) do
          if row.spaceID == id and not allowed[row.key] then return false end
        end
        return true
      end,
      move = function(row, workspace, normalized, done)
        local storedRun = self.saved and self.saved.runs[Layout.signature(self.screens)]
        assert(storedRun and storedRun.handled[row.key], 'handled must be durable before moving')
        self.moves[#self.moves + 1] = {row = row, workspace = workspace, frame = normalized}
        self.callbacks[#self.callbacks + 1] = function(ok)
          if ok then
            row.spaceID = workspace.spaceID
            if normalized then
              for _, screen in ipairs(self.screens) do
                if screen.uuid == workspace.screenUUID then
                  row.frame = {x = screen.frame.x + normalized.x * screen.frame.w,
                    y = screen.frame.y + normalized.y * screen.frame.h,
                    w = normalized.w * screen.frame.w, h = normalized.h * screen.frame.h}
                end
              end
            end
          end
          done(ok)
        end
        return true
      end,
      create = function(uuid, done)
        self.creates[#self.creates + 1] = uuid
        self.callbacks[#self.callbacks + 1] = function(ok)
          done(ok and self:space(100 + #self.workspaces, 'created-' .. #self.workspaces, uuid) or nil)
        end
        return true
      end,
      canLaunch = function(group) return not self.unlaunchable or not self.unlaunchable[group.bundleID] end,
      launch = function(group, done)
        local key = group.profileDirectory and group.bundleID .. '::' .. group.profileDirectory or group.bundleID
        assert(self.saved.runs[Layout.signature(self.screens)].launched[key], 'launch permission must be saved first')
        self.launches[#self.launches + 1] = key
        self.launchDone = done
        return true
      end,
    }
    if self.adapt then self.ctx.adaptLayout = self.adapt end
    self.session = Session.new(self.ctx)
    return self.session
  end
  function e:tick(seconds)
    self.now = self.now + (seconds or 0)
    return self.session:tick()
  end
  function e:settle() self:tick(); self:tick(3) end
  function e:done(ok)
    local callback = table.remove(self.callbacks, 1); assert(callback, 'no callback to complete'); callback(ok ~= false)
  end
  function e:drain()
    for _ = 1, 20 do
      if #self.callbacks > 0 then self:done() end
      self:tick(1)
      if not self.session:isRestoring() and #self.callbacks == 0 then return end
    end
    error('operation did not finish')
  end
  return e
end

test('old windows restore after stability with normalized frames and durable handled state', function()
  local e = env(); local a = e:space(1, 'old'); local b = e:space(2, 'target')
  local row = e:row('com.test.App', 1, a, 'title'); e:seed({[row.key] = e:group(row.key, b)})
  e:make(); e:tick(); e:tick(2); equal(#e.moves, 0); e:tick(1)
  equal(#e.moves, 1); equal(e.moves[1].workspace.spaceID, 2); equal(e.moves[1].frame.x, .1)
  e:done(); e:tick(); equal(e.session:status().sessionRestored, 1)
  equal(row.frame.x, 100); equal(row.frame.y, 180)
end)

test('same session reload never repeats a handled group', function()
  local e = env(); local a = e:space(1, 'old'); local b = e:space(2, 'target')
  local row = e:row('com.test.App', 1, a); e:seed({[row.key] = e:group(row.key, b)})
  e:make(); e:settle(); equal(#e.moves, 1)
  e.callbacks = {}; e:make(); e:settle(); equal(#e.moves, 1)
  equal(e.session:status().sessionPending, 0)
end)

test('a new session can restore again but ordinary wake cannot rearm it', function()
  local e = env(); local a = e:space(1, 'old'); local b = e:space(2, 'target')
  local row = e:row('com.test.App', 1, a); e:seed({[row.key] = e:group(row.key, b)})
  e:make(); e:settle(); e:drain(); e.generation = e.generation + 1; e:settle()
  equal(#e.moves, 1)
  row.spaceID = 1; e:make('next-session'); e:settle(); equal(#e.moves, 2)
end)

test('missing and partial window reads never authorize creation or overwrite saved placement', function()
  local e = env(); local a = e:space(1, 'old')
  local row = e:row('com.test.App', 1, a); e:seed({[row.key] = e:group(row.key, a)})
  e.incomplete = true; e:make(); e:settle(); e:tick(30)
  equal(#e.moves, 0); equal(#e.creates, 0); equal(e.writes, 0)
end)

test('pending saved groups are protected from current wrong startup locations', function()
  local e = env(); local a = e:space(1, 'old'); local b = e:space(2, 'target')
  e:seed({['com.test.App'] = e:group('com.test.App', b)})
  e:make(); e:settle(); e:tick(10)
  equal(e.saved.layouts['1:a'].groups['com.test.App'].spaceUUID, 'target')
  e:row('com.test.App', 1, a); e:settle(); equal(#e.moves, 1)
  equal(e.moves[1].workspace.spaceUUID, 'target')
end)

test('empty shutdown scan is never requested by freeze or flush', function()
  local e = env(); local a = e:space(1, 'old'); e:row('com.test.App', 1, a)
  e:make(); e:settle(); local before = clone(e.saved.layouts['1:a'])
  local reads = e.reads; e.rows = {}; assert(e.session:freeze()); assert(e.session:flush())
  equal(e.reads, reads); equal(e.saved.layouts['1:a'].savedAt, before.savedAt)
  equal(e.saved.layouts['1:a'].groups['com.test.App'].spaceUUID, 'old')
  e:tick(100); equal(e.reads, reads)
end)

test('manual moves cancel pending restore and replace its snapshot only after stability', function()
  local e = env(); local a = e:space(1, 'chosen'); local b = e:space(2, 'oldtarget')
  local row = e:row('com.test.App', 1, a); e:seed({[row.key] = e:group(row.key, b)})
  e:make(); e:tick(); e.session:cancelGroup(row.key); e:settle()
  equal(#e.moves, 0); equal(e.saved.layouts['1:a'].groups[row.key].spaceUUID, 'chosen')
end)

test('generation change discards stale callbacks without issuing the next window move', function()
  local e = env(); local a = e:space(1, 'old'); local b = e:space(2, 'target')
  e:row('com.test.App', 1, a, 'one'); e:row('com.test.App', 2, a, 'two')
  e:seed({['com.test.App'] = e:group('com.test.App', b)})
  e:make(); e:settle(); equal(#e.moves, 1)
  e.generation = e.generation + 1; e.blocked = true; e:done(); e:tick()
  equal(e.session:isRestoring(), false); e.blocked = false; e:settle(); equal(#e.moves, 1)
  equal(e.session:status().sessionRestoreFailed,1)
  e.session:cancelGroup('com.test.App'); equal(e.session:status().sessionRestoreFailed,0)
end)

test('serial restoration waits for callbacks and rechecks blocked state', function()
  local e = env(); local a = e:space(1, 'old'); local b = e:space(2, 'target')
  e:row('com.test.App', 1, a, 'same'); e:row('com.test.App', 2, a, 'same')
  e:seed({['com.test.App'] = e:group('com.test.App', b, {
    {titleHash = 'same', frame = {x=0,y=0,w=.5,h=.5}}, {titleHash='same',frame={x=.5,y=.5,w=.5,h=.5}}})})
  e:make(); e:settle(); equal(#e.moves, 1); equal(e.moves[1].frame, nil)
  e:tick(); equal(#e.moves, 1); e.blocked = true; e:done(); equal(#e.moves, 1)
  e:tick(); equal(#e.moves, 1); e.blocked = false; e:tick(); equal(#e.moves, 2)
  equal(e.moves[2].frame, nil); e:drain(); equal(e.session:status().sessionRestored, 1)
end)

test('saved UUID on another monitor never aliases its numeric ID', function()
  local e = env(); e.screens[#e.screens+1] = {uuid='b',frame={x=1000,y=0,w=1000,h=800}}
  local a = e:space(1, 'new-a', 'a', 1); local b = e:space(2, 'old-target', 'b', 1)
  local row = e:row('com.test.App', 1, b)
  local group = e:group(row.key, a); group.spaceUUID = 'old-target'
  e:seed({[row.key] = group}); e:make(); e:settle()
  equal(e.moves[1].workspace.screenUUID, 'a'); equal(e.moves[1].workspace.spaceUUID, 'new-a')
end)

test('foreign occupant at exact saved UUID selects a genuinely usable fallback', function()
  local e = env(); local a=e:space(1,'source'); local b=e:space(2,'target'); local c=e:space(3,'free')
  local row=e:row('com.test.App',1,a); e:row('com.foreign.App',2,b)
  e:seed({[row.key]=e:group(row.key,b)}); e.unknown[a.spaceID] = true
  e:make(); e:settle(); equal(e.moves[1].workspace.spaceID,c.spaceID); equal(#e.creates,0)
end)

test('creates only when an awaiting group has real windows and no usable target', function()
  local e=env(); local a=e:space(1,'source'); local row=e:row('com.test.App',1,a)
  e.unknown[1]=true; e:seed({[row.key]=e:group(row.key,a)}); e:make(); e:settle()
  equal(#e.creates,1); equal(#e.moves,0); e:done(); equal(#e.moves,0)
  e:tick(); equal(#e.moves,0); e:tick(3)
  equal(#e.moves,1); equal(e.moves[1].workspace.spaceUUID,'created-1')
end)

test('cycle A and B can exchange occupied desktops without treating each other as foreign', function()
  local e=env(); local a=e:space(1,'a'); local b=e:space(2,'b')
  local ra=e:row('com.A',1,b); local rb=e:row('com.B',2,a)
  e:seed({['com.A']=e:group('com.A',a),['com.B']=e:group('com.B',b)})
  e:make(); e:settle(); e:drain(); e:settle(); e:drain()
  equal(ra.spaceID,1); equal(rb.spaceID,2); equal(#e.creates,0)
end)

test('shared saved slot maps to the same replacement across a same-session reload', function()
  local e=env(); local a=e:space(1,'replacement'); local b=e:space(2,'source')
  local ra=e:row('com.A',1,b); local rb=e:row('com.B',2,b)
  local ga=e:group('com.A',a); ga.spaceUUID='expired'
  local gb=e:group('com.B',a); gb.spaceUUID='expired'
  e:seed({['com.A']=ga,['com.B']=gb}); e:make(); e:settle(); e:done(); e:tick()
  e:make(); e:settle(); equal(e.moves[2].workspace.spaceUUID,'replacement')
  e:drain(); equal(ra.spaceID,rb.spaceID)
end)

test('saving a group split across desktops preserves its previous complete layout', function()
  local e=env(); local a=e:space(1,'a'); local b=e:space(2,'b')
  e:row('com.A',1,a); e:row('com.A',2,b); e:seed({['com.A']=e:group('com.A',a)})
  e.saved.runs['1:a']={sessionID='session-new',handled={['com.A']=true}}
  e:make(); e:settle(); equal(e.saved.layouts['1:a'].groups['com.A'].spaceUUID,'a')
  equal(#e.saved.layouts['1:a'].groups['com.A'].windows,1)
end)

test('storage failure prevents both movement and creation', function()
  local e=env(); local a=e:space(1,'a'); local row=e:row('com.A',1,a)
  e:seed({['com.A']=e:group(row.key,a)}); e.failSave=true; e:make(); e:settle()
  equal(#e.moves,0); equal(#e.creates,0); equal(e.session:status().sessionPhase,'storage-error')
end)

test('unchanged checkpoints do not write on every interval', function()
  local e=env(); local a=e:space(1,'a'); e:row('com.A',1,a); e:make(); e:settle()
  local writes=e.writes; e:tick(10); e:tick(10); equal(e.writes,writes)
end)

test('launch only active absent groups after twenty stable seconds and never retries failures', function()
  local e=env(); local a=e:space(1,'a')
  e:seed({['com.A']=e:group('com.A',a),['com.History']=e:group('com.History',a)}, {'com.A'})
  e:make(); equal(e.session:isAutoLaunchPending('com.A'),false, 'uninitialized session returns strict false')
  equal(e.session:isAutoLaunchPending('com.Unknown'),false)
  e:settle(); e:tick(16); equal(#e.launches,0)
  equal(e.session:isAutoLaunchPending('com.A'),false, 'a saved group alone is not an automatic launch')
  e:tick(1)
  equal(#e.launches,1); equal(e.launches[1],'com.A')
  equal(e.session:isAutoLaunchPending('com.A'),true, 'in-flight background launch owns its later windows')
  equal(e.session:isAutoLaunchPending('com.History'),false)
  e.launchDone(false)
  equal(e.session:isAutoLaunchPending('com.A'),false, 'a failed launch cannot claim a later user launch')
  e:tick(60); equal(#e.launches,1); equal(e.session:status().sessionLaunchFailed,1)
  e:make(); e:settle(); e:tick(30); equal(#e.launches,1)
end)

test('late window after launch restores once without blocking the manager while absent', function()
  local e=env(); local a=e:space(1,'a'); local b=e:space(2,'b')
  e:seed({['com.A']=e:group('com.A',b)}, {'com.A'}); e:make(); e:settle(); e:tick(20)
  equal(e.session:isRestoring(),false); equal(e.session:isAutoLaunchPending('com.A'),true)
  e.launchDone(true)
  equal(e.session:isAutoLaunchPending('com.A'),true, 'successful open still waits for its window')
  e:row('com.A',1,a)
  e:settle(); equal(#e.moves,1); equal(e.moves[1].workspace.spaceID,2)
  equal(e.session:isAutoLaunchPending('com.A'),true, 'restore in flight still belongs to the automatic launch')
  e:drain(); equal(e.session:isAutoLaunchPending('com.A'),false, 'completed restore no longer blocks user focus-follow')
  e:row('com.A',2,a)
  equal(e.session:isAutoLaunchPending('com.A'),false, 'a later new window does not rearm automatic launch ownership')
end)

test('unlaunchable Chrome profile never falls back to launching generic Chrome', function()
  local e=env(); local a=e:space(1,'a'); local key='com.google.Chrome::Profile 1'
  e:seed({[key]=e:group(key,a)}, {key}); e.unlaunchable={['com.google.Chrome']=true}
  e:make(); e:settle(); e:tick(30); equal(#e.launches,0); equal(e.session:status().sessionLaunchPending,1)
end)

test('adaptation selects current monitor policy before opening or moving applications', function()
  local e=env(); local a=e:space(1,'a'); e:seed({['com.A']=e:group('com.A',a)}, {'com.A'})
  e.screens={{uuid='b',builtIn=false,frame={x=0,y=0,w=2000,h=1600}}}; e.workspaces={}
  local b=e:space(2,'b','b',1)
  e.adapt=function(layouts,screens)
    local prior=layouts['1:a']; local group=clone(prior.groups['com.A'])
    group.screenUUID='b'; group.spaceUUID=nil
    return Layout.merge(nil,screens,{['com.A']=group},e.now)
  end
  e:make(); e:settle(); e:tick(20); equal(#e.launches,1)
  e:row('com.A',1,b); e:settle(); equal(e.moves[1].workspace.screenUUID,'b')
end)

test('real topology change rearms adaptation while same topology reload does not', function()
  local e=env(); local a=e:space(1,'a'); local row=e:row('com.A',1,a)
  e:seed({['com.A']=e:group('com.A',a)})
  e.adapt=function(layouts,screens)
    local group=clone((layouts[Layout.signature(screens)] or layouts['1:a']).groups['com.A'])
    group.screenUUID=screens[1].uuid; group.spaceUUID=nil; group.spaceIndex=1
    return Layout.merge(nil,screens,{['com.A']=group},e.now)
  end
  e:make(); e:settle(); e:drain(); equal(#e.moves,1)
  e.screens={{uuid='b',frame={x=0,y=0,w=1000,h=800}}}; e.workspaces={}; local b=e:space(2,'b','b',1)
  row.spaceID=b.spaceID; e.generation=e.generation+1; e:settle(); equal(#e.moves,2); e:drain()
  e:make(); e:settle(); equal(#e.moves,2)
end)

test('manual restore request is explicit and does not repeat automatic launch attempts', function()
  local e=env(); local a=e:space(1,'a'); e:row('com.A',1,a); e:seed({['com.A']=e:group('com.A',a)})
  e:make(); e:settle(); e:drain(); equal(#e.moves,1)
  assert(e.session:requestRestore()); e:settle(); equal(#e.moves,2)
end)

test('at most eight monitor profiles survive a saved checkpoint', function()
  local e=env(); local a=e:space(1,'a'); e:row('com.A',1,a)
  e.saved={version=1,layouts={},runs={}}
  for i=1,10 do
    local uuid='monitor-'..i
    local group=e:group('com.A',a); group.screenUUID=uuid
    local layout=Layout.merge(nil,{{uuid=uuid}},{['com.A']=group},i)
    e.saved.layouts[layout.signature]=layout
  end
  e:make(); e:settle(); local count=0; for _ in pairs(e.saved.layouts) do count=count+1 end
  equal(count,8); assert(e.saved.layouts['1:a']); equal(e.saved.layouts['1:monitor-1'],nil)
end)

test('claims protects both absent pending groups and an operation until manually cancelled', function()
  local e=env(); local a=e:space(1,'a'); local b=e:space(2,'b')
  e:seed({['com.A']=e:group('com.A',a),['com.B']=e:group('com.B',b)})
  e:row('com.B',2,a); e:make(); e:tick()
  equal(e.session:claims('com.A'),true); equal(e.session:claims('com.B'),true)
  equal(e.session:claims('com.Unknown'),false); e:tick(3)
  equal(e.session:isRestoring(),true); e.session:cancelGroup('com.B')
  equal(e.session:claims('com.B'),false); equal(e.session:claims('com.A'),true)
end)

test('checkpoint storage failure remains visible and retries without claiming an unsaved timestamp', function()
  local e=env(); local a=e:space(1,'a'); e:row('com.A',1,a)
  e.failSave=true; e:make(); e:settle()
  equal(e.session:status().sessionPhase,'storage-error')
  equal(e.session:status().sessionSavedAt,nil); equal(e.saved,nil)
  e.failSave=false; e:tick(10)
  assert(e.saved.layouts['1:a']); equal(e.session:status().sessionPhase,'remembering')
  assert(e.session:status().sessionSavedAt)
end)

test('restoration visits saved display and desktop order rather than app alphabetic order', function()
  local e=env(); local a=e:space(1,'a'); local b=e:space(2,'b'); local c=e:space(3,'c')
  e:row('com.A',1,c); e:row('com.Z',2,c)
  e:seed({['com.A']=e:group('com.A',b),['com.Z']=e:group('com.Z',a)})
  e:make(); e:settle(); equal(e.moves[1].row.key,'com.Z')
  e:drain(); e:settle(); equal(e.moves[2].row.key,'com.A')
end)

test('missing Space membership retains a group claim without consuming its handled permission', function()
  local e=env(); local a=e:space(1,'a'); local row=e:row('com.A',1,a)
  e:seed({['com.A']=e:group('com.A',a)}); row.spaceID=nil
  e:make(); e:settle(); equal(#e.moves,0); equal(e.session:claims('com.A'),true)
  equal(e.saved.runs['1:a'] and e.saved.runs['1:a'].handled['com.A'],nil)
  row.spaceID=1; e:settle(); equal(#e.moves,1)
end)

test('launch persistence failure never invokes open and can recover before any attempted launch', function()
  local e=env(); local a=e:space(1,'a'); e:seed({['com.A']=e:group('com.A',a)},{'com.A'})
  e:make(); e:settle(); e.failSave=true; e:tick(20); equal(#e.launches,0)
  e.failSave=false; e:tick(); equal(#e.launches,1)
end)

test('duplicate move callbacks cannot skip the next restored window', function()
  local e=env(); local a=e:space(1,'a'); local b=e:space(2,'b')
  e:row('com.A',1,a,'one'); e:row('com.A',2,a,'two')
  e:seed({['com.A']=e:group('com.A',b)}); e:make(); e:settle()
  local callback=table.remove(e.callbacks,1); callback(true); callback(true)
  e:tick(); equal(#e.moves,2); equal(e.moves[2].row.id,2)
end)

test('manual frame changes while waiting take precedence over the restore plan', function()
  local e=env(); local a=e:space(1,'a'); local b=e:space(2,'b')
  e:row('com.A',1,a,'one'); local second=e:row('com.A',2,a,'two')
  e:seed({['com.A']=e:group('com.A',b)}); e:make(); e:settle(); e:done()
  second.frame.x=250; e:tick(); equal(#e.moves,1); equal(e.session:claims('com.A'),false)
  equal(second.spaceID,1); equal(second.frame.x,250)
end)

test('partial AX capture preserves active launch intent when the saved group may still be running', function()
  for _, running in ipairs({'unknown', true}) do
    local e=env(); local a=e:space(1,'a'); local b=e:space(2,'b')
    e:row('com.Visible',1,a)
    e:seed({['com.Visible']=e:group('com.Visible',a),['com.MissingAX']=e:group('com.MissingAX',b)})
    e.saved.runs['1:a']={sessionID='session-new',handled={['com.Visible']=true,['com.MissingAX']=true}}
    e:make(); e.ctx.isGroupRunning=function(group)
      equal(group.bundleID,'com.MissingAX')
      if running == 'unknown' then return nil end
      return running
    end
    e:settle(); local active={}
    for _, key in ipairs(e.saved.layouts['1:a'].activeKeys) do active[key]=true end
    equal(active['com.Visible'],true); equal(active['com.MissingAX'],true)
  end
end)

test('confirmed closed group loses launch intent while another active group and placement history remain', function()
  local e=env(); local a=e:space(1,'a'); local b=e:space(2,'b')
  e:row('com.Visible',1,a)
  e:seed({['com.Visible']=e:group('com.Visible',a),['com.Closed']=e:group('com.Closed',b)})
  e.saved.runs['1:a']={sessionID='session-new',handled={['com.Visible']=true,['com.Closed']=true}}
  e:make(); e.ctx.isGroupRunning=function(group) equal(group.bundleID,'com.Closed'); return false end
  e:settle(); local layout=e.saved.layouts['1:a']
  equal(#layout.activeKeys,1); equal(layout.activeKeys[1],'com.Visible')
  assert(layout.groups['com.Closed']); equal(layout.groups['com.Closed'].spaceUUID,'b')
end)

test('cancelled shutdown thaws pending work after fresh stability without repeating completed moves or launches', function()
  local e=env(); local a=e:space(1,'source'); local b=e:space(2,'target-a'); local c=e:space(3,'target-c')
  local ra=e:row('com.A',1,a)
  e:seed({['com.A']=e:group('com.A',b),['com.B']=e:group('com.B',b),['com.C']=e:group('com.C',c)}, {'com.A','com.B'})
  e:make(); e:settle(); e:drain(); equal(#e.moves,1)
  e:settle(); e:tick(20); equal(#e.launches,1); equal(e.launches[1],'com.B')
  local staleLaunchDone=e.launchDone
  assert(e.session:freeze()); ra.spaceID=a.spaceID
  local rc=e:row('com.C',3,a)
  e:tick(100); equal(#e.moves,1)
  assert(e.session:thaw()); equal(e.session:thaw(),false)
  staleLaunchDone(false) -- An earlier launch callback cannot alter the thawed run.
  equal(e.session:status().sessionLaunchFailed,0)
  e:tick(); e:tick(2); equal(#e.moves,1)
  e:tick(1); equal(#e.moves,2); equal(e.moves[2].row.key,'com.C')
  e:drain(); e:settle(); e:tick(30)
  equal(rc.spaceID,c.spaceID); equal(ra.spaceID,a.spaceID)
  equal(#e.moves,2); equal(#e.launches,1)
  equal(e.saved.layouts['1:a'].groups['com.A'].spaceUUID,a.spaceUUID)
  assert(e.saved.runs['1:a'].handled['com.A']); assert(e.saved.runs['1:a'].launched['com.B'])
end)

test('new Space waits for stable post-creation metadata before checking occupancy and moving once', function()
  local e=env(); local a=e:space(1,'source'); local row=e:row('com.A',1,a)
  e.unknown[a.spaceID]=true; e:seed({[row.key]=e:group(row.key,a)})
  e:make(); e:settle(); equal(#e.creates,1)
  e:done(); local created=e.workspaces[#e.workspaces]
  e.unknown[created.spaceID]=true -- Creation overlays are not in the previous CG metadata yet.
  e:tick(); equal(#e.moves,0); equal(e.session:isRestoring(),true)
  equal(e.session:claims(row.key),true)
  e:tick(2); equal(#e.moves,0); equal(e.session:isRestoring(),true)
  e.unknown[created.spaceID]=nil -- The fresh native snapshot confirms the new Space is usable.
  e:tick(1); equal(#e.moves,1); equal(e.moves[1].workspace.spaceID,created.spaceID)
  e:drain(); e:settle(); e:tick(10)
  equal(#e.moves,1); equal(#e.creates,1); equal(row.spaceID,created.spaceID)
  equal(e.session:status().sessionRestored,1)
end)

print('Session tests: ' .. passed .. ' passed, ' .. failed .. ' failed')
if failed > 0 then os.exit(1) end
