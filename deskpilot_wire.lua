-- hs.task may deliver a final streaming fragment after its termination callback.
-- A declared length, rather than elapsed time, establishes completeness.
local M = {}
local prefix = 'DESKPILOT-WINDOWS/1 '
local maxPayload = 8 * 1024 * 1024
local maxHeader = 64 -- Includes the terminating newline.
M.maxFrameBytes = maxPayload + maxHeader + 1

function M.payload(bytes)
  if type(bytes) ~= 'string' then return nil, 'invalid' end
  if #bytes > M.maxFrameBytes then return nil, 'oversized' end
  local newline = bytes:find('\n', 1, true)
  if not newline then
    if #bytes >= maxHeader then return nil, 'oversized' end
    if #bytes <= #prefix then
      if prefix:sub(1, #bytes) == bytes then return nil, 'incomplete' end
      return nil, 'invalid'
    end
    if bytes:sub(1, #prefix) ~= prefix then return nil, 'invalid' end
    local digits = bytes:sub(#prefix + 1)
    if not digits:match('^%d+$') then return nil, 'invalid' end
    if tonumber(digits) > maxPayload then return nil, 'oversized' end
    return nil, 'incomplete'
  end
  if newline > maxHeader then return nil, 'oversized' end
  local header = bytes:sub(1, newline - 1)
  if header:sub(1, #prefix) ~= prefix then return nil, 'invalid' end
  local digits = header:sub(#prefix + 1)
  if not digits:match('^%d+$') then return nil, 'invalid' end
  local length = tonumber(digits)
  if length > maxPayload then return nil, 'oversized' end
  if length == 0 or length % 4 ~= 0 then return nil, 'invalid' end
  local expected = newline + length + 1
  if #bytes < expected then return nil, 'incomplete' end
  if #bytes ~= expected or bytes:sub(-1) ~= '\n' then return nil, 'invalid' end
  local payload = bytes:sub(newline + 1, -2)
  local alphabet, padding = payload:match('^([A-Za-z0-9+/]+)(=*)$')
  if not alphabet or #padding > 2 then return nil, 'invalid' end
  return payload
end

return M
