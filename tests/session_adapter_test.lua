-- Pure boundary tests: no Hammerspoon, applications, UI, files, or processes.
local source = debug.getinfo(1, 'S').source:sub(2)
local directory = source:match('^(.*[/\\])') or './'
package.path = directory .. '../?.lua;' .. package.path
local captured
package.loaded.deskpilot_session = { new = function(ctx)
  captured = ctx
  return { frozen = 0, freeze = function(self) self.frozen = self.frozen + 1 end }
end }
package.loaded.deskpilot_session_adapter = nil
local Adapter = require('deskpilot_session_adapter')
local passed, failed = 0, 0
local function equal(actual, expected, label)
  assert(actual == expected, (label or 'unexpected value') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function test(name, run)
  local ok, err = pcall(run)
  if ok then passed=passed+1; print('ok - '..name)
  else failed=failed+1; print('FAIL - '..name..': '..tostring(err)) end
end
local function fixture(options)
  options = options or {}
  local e = { now=100, timers={}, windows={}, apps={}, identities={}, settings={}, tasks={}, moves={}, frames={},
    inputs={}, watchers={}, commands={}, addCalls={}, events={}, reads=0, refreshes=0,
    mouse={}, knownProfiles={Default=true,['Profile 2']=true}, occupancies={[11]=true,[22]=false},
    properties=options.properties or {CGSSessionUniqueSessionUUID='session-id'}, generation=3 }
  local function screen(id, uuid, frame)
    return { id=function()return id end, getUUID=function()return uuid end, frame=function()return frame end }
  end
  e.screens={screen(1,'internal',{x=0,y=0,w=1440,h=900}),screen(2,'external',{x=1440,y=0,w=2560,h=1440})}
  e.spaces={{spaceID=11,spaceUUID='space-i',screenUUID='internal',localIndex=1},
    {spaceID=22,spaceUUID='space-e',screenUUID='external',localIndex=1}}
  function e:advance(seconds)
    local target=self.now+seconds
    while true do
      local nextTimer
      for _, timer in ipairs(self.timers) do
        if not timer.stopped and timer.at<=target and (not nextTimer or timer.at<nextTimer.at) then nextTimer=timer end
      end
      if not nextTimer then break end
      self.now=nextTimer.at; nextTimer.stopped=true; nextTimer.callback()
    end
    self.now=target
  end
  function e:addWindow(id, pid, bundle, profile, recognized)
    local app={windows={}}
    function app:pid()return pid end
    function app:bundleID()return bundle end
    function app:allWindows()return self.windows end
    local window={windowID=id,app=app,spaceID=11,rectangle={x=10,y=20,w=600,h=400},role='AXStandardWindow',managed=true}
    function window:id()return self.windowID end
    function window:application()return self.app end
    function window:frame()return self.rectangle end
    function window:screen()return e.screens[1] end
    function window:title()return 'Synthetic private title' end
    function window:subrole()return self.role end
    function window:setFrame(frame,duration)e.frames[#e.frames+1]={window=self,frame=frame,duration=duration}end
    function window:focus()error('restore must never focus a window')end
    app.windows[1]=window
    self.windows[#self.windows+1]=window
    self.apps[bundle]=self.apps[bundle]or{};self.apps[bundle][#self.apps[bundle]+1]=app
    if recognized~=false then self.identities[window]={key=bundle..(profile and('::'..profile)or''),bundleID=bundle,profileDirectory=profile}end
    return window
  end
  e.window=e:addWindow(10,1001,'com.example.Editor')
  local api={
    timer={secondsSinceEpoch=function()return e.now end,doAfter=function(delay,callback)
      local t={at=e.now+delay,callback=callback,stop=function(self)self.stopped=true end};e.timers[#e.timers+1]=t;return t
    end},
    eventtap={checkMouseButtons=function()return e.mouse end,event={types={leftMouseDown=1,rightMouseDown=2,leftMouseDragged=3}},
      new=function(_,callback)local w={callback=callback,start=function(self)self.active=true;return self end,
        stop=function(self)self.active=false end};e.watchers[#e.watchers+1]=w;return w end},
    caffeinate={sessionProperties=function()return e.properties end},
    execute=function(command)e.commands[#e.commands+1]=command;return options.bootOutput or 'BOOT-UUID\n',options.bootOK~=false end,
    screen={allScreens=function()e.reads=e.reads+1;return e.screens end},
    settings={get=function(key)return e.settings[key]end,set=function(key,value)e.settings[key]=value end},
    hash={SHA256=function(value)return 'hashed:'..#value end},
    application={pathForBundleID=function(bundle)
        if e.emptyAppPath then return '' end
        return not e.missingApp and('/Applications/'..bundle..'.app')or nil
      end,
      applicationsForBundleID=function(bundle)return e.apps[bundle]or{} end},
    spaces={screensHaveSeparateSpaces=function()return e.separate~=false end,
      windowSpaces=function(window)return window.spaceIDs or {window.spaceID}end,
      spaceType=function()return e.spaceType or'user'end,
      addSpaceToScreen=function(display)
        e.addCalls[#e.addCalls+1]=display:getUUID()
        if e.addFailure then return false,'test rejection' end
        e.spaces[#e.spaces+1]={spaceID=33,spaceUUID='new-space',screenUUID=display:getUUID(),localIndex=2}
        e.occupancies[33]=false
        return true
      end},
    task={new=function(path,callback,args)
      if e.noTask then return nil end
      local t={path=path,args=args,running=false,callback=callback}
      function t:start()if e.startFailure then return false end;self.running=true;return self end
      function t:isRunning()return self.running end
      function t:terminate()self.running=false;self.terminated=true end
      function t:complete(code)self.running=false;self.callback(code,'','')end
      e.tasks[#e.tasks+1]=t;return t
    end},
    shutdownCallback=function()e.events[#e.events+1]='prior'end,
  }
  local manager={displays={{id=1,uuid='internal',builtIn=true},{id=2,uuid='external',builtIn=false}},
    metadataAt=e.now,guardUntil=0,layoutGuardUntil=0,generation=3,queue={},queued={},
    checkSessionLock=function()return e.locked==true end,
    occupancy=function(_,_,allowed)e.allowedGroups=allowed;e.reads=e.reads+1;return e.occupancies end,
    allWindows=function()e.reads=e.reads+1;return e.windows end,
    births={take=function(_,id,pid)e.inputs[#e.inputs+1]={id=id,pid=pid}end},
    move=function(self,window,target,manual,callback)
      equal(manual,false);if e.rejectMove then return false end
      self.busy=true;e.moves[#e.moves+1]={window=window,target=target,callback=callback};return true
    end,
    shutdown=function(self)self.shuttingDown=true;e.events[#e.events+1]='manager';self.session:freeze()end,
  }
  e.api,e.manager=api,manager
  e.helpers={workspaces=function()e.reads=e.reads+1;return e.spaces end,
    refresh=function()e.refreshes=e.refreshes+1 end,managed=function(w)return w.managed end,
    identity=function(w)return e.identities[w]end,
    knownProfile=function(directory)return e.knownProfiles[directory]==true end}
  captured=nil
  e.session,e.error=Adapter.attach(api,manager,e.helpers);e.ctx=captured
  function e:row()return self.ctx.rows()[1]end
  function e:completeMove(ok)
    local operation=self.moves[#self.moves];self.manager.busy=false
    if ok then operation.window.spaceID=operation.target.spaceID end
    operation.callback(ok)
  end
  return e
end

test('real session identity is used and boot fallback is a fixed read-only command',function()
  local e=fixture();equal(e.ctx.sessionID,'session-id');equal(#e.commands,0)
  e=fixture({properties={kCGSSessionAuditIDKey=501}})
  equal(e.ctx.sessionID,'BOOT-UUID:501');equal(e.commands[1],'/usr/sbin/sysctl -n kern.bootsessionuuid')
  e=fixture({properties={},bootOK=false});equal(e.session,nil);equal(e.ctx,nil);assert(e.error)
end)

test('display roles require matching native ID UUID and explicit built-in boolean',function()
  local e=fixture();local displays=e.ctx.screens()
  equal(displays[1].builtIn,true);equal(displays[2].builtIn,false)
  e.manager.displays[2].builtIn=nil;equal(e.ctx.screens(),nil)
  e.manager.displays[2].builtIn=false;e.manager.displays[2].id=3;equal(e.ctx.screens(),nil)
  e.manager.displays[2].id=2;e.manager.displays[2].uuid='different';equal(e.ctx.screens(),nil)
  e.manager.displays=nil;equal(e.ctx.screens(),nil)
end)

test('nonfinite native geometry cannot supply a monitor layout',function()
  for _,field in ipairs({'x','y','w','h'})do
    for _,value in ipairs({0/0,math.huge,-math.huge})do
      local e=fixture();local frame={x=1440,y=0,w=2560,h=1440};frame[field]=value
      e.screens[2].frame=function()return frame end;equal(e.ctx.screens(),nil)
    end
  end
end)

test('current native display roles apply while a manual assignment lasts for this session',function()
  local e=fixture();local chrome=e:addWindow(20,2001,'com.google.Chrome','Profile 2')
  equal(e.manager.preferredSessionScreen(chrome,nil),'external')
  local bitwarden=e:addWindow(21,2002,'com.bitwarden.desktop')
  equal(e.manager.preferredSessionScreen(bitwarden,{screenUUID='external'}),'internal')
  equal(e.manager.preferredSessionScreen(bitwarden,{screenUUID='external',manualMonitorSessionID='session-id'}),'external')
  equal(e.manager.preferredSessionScreen(bitwarden,{screenUUID='external',manualMonitorSessionID='old-session'}),'internal')
  e.manager.displays=nil;equal(e.manager.preferredSessionScreen(chrome,nil),false)
end)

test('incomplete stale or unknown occupancy cannot produce snapshot rows',function()
  local e=fixture();equal(#e.ctx.rows(),1)
  e.manager.metadataAt=e.now-5;equal(e.ctx.rows(),nil)
  e.manager.metadataAt=e.now;e.occupancies[22]=nil;equal(e.ctx.rows(),nil)
  e.occupancies[22]=false;table.remove(e.spaces,2);equal(e.ctx.rows(),nil)
end)

test('rows hash titles and exclude unrecognized or multi-Space windows',function()
  local e=fixture();local row=e:row()
  equal(row.title,nil);equal(row.titleHash,'hashed:23');equal(row.id,10);equal(row.pid,1001)
  e.window.spaceIDs={11,22};equal(#e.ctx.rows(),0)
  e.window.spaceIDs=nil;e.identities[e.window]=nil;equal(#e.ctx.rows(),0)
end)

test('pause lock drag settling and shutdown block operations',function()
  local e=fixture();equal(e.ctx.blocked(),false)
  for _, field in ipairs({'paused','busy','missionControl','shuttingDown'})do
    e.manager[field]=true;equal(e.ctx.blocked(),true);e.manager[field]=false
  end
  e.locked=true;equal(e.ctx.blocked(),true);e.locked=false
  e.mouse.left=true;equal(e.ctx.blocked(),true);e.mouse={}
  e.manager.guardUntil=e.now+1;equal(e.ctx.blocked(),true);e.manager.guardUntil=0
  e.separate=false;equal(e.ctx.blocked(),true)
end)

test('application launch uses an argument array with no shell and never duplicates a running app',function()
  local e=fixture();local result
  e.ctx.launch({bundleID='com.example.Absent'},function(ok)result=ok end)
  equal(#e.tasks,1);equal(e.tasks[1].path,'/usr/bin/open')
  equal(table.concat(e.tasks[1].args,'|'),'-g|-b|com.example.Absent')
  equal(result,nil);e.tasks[1]:complete(0);equal(result,true)
  e.ctx.launch({bundleID='com.example.Editor'},function(ok)result=ok end)
  equal(result,false);equal(#e.tasks,1)
end)

test('Chrome launch requires a currently known profile and blocks existing or unidentified profiles',function()
  local e=fixture();local chrome={bundleID='com.google.Chrome',profileDirectory='Profile 2'}
  equal(e.ctx.canLaunch(chrome),true)
  equal(e.ctx.canLaunch({bundleID='com.google.Chrome',profileDirectory='Missing Profile'}),false)
  e:addWindow(20,2001,'com.google.Chrome','Default')
  equal(e.ctx.canLaunch(chrome),true)
  local w=e:addWindow(21,2002,'com.google.Chrome','Profile 2')
  equal(e.ctx.canLaunch(chrome),false)
  e.identities[w]=nil;equal(e.ctx.canLaunch(chrome),false)
end)

test('known Chrome profile stays one literal process argument',function()
  local e=fixture();e.ctx.launch({bundleID='com.google.Chrome',profileDirectory='Profile 2'},function()end)
  equal(#e.tasks,1)
  equal(table.concat(e.tasks[1].args,'|'),'-g|-n|-b|com.google.Chrome|--args|--profile-directory=Profile 2|--restore-last-session')
end)

test('unknown display state prevents launching even an absent application',function()
  local e=fixture();e.manager.displays=nil;local result
  e.ctx.launch({bundleID='com.example.Absent'},function(ok)result=ok end)
  equal(result,false);equal(#e.tasks,0)
end)

test('an unavailable application or failed process startup resolves without a retry task',function()
  for _,failure in ipairs({'missingApp','emptyAppPath','noTask','startFailure'})do
    local e=fixture();e[failure]=true;local calls,result=0,nil
    e.ctx.launch({bundleID='com.example.Absent'},function(ok)calls=calls+1;result=ok end)
    equal(result,false);equal(calls,1);e:advance(10);equal(calls,1)
    equal(#e.tasks,failure=='startFailure'and 1 or 0)
  end
end)

test('launch timeout terminates its task and resolves only once',function()
  local e=fixture();local calls,result=0,nil
  e.ctx.launch({bundleID='com.example.Absent'},function(ok)calls=calls+1;result=ok end)
  e:advance(8);equal(calls,1);equal(result,false);equal(e.tasks[1].terminated,true)
  e.tasks[1]:complete(0);equal(calls,1)
end)

test('window identity guards reject a recycled ID PID or group before movement',function()
  for _, change in ipairs({'id','pid','key'})do
    local e=fixture();local row=e:row();local result
    if change=='id'then e.window.windowID=99
    elseif change=='pid'then e.window.app.pid=function()return 9999 end
    else e.identities[e.window].key='other-group'end
    e.ctx.move(row,e.spaces[2],nil,function(ok)result=ok end)
    equal(result,false);equal(#e.moves,0)
  end
end)

test('successful placement clears only its queued birth and clamps frame to its target monitor',function()
  local e=fixture();local row=e:row();local result
  e.manager.queue={{id=10},{id=99}};e.manager.queued={[10]=true,[99]=true}
  e.ctx.move(row,e.spaces[2],{x=-0.5,y=2,w=2,h=0.5},function(ok)result=ok end)
  equal(e.manager.queued[10],nil);equal(e.manager.queued[99],true);equal(#e.manager.queue,1)
  equal(e.inputs[1].id,10);equal(e.inputs[1].pid,1001)
  e:completeMove(true);equal(result,true);equal(#e.frames,1)
  local frame=e.frames[1].frame
  equal(frame.x,1440);equal(frame.y,720);equal(frame.w,2560);equal(frame.h,720)
  equal(e.frames[1].duration,0);equal(e.watchers[1].active,false)
end)

test('generation identity and user input changes prevent late frame application',function()
  for _, change in ipairs({'generation','pid','input'})do
    local e=fixture();local result
    e.ctx.move(e:row(),e.spaces[2],{x=0,y=0,w=0.5,h=0.5},function(ok)result=ok end)
    if change=='generation'then e.manager.generation=e.manager.generation+1
    elseif change=='pid'then e.window.app.pid=function()return 5555 end
    else e.watchers[1].callback()end
    e:completeMove(true);equal(result,false);equal(#e.frames,0);equal(e.watchers[1].active,false)
  end
end)

test('a removed or transferred target UUID prevents a late frame write',function()
  for _,change in ipairs({'uuid','monitor'})do
    local e=fixture();local result
    e.ctx.move(e:row(),e.spaces[2],{x=0,y=0,w=0.5,h=0.5},function(ok)result=ok end)
    e.spaces[2]={spaceID=22,spaceUUID=change=='uuid'and'replacement' or'space-e',
      screenUUID=change=='monitor'and'internal'or'external',localIndex=1}
    e:completeMove(true);equal(result,false);equal(#e.frames,0)
  end
end)

test('small windows remain within a target monitor smaller than the normal minimum',function()
  local e=fixture();local result
  e.screens[2].frame=function()return{x=-80,y=-60,w=80,h=60}end
  e.ctx.move(e:row(),e.spaces[2],{x=1,y=-1,w=0.01,h=0.01},function(ok)result=ok end)
  e:completeMove(true);equal(result,true)
  local frame=e.frames[1].frame
  equal(frame.x,-80);equal(frame.y,-60);equal(frame.w,80);equal(frame.h,60)
end)

test('unknown occupancy never makes a Space usable and allowed groups are forwarded unchanged',function()
  local e=fixture();local allowed={['com.example.Editor']=true}
  equal(e.ctx.canUse({},22,allowed),true);equal(e.allowedGroups,allowed)
  e.occupancies[22]=nil;equal(e.ctx.canUse({},22,allowed),false)
  e.occupancies[22]=true;equal(e.ctx.canUse({},22,allowed),false)
end)

test('suppressed stale move callbacks still release their temporary input watcher',function()
  local e=fixture()
  e.ctx.move(e:row(),e.spaces[2],{x=0,y=0,w=1,h=1},function()end)
  equal(e.watchers[1].active,true);e:advance(3);equal(e.watchers[1].active,false)
end)

test('Space creation is verified and interrupted generations cannot return a target',function()
  local e=fixture();local target,reason
  e.ctx.create('external',function(ws,err)target,reason=ws,err end)
  equal(e.manager.busy,true);equal(target,nil);equal(e.addCalls[1],'external')
  e:advance(0.6);equal(target.spaceUUID,'new-space');equal(reason,nil);equal(e.manager.busy,false)
  e=fixture();e.ctx.create('external',function(ws,err)target,reason=ws,err end)
  e.manager.generation=e.manager.generation+1;e:advance(0.6)
  equal(target,nil);equal(reason,'operation-interrupted')
end)

test('stale Space-creation completion cannot release a newer operation busy flag',function()
  local e=fixture()
  e.ctx.create('external',function()end)
  e.manager.generation=e.manager.generation+1
  e.manager.busy=false
  e.ctx.move(e:row(),e.spaces[2],nil,function()end)
  equal(#e.moves,1);equal(e.manager.busy,true)
  e:advance(0.6);equal(e.manager.busy,true)
end)

test('create rejects disconnected or incomplete state before invoking the UI',function()
  local e=fixture();local reason
  e.ctx.create('missing',function(_,err)reason=err end)
  equal(reason,'monitor-disconnected');equal(#e.addCalls,0)
  e.manager.metadataAt=e.now-8
  e.ctx.create('external',function(_,err)reason=err end)
  equal(reason,'incomplete-state');equal(#e.addCalls,0)
end)

test('failed or ambiguous Space creation releases only its own operation and never guesses a target',function()
  local e=fixture();local result,reason
  e.addFailure=true;e.ctx.create('external',function(ws,err)result,reason=ws,err end)
  equal(result,nil);equal(reason,'test rejection');equal(e.manager.busy,false);equal(e.manager.sessionCreateToken,nil)
  e=fixture();e.ctx.create('external',function(ws,err)result,reason=ws,err end)
  e.spaces[#e.spaces+1]={spaceID=34,spaceUUID='also-new',screenUUID='external',localIndex=3}
  e.occupancies[34]=false;e:advance(0.6)
  equal(result,nil);equal(reason,'ambiguous-new-space');equal(e.manager.busy,false)
end)

test('shutdown freezes the existing session and chains prior callback without scanning',function()
  local e=fixture();local reads=e.reads
  e.api.shutdownCallback()
  equal(e.session.frozen,1);equal(e.manager.shuttingDown,true)
  equal(table.concat(e.events,','),'manager,prior');equal(e.reads,reads)
end)

print(string.format('Session adapter tests: %d passed, %d failed',passed,failed))
if failed>0 then os.exit(1)end
