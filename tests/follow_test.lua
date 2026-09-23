-- Follow guards exercised against a fake Hammerspoon API, with no live UI.
local source = debug.getinfo(1, 'S').source:sub(2)
package.path = (source:match('^(.*[/\\])') or './') .. '../?.lua;' .. package.path
local Follow = require('deskpilot_follow')
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
  local e = { now = 100, generation = 1, blocked = false, timers = {}, taps = {}, focusCalls = 0,
    gotoCalls = {}, active = {a = 1, b = 5}, buttons = {}, focused = nil, focusMode = 'switch',
    gotoMode = 'switch', target = {spaceID = 2, spaceUUID = 'target', screenUUID = 'a'} }
  local app = {pidValue = 10}
  function app:pid() return self.pidValue end
  local window = {idValue = 1, spaces = {1}, app = app}
  function window:id() return self.idValue end
  function window:application() return self.app end
  function window:focus()
    e.focusCalls = e.focusCalls + 1
    if e.focusMode == 'error' then error('focus failed') end
    if e.focusMode == 'switch' then e.active[e.target.screenUUID] = self.spaces[1]; e.focused = self
    elseif e.focusMode == 'active-only' then
      if e.active[e.target.screenUUID] == self.spaces[1] then e.focused = self end
    elseif e.focusMode == 'focus-only' then e.focused = self
    elseif e.focusMode == 'input' then e:input('keyDown') end
    return self -- Real Hammerspoon returns self without proving success.
  end
  e.window, e.focused = window, window
  e.fallback = {id=function() return 99 end, application=function() return {pid=function() return 99 end} end}
  local types = {}
  for i, name in ipairs({'leftMouseDown','rightMouseDown','otherMouseDown','leftMouseDragged',
      'rightMouseDragged','otherMouseDragged','scrollWheel','keyDown','keyUp','mouseMoved'}) do types[name]=i end
  e.api = {
    window = { focusedWindow=function() return e.focused end },
    timer = {
      secondsSinceEpoch=function() return e.now end,
      doAfter=function(delay, callback)
        local timer={at=e.now+delay,callback=callback,running=true}
        function timer:stop() self.running=false end
        e.timers[#e.timers+1]=timer; return timer
      end,
    },
    eventtap = {
      checkMouseButtons=function() return e.buttons end,
      isSecureInputEnabled=function() return e.secureInput == true end,
      event={types=types},
      new=function(events,callback)
        if e.tapUnavailable then return nil end
        local tap={events={},callback=callback,running=false}
        for _, kind in ipairs(events) do tap.events[kind]=true end
        function tap:start() self.running=true; return self end
        function tap:stop() self.running=false end
        function tap:isEnabled() return self.running and not e.tapDisabled end
        e.taps[#e.taps+1]=tap; return tap
      end,
    },
    spaces = {
      activeSpaces=function() if e.activeUnavailable then return nil end; return e.active end,
      windowSpaces=function(candidate) return candidate.spaces end,
      gotoSpace=function(id)
        e.gotoCalls[#e.gotoCalls+1]=id
        if e.gotoMode=='error' then error('goto failed') end
        if e.gotoMode=='fail' then return nil end
        if e.gotoMode=='switch' then e.active[e.target.screenUUID]=id end
        return true
      end,
    },
  }
  e.ctx={
    blocked=function() return e.blocked end,
    generation=function() return e.generation end,
    managed=function(candidate) return candidate==e.window and not e.unmanaged end,
    resolve=function(target)
      if not e.targetUnavailable and target.spaceUUID==e.target.spaceUUID
          and target.screenUUID==e.target.screenUUID then return e.target end
    end,
  }
  e.follow=Follow.new(e.api,e.ctx)
  function e:advance(seconds)
    local finish=self.now+seconds
    for _=1,1000 do
      local nextTimer
      for _, timer in ipairs(self.timers) do
        if timer.running and timer.at <= finish and (not nextTimer or timer.at < nextTimer.at) then nextTimer=timer end
      end
      if not nextTimer then self.now=finish; return end
      self.now=nextTimer.at; nextTimer.running=false; nextTimer.callback()
    end
    error('unbounded timer loop')
  end
  function e:input(kind)
    for _, tap in ipairs(self.taps) do if tap.running and tap.events[types[kind]] then tap.callback() end end
  end
  function e:liveTimers()
    local count=0; for _, timer in ipairs(self.timers) do if timer.running then count=count+1 end end; return count
  end
  function e:liveTaps()
    local count=0; for _, tap in ipairs(self.taps) do if tap.running then count=count+1 end end; return count
  end
  function e:arm()
    local guard=self.follow:begin(self.window); assert(guard); assert(guard:beforeMove())
    self.window.spaces={self.target.spaceID}; self.focused=self.fallback
    return guard
  end
  function e:clean()
    equal(self:liveTimers(),0,'leaked timers'); equal(self:liveTaps(),0,'leaked input taps')
  end
  return e
end

test('background windows never create a follow guard', function()
  local e=fixture(); e.focused=e.fallback
  equal(e.follow:begin(e.window),nil); equal(e.focusCalls,0); e:clean()
end)

test('a different focused window before the move cancels follow', function()
  local e=fixture(); local guard=e.follow:begin(e.window); assert(guard)
  e.focused=e.fallback; equal(guard:beforeMove(),false); equal(e.focusCalls,0); e:clean()
end)

test('natural focus fallback during the native move still follows through exact window focus', function()
  local e=fixture(); local guard=e:arm()
  assert(guard:complete(e.target)); equal(e.focusCalls,1); equal(#e.gotoCalls,0)
  equal(e.focused,e.window); equal(e.active.a,2); equal(e.active.b,5); e:clean()
end)

test('already active destination only focuses the exact window', function()
  local e=fixture(); local guard=e:arm(); e.active.a=2
  assert(guard:complete(e.target)); equal(e.focusCalls,1); equal(#e.gotoCalls,0); e:clean()
end)

for _, event in ipairs({'leftMouseDown','rightMouseDown','leftMouseDragged','rightMouseDragged','scrollWheel','keyDown'}) do
  test(event..' during the move cancels without any focus or Space switch', function()
    local e=fixture(); local guard=e:arm(); e:input(event)
    equal(guard:complete(e.target),false); equal(e.focusCalls,0); equal(#e.gotoCalls,0); e:clean()
  end)
end

test('mouse motion and releasing the launching key do not cancel follow', function()
  local e=fixture(); local guard=e:arm(); e:input('mouseMoved'); e:input('keyUp')
  assert(guard:complete(e.target)); equal(e.focusCalls,1); e:clean()
end)

test('gesture to a different Space cancels even without an input tap event', function()
  local e=fixture(); local guard=e:arm(); e.active.a=3
  equal(guard:complete(e.target),false); equal(e.focusCalls,0); equal(#e.gotoCalls,0); e:clean()
end)

test('changing another monitor cancels even when the destination is already active', function()
  local e=fixture(); local guard=e:arm(); e.active.a=2; e.active.b=6
  equal(guard:complete(e.target),false); equal(e.focusCalls,0); equal(#e.gotoCalls,0); e:clean()
end)

test('unsuccessful focus gets one goto fallback followed by verified focus', function()
  local e=fixture(); e.focusMode='active-only'; local guard=e:arm()
  assert(guard:complete(e.target)); equal(e.focusCalls,1); equal(#e.gotoCalls,0)
  e:advance(.1); equal(#e.gotoCalls,0)
  e:advance(.3); equal(#e.gotoCalls,1); equal(e.gotoCalls[1],2)
  equal(e.focusCalls,2); equal(e.focused,e.window); equal(e.active.b,5); e:clean()
end)

test('reported goto success without a real Space switch times out without retrying Mission Control', function()
  local e=fixture(); e.focusMode='none'; e.gotoMode='none'; local guard=e:arm()
  assert(guard:complete(e.target)); e:advance(2.2)
  equal(#e.gotoCalls,1); equal(e.focusCalls,1); equal(e.active.a,1); e:clean()
end)

test('a focus return object is not treated as proof of active Space or focused window', function()
  local e=fixture(); e.focusMode='none'; e.gotoMode='switch'; local guard=e:arm()
  assert(guard:complete(e.target)); e:advance(2.2)
  equal(#e.gotoCalls,1); equal(e.focusCalls,2); equal(e.focused,e.fallback); e:clean()
end)

test('user input during polling prevents the fallback', function()
  local e=fixture(); e.focusMode='none'; local guard=e:arm()
  assert(guard:complete(e.target)); e:input('keyDown'); e:advance(3)
  equal(#e.gotoCalls,0); equal(e.focusCalls,1); e:clean()
end)

test('a user Space change after goto prevents final focus', function()
  local e=fixture(); e.focusMode='none'; local guard=e:arm()
  assert(guard:complete(e.target)); e:advance(.31); equal(#e.gotoCalls,1)
  e.active.a=3; e:advance(.2); equal(e.focusCalls,1); e:clean()
end)

test('returning to the original Space after goto is user navigation and cancels final focus', function()
  local e=fixture(); e.focusMode='none'; local guard=e:arm()
  assert(guard:complete(e.target)); e:advance(.31); equal(#e.gotoCalls,1); equal(e.active.a,2)
  e.active.a=1; e:advance(.2); equal(e.focusCalls,1); equal(#e.gotoCalls,1); e:clean()
end)

for _, change in ipairs({'pid','id','lock','generation','target-uuid','target-monitor','screen-added','window-spaces'}) do
  test(change..' invalidates the original permission before follow', function()
    local e=fixture(); local guard=e:arm(); local original={spaceID=2,spaceUUID='target',screenUUID='a'}
    if change=='pid' then e.window.app.pidValue=11
    elseif change=='id' then e.window.idValue=2
    elseif change=='lock' then e.blocked=true
    elseif change=='generation' then e.generation=2
    elseif change=='target-uuid' then e.target.spaceUUID='recycled'
    elseif change=='target-monitor' then e.target.screenUUID='b'
    elseif change=='screen-added' then e.active.c=10
    elseif change=='window-spaces' then e.window.spaces={2,3} end
    equal(guard:complete(original),false); equal(e.focusCalls,0); equal(#e.gotoCalls,0); e:clean()
  end)
end

test('generation change during the polling interval cancels without another operation', function()
  local e=fixture(); e.focusMode='none'; local guard=e:arm()
  assert(guard:complete(e.target)); e.generation=2; e:advance(.2)
  equal(#e.gotoCalls,0); equal(e.focusCalls,1); e:clean()
end)

test('unused guards expire after twelve seconds and cleanup cancellation is idempotent', function()
  local e=fixture(); local guard=e.follow:begin(e.window); assert(guard)
  e:advance(12); equal(guard:beforeMove(),false); equal(guard:cancel(),false); e:clean()
end)

test('explicit cancellation stops lifetime and polling timers', function()
  local e=fixture(); e.focusMode='none'; local guard=e:arm(); assert(guard:complete(e.target))
  assert(guard:cancel()); equal(guard:cancel(),false); e:advance(20)
  equal(e.focusCalls,1); equal(#e.gotoCalls,0); e:clean()
end)

test('focus and goto errors fail closed without escaping to the manager', function()
  for _, mode in ipairs({'focus','goto'}) do
    local e=fixture(); local guard=e:arm()
    if mode=='focus' then e.focusMode='error'; equal(guard:complete(e.target),false)
    else e.focusMode='none'; e.gotoMode='error'; assert(guard:complete(e.target)); e:advance(.4) end
    e:clean()
  end
end)

test('input generated during focus cancels instead of scheduling later fallback', function()
  local e=fixture(); e.focusMode='input'; local guard=e:arm()
  equal(guard:complete(e.target),false); e:advance(3); equal(#e.gotoCalls,0); e:clean()
end)

test('missing input permission or active Space data creates no guard', function()
  for _, missing in ipairs({'tap','active'}) do
    local e=fixture(); if missing=='tap' then e.tapUnavailable=true else e.activeUnavailable=true end
    equal(e.follow:begin(e.window),nil); equal(e.focusCalls,0); e:clean()
  end
end)

test('a held mouse button prevents arming even before an observed input event', function()
  local e=fixture(); local guard=e.follow:begin(e.window); assert(guard); e.buttons.left=true
  equal(guard:beforeMove(),false); e:clean()
end)

test('successful guards cannot issue a second complete operation', function()
  local e=fixture(); local guard=e:arm(); assert(guard:complete(e.target))
  equal(guard:complete(e.target),false); equal(e.focusCalls,1); equal(#e.gotoCalls,0); e:clean()
end)

test('begin supports the declared function-style API as well as Lua method syntax', function()
  local e=fixture(); local guard=e.follow.begin(e.window); assert(guard); assert(guard:beforeMove())
  guard:cancel(); e:clean()
end)

test('disabled event taps fail closed at creation and if input protection is lost during a move', function()
  local e=fixture(); e.tapDisabled=true
  equal(e.follow:begin(e.window),nil); e:clean()
  e.tapDisabled=false; local guard=e:arm(); e.tapDisabled=true
  equal(guard:complete(e.target),false); equal(e.focusCalls,0); e:clean()
end)

test('Secure Input blocks guard creation and cancels an armed move before any focus', function()
  local e=fixture(); e.secureInput=true
  equal(e.follow:begin(e.window),nil); equal(e.focusCalls,0); e:clean()
  e.secureInput=false; local guard=e:arm(); e.secureInput=true
  equal(guard:complete(e.target),false); equal(e.focusCalls,0); equal(#e.gotoCalls,0); e:clean()
end)

test('Secure Input during polling cancels before the goto fallback', function()
  local e=fixture(); e.focusMode='none'; local guard=e:arm(); assert(guard:complete(e.target))
  e.secureInput=true; e:advance(.4)
  equal(e.focusCalls,1); equal(#e.gotoCalls,0); e:clean()
end)

print('Follow tests: '..passed..' passed, '..failed..' failed')
if failed>0 then os.exit(1) end
