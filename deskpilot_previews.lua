-- Optional window thumbnails stay in memory and are never written to disk.
local M = {}
local failureBackoff, maxEntries, maxBytes, maxCacheBytes = 15, 32, 1200000, 16 * 1024 * 1024
local protectedNames = {
  'bitwarden', '1password', 'agilebits', 'keepass', 'strongbox', 'enpass',
  'dashlane', 'lastpass', 'nordpass',
}
local protectedBundles = { ['com.apple.passwords'] = true, ['com.apple.keychainaccess'] = true }

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function identity(value)
  return finite(value) and value > 0 and value % 1 == 0
end

local function protectedBundle(bundle)
  if type(bundle) ~= 'string' or not bundle:find('%S') then return true end
  if protectedBundles[bundle:lower()] then return true end
  local normalized = bundle:lower():gsub('[^%w]', '')
  if normalized == '' or normalized == 'unknown' then return true end
  for _, name in ipairs(protectedNames) do
    if normalized:find(name, 1, true) then return true end
  end
  return false
end

function M.new(api, captureProvider)
  local self = {}
  local cache, active, budget, sequence, pending = {}, false, 0, 0, {}
  local function cancelPending(id)
    local job = pending[id]; pending[id] = nil
    if job and job.cancel then pcall(job.cancel) end
  end

  function self:clear()
    cache, active, budget = {}, false, 0
    local abandoned = pending; pending = {}
    for _, job in pairs(abandoned) do if job.cancel then pcall(job.cancel) end end
  end

  function self:beginFrame(enabled, visible, captureRequested)
    local ok, permission = pcall(function() return api.screenRecordingState(false) end)
    permission = ok and permission == true
    active = enabled == true and visible == true and permission
    budget = captureRequested ~= false and 1 or 0
    if not active then self:clear() end
    return permission
  end

  local function result(entry, protected)
    return { image = entry and entry.image, at = entry and entry.at,
      unavailable = entry ~= nil and entry.image == nil, protected = protected == true }
  end

  local function store(id, entry)
    sequence = sequence + 1
    entry.sequence = sequence
    cache[id] = entry
    while true do
      local count, bytes, oldestID, oldest = 0, 0, nil, math.huge
      for otherID, other in pairs(cache) do
        count = count + 1; bytes = bytes + (other.image and #other.image or 0)
        if other.sequence < oldest then oldestID, oldest = otherID, other.sequence end
      end
      if count <= maxEntries and bytes <= maxCacheBytes then break end
      cache[oldestID] = nil
    end
  end
  function self:cachedIDs()
    local ids = {}; for id, entry in pairs(cache) do if entry.image then ids[id] = true end end
    return ids
  end

  local function prepare(id, pid, bundle, allowed, now, refresh)
    local protected = allowed ~= true or protectedBundle(bundle) or not identity(id) or not identity(pid)
    if protected then
      if identity(id) then cache[id] = nil; cancelPending(id) end
      return result(nil, true)
    end
    if not active then return result(nil, false) end
    if not finite(now) then cache[id] = nil; cancelPending(id); return result(nil, false) end
    local inflight = pending[id]
    if inflight and (inflight.pid ~= pid or inflight.bundle ~= bundle or refresh == true) then cancelPending(id) end

    local entry = cache[id]
    if entry and (entry.pid ~= pid or entry.bundle ~= bundle or now < entry.time or refresh == true) then
      cache[id], entry = nil, nil
    end
    if entry then
      -- A successful image is an explicitly dated snapshot. Repainting the UI
      -- never refreshes it; selecting refresh, hiding, or clearing discards it.
      if entry.image or now - entry.time < failureBackoff or budget <= 0 then return result(entry, false) end
      cache[id], entry = nil, nil
    end
    if budget <= 0 then return result(nil, false) end
    budget = budget - 1
    return nil, { id = id, pid = pid, bundle = bundle, time = now }
  end
  local function validImage(encoded)
    return type(encoded) == 'string' and #encoded <= maxBytes
      and encoded:match('^data:image/jpeg;base64,[%w+/=]+$') ~= nil
  end
  local function save(job, imageURL)
    local entry = { pid = job.pid, bundle = job.bundle, time = job.time }
    if validImage(imageURL) then entry.image, entry.at = imageURL, os.date('%H:%M:%S', math.floor(job.time)) end
    store(job.id, entry)
    return result(entry, false)
  end
  local function synchronous(job)
    local ok, imageURL = pcall(function()
      local snapshot = api.window.snapshotForID(job.id, false)
      if not snapshot then return nil end
      local size = snapshot:size()
      if not size or not finite(size.w) or not finite(size.h) or size.w <= 0 or size.h <= 0 then return nil end
      local scale = math.min(1, 1280 / size.w, 800 / size.h)
      if scale < 1 then
        snapshot = snapshot:size({ w = size.w * scale, h = size.h * scale }, true)
        if not snapshot then return nil end
      end
      local encoded = snapshot:encodeAsURLString(false, 'JPEG')
      if not validImage(encoded) then return nil end
      return encoded
    end)
    return save(job, ok and imageURL or nil)
  end

  function self:get(id, pid, bundle, allowed, now, refresh)
    local cached, job = prepare(id, pid, bundle, allowed, now, refresh)
    return cached or synchronous(job)
  end

  -- Optional asynchronous providers support off-Space capture without moving
  -- windows. Their cancellation function is called when the panel discards data.
  function self:capture(id, pid, bundle, allowed, now, refresh, callback)
    local cached, job = prepare(id, pid, bundle, allowed, now, refresh)
    if cached then callback(cached); return end
    if not captureProvider then callback(synchronous(job)); return end
    pending[id] = job
    local function complete(imageURL)
      if pending[id] ~= job then return end
      pending[id] = nil
      local ok, permission = pcall(function() return api.screenRecordingState(false) end)
      if not active or not ok or permission ~= true then
        self:clear(); callback(result(nil, false)); return
      end
      callback(save(job, imageURL))
    end
    local ok, cancel = pcall(captureProvider, id, pid, bundle, complete)
    if not ok then complete(nil)
    elseif pending[id] == job and type(cancel) == 'function' then job.cancel = cancel end
  end

  return self
end

return M
