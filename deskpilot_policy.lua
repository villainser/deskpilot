-- Pure decisions for DeskPilot. The caller supplies user Spaces only and is
-- responsible for collecting fresh state before carrying out these decisions.
local P = {}

local function hasUUID(value)
  return type(value) == "string" and value ~= ""
end

local function validWorkspace(workspace)
  return type(workspace) == "table"
    and workspace.spaceID ~= nil
    and hasUUID(workspace.screenUUID)
end

-- Space numbers are display labels, never identities. A stored UUID must not
-- fall back to a recycled numeric ID, even when that ID is on the same screen.
function P.resolve(rule, workspaces)
  if type(rule) ~= "table" or not hasUUID(rule.screenUUID) then return nil end
  local useUUID = hasUUID(rule.spaceUUID)
  if not useUUID and rule.spaceID == nil then return nil end

  for _, workspace in ipairs(workspaces or {}) do
    if validWorkspace(workspace) and workspace.screenUUID == rule.screenUUID then
      if useUUID then
        if workspace.spaceUUID == rule.spaceUUID then return workspace end
      elseif workspace.spaceID == rule.spaceID then
        return workspace
      end
    end
  end
  return nil
end

local function localOrder(entry)
  local workspace = entry.workspace
  return tonumber(workspace.localIndex) or tonumber(workspace.index) or entry.position
end

local function sortLocally(entries)
  table.sort(entries, function(left, right)
    local leftOrder, rightOrder = localOrder(left), localOrder(right)
    if leftOrder == rightOrder then return left.position < right.position end
    return leftOrder < rightOrder
  end)
end

-- nil occupancy means the query failed or has not completed. Only an explicit
-- false can make a Space available for a new application.
function P.firstFree(workspaces, screenUUID, occupied, reserved)
  if not hasUUID(screenUUID) then return nil end
  occupied, reserved = occupied or {}, reserved or {}
  local available = {}
  for position, workspace in ipairs(workspaces or {}) do
    if validWorkspace(workspace) and workspace.screenUUID == screenUUID
      and occupied[workspace.spaceID] == false and not reserved[workspace.spaceID] then
      available[#available + 1] = { workspace = workspace, position = position }
    end
  end
  sortLocally(available)
  return available[1] and available[1].workspace or nil
end

-- Remove empty Spaces from the end of each display's list, while preserving
-- at least one user Space per display (also when its active Space is fullscreen
-- and therefore is absent from this list). This function never moves windows.
function P.cleanupCandidates(workspaces, occupied, reserved, active, emptySince, now, grace)
  if type(now) ~= "number" or type(grace) ~= "number" or grace < 0 then return {} end
  occupied, reserved = occupied or {}, reserved or {}
  active, emptySince = active or {}, emptySince or {}
  local screens, byScreen = {}, {}
  for position, workspace in ipairs(workspaces or {}) do
    if validWorkspace(workspace) then
      local screen = byScreen[workspace.screenUUID]
      if not screen then
        screen = {}
        byScreen[workspace.screenUUID] = screen
        screens[#screens + 1] = screen
      end
      screen[#screen + 1] = { workspace = workspace, position = position }
    end
  end

  local candidates = {}
  for _, screen in ipairs(screens) do
    sortLocally(screen)
    local remaining = #screen
    for index = #screen, 1, -1 do
      local workspace = screen[index].workspace
      local id = workspace.spaceID
      local since = emptySince[id]
      if remaining > 1 and occupied[id] == false and not reserved[id] and not active[id]
        and type(since) == "number" and now - since >= grace then
        candidates[#candidates + 1] = workspace
        remaining = remaining - 1
      end
    end
  end
  return candidates
end

return P
