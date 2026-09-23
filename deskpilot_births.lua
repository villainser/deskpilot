-- WindowServer birth evidence only. AX discovery, visibility and Space changes
-- cannot establish that an existing window has just been created.
local M = {}
local Tracker = {}
Tracker.__index = Tracker
local lifetime = 60

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function identity(value)
  return finite(value) and value > 0 and value % 1 == 0
end

local function expired(birth, now)
  return not finite(now) or now < birth.time or now - birth.time >= lifetime
end

function M.new()
  return setmetatable({ initialized = false, seen = {}, pending = {} }, Tracker)
end

function Tracker:ready()
  return self.initialized
end

function Tracker:resetPending()
  self.pending = {}
end

function Tracker:observe(rows, acceptNew, now)
  -- A failed native query must neither establish a baseline nor forget it.
  if type(rows) ~= 'table' then return false end
  local mayCreate = self.initialized and acceptNew == true and finite(now)
  if not mayCreate then self:resetPending() end
  for id, birth in pairs(self.pending) do
    if expired(birth, now) then self.pending[id] = nil end
  end

  -- Consolidate first, so conflicting or duplicate rows never depend on order.
  -- Keep only identity and layer eligibility, never titles or other metadata.
  local current = {}
  for _, row in pairs(rows) do
    if type(row) == 'table' and identity(row.kCGWindowNumber) then
      local id, pid = row.kCGWindowNumber, row.kCGWindowOwnerPID
      local item = current[id]
      if not item then
        item = { owners = {}, eligible = true }
        current[id] = item
      end
      if identity(pid) then item.owners[pid] = true else item.eligible = false end
      if row.kCGWindowLayer ~= 0 then item.eligible = false end
    end
  end

  for id, item in pairs(current) do
    local owner, ownerCount = nil, 0
    for pid in pairs(item.owners) do owner, ownerCount = pid, ownerCount + 1 end
    local uniqueOwner = ownerCount == 1 and owner or nil
    local known = self.seen[id] or {}
    self.seen[id] = known
    local birth = self.pending[id]
    if birth and (not item.eligible or birth.pid ~= uniqueOwner) then
      self.pending[id] = nil
    end
    if mayCreate and item.eligible and uniqueOwner and not known[uniqueOwner] then
      self.pending[id] = { pid = uniqueOwner, time = now }
    end
    -- Retain session history even when a window disappears from later queries.
    -- Reappearance or a change from a system layer to layer zero is not birth.
    for pid in pairs(item.owners) do known[pid] = true end
  end
  self.initialized = true
  return true
end

function Tracker:take(id, pid, now)
  if not identity(id) or not identity(pid) then return false end
  local birth = self.pending[id]
  if not birth then return false end
  if expired(birth, now) then self.pending[id] = nil; return false end
  if birth.pid ~= pid then return false end
  self.pending[id] = nil
  return true
end

return M
