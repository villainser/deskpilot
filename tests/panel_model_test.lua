package.path = './?.lua;./mac-deskpilot/?.lua;' .. package.path
local P = require('deskpilot_panel_model')
local count = 0
local function test(name, fn) fn(); count = count + 1; print('ok ' .. name) end
local function rect(x,y,w,h) return {x=x,y=y,w=w,h=h} end
test('negative monitor origin projects relative coordinates', function()
  local p=P.project(rect(-1800,200,500,400),rect(-2000,100,2000,1000))
  assert(p.x==0.1 and p.y==0.1 and p.w==0.25 and p.h==0.4)
end)
test('clipping a window spanning screens',function()
  local p=P.project(rect(-100,-20,500,300),rect(0,0,1000,800))
  assert(p.x==0 and p.y==0 and p.w==0.4 and p.h==0.35)
end)
test('offscreen windows do not invent positions',function() assert(P.project(rect(1200,0,100,100),rect(0,0,1000,800))==nil) end)
test('invalid geometry never yields NaN',function()
  assert(P.project(rect(0,0,0,5),rect(0,0,100,100))==nil)
  assert(P.project(rect(0/0,0,10,5),rect(0,0,100,100))==nil)
  assert(P.project(rect(0,0,10,5),rect(0,0,math.huge,100))==nil)
end)
local a={id='space-a',spaceID=10,screenUUID='left',screenName='Dell',screenFrame=rect(-1000,0,1000,800),index=1,localIndex=1,name='Chrome'}
local b={id='space-b',spaceID=20,screenUUID='left',screenName='Dell',screenFrame=a.screenFrame,index=2,localIndex=2,name='Bitwarden'}
test('stable id resolves after reorder',function() assert(P.resolve('space-a',{b,a})==a) end)
test('stale and numeric references cannot target recycled positions',function()
  assert(P.resolve('space-gone',{a,b})==nil); assert(P.resolve(1,{a,b})==nil)
end)
test('native order remains authoritative',function()
  local result=P.build({b,a},{},{[10]={},[20]={}},{left=20})
  assert(result[1].spaces[1].id=='space-b' and result[1].spaces[1].active)
end)
test('known system surfaces do not inflate preview counts',function()
  local result=P.build({a},{[99]=false},{[10]={99}},{})[1].spaces[1]
  assert(result.windowCount==0 and result.unknownCount==0 and #result.windows==0)
end)
test('unknown and geometry-less windows stay explicit',function()
  local result=P.build({a},{[1]={label='App'}},{[10]={1,2,2}},{})[1].spaces[1]
  assert(result.windowCount==2 and result.unknownCount==2 and #result.windows==0)
end)
test('failed Space enumeration differs from an empty desktop',function()
  assert(P.build({a},{},{},{})[1].spaces[1].unavailable)
  assert(not P.build({a},{},{[10]={}},{})[1].spaces[1].unavailable)
end)
test('preview retains stack and minimized flags without titles',function()
  local result=P.build({a},{[1]={frame=rect(-900,20,300,400),label='Front'},[2]={frame=rect(-800,30,200,400),label='Back',minimized=true}},{[10]={1,2}},{})[1].spaces[1]
  assert(result.windows[1].id==2 and result.windows[1].minimized and result.windows[2].label=='Front')
end)
test('two monitors are never merged by equal display names',function()
  local other={id='space-c',spaceID=30,screenUUID='right',screenName='Dell',screenFrame=rect(0,0,1000,800),index=3,localIndex=1,name='App'}
  assert(#P.build({a,other},{},{[10]={},[30]={}},{})==2)
end)
print(string.format('%d panel model tests passed',count))
