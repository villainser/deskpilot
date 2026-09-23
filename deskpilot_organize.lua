-- Pure plan for explicitly separating applications/profiles sharing a Space.
-- The caller resolves live windows, chooses destinations and performs moves.
local M = {}

local function identity(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
    and value > 0 and value % 1 == 0
end
local function text(value, limit)
  return type(value) == 'string' and value ~= '' and #value <= limit and not value:find('[%c]')
end
local function rowCopy(row)
  if type(row) ~= 'table' or not text(row.key, 512) or not identity(row.id)
    or not identity(row.pid) or not identity(row.spaceID) or not text(row.screenUUID, 128)
    or not text(row.spaceUUID, 128) then return nil end
  return {key = row.key, id = row.id, pid = row.pid, spaceID = row.spaceID,
    screenUUID = row.screenUUID, spaceUUID = row.spaceUUID}
end
local function sameSpace(a, b)
  return a.spaceID == b.spaceID and a.spaceUUID == b.spaceUUID and a.screenUUID == b.screenUUID
end
local function spaceOrder(a, b)
  if a.screenUUID ~= b.screenUUID then return a.screenUUID < b.screenUUID end
  if a.spaceID ~= b.spaceID then return a.spaceID < b.spaceID end
  return a.spaceUUID < b.spaceUUID
end
local function sortedKeys(map)
  local keys = {}
  for key in pairs(map) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

function M.plan(rows, focusedKey)
  local result = {groups = {}, conflicts = 0, groupCount = 0}
  if type(rows) ~= 'table' then return result end
  local windows, spacesByID, spacesByUUID = {}, {}, {}
  local badWindows, badSpaceIDs, badSpaceUUIDs = {}, {}, {}
  for index, source in pairs(rows) do
    local row = identity(index) and rowCopy(source) or nil
    if row then
      local prior = windows[row.id]
      if prior and (prior.pid ~= row.pid or prior.key ~= row.key or not sameSpace(prior, row)) then
        badWindows[row.id] = true
      end
      windows[row.id] = row
      local byID, byUUID = spacesByID[row.spaceID], spacesByUUID[row.spaceUUID]
      if byID and not sameSpace(byID, row) then badSpaceIDs[row.spaceID] = true end
      if byUUID and not sameSpace(byUUID, row) then badSpaceUUIDs[row.spaceUUID] = true end
      spacesByID[row.spaceID], spacesByUUID[row.spaceUUID] = row, row
    end
  end

  local groups, spaces = {}, {}
  for id, row in pairs(windows) do
    if not badWindows[id] and not badSpaceIDs[row.spaceID] and not badSpaceUUIDs[row.spaceUUID] then
      local group = groups[row.key]
      if not group then group = {windows = {}, conflicts = {}}; groups[row.key] = group end
      group.windows[#group.windows + 1] = row
      local space = spaces[row.spaceID]
      if not space then
        space = {spaceID = row.spaceID, screenUUID = row.screenUUID, spaceUUID = row.spaceUUID, keys = {}}
        spaces[row.spaceID] = space
      end
      space.keys[row.key] = true
    end
  end

  local candidates = {}
  for _, space in pairs(spaces) do
    local keys = sortedKeys(space.keys)
    if #keys > 1 then
      result.conflicts = result.conflicts + 1
      for _, key in ipairs(keys) do
        candidates[key] = true
        groups[key].conflicts[#groups[key].conflicts + 1] = space
      end
    end
  end

  local order = sortedKeys(candidates)
  if text(focusedKey, 512) and candidates[focusedKey] then
    for index, key in ipairs(order) do
      if key == focusedKey then table.remove(order, index); break end
    end
    table.insert(order, 1, focusedKey)
  end
  -- A group stays only if it can stay on every contested Space it occupies.
  -- For A+B and B+C this keeps A and C, moving B once with all its windows.
  -- Picking an independent keeper for each Space would also move C needlessly.
  local keepers, moving = {}, {}
  for _, key in ipairs(order) do
    local canStay = true
    for _, space in ipairs(groups[key].conflicts) do
      if keepers[space.spaceID] then canStay = false; break end
    end
    if canStay then
      for _, space in ipairs(groups[key].conflicts) do keepers[space.spaceID] = key end
    else moving[key] = true end
  end

  for _, key in ipairs(sortedKeys(moving)) do
    local group = groups[key]
    table.sort(group.conflicts, spaceOrder)
    table.sort(group.windows, function(a, b) return a.id < b.id end)
    local source = group.conflicts[1]
    result.groups[#result.groups + 1] = {key = key, sourceSpaceID = source.spaceID,
      sourceScreenUUID = source.screenUUID, sourceSpaceUUID = source.spaceUUID, windows = group.windows}
  end
  result.groupCount = #result.groups
  return result
end

return M
