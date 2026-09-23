-- Chrome profile identity for Hammerspoon. Never use a page title, PID or an
-- ambiguous display name as the identity of a Chrome profile.
local Profiles = require('deskpilot_chrome_profiles')
local M = {}
local bundleID = 'com.google.Chrome'

function M.new(api, statePath)
  local self = { bindings = {}, refreshAt = 0, resolver = nil, loadError = nil }
  statePath = statePath or ((os.getenv('HOME') or '') .. '/Library/Application Support/Google/Chrome/Local State')
  function self:isChrome(window)
    local app = window and window:application()
    return app and app:bundleID() == bundleID or false
  end
  function self:refresh(force)
    local now = api.timer.secondsSinceEpoch()
    if not force and now < self.refreshAt then return end
    self.refreshAt = now + 10
    local ok, data = pcall(api.json.read, statePath)
    if not ok or type(data) ~= 'table' or type(data.profile) ~= 'table'
        or type(data.profile.info_cache) ~= 'table' then
      self.loadError = 'profile-list-unavailable'
      return
    end
    -- Only display-name fields enter the resolver. No email, account ID,
    -- browsing history, cookies or profile Preferences are needed.
    local names = {}
    for directory, info in pairs(data.profile.info_cache) do
      if type(info) == 'table' then
        local entry = {}
        for _, key in ipairs({ 'name', 'gaia_given_name', 'gaia_name',
            'is_using_default_name', 'enterprise_label', 'oidc_identity_name' }) do
          entry[key] = info[key]
        end
        names[directory] = entry
      end
    end
    self.resolver = Profiles.new(names)
    self.loadError = nil
  end
  function self:identify(window)
    if not self:isChrome(window) then return nil, 'not-chrome' end
    local id = window:id()
    if not id then return nil, 'closed-window' end
    local app = window:application()
    local pid = app:pid()
    self:refresh()
    local profile, reason
    if self.resolver then profile, reason = self.resolver:resolve(window:title() or '')
    else reason = self.loadError or 'profile-list-unavailable' end
    if profile then
      self.bindings[id] = { pid = pid, profile = profile }
      return profile
    end
    local prior = self.bindings[id]
    if prior and prior.pid == pid then
      -- A Chrome window keeps its profile for its lifetime. A tab dialog may
      -- temporarily replace AXTitle; it must not merge the window with Chrome.
      return prior.profile, 'cached-window'
    end
    self.bindings[id] = nil
    return nil, reason
  end
  function self:groupKey(window)
    local app = window and window:application()
    if not app then return nil end
    if self:isChrome(window) then
      local profile = self:identify(window)
      if profile then return bundleID .. '::' .. profile.directory end
      return bundleID .. '::unresolved-window-' .. tostring(window:id())
    end
    return app:bundleID() or app:name()
  end
  function self:groupKeyForWindowID(id, pid)
    local prior = self.bindings[id]
    if prior and prior.pid == pid then return bundleID .. '::' .. prior.profile.directory end
    return nil
  end
  function self:forget(id) self.bindings[id] = nil end
  return self
end
return M
