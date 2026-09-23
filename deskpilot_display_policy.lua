-- Pure role-based adaptation of a saved layout to the displays present now.
local Layout = require('deskpilot_layout')
local M = {}
local builtinApps = {
  'com.microsoft.teams', 'com.microsoft.teams2', 'com.apple.mobilesms',
  'com.facebook.archon', 'com.facebook.messenger', 'com.bitwarden.desktop', 'com.8bit.bitwarden',
  'com.apple.systempreferences', 'com.apple.systemsettings', 'com.apple.terminal',
  'com.googlecode.iterm2', 'com.googlecode.iterm', 'dev.warp.warp', 'dev.warp.warp-stable',
  'com.github.wez.wezterm', 'net.kovidgoyal.kitty', 'org.alacritty', 'com.mitchellh.ghostty',
  'co.zeit.hyper', 'org.tabby', 'com.raphaelamorim.rio',
}
local browsers = {
  'com.google.chrome', 'com.microsoft.edgemac', 'com.brave.browser', 'org.mozilla.firefox',
  'org.mozilla.nightly', 'org.mozilla.firefoxdeveloperedition', 'com.apple.safari',
  'com.apple.safaritechnologypreview', 'company.thebrowser.browser', 'com.vivaldi.vivaldi',
  'com.operasoftware.opera', 'com.operasoftware.operagx',
}

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function member(bundle, names)
  for _, name in ipairs(names) do
    if bundle == name or bundle:sub(1, #name + 1) == name .. '.' then return true end
  end
  return false
end

local function role(group)
  local bundle = type(group.bundleID) == 'string' and group.bundleID:lower() or ''
  if member(bundle, builtinApps) then return 'builtin' end
  if member(bundle, browsers) then return 'browser' end
  return 'other'
end

local function displays(screens)
  if not Layout.signature(screens) then return nil end
  local list, byID, external, builtIn = {}, {}, {}, nil
  for _, screen in ipairs(screens) do
    if screen.builtIn ~= nil and type(screen.builtIn) ~= 'boolean' then return nil end
    local area = 1
    if screen.frame ~= nil then
      local frame = screen.frame
      if type(frame) ~= 'table' or not finite(frame.w) or not finite(frame.h)
          or frame.w <= 0 or frame.h <= 0 or frame.w > 1000000 or frame.h > 1000000 then return nil end
      for _, field in ipairs({ 'x', 'y' }) do
        if frame[field] ~= nil and (not finite(frame[field]) or math.abs(frame[field]) > 10000000) then return nil end
      end
      area = frame.w * frame.h
    end
    local item = { uuid = screen.uuid, builtIn = screen.builtIn == true, area = area }
    list[#list + 1], byID[item.uuid] = item, item
    if item.builtIn then builtIn = builtIn or item else external[#external + 1] = item end
  end
  return { list = list, byID = byID, external = external, builtIn = builtIn }
end

local function fixedTarget(group, screens)
  local category, saved = role(group), screens.byID[group.screenUUID]
  if category == 'builtin' and screens.builtIn then return screens.builtIn.uuid end
  if category == 'browser' then
    if #screens.external > 0 then
      if saved and not saved.builtIn then return saved.uuid end
      return nil, true
    end
    return (screens.builtIn or screens.list[1]).uuid
  end
  return (saved or screens.builtIn or screens.list[1]).uuid
end

local function balancedScreen(external, loads)
  local best, score
  for _, screen in ipairs(external) do
    local load = type(loads) == 'table' and loads[screen.uuid] or 0
    if not finite(load) or load < 0 then load = 0 end
    local candidate = (load + 1) / screen.area
    if not score or candidate < score then best, score = screen.uuid, candidate end
  end
  return best
end

function M.preferredScreen(group, screens, loads)
  if type(group) ~= 'table' then return nil end
  local current = displays(screens)
  if not current then return nil end
  local fixed, balance = fixedTarget(group, current)
  return balance and balancedScreen(current.external, loads) or fixed
end

local function sourceLayout(layouts, signature)
  if type(layouts) ~= 'table' then return nil end
  local newest
  for _, value in pairs(layouts) do
    local saved = Layout.validateLayout(value)
    if saved then
      local exact, newestExact = saved.signature == signature, newest and newest.signature == signature
      if not newest or saved.savedAt > newest.savedAt
          or (saved.savedAt == newest.savedAt and (exact and not newestExact
            or exact == newestExact and saved.signature < newest.signature)) then newest = saved end
    end
  end
  return newest
end

function M.adapt(layouts, screens, now)
  local current = displays(screens)
  if not current then return nil end
  local signature = Layout.signature(screens)
  local source = sourceLayout(layouts, signature)
  if not source then return nil end
  local rank, records, loads = {}, {}, {}
  for index, uuid in ipairs(source.screens) do rank[uuid] = index end
  for _, screen in ipairs(current.list) do loads[screen.uuid] = 0 end
  for key, group in pairs(source.groups) do records[#records + 1] = { key = key, group = group } end
  table.sort(records, function(a, b)
    local first, second = rank[a.group.screenUUID], rank[b.group.screenUUID]
    if first ~= second then return first < second end
    if a.group.spaceIndex ~= b.group.spaceIndex then return a.group.spaceIndex < b.group.spaceIndex end
    return a.key < b.key
  end)
  -- Existing permitted assignments contribute to load before allocating groups
  -- whose previous display is absent or disallowed by their application role.
  for _, record in ipairs(records) do
    record.target, record.balance = fixedTarget(record.group, current)
    if record.target then loads[record.target] = loads[record.target] + 1 end
  end
  for _, record in ipairs(records) do
    if record.balance then
      record.target = balancedScreen(current.external, loads)
      loads[record.target] = loads[record.target] + 1
    end
  end
  local used = {}
  for _, record in ipairs(records) do
    if record.target == record.group.screenUUID then
      used[record.target] = used[record.target] or {}
      used[record.target][record.group.spaceIndex] = true
    end
  end
  for _, record in ipairs(records) do
    local group = record.group
    if record.target ~= group.screenUUID then
      local indices = used[record.target] or {}; used[record.target] = indices
      local index = 1; while indices[index] do index = index + 1 end
      indices[index] = true
      group.screenUUID, group.spaceUUID, group.spaceIndex = record.target, nil, index
    end
  end
  source.signature, source.savedAt, source.screens = signature, now, {}
  for _, screen in ipairs(current.list) do source.screens[#source.screens + 1] = screen.uuid end
  return Layout.validateLayout(source)
end

return M
