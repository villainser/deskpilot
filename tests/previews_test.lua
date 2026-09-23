local source = debug.getinfo(1, 'S').source:sub(2)
local directory = source:match('^(.*[/\\])') or './'
package.path = directory .. '../?.lua;' .. package.path
local Previews = require('deskpilot_previews')
local passed = 0

local function equal(actual, expected, message)
  assert(actual == expected, (message or 'unexpected value') .. ': expected '
    .. tostring(expected) .. ', got ' .. tostring(actual))
end

local function test(name, run)
  run(); passed = passed + 1; print('ok - ' .. name)
end

local jpeg = 'data:image/jpeg;base64,YWJjZA=='
local bundle = 'com.example.Editor'
local function fixture()
  local e = { permission = true, permissionCalls = {}, captures = {}, resizes = {},
    size = { w = 2560, h = 1600 }, encoded = jpeg }
  local image = {}
  function image:size(size, absolute)
    if e.sizeError then error('size unavailable') end
    if not size then return e.size end
    e.resizes[#e.resizes + 1] = { w = size.w, h = size.h, absolute = absolute }
    if e.resizeFailure then return nil end
    return self
  end
  function image:encodeAsURLString(scale, format)
    equal(scale, false); equal(format, 'JPEG')
    if e.encodeError then error('encode unavailable') end
    return e.encoded
  end
  local api = {
    screenRecordingState = function(prompt)
      e.permissionCalls[#e.permissionCalls + 1] = { prompt = prompt }
      if e.permissionError then error('permission unavailable') end
      return e.permission
    end,
    window = { snapshotForID = function(id, keepTransparency)
      equal(keepTransparency, false)
      e.captures[#e.captures + 1] = id
      if e.captureError then error('snapshot unavailable') end
      if e.hidden then return nil end
      return image
    end },
  }
  e.api = api
  e.previews = Previews.new(api)
  return e
end

test('capture requires a visible enabled frame with permission and never prompts', function()
  local e = fixture()
  equal(e.previews:get(1, 100, bundle, true, 100).image, nil)
  e.previews:beginFrame(false, true)
  e.previews:get(1, 100, bundle, true, 100)
  e.previews:beginFrame(true, false)
  e.previews:get(1, 100, bundle, true, 100)
  e.permission = false
  equal(e.previews:beginFrame(true, true), false)
  e.previews:get(1, 100, bundle, true, 100)
  equal(#e.captures, 0)
  for _, call in ipairs(e.permissionCalls) do equal(call.prompt, false) end
end)

test('permission errors fail closed', function()
  local e = fixture(); e.permissionError = true
  equal(e.previews:beginFrame(true, true), false)
  equal(e.previews:get(1, 100, bundle, true, 100).image, nil)
  equal(#e.captures, 0)
end)

test('one capture per frame and cached reads do not consume the budget', function()
  local e = fixture(); e.previews:beginFrame(true, true)
  equal(e.previews:get(1, 100, bundle, true, 100).image, jpeg)
  equal(e.previews:get(1, 100, bundle, true, 101).image, jpeg)
  equal(e.previews:get(2, 100, bundle, true, 101).image, nil)
  equal(#e.captures, 1)
  e.previews:beginFrame(true, true)
  equal(e.previews:get(1, 100, bundle, true, 101).image, jpeg)
  equal(e.previews:get(2, 100, bundle, true, 101).image, jpeg)
  equal(e.previews:get(3, 100, bundle, true, 101).image, nil)
  equal(#e.captures, 2)
end)

test('frames without a capture request never create missing images', function()
  local e = fixture(); e.previews:beginFrame(true, true, false)
  equal(e.previews:get(1, 100, bundle, true, 100).image, nil)
  equal(e.previews:get(2, 100, bundle, true, 100).image, nil)
  equal(#e.captures, 0)
  e.previews:beginFrame(true, true, true)
  equal(e.previews:get(1, 100, bundle, true, 101).image, jpeg)
  e.previews:beginFrame(true, true, false)
  equal(e.previews:get(1, 100, bundle, true, 600).image, jpeg)
  equal(e.previews:get(2, 100, bundle, true, 600).image, nil)
  equal(#e.captures, 1)
end)

test('explicit refresh replaces a cached image and updates its capture time', function()
  local e = fixture(); e.previews:beginFrame(true, true, true)
  local first = e.previews:get(1, 100, bundle, true, 100)
  e.encoded = 'data:image/jpeg;base64,ZWZnaA=='
  e.previews:beginFrame(true, true, true)
  equal(e.previews:get(1, 100, bundle, true, 101).image, jpeg)
  local fresh = e.previews:get(1, 100, bundle, true, 101, true)
  equal(fresh.image, e.encoded); equal(fresh.at, os.date('%H:%M:%S', 101))
  assert(fresh.at ~= first.at)
  equal(#e.captures, 2)
end)

test('explicit refresh bypasses failure backoff but still consumes the single capture budget', function()
  local e = fixture(); e.hidden = true; e.previews:beginFrame(true, true, true)
  equal(e.previews:get(1, 100, bundle, true, 100).image, nil)
  e.hidden = false; e.previews:beginFrame(true, true, true)
  equal(e.previews:get(1, 100, bundle, true, 101).image, nil)
  equal(e.previews:get(1, 100, bundle, true, 101, true).image, jpeg)
  equal(e.previews:get(2, 100, bundle, true, 101, true).image, nil)
  equal(#e.captures, 2)
end)

test('explicit refresh cannot capture without a requested active frame', function()
  local e = fixture(); e.previews:beginFrame(true, true)
  equal(e.previews:get(1, 100, bundle, true, 100).image, jpeg)
  e.previews:beginFrame(true, true, false)
  equal(e.previews:get(1, 100, bundle, true, 101, true).image, nil)
  equal(e.previews:get(1, 100, bundle, true, 101).image, nil)
  equal(#e.captures, 1)
  e.permission = false; e.previews:beginFrame(true, true, true)
  equal(e.previews:get(1, 100, bundle, true, 102, true).image, nil)
  e.permission = true; e.previews:beginFrame(true, false, true)
  equal(e.previews:get(1, 100, bundle, true, 102, true).image, nil)
  e.previews:beginFrame(true, true, true); e.previews:clear()
  equal(e.previews:get(1, 100, bundle, true, 102, true).image, nil)
  equal(#e.captures, 1)
end)

test('password managers and unknown or disallowed windows are never captured', function()
  local e = fixture(); e.previews:beginFrame(true, true)
  for _, name in ipairs({ 'COM.BITWARDEN.DESKTOP', 'com.1-Password.8', 'com.agilebits.onepassword',
      'org.KeePassXC.keepassxc', 'com.strongbox.mac', 'io.enpass.app', 'com.dashlane.mac',
      'com.lastpass.LastPass', 'com.nord-pass.macos', 'com.apple.Passwords',
      'COM.APPLE.KEYCHAINACCESS', '', 'unknown' }) do
    equal(e.previews:get(1, 100, name, true, 100).protected, true)
  end
  equal(e.previews:get(1, 100, nil, true, 100).protected, true)
  equal(e.previews:get(1, 100, bundle, false, 100).protected, true)
  equal(#e.captures, 0)
end)

test('protecting a previously cached window purges its image', function()
  local e = fixture(); e.previews:beginFrame(true, true)
  equal(e.previews:get(1, 100, bundle, true, 100).image, jpeg)
  local protected = e.previews:get(1, 100, bundle, false, 101)
  equal(protected.protected, true); equal(protected.image, nil)
  e.hidden = true
  e.previews:beginFrame(true, true)
  equal(e.previews:get(1, 100, bundle, true, 102).image, nil)
  equal(#e.captures, 2)
end)

test('cache binds window ID to PID and bundle', function()
  local e = fixture(); e.previews:beginFrame(true, true)
  e.previews:get(1, 100, bundle, true, 100)
  e.encoded = 'data:image/jpeg;base64,ZWZnaA=='
  e.previews:beginFrame(true, true)
  equal(e.previews:get(1, 101, bundle, true, 101).image, e.encoded)
  e.previews:beginFrame(true, true); e.hidden = true
  equal(e.previews:get(1, 101, 'com.example.Other', true, 102).image, nil)
  equal(#e.captures, 3)
end)

test('successful cache keeps its original image and timestamp after several minutes', function()
  local e = fixture(); e.previews:beginFrame(true, true)
  local first = e.previews:get(1, 100, bundle, true, 100.9)
  equal(first.at, os.date('%H:%M:%S', 100))
  equal(first.protected, false)
  equal(e.previews:get(1, 100, bundle, true, 108.8).at, first.at)
  equal(#e.captures, 1)
  e.hidden = true; e.previews:beginFrame(true, true, false)
  equal(e.previews:get(1, 100, bundle, true, 1000).image, jpeg)
  equal(e.previews:get(1, 100, bundle, true, 1000).at, first.at)
  equal(#e.captures, 1)
end)

test('failed capture backs off for fifteen seconds and retries after that', function()
  local e = fixture(); e.previews:beginFrame(true, true); e.hidden = true
  equal(e.previews:get(1, 100, bundle, true, 100).image, nil)
  e.hidden = false
  equal(e.previews:get(1, 100, bundle, true, 114.9).image, nil)
  equal(#e.captures, 1)
  e.previews:beginFrame(true, true)
  equal(e.previews:get(1, 100, bundle, true, 115).image, jpeg)
  equal(#e.captures, 2)
end)

test('large snapshots scale within 1280 by 800 with their aspect ratio', function()
  for _, size in ipairs({ { w = 2560, h = 1440 }, { w = 900, h = 1800 } }) do
    local e = fixture(); e.size = size; e.previews:beginFrame(true, true)
    equal(e.previews:get(1, 100, bundle, true, 100).image, jpeg)
    local resized = e.resizes[1]
    assert(resized.w <= 1280 and resized.h <= 800)
    assert(math.abs(resized.w / resized.h - size.w / size.h) < 0.000001)
    equal(resized.absolute, true)
  end
end)

test('small snapshots are not enlarged', function()
  local e = fixture(); e.size = { w = 320, h = 200 }; e.previews:beginFrame(true, true)
  equal(e.previews:get(1, 100, bundle, true, 100).image, jpeg)
  equal(#e.resizes, 0)
end)

test('missing, invalid, or failed image operations return no thumbnail', function()
  for _, field in ipairs({ 'captureError', 'sizeError', 'resizeFailure', 'encodeError', 'hidden' }) do
    local e = fixture(); e[field] = true; e.previews:beginFrame(true, true)
    equal(e.previews:get(1, 100, bundle, true, 100).image, nil)
    equal(e.previews:get(1, 100, bundle, true, 101).image, nil)
    equal(#e.captures, 1)
  end
  for _, size in ipairs({ { w = 0, h = 400 }, { w = 640, h = -1 }, { w = math.huge, h = 10 }, {} }) do
    local e = fixture(); e.size = size; e.previews:beginFrame(true, true)
    equal(e.previews:get(1, 100, bundle, true, 100).image, nil)
  end
end)

test('oversized or non-JPEG data URLs are rejected', function()
  for _, encoded in ipairs({ 'data:image/png;base64,YWJjZA==', 'https://example.org/image.jpg',
      'data:image/jpeg;base64,', 'data:image/jpeg;base64,YWJjZA==\n',
      'data:image/jpeg;base64,' .. string.rep('A', 1200000) }) do
    local e = fixture(); e.encoded = encoded; e.previews:beginFrame(true, true)
    equal(e.previews:get(1, 100, bundle, true, 100).image, nil)
  end
end)

test('larger on-demand images are accepted within the new encoded-size limit', function()
  local e = fixture()
  e.encoded = 'data:image/jpeg;base64,' .. string.rep('A', 800000)
  e.previews:beginFrame(true, true, true)
  equal(e.previews:get(1, 100, bundle, true, 100).image, e.encoded)
end)

test('clear, disabling, hiding, and permission loss each discard stored thumbnails', function()
  for _, action in ipairs({ 'clear', 'disable', 'hide', 'permission' }) do
    local e = fixture(); e.previews:beginFrame(true, true)
    equal(e.previews:get(1, 100, bundle, true, 100).image, jpeg)
    if action == 'clear' then e.previews:clear()
    elseif action == 'disable' then e.previews:beginFrame(false, true)
    elseif action == 'hide' then e.previews:beginFrame(true, false)
    else e.permission = false; e.previews:beginFrame(true, true) end
    e.permission, e.hidden = true, true
    e.previews:beginFrame(true, true)
    equal(e.previews:get(1, 100, bundle, true, 101).image, nil)
    equal(#e.captures, 2)
  end
end)

test('bounded cache retains up to thirty two gallery pictures', function()
  local e = fixture()
  for id = 1, 33 do
    e.previews:beginFrame(true, true)
    equal(e.previews:get(id, 100, bundle, true, 100).image, jpeg)
  end
  e.previews:beginFrame(true, true); e.hidden = true
  equal(e.previews:get(2, 100, bundle, true, 101).image, jpeg)
  equal(#e.captures, 33)
  equal(e.previews:get(1, 100, bundle, true, 101).image, nil)
  equal(#e.captures, 34)
end)

test('caller changes to returned results cannot change the cache', function()
  local e = fixture(); e.previews:beginFrame(true, true)
  local result = e.previews:get(1, 100, bundle, true, 100)
  result.image, result.at = 'changed', 'changed'
  equal(e.previews:get(1, 100, bundle, true, 101).image, jpeg)
end)

test('clear prevents further capture until another visible enabled frame begins', function()
  local e = fixture(); e.previews:beginFrame(true, true)
  equal(e.previews:get(1, 100, bundle, true, 100).image, jpeg)
  e.previews:clear()
  equal(e.previews:get(1, 100, bundle, true, 101).image, nil)
  equal(e.previews:get(2, 100, bundle, true, 101).image, nil)
  equal(#e.captures, 1)
  e.previews:beginFrame(true, true)
  equal(e.previews:get(1, 100, bundle, true, 101).image, jpeg)
  equal(#e.captures, 2)
end)

test('invalid identities and timestamps cannot capture or revive cached images', function()
  local e = fixture(); e.previews:beginFrame(true, true)
  for _, id in ipairs({ 0, -1, 1.5, math.huge, 0 / 0, '1' }) do
    equal(e.previews:get(id, 100, bundle, true, 100).protected, true)
  end
  equal(e.previews:get(nil, 100, bundle, true, 100).protected, true)
  equal(e.previews:get(1, nil, bundle, true, 100).protected, true)
  equal(#e.captures, 0)
  equal(e.previews:get(1, 100, bundle, true, 100).image, jpeg)
  equal(e.previews:get(1, 100, bundle, true, 0 / 0).image, nil)
  e.hidden = true
  e.previews:beginFrame(true, true)
  equal(e.previews:get(1, 100, bundle, true, 101).image, nil)
  equal(#e.captures, 2)
end)

test('failed captures remain visibly unavailable until an actual retry', function()
  local e = fixture(); e.hidden = true; e.previews:beginFrame(true, true)
  equal(e.previews:get(1, 100, bundle, true, 100).unavailable, true)
  e.previews:beginFrame(true, true, false)
  equal(e.previews:get(1, 100, bundle, true, 1000).unavailable, true)
  equal(#e.captures, 1)
end)

test('asynchronous providers cache a completed image without synchronous capture', function()
  local e = fixture(); local complete, calls, result
  e.previews = Previews.new(e.api, function(id, pid, app, callback)
    equal(id, 1); equal(pid, 100); equal(app, bundle); complete = callback; calls = (calls or 0) + 1
  end)
  e.previews:beginFrame(true, true)
  e.previews:capture(1, 100, bundle, true, 100, false, function(value) result = value end)
  equal(result, nil); equal(calls, 1); equal(#e.captures, 0)
  complete(jpeg); equal(result.image, jpeg)
  e.previews:beginFrame(true, true, false)
  equal(e.previews:get(1, 100, bundle, true, 1000).image, jpeg)
end)

test('clearing or protecting pending asynchronous images cancels and discards late results', function()
  for _, action in ipairs({ 'clear', 'protect', 'identity' }) do
    local e = fixture(); local complete, canceled, calls = nil, 0, 0
    e.previews = Previews.new(e.api, function(_, _, _, callback)
      complete = callback; return function() canceled = canceled + 1 end
    end)
    e.previews:beginFrame(true, true)
    e.previews:capture(1, 100, bundle, true, 100, false, function() calls = calls + 1 end)
    if action == 'clear' then e.previews:clear()
    elseif action == 'protect' then e.previews:get(1, 100, bundle, false, 101)
    else e.previews:beginFrame(true, true, false); e.previews:get(1, 101, bundle, true, 101) end
    complete(jpeg); equal(canceled, 1); equal(calls, 0)
    e.previews:beginFrame(true, true, false)
    equal(e.previews:get(1, 100, bundle, true, 102).image, nil)
  end
end)

test('asynchronous permission loss and invalid provider output cannot enter the image cache', function()
  for _, action in ipairs({ 'permission', 'invalid', 'error' }) do
    local e = fixture(); local complete, result
    e.previews = Previews.new(e.api, function(_, _, _, callback)
      if action == 'error' then error('provider unavailable') end
      complete = callback
    end)
    e.previews:beginFrame(true, true)
    e.previews:capture(1, 100, bundle, true, 100, false, function(value) result = value end)
    if action ~= 'error' then
      if action == 'permission' then e.permission = false end
      complete(action == 'invalid' and 'https://invalid/image' or jpeg)
    end
    equal(result.image, nil)
    e.previews:beginFrame(true, true, false)
    equal(e.previews:get(1, 100, bundle, true, 101).image, nil)
    equal(#e.captures, 0)
  end
end)

test('the total encoded cache also stays below sixteen MiB', function()
  local e = fixture(); e.encoded = 'data:image/jpeg;base64,' .. string.rep('A', 800000)
  for id=1,21 do
    e.previews:beginFrame(true, true); e.previews:get(id, 100, bundle, true, 100)
  end
  e.previews:beginFrame(true, true, false)
  equal(e.previews:get(1, 100, bundle, true, 101).image, nil)
  equal(e.previews:get(2, 100, bundle, true, 101).image, e.encoded)
  equal(e.previews:cachedIDs()[1], nil); equal(e.previews:cachedIDs()[2], true)
end)

print(string.format('%d preview tests passed', passed))
