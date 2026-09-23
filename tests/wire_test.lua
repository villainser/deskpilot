local source = debug.getinfo(1, 'S').source:sub(2)
local directory = source:match('^(.*[/\\])') or './'
package.path = directory .. '../?.lua;' .. package.path
local Wire = require('deskpilot_wire')
local passed = 0
local function equal(actual, expected)
  assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function test(name, run)
  run(); passed = passed + 1; print('ok - ' .. name)
end
local function frame(payload)
  return 'DESKPILOT-WINDOWS/1 ' .. #payload .. '\n' .. payload .. '\n'
end
local function rejected(bytes, reason)
  local payload, actualReason = Wire.payload(bytes)
  equal(payload, nil); equal(actualReason, reason)
end

test('complete frame returns only its base64 payload', function()
  local payload, reason = Wire.payload(frame('eyJ3aW5kb3dzIjpbXX0='))
  equal(payload, 'eyJ3aW5kb3dzIjpbXX0='); equal(reason, nil)
end)
test('every truncated prefix waits without accepting incomplete output', function()
  local bytes = frame('eyJ3aW5kb3dzIjpbXX0=')
  for length = 0, #bytes - 1 do rejected(bytes:sub(1, length), 'incomplete') end
end)
test('late middle fragment precedes termination tail', function()
  local bytes = frame('eyJ3aW5kb3dzIjpbXX0=')
  local prefix, late, tail = bytes:sub(1, 25), bytes:sub(26, 35), bytes:sub(36)
  rejected(prefix .. tail, 'incomplete')
  equal(Wire.payload(prefix .. late .. tail), 'eyJ3aW5kb3dzIjpbXX0=')
end)
test('Unicode JSON crosses transport boundaries as ASCII', function()
  -- Base64 for {"name":"Michał"}; no transport chunk contains partial UTF-8.
  local payload = 'eyJuYW1lIjoiTWljaGHFgiJ9'
  for character in payload:gmatch('.') do assert(character:byte() < 128) end
  equal(Wire.payload(frame(payload)), payload)
end)
test('metadata larger than a pipe remains complete only at its declared length', function()
  local payload = string.rep('YWJj', 20000)
  local bytes = frame(payload)
  rejected(bytes:sub(1, 65536), 'incomplete')
  equal(Wire.payload(bytes), payload)
end)
test('base64 accepts zero one or two padding characters', function()
  for _, payload in ipairs({ 'YWJj', 'YWI=', 'YQ==' }) do equal(Wire.payload(frame(payload)), payload) end
end)
test('base64 rejects embedded or excessive padding', function()
  for _, payload in ipairs({ '====', 'Y===', 'Y=Q=', 'YQ==YQ==' }) do rejected(frame(payload), 'invalid') end
end)
test('base64 rejects whitespace url alphabet and non-ASCII bytes', function()
  for _, payload in ipairs({ 'YW J', 'YW\nJ', 'YW-J', 'YW_J', 'YW\0J', 'YW\255J' }) do
    rejected(frame(payload), 'invalid')
  end
end)
test('header rejects wrong protocol and malformed lengths', function()
  for _, header in ipairs({ 'DESKPILOT-WINDOWS/2 4', 'DESKPILOT-WINDOWS/1 ',
      'DESKPILOT-WINDOWS/1 -4', 'DESKPILOT-WINDOWS/1 4.0', 'DESKPILOT-WINDOWS/1 4 ',
      'DESKPILOT-WINDOWS/1 +4', 'DESKPILOT-WINDOWS/1 0', 'DESKPILOT-WINDOWS/1 3' }) do
    rejected(header .. '\nYWJj\n', 'invalid')
  end
end)
test('malformed partial headers fail without waiting for newline', function()
  for _, bytes in ipairs({ 'X', 'DESKPILOT-WINDOWS/2', 'DESKPILOT-WINDOWS/1 -',
      'DESKPILOT-WINDOWS/1 4x' }) do rejected(bytes, 'invalid') end
end)
test('frame requires exact newline and rejects trailing data', function()
  local bytes = frame('YWJj')
  rejected(bytes:sub(1, -2) .. 'x', 'invalid')
  rejected(bytes .. '\n', 'invalid')
  rejected(bytes .. frame('YWJj'), 'invalid')
end)
test('header rejects CRLF instead of silently changing the wire length', function()
  rejected('DESKPILOT-WINDOWS/1 4\r\nYWJj\n', 'invalid')
end)
test('payload length is limited before collecting the announced body', function()
  rejected('DESKPILOT-WINDOWS/1 8388612\n', 'oversized')
  rejected('DESKPILOT-WINDOWS/1 8388612', 'oversized')
end)
test('header length limit also applies before newline arrives', function()
  local header = 'DESKPILOT-WINDOWS/1 ' .. string.rep('0', 46)
  rejected(header, 'oversized'); rejected(header .. '\n', 'oversized')
end)
test('maximum payload is accepted and a larger buffer is bounded', function()
  local payload = string.rep('YWJj', 2 * 1024 * 1024)
  equal(Wire.payload(frame(payload)), payload)
  equal(Wire.maxFrameBytes, 8 * 1024 * 1024 + 65)
  rejected(string.rep('x', Wire.maxFrameBytes + 1), 'oversized')
end)
test('non-string input is rejected', function()
  for _, bytes in ipairs({ false, 1, {} }) do rejected(bytes, 'invalid') end
  rejected(nil, 'invalid')
end)

print(string.format('%d wire tests passed', passed))
