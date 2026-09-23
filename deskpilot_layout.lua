-- Pure validation and selection for persistent desktop layouts. No Hammerspoon,
-- window handles, process IDs, file access, or screen capture belongs here.
local M = {}
local chrome = 'com.google.Chrome'
local limits = { screens = 8, groups = 128, windows = 16 }

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function integer(value, maximum)
  return finite(value) and value > 0 and value % 1 == 0 and (not maximum or value <= maximum)
end

local function text(value, maximum)
  return type(value) == 'string' and #value > 0 and #value <= maximum
    and not value:find('[%c]') and value:find('%S') ~= nil
end

local function screenID(value)
  return text(value, 128) and not value:find('[|:]')
end

local function arrayLength(value, maximum)
  if type(value) ~= 'table' then return nil end
  local count = 0
  for key in pairs(value) do
    if not integer(key, maximum) then return nil end
    count = count + 1
  end
  if count ~= #value then return nil end
  return count
end

local function screenIDs(screens)
  local count = arrayLength(screens, limits.screens)
  if not count or count == 0 then return nil end
  local ids, seen = {}, {}
  for _, screen in ipairs(screens) do
    local uuid = type(screen) == 'table' and screen.uuid
    if not screenID(uuid) or seen[uuid] then return nil end
    seen[uuid] = true; ids[#ids + 1] = uuid
  end
  table.sort(ids)
  return ids, seen
end

function M.signature(screens)
  local ids = screenIDs(screens)
  if not ids then return nil end
  return tostring(#ids) .. ':' .. table.concat(ids, '|')
end

local function frameCopy(frame)
  if type(frame) ~= 'table' then return nil end
  local x, y, w, h = frame.x, frame.y, frame.w, frame.h
  if not finite(x) or not finite(y) or not finite(w) or not finite(h)
      or x < -1 or x > 2 or y < -1 or y > 2 or w <= 0 or w > 2 or h <= 0 or h > 2 then return nil end
  return { x = x, y = y, w = w, h = h }
end

local function groupCopy(key, value, monitors)
  if not text(key, 512) or type(value) ~= 'table' then return nil end
  local bundle, directory = value.bundleID, value.profileDirectory
  if not text(bundle, 256) or not bundle:match('^[%w][%w._%-]*$') then return nil end
  if bundle == chrome then
    if not text(directory, 128) or directory:find('[/\\:]')
        or directory:lower():match('^unresolved') or key ~= chrome .. '::' .. directory then return nil end
  elseif directory ~= nil or key ~= bundle then return nil end
  if not monitors[value.screenUUID] or (value.spaceUUID ~= nil and not text(value.spaceUUID, 128))
      or not integer(value.spaceIndex, 128) then return nil end
  if not arrayLength(value.windows, limits.windows) then return nil end
  local group = { bundleID = bundle, profileDirectory = directory,
    screenUUID = value.screenUUID, spaceUUID = value.spaceUUID, spaceIndex = value.spaceIndex, windows = {} }
  for _, window in ipairs(value.windows) do
    if type(window) ~= 'table' then return nil end
    local frame = frameCopy(window.frame)
    if not frame or (window.titleHash ~= nil and not text(window.titleHash, 128)) then return nil end
    group.windows[#group.windows + 1] = { titleHash = window.titleHash, frame = frame }
  end
  return group
end

function M.validateLayout(value)
  if type(value) ~= 'table' or value.version ~= 1 or not finite(value.savedAt)
      or value.savedAt < 0 or value.savedAt > 1000000000000 then return nil end
  local count = arrayLength(value.screens, limits.screens)
  if not count or count == 0 then return nil end
  local screens = {}
  for _, uuid in ipairs(value.screens) do screens[#screens + 1] = { uuid = uuid } end
  local ids, monitors = screenIDs(screens)
  local signature = M.signature(screens)
  if not signature or value.signature ~= signature or type(value.groups) ~= 'table' then return nil end
  local result = { version = 1, signature = signature, savedAt = value.savedAt, screens = ids, groups = {}, activeKeys = {} }
  local groupCount = 0
  for key, group in pairs(value.groups) do
    groupCount = groupCount + 1
    if groupCount > limits.groups then return nil end
    local validated = groupCopy(key, group, monitors)
    if not validated then return nil end
    result.groups[key] = validated
  end
  local activeKeys = value.activeKeys
  if activeKeys == nil then activeKeys = {} end
  if not arrayLength(activeKeys, limits.groups) then return nil end
  local active = {}
  for _, key in ipairs(activeKeys) do
    if not text(key, 512) or not result.groups[key] or active[key] then return nil end
    active[key] = true; result.activeKeys[#result.activeKeys + 1] = key
  end
  table.sort(result.activeKeys)
  return result
end

function M.merge(previous, screens, groups, now)
  if groups ~= nil and type(groups) ~= 'table' then return nil end
  local ids = screenIDs(screens)
  if not ids then return nil end
  local result = M.validateLayout({ version = 1, signature = M.signature(screens),
    savedAt = now, screens = ids, groups = groups or {} })
  if not result then return nil end
  for key in pairs(result.groups) do result.activeKeys[#result.activeKeys + 1] = key end
  local old = M.validateLayout(previous)
  if old and old.signature == result.signature then
    if #result.activeKeys == 0 then result.activeKeys = old.activeKeys end
    for key, group in pairs(old.groups) do
      local current = result.groups[key]
      if not current then result.groups[key] = group
      elseif #current.windows < #group.windows then
        -- Closing windows must not replace a complete layout with a partial one.
        -- Keep the current desktop assignment while retaining all saved frames.
        current.windows = group.windows
      end
    end
  end
  return M.validateLayout(result)
end

function M.target(group, workspaces, usable)
  if type(group) ~= 'table' or not screenID(group.screenUUID) or type(workspaces) ~= 'table' then return nil end
  local sameScreen, exact = {}, nil
  for position, workspace in ipairs(workspaces) do
    if type(workspace) == 'table' and workspace.screenUUID == group.screenUUID
        and integer(workspace.spaceID) then
      if text(group.spaceUUID, 128) and workspace.spaceUUID == group.spaceUUID then
        if exact then return nil end -- A contradictory identity is not a safe destination.
        exact = workspace
      end
      if integer(workspace.localIndex, 128) then
        sameScreen[#sameScreen + 1] = { workspace = workspace, position = position }
      end
    end
  end
  if exact then return exact end
  table.sort(sameScreen, function(a, b)
    if a.workspace.localIndex == b.workspace.localIndex then return a.position < b.position end
    return a.workspace.localIndex < b.workspace.localIndex
  end)
  local function available(workspace)
    if type(usable) ~= 'function' then return false end
    local ok, value = pcall(usable, workspace.spaceID)
    return ok and value == true
  end
  local first
  for _, item in ipairs(sameScreen) do
    local workspace = item.workspace
    if available(workspace) then
      if workspace.localIndex == group.spaceIndex then return workspace end
      first = first or workspace
    end
  end
  return first
end

function M.frameFor(group, windows, row)
  if type(group) ~= 'table' or type(row) ~= 'table' then return nil end
  local savedCount, currentCount = arrayLength(group.windows, limits.windows), arrayLength(windows, limits.windows)
  if not savedCount or not currentCount or savedCount == 0 or currentCount == 0 then return nil end
  local member = false
  for _, window in ipairs(windows) do
    if type(window) ~= 'table' then return nil end
    if window == row then member = true end
  end
  if not member then return nil end
  if savedCount == 1 and currentCount == 1 then
    local saved = group.windows[1]
    return type(saved) == 'table' and frameCopy(saved.frame) or nil
  end
  if not text(row.titleHash, 128) then return nil end
  local currentMatches, savedMatches, match = 0, 0, nil
  for _, window in ipairs(windows) do
    if window.titleHash == row.titleHash then currentMatches = currentMatches + 1 end
  end
  for _, window in ipairs(group.windows) do
    if type(window) ~= 'table' then return nil end
    if window.titleHash == row.titleHash then savedMatches, match = savedMatches + 1, window end
  end
  if currentMatches == 1 and savedMatches == 1 then return frameCopy(match.frame) end
  return nil
end

return M
