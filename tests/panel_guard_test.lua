package.path = './?.lua;./mac-deskpilot/?.lua;' .. package.path
local G = require('deskpilot_panel_guard')
local count, view = 0, {}
local function test(name, fn) fn(); count = count + 1; print('ok ' .. name) end
local function message(action, id)
  return {webView=view,name='deskpilot',frameInfo={mainFrame=true,request={URL='about:blank'}},body={action=action or 'ready',id=id}}
end
test('local main frame may handshake',function() assert(G.message(message(),view).action=='ready') end)
test('NSURL request bridge accepted',function()
  local m=message(); m.frameInfo.request.URL={url='about:blank',__luaSkinType='NSURL'}
  assert(G.message(m,view))
end)
test('foreign webview rejected',function() assert(not G.message(message(),{})) end)
test('missing webview rejected',function() local m=message(); m.webView=nil; assert(not G.message(m,view)); assert(not G.message(m,nil)) end)
test('subframe rejected',function() local m=message(); m.frameInfo.mainFrame=false; assert(not G.message(m,view)) end)
test('missing frame identity rejected',function() local m=message(); m.frameInfo=nil; assert(not G.message(m,view)) end)
test('missing request URL rejected',function() local m=message(); m.frameInfo.request={}; assert(not G.message(m,view)); assert(not G.localURL(nil)) end)
test('remote local-file data and javascript URLs rejected',function()
  for _,url in ipairs({'https://example.com','file:///tmp/panel.html','data:text/html,test','javascript:alert(1)','about:blank#other',''}) do
    local m=message(); m.frameInfo.request.URL=url; assert(not G.message(m,view)); assert(not G.localURL(url))
  end
end)
test('foreign channel rejected',function() local m=message(); m.name='other'; assert(not G.message(m,view)) end)
test('unknown and malformed commands rejected',function()
  for _,action in ipairs({'execute','openURL',42,{}}) do assert(not G.message(message(action),view)) end
  local m=message(); m.body=nil; assert(not G.message(m,view))
end)
test('stable Space and monitor identities accepted',function()
  for _,action in ipairs({'switch','move','rename','selectMonitor'}) do assert(G.message(message(action,'abc_123-DEF'),view).id=='abc_123-DEF') end
end)
test('missing oversized numeric and executable identities rejected',function()
  for _,action in ipairs({'switch','move','rename','selectMonitor'}) do
    assert(not G.message(message(action),view))
    for _,id in ipairs({'',42,string.rep('a',129),'<script>','x/y',"a');evil()"}) do assert(not G.message(message(action,id),view)) end
  end
end)
test('only approved fields reach native dispatcher',function()
  local m=message('enablePreviews'); m.body.url='https://example.com'; m.body.code='evil()'
  local body=G.message(m,view); assert(body.action=='enablePreviews' and body.url==nil and body.code==nil)
end)
test('on-demand preview commands require a bounded explicit target',function()
  for _,action in ipairs({'selectSpace','selectWindow','refreshPreview'}) do
    assert(G.message(message(action,'123-abc'),view).action==action)
    assert(not G.message(message(action),view))
    assert(not G.message(message(action,'../arbitrary'),view))
  end
end)
print(string.format('%d panel guard tests passed',count))
