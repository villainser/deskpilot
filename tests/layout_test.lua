local source = debug.getinfo(1, 'S').source:sub(2)
local directory = source:match('^(.*[/\\])') or './'
package.path = directory .. '../?.lua;' .. package.path
local Layout = require('deskpilot_layout')
local passed = 0
local function equal(actual, expected, message)
  assert(actual == expected, (message or 'unexpected value') .. ': expected '
    .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function test(name, run) run(); passed = passed + 1; print('ok - ' .. name) end
local function frame(x) return { x = x or 0, y = 0.1, w = 0.4, h = 0.8 } end
local function window(hash, x) return { titleHash = hash, frame = frame(x) } end
local function group(bundle, screen, space, index, directory)
  return { bundleID = bundle or 'com.example.Editor', profileDirectory = directory,
    screenUUID = screen or 'A', spaceUUID = space or 'space-A', spaceIndex = index or 1,
    windows = { window('first') } }
end
local function snapshot(groups, screens)
  screens = screens or { { uuid = 'A' }, { uuid = 'B' } }
  local ids = {}; for _, screen in ipairs(screens) do ids[#ids + 1] = screen.uuid end
  return { version = 1, signature = Layout.signature(screens), savedAt = 100,
    screens = ids, groups = groups or { ['com.example.Editor'] = group() } }
end
local function workspace(id, uuid, screen, index)
  return { spaceID = id, spaceUUID = uuid, screenUUID = screen, localIndex = index }
end

test('profile signature depends on monitor identities and count, not order or geometry', function()
  local screens = { { uuid = 'B', frame = { x = 0, y = 0, w = 1920, h = 1080 } }, { uuid = 'A' } }
  equal(Layout.signature(screens), '2:A|B')
  screens[1].frame = { x = -2560, y = 200, w = 2560, h = 1440 }
  equal(Layout.signature(screens), Layout.signature({ { uuid = 'A' }, { uuid = 'B' } }))
  assert(Layout.signature({ { uuid = 'A' } }) ~= Layout.signature(screens))
  assert(Layout.signature({ { uuid = 'A' }, { uuid = 'C' } }) ~= Layout.signature(screens))
end)

test('invalid, duplicate, sparse, or excessive screen identities are rejected', function()
  equal(Layout.signature({}), nil)
  equal(Layout.signature({ { uuid = 'A' }, { uuid = 'A' } }), nil)
  equal(Layout.signature({ { uuid = 'A|B' } }), nil)
  equal(Layout.signature({ [1] = { uuid = 'A' }, [3] = { uuid = 'B' } }), nil)
  local many = {}; for i = 1, 9 do many[i] = { uuid = tostring(i) } end
  equal(Layout.signature(many), nil)
end)

test('validation produces a deep whitelist copy without transient IDs or titles', function()
  local value = snapshot()
  value.pid, value.extra = 100, 'ignored'
  local original = value.groups['com.example.Editor']
  original.windowID, original.pid, original.title = 12, 100, 'not persisted'
  original.windows[1].windowID, original.windows[1].title = 12, 'not persisted'
  original.windows[1].frame.extra = true
  local copy = assert(Layout.validateLayout(value))
  local saved = copy.groups['com.example.Editor']
  equal(copy.pid, nil); equal(copy.extra, nil); equal(saved.pid, nil)
  equal(saved.windowID, nil); equal(saved.title, nil)
  equal(saved.windows[1].windowID, nil); equal(saved.windows[1].title, nil)
  equal(saved.windows[1].frame.extra, nil)
  saved.windows[1].frame.x = 0.9
  equal(original.windows[1].frame.x, 0)
end)

test('corrupt layout versions, times, group fields, and monitor references fail validation', function()
  local mutations = {
    function(v) v.version = 2 end,
    function(v) v.savedAt = 0 / 0 end,
    function(v) v.savedAt = -1 end,
    function(v) v.groups['com.example.Editor'].screenUUID = 'C' end,
    function(v) v.groups['com.example.Editor'].spaceUUID = '' end,
    function(v) v.groups['com.example.Editor'].spaceIndex = 0 end,
    function(v) v.groups['com.example.Editor'].spaceIndex = 1.5 end,
    function(v) v.groups['com.example.Editor'].bundleID = 'different' end,
    function(v) v.groups['com.example.Editor'].windows[1].titleHash = string.rep('x', 129) end,
    function(v) v.groups['com.example.Editor'].windows = { [2] = window() } end,
  }
  for _, mutate in ipairs(mutations) do local v = snapshot(); mutate(v); equal(Layout.validateLayout(v), nil) end
end)

test('saved signature must match both monitor count and exact identities', function()
  for _, signature in ipairs({ '1:A', '2:A|C', '3:A|B|C', '2:B|A' }) do
    local v = snapshot(); v.signature = signature; equal(Layout.validateLayout(v), nil)
  end
end)

test('Chrome profiles remain distinct and unidentified or inconsistent Chrome groups are rejected', function()
  local groups = {
    ['com.google.Chrome::Default'] = group('com.google.Chrome', 'A', 'chrome-main', 1, 'Default'),
    ['com.google.Chrome::Profile 1'] = group('com.google.Chrome', 'B', 'chrome-work', 2, 'Profile 1'),
  }
  local copy = assert(Layout.validateLayout(snapshot(groups)))
  equal(copy.groups['com.google.Chrome::Default'].screenUUID, 'A')
  equal(copy.groups['com.google.Chrome::Profile 1'].screenUUID, 'B')
  equal(Layout.validateLayout(snapshot({ ['com.google.Chrome'] = group('com.google.Chrome') })), nil)
  equal(Layout.validateLayout(snapshot({ ['com.google.Chrome::Default'] = group('com.google.Chrome', nil, nil, nil, 'Profile 1') })), nil)
  equal(Layout.validateLayout(snapshot({ ['com.google.Chrome::unresolved-window-5'] = group('com.google.Chrome', nil, nil, nil, 'unresolved-window-5') })), nil)
  equal(Layout.validateLayout(snapshot({ ['com.example.Editor'] = group(nil, nil, nil, nil, 'Default') })), nil)
end)

test('group and window record limits are enforced', function()
  local groups = {}; for i = 1, 129 do local bundle = 'com.example.App' .. i; groups[bundle] = group(bundle) end
  equal(Layout.validateLayout(snapshot(groups)), nil)
  local value = snapshot(); local windows = value.groups['com.example.Editor'].windows
  for i = 1, 17 do windows[i] = window(tostring(i)) end
  equal(Layout.validateLayout(value), nil)
  windows[17] = nil
  assert(Layout.validateLayout(value))
end)

test('normalized frames must be finite, bounded, and have nonzero dimensions', function()
  for _, invalid in ipairs({ { x = 0, y = 0, w = 0, h = 1 }, { x = 0, y = 0, w = 1, h = -1 },
      { x = 0, y = math.huge, w = 1, h = 1 }, { x = 0 / 0, y = 0, w = 1, h = 1 },
      { x = 300, y = 0, w = 600, h = 400 }, { x = 0, y = 0, w = 2.1, h = 1 } }) do
    local value = snapshot(); value.groups['com.example.Editor'].windows[1].frame = invalid
    equal(Layout.validateLayout(value), nil)
  end
  local value = snapshot(); value.groups['com.example.Editor'].windows[1].frame = { x = -0.1, y = 0, w = 0.2, h = 0.2 }
  assert(Layout.validateLayout(value))
end)

test('an empty observation retains absent groups and frames on the same monitors', function()
  local previous = snapshot()
  local merged = assert(Layout.merge(previous, { { uuid = 'B' }, { uuid = 'A' } }, {}, 200))
  equal(merged.savedAt, 200)
  equal(#merged.groups['com.example.Editor'].windows, 1)
  equal(merged.groups['com.example.Editor'].windows[1].titleHash, 'first')
  merged.groups['com.example.Editor'].windows[1].frame.x = 0.7
  equal(previous.groups['com.example.Editor'].windows[1].frame.x, 0)
end)

test('a partial window observation preserves all old frames while updating the desktop assignment', function()
  local previous = snapshot()
  previous.groups['com.example.Editor'].windows = { window('first'), window('second', 0.5) }
  for _, windows in ipairs({ {}, { window('first', 0.2) } }) do
    local current = group(nil, 'B', 'new-space', 3); current.windows = windows
    local merged = assert(Layout.merge(previous, { { uuid = 'A' }, { uuid = 'B' } }, { ['com.example.Editor'] = current }, 200))
    local saved = merged.groups['com.example.Editor']
    equal(saved.screenUUID, 'B'); equal(saved.spaceUUID, 'new-space'); equal(saved.spaceIndex, 3)
    equal(#saved.windows, 2); equal(saved.windows[1].frame.x, 0); equal(saved.windows[2].frame.x, 0.5)
  end
end)

test('complete newer observations replace frames and add groups without losing absent applications', function()
  local previous = snapshot()
  previous.groups['com.example.Absent'] = group('com.example.Absent')
  local updated = group(); updated.windows[1].frame.x = 0.4
  local merged = assert(Layout.merge(previous, { { uuid = 'A' }, { uuid = 'B' } }, {
    ['com.example.Editor'] = updated, ['com.example.New'] = group('com.example.New') }, 200))
  equal(merged.groups['com.example.Editor'].windows[1].frame.x, 0.4)
  assert(merged.groups['com.example.Absent']); assert(merged.groups['com.example.New'])
end)

test('another monitor profile and corrupt previous data cannot leak old groups into a new layout', function()
  for _, screens in ipairs({ { { uuid = 'A' } }, { { uuid = 'A' }, { uuid = 'C' } } }) do
    local merged = assert(Layout.merge(snapshot(), screens, {}, 200))
    equal(next(merged.groups), nil)
  end
  local previous = snapshot(); previous.version = 99
  local merged = assert(Layout.merge(previous, { { uuid = 'A' }, { uuid = 'B' } }, {}, 200))
  equal(next(merged.groups), nil)
  equal(Layout.merge(snapshot(), { { uuid = 'A' } }, { bad = {} }, 200), nil)
end)

test('stable Space UUID on the correct monitor wins without an occupancy fallback', function()
  local expected = workspace(9, 'saved', 'A', 4)
  local selected = Layout.target(group(nil, 'A', 'saved', 1), { workspace(8, 'saved', 'B', 1), expected },
    function() error('must not query a fallback') end)
  equal(selected, expected)
end)

test('recycled numeric positions require explicit usability and never cross monitors', function()
  local busy = workspace(1, 'replacement', 'A', 2)
  local free = workspace(2, 'free', 'A', 3)
  local elsewhere = workspace(3, 'saved', 'B', 2)
  local saved = group(nil, 'A', 'saved', 2)
  equal(Layout.target(saved, { elsewhere, busy, free }, function(id) return id == 2 end), free)
  equal(Layout.target(saved, { elsewhere, busy }, function() return false end), nil)
  equal(Layout.target(saved, { elsewhere, busy }, function() return nil end), nil)
  equal(Layout.target(saved, { elsewhere, busy }, function() error('unknown occupancy') end), nil)
  equal(Layout.target(saved, { elsewhere, busy }, nil), nil)
end)

test('a usable saved local index is preferred before the first usable desktop', function()
  local first, preferred = workspace(1, 'first', 'A', 1), workspace(5, 'preferred', 'A', 5)
  equal(Layout.target(group(nil, 'A', 'missing', 5), { preferred, first }, function() return true end), preferred)
  equal(Layout.target(group(nil, 'A', 'missing', 4), { preferred, first }, function() return true end), first)
end)

test('ambiguous Space identity cannot choose an arbitrary desktop', function()
  equal(Layout.target(group(nil, 'A', 'saved'), { workspace(1, 'saved', 'A', 1), workspace(2, 'saved', 'A', 2) },
    function() return true end), nil)
end)

test('one saved and one current window restore a copied frame without needing a title match', function()
  local saved = group(); local current = { { titleHash = 'different' } }
  local selected = assert(Layout.frameFor(saved, current, current[1]))
  equal(selected.w, 0.4); selected.w = 1
  equal(saved.windows[1].frame.w, 0.4)
end)

test('multiple windows match exact hashes regardless of order', function()
  local saved = group(); saved.windows = { window('alpha'), window('beta', 0.5) }
  local current = { { titleHash = 'beta' }, { titleHash = 'alpha' } }
  equal(Layout.frameFor(saved, current, current[1]).x, 0.5)
  equal(Layout.frameFor(saved, current, current[2]).x, 0)
end)

test('duplicate hashes on either side and missing hashes never guess an ordinal', function()
  local saved = group(); saved.windows = { window('alpha'), window('alpha', 0.5) }
  local current = { { titleHash = 'alpha' }, { titleHash = 'beta' } }
  equal(Layout.frameFor(saved, current, current[1]), nil)
  saved.windows = { window('alpha'), window('beta', 0.5) }
  current[2].titleHash = 'alpha'
  equal(Layout.frameFor(saved, current, current[1]), nil)
  current[1].titleHash, current[2].titleHash = nil, nil
  equal(Layout.frameFor(saved, current, current[1]), nil)
end)

test('empty layouts, invalid frames, and unrelated current rows have no restore frame', function()
  local saved = group(); local current = { {} }
  equal(Layout.frameFor(saved, current, {}), nil)
  equal(Layout.frameFor(saved, {}, current[1]), nil)
  saved.windows = {}
  equal(Layout.frameFor(saved, current, current[1]), nil)
  saved.windows = { { frame = { x = 0, y = 0, w = 0, h = 1 } } }
  equal(Layout.frameFor(saved, current, current[1]), nil)
end)

test('legacy layouts have no launch list and invalid active keys are rejected', function()
  local legacy = assert(Layout.validateLayout(snapshot()))
  equal(#legacy.activeKeys, 0)
  for _, keys in ipairs({ { 'missing' }, { 'com.example.Editor', 'com.example.Editor' },
      { [2] = 'com.example.Editor' }, { ['com.example.Editor'] = true } }) do
    local value = snapshot(); value.activeKeys = keys
    equal(Layout.validateLayout(value), nil)
  end
end)

test('active keys contain only current observations while preserving older closed application layouts', function()
  local previous = snapshot({ ['com.example.Editor'] = group(), ['com.example.Old'] = group('com.example.Old') })
  previous.activeKeys = { 'com.example.Old' }
  local saved = assert(Layout.merge(previous, { { uuid = 'A' }, { uuid = 'B' } }, { ['com.example.Editor'] = group() }, 200))
  equal(#saved.activeKeys, 1); equal(saved.activeKeys[1], 'com.example.Editor')
  assert(saved.groups['com.example.Old'])
  local empty = assert(Layout.merge(saved, { { uuid = 'A' }, { uuid = 'B' } }, {}, 201))
  equal(#empty.activeKeys, 1); equal(empty.activeKeys[1], 'com.example.Editor')
end)

test('missing Space UUID supports safe adaptation without trusting a persisted numeric Space ID', function()
  local value = snapshot(); local saved = value.groups['com.example.Editor']
  saved.spaceUUID, saved.spaceID = nil, 99
  local validated = assert(Layout.validateLayout(value)).groups['com.example.Editor']
  equal(validated.spaceUUID, nil); equal(validated.spaceID, nil)
  local recycled = workspace(99, 'different', 'A', 1)
  equal(Layout.target(validated, { recycled }, function() return false end), nil)
  equal(Layout.target(validated, { recycled }, function() return nil end), nil)
  equal(Layout.target(validated, { recycled }, function() return true end), recycled)
end)

print(string.format('%d layout tests passed', passed))
