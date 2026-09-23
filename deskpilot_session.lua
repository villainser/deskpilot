-- Session restoration coordinator. The adapter owns all macOS reads and writes;
-- restore and explicitly allowed app launches go through the supplied adapter.
local Layout = require('deskpilot_layout')
local M = {}

local function copy(value)
  if type(value) ~= 'table' then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end
local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end
local function text(value) return type(value) == 'string' and value ~= '' end
local function frame(value)
  return type(value) == 'table' and finite(value.x) and finite(value.y)
    and finite(value.w) and finite(value.h) and value.w > 0 and value.h > 0
end
local function sortedKeys(value)
  local keys = {}
  for key in pairs(value or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end
local function encode(value)
  if type(value) ~= 'table' then
    local raw = tostring(value)
    return type(value) .. ':' .. #raw .. ':' .. raw
  end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, key in ipairs(keys) do parts[#parts + 1] = encode(key) .. encode(value[key]) end
  return '{' .. table.concat(parts) .. '}'
end
local function slot(group)
  return group.screenUUID .. (text(group.spaceUUID) and ('|uuid:' .. group.spaceUUID)
    or ('|index:' .. tostring(group.spaceIndex)))
end
local function workspaceTarget(workspace)
  return { screenUUID = workspace.screenUUID, spaceUUID = workspace.spaceUUID,
    spaceIndex = workspace.localIndex or workspace.index }
end
local function validTarget(value)
  if type(value) ~= 'table' or not text(value.screenUUID) or not text(value.spaceUUID)
    or #value.screenUUID > 128 or #value.spaceUUID > 128 or value.screenUUID:find('[%c]')
    or value.spaceUUID:find('[%c]') or not finite(value.spaceIndex)
    or value.spaceIndex < 1 or value.spaceIndex > 128 or value.spaceIndex % 1 ~= 0 then return nil end
  return { screenUUID = value.screenUUID, spaceUUID = value.spaceUUID, spaceIndex = value.spaceIndex }
end

function M.new(ctx)
  assert(type(ctx) == 'table' and text(ctx.sessionID), 'a real session ID is required')
  local self = { phase = 'waiting', signature = nil, source = nil, pending = {}, protected = {},
    restored = 0, operation = nil, epoch = 0, dirty = false, frozen = false,
    stableSince = nil, fingerprint = nil, lastCheckpoint = -math.huge, monitorCount = 0,
    monitorSince = nil, monitorToken = nil, launching = {}, launchFailed = {}, committedAt = {} }
  local store = { version = 1, layouts = {}, runs = {} }
  local loadedOK, loaded = pcall(ctx.load)
  if loadedOK and type(loaded) == 'table' and loaded.version == 1 then
    for signature, candidate in pairs(type(loaded.layouts) == 'table' and loaded.layouts or {}) do
      if text(signature) then
        local valid = Layout.validateLayout(candidate)
        if valid and valid.signature == signature then
          store.layouts[signature] = valid
          self.committedAt[signature] = valid.savedAt
        end
      end
    end
    for signature, candidate in pairs(type(loaded.runs) == 'table' and loaded.runs or {}) do
      if store.layouts[signature] and type(candidate) == 'table' and text(candidate.sessionID) then
        local run = { sessionID = candidate.sessionID, handled = {}, targets = {}, launched = {} }
        local validSlots, validScreens = {}, {}
        for _, group in pairs(store.layouts[signature].groups) do validSlots[slot(group)] = true end
        for _, uuid in ipairs(store.layouts[signature].screens) do validScreens[uuid] = true end
        for key, handled in pairs(type(candidate.handled) == 'table' and candidate.handled or {}) do
          if store.layouts[signature].groups[key] and handled == true then run.handled[key] = true end
        end
        for key, target in pairs(type(candidate.targets) == 'table' and candidate.targets or {}) do
          local valid = validTarget(target)
          if validSlots[key] and valid and validScreens[valid.screenUUID] then run.targets[key] = valid end
        end
        for key, launched in pairs(type(candidate.launched) == 'table' and candidate.launched or {}) do
          if store.layouts[signature].groups[key] and launched == true then run.launched[key] = true end
        end
        store.runs[signature] = run
      end
    end
  end

  local function prune()
    for signature in pairs(store.runs) do
      if not store.layouts[signature] and signature ~= self.signature then store.runs[signature] = nil end
    end
    local keys = sortedKeys(store.layouts)
    table.sort(keys, function(a, b)
      if a == self.signature then return false end
      if b == self.signature then return true end
      local at, bt = store.layouts[a].savedAt or 0, store.layouts[b].savedAt or 0
      return at == bt and a < b or at < bt
    end)
    while #keys > 8 do
      local oldest = table.remove(keys, 1)
      store.layouts[oldest], store.runs[oldest] = nil, nil
      self.dirty = true
    end
  end
  local function persist()
    if not self.dirty then return true end
    prune()
    local ok, saved = pcall(ctx.save, copy(store))
    if not ok or saved ~= true then self.phase = 'storage-error'; return false end
    self.dirty = false
    self.committedAt = {}
    for signature, layout in pairs(store.layouts) do self.committedAt[signature] = layout.savedAt end
    if self.phase == 'storage-error' then self.phase = 'waiting' end
    return true
  end
  local function run()
    return self.signature and store.runs[self.signature]
  end
  local function pendingCount()
    local count = 0
    for _ in pairs(self.pending) do count = count + 1 end
    return count
  end
  local function stopOperation(reason)
    local operation = self.operation
    if operation then
      self.pending[operation.key] = nil
      if reason ~= 'manual' then self.protected[operation.key] = true end
    end
    self.operation = nil
    self.epoch = self.epoch + 1
    self.phase = reason == 'manual' and 'waiting' or (reason or 'waiting')
  end
  local function activate(signature, screens)
    if self.signature == signature then return end
    local changedTopology = self.signature ~= nil
    stopOperation('waiting')
    self.signature, self.fingerprint, self.stableSince = signature, nil, nil
    self.pending, self.protected, self.launching, self.launchFailed = {}, {}, {}, {}
    self.source = copy(store.layouts[signature])
    if ctx.adaptLayout then
      local ok, adapted = pcall(ctx.adaptLayout, copy(store.layouts), copy(screens))
      local valid = ok and Layout.validateLayout(adapted)
      if valid and valid.signature == signature then
        self.source = valid
        if encode(store.layouts[signature]) ~= encode(valid) then
          store.layouts[signature] = copy(valid)
          self.dirty = true
        end
      end
    end
    local prior = store.runs[signature]
    if changedTopology or not prior or prior.sessionID ~= ctx.sessionID then
      store.runs[signature] = { sessionID = ctx.sessionID, handled = {}, targets = {}, launched = {} }
      self.dirty = true
    end
    for key in pairs(self.source and self.source.groups or {}) do
      if not run().handled[key] then self.pending[key] = true end
    end
    self.phase = pendingCount() > 0 and 'waiting' or 'remembering'
  end
  local function readState()
    local screens = ctx.screens()
    local signature = Layout.signature(screens)
    if not signature then return nil end
    local workspaces, rows = ctx.workspaces(), ctx.rows()
    if type(workspaces) ~= 'table' or type(rows) ~= 'table' then return nil end
    local state = { signature = signature, screens = screens, workspaces = workspaces,
      rows = rows, screensByID = {}, spacesByID = {}, groups = {} }
    local parts, seen = {}, {}
    for _, screen in ipairs(screens) do
      if not text(screen.uuid) or not frame(screen.frame) or state.screensByID[screen.uuid] then return nil end
      state.screensByID[screen.uuid] = screen
      parts[#parts + 1] = encode({ screen.uuid, screen.frame })
    end
    for _, workspace in ipairs(workspaces) do
      if not workspace.spaceID or not state.screensByID[workspace.screenUUID]
        or state.spacesByID[workspace.spaceID] then return nil end
      state.spacesByID[workspace.spaceID] = workspace
      seen[workspace.screenUUID] = true
      parts[#parts + 1] = encode({ workspace.screenUUID, workspace.spaceUUID,
        workspace.spaceID, workspace.localIndex or workspace.index })
    end
    for uuid in pairs(state.screensByID) do if not seen[uuid] then return nil end end
    for _, row in ipairs(rows) do
      if not text(row.key) or not text(row.bundleID) or not row.id or not row.pid then return nil end
      if not state.groups[row.key] then state.groups[row.key] = {} end
      state.groups[row.key][#state.groups[row.key] + 1] = row
      parts[#parts + 1] = encode({ row.key, row.id, row.pid, row.spaceID, row.titleHash, row.frame })
    end
    table.sort(parts)
    state.fingerprint = table.concat(parts, '\n')
    return state
  end
  local function observe(state)
    activate(state.signature, state.screens)
    self.monitorCount = #state.screens
    local monitorToken = state.signature .. ':' .. tostring(ctx.generation())
    if self.monitorToken ~= monitorToken then
      self.monitorToken, self.monitorSince = monitorToken, ctx.now()
    end
    if self.fingerprint ~= state.fingerprint then
      self.fingerprint, self.stableSince = state.fingerprint, ctx.now()
      return false
    end
    return self.stableSince ~= nil and ctx.now() - self.stableSince >= 3
  end
  local function capture(state)
    local groups = {}
    for key, rows in pairs(state.groups) do
      local first = rows[1]
      local workspace = first and state.spacesByID[first.spaceID]
      local screen = workspace and state.screensByID[workspace.screenUUID]
      if screen then
        local valid, windows = true, {}
        for _, row in ipairs(rows) do
          if row.spaceID ~= first.spaceID or not frame(row.frame)
            or row.bundleID ~= first.bundleID or row.profileDirectory ~= first.profileDirectory then valid = false; break end
          local rect = screen.frame
          windows[#windows + 1] = { titleHash = row.titleHash,
            frame = { x = (row.frame.x - rect.x) / rect.w, y = (row.frame.y - rect.y) / rect.h,
              w = row.frame.w / rect.w, h = row.frame.h / rect.h } }
        end
        if valid then
          local group = { bundleID = first.bundleID, profileDirectory = first.profileDirectory,
            screenUUID = workspace.screenUUID, spaceUUID = workspace.spaceUUID,
            spaceIndex = workspace.localIndex or workspace.index, windows = windows }
          if Layout.merge(nil, state.screens, { [key] = group }, ctx.now()) then groups[key] = group end
        end
      end
    end
    return groups
  end
  local function checkpoint(state, force)
    if self.frozen or self.operation or (not force and ctx.now() - self.lastCheckpoint < 10) then return false end
    self.lastCheckpoint = ctx.now()
    local protected = copy(self.protected)
    for key in pairs(self.pending) do protected[key] = true end
    local previous, groups = store.layouts[state.signature], capture(state)
    for key in pairs(protected) do groups[key] = nil end
    local merged = Layout.merge(previous, state.screens, groups, ctx.now())
    if not merged then return false end
    local active = {}
    for key in pairs(state.groups) do if merged.groups[key] then active[key] = true end end
    for _, key in ipairs(self.source and self.source.activeKeys or {}) do
      if self.pending[key] and merged.groups[key] then active[key] = true end
    end
    if ctx.isGroupRunning then
      for _, key in ipairs(previous and previous.activeKeys or {}) do
        if not state.groups[key] and merged.groups[key] then
          local ok, running = pcall(ctx.isGroupRunning, merged.groups[key])
          -- Missing AX rows are not evidence of a closed application/profile.
          -- Only an explicit, reliable false can remove its launch intent.
          if self.pending[key] or not ok or running ~= false then active[key] = true end
        end
      end
    end
    if next(active) or ctx.isGroupRunning then merged.activeKeys = sortedKeys(active) end
    merged = Layout.validateLayout(merged)
    if not merged then return false end
    if previous and encode(previous.groups) == encode(merged.groups)
      and encode(previous.activeKeys) == encode(merged.activeKeys) then return persist() end
    if not next(merged.groups) then return false end
    store.layouts[state.signature] = merged
    for key in pairs(merged.groups) do
      if not self.pending[key] then run().handled[key] = true end
    end
    self.dirty = true
    return persist()
  end
  local function operationCurrent(operation)
    if self.operation ~= operation or self.frozen or operation.epoch ~= self.epoch
      or operation.generation ~= ctx.generation() then return false end
    return Layout.signature(ctx.screens()) == operation.signature
  end
  local function allowedKeys(key, state)
    local allowed = { [key] = true }
    for pending in pairs(self.pending) do
      if state.groups[pending] and not self.protected[pending] then allowed[pending] = true end
    end
    local group = self.source and self.source.groups[key]
    if group then
      for other, saved in pairs(self.source.groups) do
        if slot(saved) == slot(group) then allowed[other] = true end
      end
    end
    return allowed
  end
  local function resolveTarget(target, state)
    if not target or not text(target.spaceUUID) then return nil end
    for _, workspace in ipairs(state.workspaces) do
      if workspace.screenUUID == target.screenUUID and workspace.spaceUUID == target.spaceUUID then return workspace end
    end
  end
  local function usable(operation, workspace, state)
    if not workspace or workspace.screenUUID ~= operation.group.screenUUID then return false end
    for savedSlot, target in pairs(run().targets) do
      if savedSlot ~= operation.slot and target.screenUUID == workspace.screenUUID
        and target.spaceUUID == workspace.spaceUUID then return false end
    end
    return ctx.canUse(operation.group, workspace.spaceID, allowedKeys(operation.key, state)) == true
  end
  local function finishOperation(operation, ok)
    if self.operation ~= operation then return end
    self.pending[operation.key] = nil
    if ok then self.restored = self.restored + 1
    else self.protected[operation.key] = true end
    self.operation = nil
    self.fingerprint, self.stableSince = nil, nil
    self.phase = ok and (pendingCount() > 0 and 'waiting' or 'remembering') or 'partial'
  end
  local function progress(operation, state)
    if not operationCurrent(operation) then stopOperation('interrupted'); return false end
    if operation.inflight then return true end
    if operation.failed then finishOperation(operation, false); return false end
    if operation.created then
      local target = resolveTarget(operation.created, state)
      if not usable(operation, target, state) then finishOperation(operation, false); return false end
      run().targets[operation.slot] = workspaceTarget(target)
      self.dirty = true
      if not persist() then return true end
      operation.target, operation.created = workspaceTarget(target), nil
    end
    if not operation.target then
      local target = resolveTarget(run().targets[operation.slot], state)
      if not usable(operation, target, state) then
        local function canUse(spaceID) return usable(operation, state.spacesByID[spaceID], state) end
        target = Layout.target(operation.group, state.workspaces, canUse)
        if target and not usable(operation, target, state) then
          local fallback = copy(operation.group)
          fallback.spaceUUID = nil
          target = Layout.target(fallback, state.workspaces, canUse)
        end
      end
      if target and not usable(operation, target, state) then target = nil end
      if target then
        run().targets[operation.slot] = workspaceTarget(target)
        self.dirty = true
        if not persist() then return true end
        operation.target = workspaceTarget(target)
      else
        operation.inflight = true
        local callbackUsed = false
        local ok, result = pcall(ctx.create, operation.group.screenUUID, function(created)
          if callbackUsed then return end
          callbackUsed = true
          if not operationCurrent(operation) then return end
          operation.inflight = false
          local target = created and validTarget(workspaceTarget(created))
          if target and target.screenUUID == operation.group.screenUUID then operation.created = target
          else operation.failed = true end
        end)
        if not ok or result == false then operation.inflight = false; operation.failed = true end
        return true
      end
    end
    local target = resolveTarget(operation.target, state)
    if not usable(operation, target, state) then finishOperation(operation, false); return false end
    while operation.index <= #operation.rows do
      local expected = operation.rows[operation.index]
      local current
      for _, row in ipairs(state.groups[operation.key] or {}) do
        if row.id == expected.id and row.pid == expected.pid then current = row; break end
      end
      if not current then operation.index = operation.index + 1
      elseif current.spaceID ~= expected.spaceID or encode(current.frame) ~= encode(expected.frame) then
        self:cancelGroup(operation.key); return false
      else
        local normalized = Layout.frameFor(operation.group, operation.rows, expected)
        operation.inflight = true
        local callbackUsed = false
        local ok, result = pcall(ctx.move, current, target, normalized, function(moved)
          if callbackUsed then return end
          callbackUsed = true
          if not operationCurrent(operation) then return end
          operation.inflight = false
          if moved == true then operation.index = operation.index + 1
          else operation.failed = true end
        end)
        if not ok or result == false then operation.inflight = false; operation.failed = true end
        return true
      end
    end
    finishOperation(operation, true)
    return false
  end

  local function tryLaunch(state)
    if not ctx.launch or not ctx.canLaunch or not self.monitorSince
      or ctx.now() - self.monitorSince < 20 then return false end
    for _, key in ipairs(self.source and self.source.activeKeys or {}) do
      local group = self.source.groups[key]
      if self.pending[key] and not state.groups[key] and not run().launched[key]
        and not run().handled[key] and ctx.canLaunch(group) == true then
        run().launched[key] = true
        self.dirty = true
        if not persist() then run().launched[key] = nil; self.dirty = true; return false end
        local token = { epoch = self.epoch, signature = self.signature, generation = ctx.generation() }
        self.launching[key] = token
        local ok, result = pcall(ctx.launch, copy(group), function(launched)
          if self.launching[key] ~= token or self.frozen or token.epoch ~= self.epoch
            or token.signature ~= Layout.signature(ctx.screens()) or token.generation ~= ctx.generation() then return end
          self.launching[key] = nil
          if launched ~= true then self.launchFailed[key] = true end
        end)
        if not ok or result == false then self.launching[key] = nil; self.launchFailed[key] = true end
        self.phase = 'waiting-for-apps'
        return true
      end
    end
    return false
  end
  local function pendingOrder()
    local keys = sortedKeys(self.pending)
    table.sort(keys, function(a, b)
      local ga, gb = self.source.groups[a], self.source.groups[b]
      if ga.screenUUID ~= gb.screenUUID then return ga.screenUUID < gb.screenUUID end
      if ga.spaceIndex ~= gb.spaceIndex then return ga.spaceIndex < gb.spaceIndex end
      return a < b
    end)
    return keys
  end
  local function rowsReady(rows, state)
    if not rows or #rows == 0 then return false end
    for _, row in ipairs(rows) do
      if not state.spacesByID[row.spaceID] or not frame(row.frame) then return false end
    end
    return true
  end

  function self:tick()
    if self.frozen then return false end
    if self.operation and not operationCurrent(self.operation) then stopOperation('interrupted') end
    if ctx.blocked() then return self.operation ~= nil end
    local state = readState()
    if not state then self.phase = 'waiting-for-state'; return self.operation ~= nil end
    local stable = observe(state)
    if self.operation then
      -- Creating a Space changes the native window/overlay lists. A successful
      -- creation callback can precede fresh CG metadata; do not interpret that
      -- transitional occupancy as a permanently unusable destination.
      if self.operation.created and not stable then return true end
      return progress(self.operation, state)
    end
    if not stable then self.phase = 'settling'; return false end
    for _, key in ipairs(pendingOrder()) do
      local rows = state.groups[key]
      local group = self.source and self.source.groups[key]
      if group and rowsReady(rows, state) and state.screensByID[group.screenUUID] then
        run().handled[key] = true -- Persist permission consumption before any external operation.
        self.dirty = true
        if not persist() then return false end
        local operation = { key = key, group = copy(group), rows = copy(rows), index = 1,
          slot = slot(group), generation = ctx.generation(), epoch = self.epoch, signature = self.signature }
        self.operation, self.phase = operation, 'restoring'
        return progress(operation, state)
      end
    end
    if tryLaunch(state) then return false end
    checkpoint(state, false)
    if self.phase ~= 'storage-error' then self.phase = pendingCount() > 0 and 'waiting-for-apps' or 'remembering' end
    return false
  end
  function self:cancelGroup(key)
    if not text(key) then return end
    if self.operation and self.operation.key == key then stopOperation('manual') end
    self.pending[key], self.protected[key] = nil, nil
    if run() then run().handled[key] = true; self.dirty = true; persist() end
    self.fingerprint, self.stableSince = nil, nil
  end
  function self:freeze()
    self.frozen = true
    stopOperation('frozen')
    return persist() -- Never read disappearing shutdown windows.
  end
  function self:thaw()
    if not self.frozen then return false end
    self.frozen = false
    self.epoch = self.epoch + 1
    self.operation, self.launching = nil, {}
    self.fingerprint, self.stableSince = nil, nil
    self.monitorToken, self.monitorSince = nil, nil
    self.phase = 'waiting'
    -- A cancelled shutdown resumes the same run: consumed movement/launch
    -- permissions remain consumed, including uncertain operations at freeze.
    return true
  end
  function self:flush() return persist() end
  function self:saveNow()
    if self.frozen or self.operation or ctx.blocked() then return false end
    local state = readState()
    if not state or not observe(state) then return false end
    return checkpoint(state, true)
  end
  function self:requestRestore()
    if self.frozen then return false end
    local state = readState()
    if not state then return false end
    activate(state.signature, state.screens)
    local layout = store.layouts[state.signature]
    if not layout then return false end
    stopOperation('waiting')
    self.source, self.pending, self.protected = copy(layout), {}, {}
    store.runs[state.signature] = { sessionID = ctx.sessionID, handled = {}, targets = {},
      launched = copy(run().launched) }
    for key in pairs(layout.groups) do self.pending[key] = true end
    self.fingerprint, self.stableSince = nil, nil
    self.dirty = true
    return persist()
  end
  function self:isRestoring() return self.operation ~= nil end
  function self:claims(key)
    return self.pending[key] == true or (self.operation ~= nil and self.operation.key == key)
  end
  function self:isAutoLaunchPending(key)
    local current = run()
    return self.pending[key] == true and current ~= nil and current.launched[key] == true
      and self.launchFailed[key] ~= true
  end
  function self:status()
    local launchPending, launchFailed, restoreFailed = 0, 0, 0
    for _, key in ipairs(self.source and self.source.activeKeys or {}) do
      if self.pending[key] and not (run() and run().handled[key]) then launchPending = launchPending + 1 end
    end
    for _ in pairs(self.launchFailed) do launchFailed = launchFailed + 1 end
    for _ in pairs(self.protected) do restoreFailed = restoreFailed + 1 end
    return { sessionPhase = self.phase, sessionPending = pendingCount(), sessionRestored = self.restored,
      sessionSavedAt = self.signature and self.committedAt[self.signature] or nil, sessionMonitorCount = self.monitorCount,
      sessionLaunchPending = launchPending, sessionLaunchFailed = launchFailed, sessionRestoreFailed = restoreFailed }
  end
  prune()
  return self
end
return M
