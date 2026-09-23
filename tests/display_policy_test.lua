local source = debug.getinfo(1, 'S').source:sub(2)
local directory = source:match('^(.*[/\\])') or './'
package.path = directory .. '../?.lua;' .. package.path
local Policy = require('deskpilot_display_policy')
local Layout = require('deskpilot_layout')
local passed = 0
local function equal(actual, expected, message)
  assert(actual == expected, (message or 'unexpected value') .. ': expected '
    .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function test(name, run) run(); passed = passed + 1; print('ok - ' .. name) end
local function screen(uuid, builtIn, w, h)
  return { uuid = uuid, builtIn = builtIn, frame = { x = 0, y = 0, w = w or 1920, h = h or 1080 } }
end
local function group(bundle, monitor, index, profile)
  return { bundleID = bundle, profileDirectory = profile, screenUUID = monitor,
    spaceUUID = monitor .. '-space-' .. index, spaceIndex = index,
    windows = { { titleHash = 'hash', frame = { x = 0.1, y = 0.2, w = 0.7, h = 0.6 } } } }
end
local function layout(screens, groups, savedAt, active)
  local ids = {}; for _, item in ipairs(screens) do ids[#ids + 1] = item.uuid end
  return assert(Layout.validateLayout({ version = 1, signature = Layout.signature(screens), savedAt = savedAt or 100,
    screens = ids, groups = groups, activeKeys = active or {} }))
end
local laptop, large, small = screen('L', true), screen('E', false, 3840, 2160), screen('S', false)

test('communication, password manager, settings, and terminal variants prefer the built-in display', function()
  for _, bundle in ipairs({ 'com.microsoft.teams', 'com.microsoft.teams2', 'COM.MICROSOFT.TEAMS2.preview',
      'com.apple.MobileSMS', 'com.facebook.archon', 'com.facebook.Messenger', 'com.bitwarden.desktop',
      'com.8bit.bitwarden', 'com.apple.systempreferences', 'com.apple.Terminal', 'com.googlecode.iterm2',
      'dev.warp.Warp-Stable', 'com.github.wez.wezterm', 'com.mitchellh.ghostty', 'net.kovidgoyal.kitty' }) do
    equal(Policy.preferredScreen({ bundleID = bundle, screenUUID = 'E' }, { large, laptop }, {}), 'L', bundle)
  end
end)

test('browser variants prefer external displays and retain their existing external target', function()
  for _, bundle in ipairs({ 'com.google.Chrome', 'com.google.Chrome.canary', 'com.microsoft.edgemac',
      'com.microsoft.edgemac.Beta', 'com.brave.Browser', 'org.mozilla.firefox', 'com.apple.Safari',
      'company.thebrowser.Browser', 'com.vivaldi.Vivaldi', 'com.operasoftware.Opera', 'com.operasoftware.OperaGX' }) do
    equal(Policy.preferredScreen({ bundleID = bundle, screenUUID = 'L' }, { laptop, large, small }, {}), 'E', bundle)
    equal(Policy.preferredScreen({ bundleID = bundle, screenUUID = 'S' }, { laptop, large, small }, { S = 100 }), 'S')
  end
end)

test('disconnected roles have a usable laptop-only or external-only fallback', function()
  equal(Policy.preferredScreen({ bundleID = 'com.google.Chrome', screenUUID = 'E' }, { laptop }, {}), 'L')
  equal(Policy.preferredScreen({ bundleID = 'com.apple.Terminal', screenUUID = 'S' }, { large, small }, {}), 'S')
  equal(Policy.preferredScreen({ bundleID = 'com.apple.Terminal', screenUUID = 'missing' }, { large }, {}), 'E')
end)

test('other applications retain their present saved monitor and otherwise prefer laptop then first', function()
  equal(Policy.preferredScreen({ bundleID = 'com.example.Editor', screenUUID = 'S' }, { large, laptop, small }, {}), 'S')
  equal(Policy.preferredScreen({ bundleID = 'com.example.Editor', screenUUID = 'missing' }, { large, laptop }, {}), 'L')
  equal(Policy.preferredScreen({ bundleID = 'com.example.Editor' }, { small, large }, {}), 'S')
end)

test('the latest session launch list and geometry win over an older exact monitor profile', function()
  local exact = layout({ laptop, large }, {
    ['com.google.Chrome::Default'] = group('com.google.Chrome', 'E', 5, 'Default') }, 100,
    { 'com.google.Chrome::Default' })
  local teams = group('com.microsoft.teams2', 'L', 1)
  teams.windows[1].frame.x, teams.windows[1].frame.y = 0.3, 0.25
  local newer = layout({ laptop }, { ['com.microsoft.teams2'] = teams }, 200, { 'com.microsoft.teams2' })
  local adapted = assert(Policy.adapt({ exact = exact, newer = newer }, { large, laptop }, 300))
  equal(adapted.signature, '2:E|L'); equal(adapted.savedAt, 300)
  equal(adapted.groups['com.google.Chrome::Default'], nil)
  equal(#adapted.activeKeys, 1); equal(adapted.activeKeys[1], 'com.microsoft.teams2')
  equal(adapted.groups['com.microsoft.teams2'].screenUUID, 'L')
  equal(adapted.groups['com.microsoft.teams2'].windows[1].frame.x, 0.3)
  equal(adapted.groups['com.microsoft.teams2'].windows[1].frame.y, 0.25)
end)

test('equal saved times prefer the exact monitor profile regardless of input order', function()
  local exact = layout({ laptop, large }, { ['com.apple.Terminal'] = group('com.apple.Terminal', 'E', 5) }, 100)
  local other = layout({ laptop }, { ['com.example.Other'] = group('com.example.Other', 'L', 1) }, 100)
  for _, saved in ipairs({ { exact, other }, { other, exact } }) do
    local adapted = assert(Policy.adapt(saved, { laptop, large }, 200))
    equal(adapted.groups['com.example.Other'], nil)
    equal(adapted.groups['com.apple.Terminal'].screenUUID, 'L')
    equal(adapted.groups['com.apple.Terminal'].spaceUUID, nil)
  end
end)

test('the most recent valid source is used when no exact monitor profile exists', function()
  local oldest = layout({ laptop }, { ['com.example.Old'] = group('com.example.Old', 'L', 1) }, 100)
  local newest = layout({ small }, { ['com.example.New'] = group('com.example.New', 'S', 1) }, 200)
  local invalid = { version = 1, savedAt = 10000, groups = {} }
  local adapted = assert(Policy.adapt({ oldest, invalid, newest }, { laptop, large }, 300))
  assert(adapted.groups['com.example.New']); equal(adapted.groups['com.example.Old'], nil)
  equal(adapted.groups['com.example.New'].screenUUID, 'L')
end)

test('the same monitor count with different UUIDs adapts rather than trusting an unrelated Space', function()
  local original = layout({ laptop, small }, { ['com.google.Chrome::Default'] = group('com.google.Chrome', 'S', 7, 'Default') }, 100,
    { 'com.google.Chrome::Default' })
  local adapted = assert(Policy.adapt({ original }, { laptop, large }, 200))
  local browser = adapted.groups['com.google.Chrome::Default']
  equal(adapted.signature, '2:E|L'); equal(browser.screenUUID, 'E')
  equal(browser.spaceUUID, nil); equal(browser.spaceIndex, 1)
  equal(adapted.activeKeys[1], 'com.google.Chrome::Default')
  equal(browser.windows[1].frame.x, 0.1)
  equal(original.groups['com.google.Chrome::Default'].spaceUUID, 'S-space-7')
end)

test('distinct Chrome profiles are distributed proportionally by external display area', function()
  local groups, active = {}, {}
  for index = 1, 10 do
    local directory = 'Profile ' .. index
    local key = 'com.google.Chrome::' .. directory
    groups[key] = group('com.google.Chrome', 'L', index, directory)
    active[#active + 1] = key
  end
  local original = layout({ laptop }, groups, 100, active)
  local adapted = assert(Policy.adapt({ original }, { laptop, large, small }, 200))
  local counts, indices = { E = 0, S = 0 }, { E = {}, S = {} }
  for key, browser in pairs(adapted.groups) do
    assert(original.groups[key]); assert(browser.profileDirectory)
    equal(browser.spaceUUID, nil)
    counts[browser.screenUUID] = counts[browser.screenUUID] + 1
    assert(not indices[browser.screenUUID][browser.spaceIndex], 'moved profiles must get distinct local positions')
    indices[browser.screenUUID][browser.spaceIndex] = true
  end
  equal(counts.E, 8); equal(counts.S, 2)
  equal(#adapted.activeKeys, 10)
end)

test('permitted saved external assignments survive adaptation and count toward balancing', function()
  local groups = {
    ['com.google.Chrome::Default'] = group('com.google.Chrome', 'E', 3, 'Default'),
    ['com.google.Chrome::Profile 1'] = group('com.google.Chrome', 'L', 1, 'Profile 1'),
  }
  local equallyLarge = screen('S', false, 3840, 2160)
  local original = layout({ laptop, large, equallyLarge }, groups)
  local adapted = assert(Policy.adapt({ original }, { laptop, large, equallyLarge }, 200))
  equal(adapted.groups['com.google.Chrome::Default'].spaceUUID, 'E-space-3')
  equal(adapted.groups['com.google.Chrome::Default'].spaceIndex, 3)
  equal(adapted.groups['com.google.Chrome::Profile 1'].screenUUID, 'S')
end)

test('moved groups receive compact available indices in their original order without replacing retained indices', function()
  local groups = {
    ['com.example.Stays'] = group('com.example.Stays', 'L', 1),
    ['com.apple.Terminal'] = group('com.apple.Terminal', 'E', 8),
    ['com.bitwarden.desktop'] = group('com.bitwarden.desktop', 'E', 2),
  }
  local original = layout({ laptop, large }, groups)
  local adapted = assert(Policy.adapt({ original }, { laptop, large }, 200))
  equal(adapted.groups['com.example.Stays'].spaceIndex, 1)
  equal(adapted.groups['com.bitwarden.desktop'].spaceIndex, 2)
  equal(adapted.groups['com.apple.Terminal'].spaceIndex, 3)
end)

test('legacy and inactive stored groups are retained without inventing a launch list', function()
  local original = layout({ laptop }, { ['com.example.Editor'] = group('com.example.Editor', 'L', 1) })
  original.activeKeys = nil
  local adapted = assert(Policy.adapt({ original }, { laptop, large }, 200))
  equal(#adapted.activeKeys, 0); assert(adapted.groups['com.example.Editor'])
end)

test('invalid or excessive display inputs and invalid output timestamps fail closed', function()
  local original = layout({ laptop }, {})
  equal(Policy.adapt({}, { laptop }, 200), nil)
  equal(Policy.adapt({ original }, {}, 200), nil)
  equal(Policy.adapt({ original }, { laptop, laptop }, 200), nil)
  equal(Policy.adapt({ original }, { laptop }, 0 / 0), nil)
  equal(Policy.preferredScreen({}, { screen('X', false, -1, 1) }, {}), nil)
  local many = {}; for i = 1, 9 do many[i] = screen(tostring(i), false) end
  equal(Policy.adapt({ original }, many, 200), nil)
end)

print(string.format('%d display policy tests passed', passed))
