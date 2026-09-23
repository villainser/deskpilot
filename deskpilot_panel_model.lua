-- Geometry and identity for previews. No screenshots, page titles or movement.
local M = {}
local function finite(n) return type(n) == 'number' and n == n and math.abs(n) < math.huge end
function M.project(frame, screen)
  if type(frame) ~= 'table' or type(screen) ~= 'table' then return nil end
  for _, key in ipairs({ 'x', 'y', 'w', 'h' }) do
    if not finite(frame[key]) or not finite(screen[key]) then return nil end
  end
  if frame.w <= 0 or frame.h <= 0 or screen.w <= 0 or screen.h <= 0 then return nil end
  local left, top = math.max(frame.x, screen.x), math.max(frame.y, screen.y)
  local right, bottom = math.min(frame.x + frame.w, screen.x + screen.w), math.min(frame.y + frame.h, screen.y + screen.h)
  if right <= left or bottom <= top then return nil end
  return { x = (left - screen.x) / screen.w, y = (top - screen.y) / screen.h,
    w = (right - left) / screen.w, h = (bottom - top) / screen.h }
end
function M.resolve(id, workspaces)
  if type(id) ~= 'string' then return nil end
  for _, workspace in ipairs(workspaces) do
    if workspace.id == id and workspace.spaceID and workspace.screenUUID then return workspace end
  end
end
function M.build(workspaces, descriptions, spaceWindows, active)
  local monitors, byMonitor = {}, {}
  for _, ws in ipairs(workspaces) do
    local monitor = byMonitor[ws.screenUUID]
    if not monitor then
      monitor = { id = ws.screenUUID, name = ws.screenName or 'Monitor', spaces = {} }
      byMonitor[ws.screenUUID] = monitor; monitors[#monitors + 1] = monitor
    end
    local item = { id = ws.id, number = ws.index, localIndex = ws.localIndex,
      name = ws.name, key = ws.key, active = active[ws.screenUUID] == ws.spaceID,
      windows = {}, windowCount = 0, unknownCount = 0,
      unavailable = spaceWindows[ws.spaceID] == nil }
    local seen = {}
    for _, id in ipairs(spaceWindows[ws.spaceID] or {}) do
      local description = descriptions[id]
      if not seen[id] and description ~= false then
        seen[id] = true; item.windowCount = item.windowCount + 1
        local projection = description and M.project(description.frame, ws.screenFrame)
        if projection then
          projection.id, projection.label, projection.icon = id, description.label, description.icon
          projection.minimized = description.minimized
          item.windows[#item.windows + 1] = projection
        else item.unknownCount = item.unknownCount + 1 end
      end
    end
    -- The WindowServer ID list is front-to-back; drawing later windows on top
    -- needs the opposite order. Keep the real relative stack, no random offsets.
    local reversed = {}
    for i = #item.windows, 1, -1 do reversed[#reversed + 1] = item.windows[i] end
    item.windows = reversed
    monitor.spaces[#monitor.spaces + 1] = item
  end
  return monitors
end
return M
