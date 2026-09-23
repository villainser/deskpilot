-- Pure planner tests; no Hammerspoon, filesystem changes or window movement.
local source = debug.getinfo(1, 'S').source:sub(2)
package.path = (source:match('^(.*[/\\])') or './') .. '../?.lua;' .. package.path
local Organize = require('deskpilot_organize')
local passed, failed = 0, 0
local function equal(actual, expected, message)
  assert(actual == expected, (message or 'unexpected value') .. ': expected '
    .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function test(name, run)
  local ok, err = pcall(run)
  if ok then passed = passed + 1; print('ok - ' .. name)
  else failed = failed + 1; print('FAIL - ' .. name .. ': ' .. tostring(err)) end
end
local function row(key, id, space, monitor)
  return {key = key, id = id, pid = id + 1000, spaceID = space,
    screenUUID = monitor or 'screen-a', spaceUUID = 'space-' .. space}
end
local function keys(plan)
  local result = {}; for _, group in ipairs(plan.groups) do result[#result + 1] = group.key end
  return table.concat(result, ',')
end
local function encode(value)
  if type(value) ~= 'table' then return type(value) .. ':' .. tostring(value) end
  local keys = {}; for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local result = {}; for _, key in ipairs(keys) do result[#result + 1] = encode(key) .. '=' .. encode(value[key]) end
  return '{' .. table.concat(result, '|') .. '}'
end

test('missing or malformed input produces an empty plan', function()
  for _, input in ipairs({false, 42, 'rows', {}}) do
    local plan = Organize.plan(input)
    equal(plan.conflicts, 0); equal(plan.groupCount, 0); equal(#plan.groups, 0)
  end
  equal(Organize.plan(nil).groupCount, 0)
end)

test('separate desktops and several windows from one group do not conflict', function()
  local plan = Organize.plan({row('A', 1, 10), row('A', 2, 10), row('B', 3, 20)})
  equal(plan.conflicts, 0); equal(plan.groupCount, 0)
end)

test('a split group alone does not authorize consolidation', function()
  local plan = Organize.plan({row('A', 1, 10), row('A', 2, 20, 'screen-b')})
  equal(plan.conflicts, 0); equal(plan.groupCount, 0)
end)

test('alphabetical keeper is independent of input order', function()
  local plan = Organize.plan({row('Z', 2, 10), row('A', 1, 10)})
  equal(plan.conflicts, 1); equal(plan.groupCount, 1); equal(keys(plan), 'Z')
  equal(plan.groups[1].sourceSpaceID, 10); equal(plan.groups[1].sourceSpaceUUID, 'space-10')
  equal(plan.groups[1].sourceScreenUUID, 'screen-a')
end)

test('focused group stays on its shared desktop', function()
  local rows = {row('Z', 2, 10), row('A', 1, 10), row('B', 3, 10)}
  equal(keys(Organize.plan(rows, 'Z')), 'A,B')
  equal(keys(Organize.plan(rows, 'missing')), 'B,Z')
  equal(keys(Organize.plan(rows, false)), 'B,Z')
end)

test('Chrome profiles remain distinct even with a shared PID', function()
  local a, b = row('com.google.Chrome::Default', 1, 10), row('com.google.Chrome::Profile 1', 2, 10)
  a.pid, b.pid = 900, 900
  local plan = Organize.plan({a, b}, b.key)
  equal(keys(plan), a.key); equal(plan.groups[1].windows[1].pid, 900)
end)

test('all windows of a moved group are included across desktops and monitors', function()
  local plan = Organize.plan({row('A', 1, 10), row('B', 2, 10), row('B', 3, 20), row('B', 4, 30, 'screen-b')})
  equal(keys(plan), 'B'); equal(plan.groupCount, 1); equal(plan.conflicts, 1)
  local windows = plan.groups[1].windows
  equal(#windows, 3); equal(windows[1].id, 2); equal(windows[3].screenUUID, 'screen-b')
  equal(plan.groups[1].sourceSpaceID, 10)
end)

test('global keeper selection avoids moving a keeper from a second conflict unnecessarily', function()
  local plan = Organize.plan({row('A', 1, 10), row('B', 2, 10), row('B', 3, 20), row('C', 4, 20)})
  equal(plan.conflicts, 2); equal(plan.groupCount, 1); equal(keys(plan), 'B')
  equal(#plan.groups[1].windows, 2)
end)

test('focused group has global priority across multiple shared desktops', function()
  local plan = Organize.plan({row('A', 1, 10), row('B', 2, 10), row('B', 3, 20), row('C', 4, 20)}, 'B')
  equal(plan.conflicts, 2); equal(plan.groupCount, 2); equal(keys(plan), 'A,C')
end)

test('cycles plan every moving group only once', function()
  local plan = Organize.plan({row('A', 1, 10), row('B', 2, 10), row('B', 3, 20),
    row('C', 4, 20), row('C', 5, 30), row('A', 6, 30)})
  equal(plan.conflicts, 3); equal(keys(plan), 'B,C'); equal(plan.groupCount, 2)
  equal(#plan.groups[1].windows, 2); equal(#plan.groups[2].windows, 2)
end)

test('source and complete output stay identical through row permutations', function()
  local rows = {row('B', 9, 20, 'screen-b'), row('A', 8, 20, 'screen-b'),
    row('A', 4, 30), row('B', 3, 30), row('B', 2, 10), row('A', 1, 10)}
  local expected = encode(Organize.plan(rows))
  equal(Organize.plan(rows).groups[1].sourceSpaceID, 10)
  for shift = 0, #rows - 1 do
    local permutation = {}
    for i = 1, #rows do permutation[i] = rows[(i + shift - 1) % #rows + 1] end
    equal(encode(Organize.plan(permutation)), expected)
    local reversed = {}; for i = #permutation, 1, -1 do reversed[#reversed + 1] = permutation[i] end
    equal(encode(Organize.plan(reversed)), expected)
  end
end)

test('identical repeated rows never duplicate a window or group', function()
  local a, b = row('A', 1, 10), row('B', 2, 10)
  local plan = Organize.plan({a, b, a, b, row('B', 2, 10)})
  equal(plan.conflicts, 1); equal(plan.groupCount, 1); equal(#plan.groups[1].windows, 1)
end)

test('contradictory PID group or location for an ID is never guessed', function()
  for _, field in ipairs({'pid', 'key', 'spaceID', 'screenUUID', 'spaceUUID'}) do
    local conflicting = row('B', 2, 10)
    conflicting[field] = type(conflicting[field]) == 'number' and 99 or 'other'
    local rows = {row('A', 1, 10), row('B', 2, 10), conflicting}
    equal(Organize.plan(rows).groupCount, 0, field)
    equal(Organize.plan({rows[3], rows[2], rows[1]}).groupCount, 0, field .. ' reverse')
  end
end)

test('inconsistent Space ID or UUID mapping does not create a synthetic conflict', function()
  local a, b = row('A', 1, 10), row('B', 2, 10)
  b.screenUUID = 'other-monitor'
  equal(Organize.plan({a, b}).conflicts, 0)
  b = row('B', 2, 20); b.spaceUUID = a.spaceUUID
  equal(Organize.plan({a, b, row('C', 3, 10)}).conflicts, 0)
end)

test('malformed rows are skipped while later valid sparse entries remain usable', function()
  local rows = {[2] = row('A', 1, 10), [8] = row('B', 2, 10), label = row('C', 3, 10), [9] = false}
  equal(keys(Organize.plan(rows)), 'B')
  for _, field in ipairs({'id', 'pid', 'spaceID'}) do
    for _, bad in ipairs({0, -1, 1.5, 0/0, math.huge, '10'}) do
      local invalid = row('C', 3, 10); invalid[field] = bad; rows[20] = invalid
      equal(keys(Organize.plan(rows)), 'B', field)
    end
  end
  for _, field in ipairs({'key', 'spaceUUID', 'screenUUID'}) do
    for _, bad in ipairs({'', '\0hidden', false, string.rep('x', 513)}) do
      local invalid = row('C', 3, 10); invalid[field] = bad; rows[20] = invalid
      equal(keys(Organize.plan(rows)), 'B', field)
    end
  end
end)

test('output is detached from input and excludes unrelated private fields', function()
  local a, b = row('A', 1, 10), row('B', 2, 10)
  b.title, b.image, b.window = 'private title', 'private image', {}
  local rows = {b, a}; local before = encode(rows)
  local plan = Organize.plan(rows)
  equal(encode(rows), before)
  local output = plan.groups[1].windows[1]
  equal(output.title, nil); equal(output.image, nil); equal(output.window, nil)
  output.id = 999; equal(b.id, 2)
  plan.groups[1].sourceSpaceUUID = 'changed'; equal(b.spaceUUID, 'space-10')
end)

print(string.format('Organize tests: %d passed, %d failed', passed, failed))
if failed > 0 then os.exit(1) end
