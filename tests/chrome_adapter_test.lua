local source = debug.getinfo(1, 'S').source:sub(2)
package.path = (source:match('^(.*[/\\])') or './') .. '../?.lua;' .. package.path
local Adapter = require('deskpilot_chrome')
local count = 0
local function test(name, fn) fn(); count = count + 1; print('ok - ' .. name) end
local function fixture()
  local env = { now = 100, data = { profile = { info_cache = {
    Default = { name = '[Główny]', gaia_given_name = 'Michał', is_using_default_name = false },
    ['Profile 51'] = { name = 'Michał', gaia_given_name = 'Michał', is_using_default_name = false },
    ['Profile 11'] = { name = 'WGB' },
  } } } }
  local api = { timer = { secondsSinceEpoch = function() return env.now end },
    json = { read = function() if env.broken then error('partial write') end; return env.data end } }
  env.adapter = Adapter.new(api, '/test/Local State')
  function env.window(id, title, pid, bundle)
    local app = { pid = function() return pid or 1 end, bundleID = function() return bundle or 'com.google.Chrome' end,
      name = function() return 'App' end }
    return { titleText = title, windowID = id, id = function(self) return self.windowID end,
      application = function() return app end, title = function(self) return self.titleText end }
  end
  return env
end

test('different profiles sharing a process have stable distinct group keys', function()
  local e = fixture()
  local a = e.window(1, 'Page – Google Chrome – Michał ([Główny])')
  local b = e.window(2, 'Page – Google Chrome – Michał')
  assert(e.adapter:groupKey(a) == 'com.google.Chrome::Default')
  assert(e.adapter:groupKey(b) == 'com.google.Chrome::Profile 51')
  a.titleText = 'Different tab – Google Chrome – Michał ([Główny])'
  assert(e.adapter:groupKey(a) == 'com.google.Chrome::Default')
end)

test('a tab dialog does not erase a trusted profile of the same window', function()
  local e = fixture(); local w = e.window(1, 'Page – Google Chrome – WGB')
  assert(e.adapter:identify(w).directory == 'Profile 11')
  w.titleText = 'Permission dialog'
  local profile, reason = e.adapter:identify(w)
  assert(profile.directory == 'Profile 11' and reason == 'cached-window')
end)

test('an unknown fresh window never inherits another window profile', function()
  local e = fixture()
  assert(e.adapter:identify(e.window(1, 'Page – Google Chrome – WGB')))
  local w = e.window(2, 'Incognito – Google Chrome')
  assert(e.adapter:identify(w) == nil)
  assert(e.adapter:groupKey(w) == 'com.google.Chrome::unresolved-window-2')
end)

test('a reused window ID in another process cannot inherit cached identity', function()
  local e = fixture()
  assert(e.adapter:identify(e.window(1, 'Page – Google Chrome – WGB', 1)))
  assert(e.adapter:identify(e.window(1, 'Dialog', 2)) == nil)
end)

test('closing a window clears its temporary profile binding', function()
  local e = fixture(); local w = e.window(1, 'Page – Google Chrome – WGB')
  assert(e.adapter:identify(w)); e.adapter:forget(1); w.titleText = 'Dialog'
  assert(e.adapter:identify(w) == nil)
end)

test('temporarily invalid Local State retains the last valid resolver', function()
  local e = fixture(); local w = e.window(1, 'Page – Google Chrome – WGB')
  assert(e.adapter:identify(w)); e.broken = true; e.now = e.now + 11
  assert(e.adapter:identify(e.window(2, w.titleText)).directory == 'Profile 11')
end)

test('renaming a profile changes its label and preserves directory identity', function()
  local e = fixture(); local w = e.window(1, 'Page – Google Chrome – WGB')
  assert(e.adapter:identify(w).directory == 'Profile 11')
  e.data.profile.info_cache['Profile 11'].name = 'WGB nowa nazwa'; e.now = e.now + 11
  w.titleText = 'Other page – Google Chrome – WGB nowa nazwa'
  local profile = e.adapter:identify(w)
  assert(profile.directory == 'Profile 11' and profile.label == 'WGB nowa nazwa')
end)

test('ordinary applications preserve their application group', function()
  local e = fixture(); local w = e.window(1, 'Page', 2, 'com.example.app')
  assert(not e.adapter:isChrome(w)); assert(e.adapter:groupKey(w) == 'com.example.app')
end)
test('known offscreen window IDs retain identity only for their owner process', function()
  local e = fixture(); local w = e.window(77, 'Page – Google Chrome – WGB', 42)
  assert(e.adapter:identify(w))
  assert(e.adapter:groupKeyForWindowID(77, 42) == 'com.google.Chrome::Profile 11')
  assert(e.adapter:groupKeyForWindowID(77, 43) == nil)
  assert(e.adapter:groupKeyForWindowID(78, 42) == nil)
  e.adapter:forget(77)
  assert(e.adapter:groupKeyForWindowID(77, 42) == nil)
end)
print('Passed ' .. count .. ' Chrome adapter tests')
