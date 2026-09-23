-- DeskPilot: named macOS Spaces + automatic window assignment for Hammerspoon.
-- Edit the config table below to match your real desktops and apps.

local spaces = hs.spaces
local windowFilter = hs.window.filter
local dialog = hs.dialog
local json = hs.json
local log = hs.logger.new("DeskPilot", "info")
local policy = require("deskpilot_policy")
local manager
local windowFollow
local chromeProfiles = require("deskpilot_chrome").new(hs)

local config = {
  menuTitlePrefix = "Desk",
  workspaceScreen = "All",
  switchMods = { "ctrl" },
  moveMods = { "ctrl", "shift" },
  previewHotkeys = {
    { mods = { "ctrl" }, key = "escape", label = "^Esc" },
    { mods = { "ctrl" }, key = "`", label = "^`" },
    { mods = { "cmd", "alt", "ctrl" }, key = "space", label = "^⌥⌘Space" },
  },
  shortcutKeys = {
    [1] = "1",
    [2] = "2",
    [3] = "3",
    [4] = "4",
    [5] = "5",
    [6] = "6",
    [7] = "7",
    [8] = "8",
    [9] = "9",
    [10] = "0",
    [11] = "-",
  },
  previewSeconds = 6,
  focusTargetScreenBeforeSwitch = true,
  focusTargetScreenBeforeMove = false,
  arrangeExistingWindowsOnReload = false,

  autoDock = {
    enabled = true,
    frame = "full",
    createSpaceWhenFull = true,
    ignoredBundles = {
      ["com.apple.controlcenter"] = true,
      ["com.apple.dock"] = true,
      ["com.apple.finder"] = true,
      ["com.apple.notificationcenterui"] = true,
      ["org.hammerspoon.Hammerspoon"] = true,
    },
  },

  autoName = {
    enabled = true,
    cacheSeconds = 2,
    maxLabels = 2,
    skipWindowsOnMoreThanSpaces = 3,
    ignoredBundles = {
      ["com.apple.controlcenter"] = true,
      ["com.apple.dock"] = true,
      ["com.apple.finder"] = true,
      ["com.apple.notificationcenterui"] = true,
      ["org.hammerspoon.Hammerspoon"] = true,
    },
    titleHints = {
      { label = "GitHub", patterns = { "github" } },
      { label = "Cloud", patterns = { "google cloud", "compute engine", "cloud console", "konsola google cloud" } },
      { label = "AI", patterns = { "chatgpt", "openai", "claude", "gemini" } },
      { label = "YouTube", patterns = { "youtube" } },
      { label = "Docs", patterns = { "google docs", "google sheets", "notion" } },
    },
    browserProfileBundles = {
      ["com.google.Chrome"] = { "Google Chrome" },
      ["com.google.Chrome.canary"] = { "Google Chrome Canary" },
      ["com.brave.Browser"] = { "Brave Browser", "Brave" },
      ["com.microsoft.edgemac"] = { "Microsoft Edge", "Edge" },
      ["company.thebrowser.Browser"] = { "Arc" },
      ["com.vivaldi.Vivaldi"] = { "Vivaldi" },
      ["org.mozilla.firefox"] = { "Firefox" },
    },
    appNameLabels = {
      ["Bitwarden"] = "Bitwarden",
      ["TeamViewer"] = "TeamViewer",
      ["TeamViewer Host"] = "TeamViewer",
      ["Microsoft Outlook"] = "Outlook",
      ["Microsoft Excel"] = "Excel",
      ["Microsoft Word"] = "Word",
      ["Microsoft PowerPoint"] = "PowerPoint",
      ["Microsoft Teams"] = "Teams",
      ["Microsoft Teams (PWA)"] = "Teams",
      ["Google Chrome"] = "Chrome",
      ["Brave Browser"] = "Brave",
      ["Microsoft Edge"] = "Edge",
      ["Safari"] = "Safari",
    },
    bundleLabels = {
      ["com.openai.codex"] = "Codex",
      ["com.microsoft.VSCode"] = "Kod",
      ["com.todesktop.230313mzl4w4u92"] = "Cursor",
      ["com.apple.Terminal"] = "Terminal",
      ["com.googlecode.iterm2"] = "Terminal",
      ["com.apple.dt.Xcode"] = "Kod",
      ["com.bitwarden.desktop"] = "Bitwarden",
      ["com.8bit.bitwarden"] = "Bitwarden",
      ["com.teamviewer.TeamViewer"] = "TeamViewer",
      ["com.teamviewer.TeamViewerHost"] = "TeamViewer",
      ["com.tinyspeck.slackmacgap"] = "Komunikacja",
      ["com.microsoft.teams2"] = "Komunikacja",
      ["com.microsoft.teams"] = "Komunikacja",
      ["com.hnc.Discord"] = "Komunikacja",
      ["com.apple.MobileSMS"] = "Wiadomosci",
      ["com.apple.mail"] = "Mail",
      ["com.microsoft.Outlook"] = "Outlook",
      ["com.spotify.client"] = "Media",
      ["com.apple.Music"] = "Media",
      ["com.apple.QuickTimePlayerX"] = "Media",
      ["com.apple.Preview"] = "Dokumenty",
      ["com.microsoft.Word"] = "Word",
      ["com.microsoft.Excel"] = "Excel",
      ["com.microsoft.Powerpoint"] = "PowerPoint",
      ["com.figma.Desktop"] = "Design",
    },
    categories = {
      { label = "Web", bundles = { "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac" } },
      { label = "Kod", bundles = { "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode" } },
      { label = "Komunikacja", bundles = { "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.hnc.Discord", "com.apple.MobileSMS" } },
      { label = "Media", bundles = { "com.spotify.client", "com.apple.Music", "com.apple.QuickTimePlayerX", "org.videolan.vlc" } },
      { label = "Dokumenty", bundles = { "com.apple.Preview", "com.microsoft.Word", "com.microsoft.Excel", "notion.id" } },
      { label = "Design", bundles = { "com.figma.Desktop", "com.bohemiancoding.sketch3", "com.adobe.Photoshop" } },
    },
  },

  -- Default labels for the first desktops. DeskPilot reads the real number of
  -- macOS desktops at runtime and adds "Biurko N" for anything beyond this list.
  workspaces = {
    { id = "start", name = "Start", index = 1, key = "1" },
    { id = "code", name = "Code", index = 2, key = "2" },
    { id = "web", name = "Web", index = 3, key = "3" },
    { id = "comms", name = "Komunikacja", index = 4, key = "4" },
    { id = "media", name = "Media", index = 5, key = "5" },
  },

  frames = {
    full = { x = 0, y = 0, w = 1, h = 1 },
    left = { x = 0, y = 0, w = 0.5, h = 1 },
    right = { x = 0.5, y = 0, w = 0.5, h = 1 },
    wideLeft = { x = 0, y = 0, w = 0.65, h = 1 },
    narrowRight = { x = 0.65, y = 0, w = 0.35, h = 1 },
    top = { x = 0, y = 0, w = 1, h = 0.5 },
    bottom = { x = 0, y = 0.5, w = 1, h = 0.5 },
  },

  -- First matching rule wins. Keep this empty for "first free desktop" behavior
  -- and use the DeskPilot menu to create your real app/profile rules.
  rules = {},
}

local settingsKey = "deskpilot.userRules.v2"
local dockedRulesKey = "deskpilot.dockedRules.v2"
local workspaceNamesKey = "deskpilot.workspaceNames.v2"
local missionNamesKey = "deskpilot.missionNames.v2"
local workspaceNames = hs.settings.get(workspaceNamesKey) or {}
local userRules = hs.settings.get(settingsKey) or hs.settings.get("deskpilot.userRules.v1") or {}
local dockedRules = hs.settings.get(dockedRulesKey) or {}
local savedMissionNameEntries = hs.settings.get(missionNamesKey) or {}
local menu = hs.menubar.new(true, "DeskPilot")
local pendingTimers = {}
local workspacePanel
local settingsMenu = hs.menubar.new(false)
local workspaces = {}
local autoNameCache = { timestamp = 0, names = {} }
local missionNameCache = { timestamp = 0, entries = savedMissionNameEntries, bySpaceID = nil }
local workspaceShortcutTap = nil
local workspaceHotkeys = {}
local lastShortcut = { index = nil, moveWindow = nil, timestamp = 0 }
local appLaunchWatcher = nil
local updateMenuTitle

local function trim(text)
  local trimmed = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return trimmed
end

local function copyTable(source)
  local target = {}
  for key, value in pairs(source) do
    target[key] = value
  end
  return target
end

local function patternEscape(text)
  return (text or ""):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

local function shellQuote(text)
  return "'" .. tostring(text or ""):gsub("'", "'\\''") .. "'"
end

local function containsText(text, needle)
  return (text or ""):lower():find((needle or ""):lower(), 1, true) ~= nil
end

local function listContains(list, value)
  for _, item in ipairs(list or {}) do
    if item == value then
      return true
    end
  end
  return false
end

local function lastPlainFind(text, needle)
  local lastStart, lastFinish = nil, nil
  local start = 1
  while true do
    local foundStart, foundFinish = (text or ""):find(needle, start, true)
    if not foundStart then
      break
    end
    lastStart = foundStart
    lastFinish = foundFinish
    start = foundFinish + 1
  end
  return lastStart, lastFinish
end

local function stripLeadingSeparator(text)
  local result = trim(text)
  local enDash = "\226\128\147"
  local emDash = "\226\128\148"
  local separators = { "-", ":", "|", enDash, emDash }

  local changed = true
  while changed do
    changed = false
    result = trim(result)
    for _, separator in ipairs(separators) do
      if result:sub(1, #separator) == separator then
        result = result:sub(#separator + 1)
        changed = true
      end
    end
  end

  return trim(result)
end

local function browserProfileLabel(bundleID, title)
  local browsers = (config.autoName or {}).browserProfileBundles or {}
  local appNames = browsers[bundleID]
  if not appNames then
    return nil
  end

  for _, browserName in ipairs(appNames) do
    local _, appNameEnd = lastPlainFind(title or "", browserName)
    if appNameEnd then
      local profile = stripLeadingSeparator((title or ""):sub(appNameEnd + 1))
      if profile ~= "" and #profile <= 48 and profile ~= browserName then
        return profile
      end
    end
  end

  return nil
end

local function cleanAppLabel(appName)
  local labels = (config.autoName or {}).appNameLabels or {}
  if labels[appName] then
    return labels[appName]
  end

  local label = appName or ""
  label = label:gsub("%s*%(PWA%)%s*$", "")
  label = label:gsub("^Microsoft%s+", "")
  label = trim(label)

  if label == "" then
    return nil
  end

  return label
end

local function screenList()
  if config.workspaceScreen == "All" then
    return hs.screen.allScreens()
  end
  return { config.workspaceScreen or "Primary" }
end

local function rebuildMissionNameLookup(entries)
  local bySpaceID = {}
  for _, entry in ipairs(entries or {}) do
    local spaceID = tonumber(entry.spaceID)
    if spaceID then
      bySpaceID[spaceID] = {
        missionName = entry.missionName,
        systemIndex = entry.systemIndex,
        screenUUID = entry.screenUUID,
      }
    end
  end
  return bySpaceID
end

local function spaceEntriesFromSystemPreferences()
  local path = (os.getenv("HOME") or "") .. "/Library/Preferences/com.apple.spaces.plist"
  local command = "/usr/bin/plutil -convert json -o - " .. shellQuote(path)
  local output, ok, _, rc = hs.execute(command, true)
  if not ok or not output or output == "" then
    return nil, "plutil failed: " .. tostring(rc)
  end

  local decodedOK, data = pcall(json.decode, output)
  if not decodedOK or type(data) ~= "table" then
    return nil, "cannot decode Spaces preferences"
  end

  local configRoot = data.SpacesDisplayConfiguration or {}
  local managementData = configRoot["Management Data"] or {}
  local monitors = managementData.Monitors or {}
  local entries = {}
  local desktopNumber = 0

  for _, monitor in ipairs(monitors) do
    for _, space in ipairs(monitor.Spaces or {}) do
      local spaceID = tonumber(space.ManagedSpaceID or space.id64)
      local spaceType = tonumber(space.type or 0)
      if spaceID and spaceType == 0 then
        desktopNumber = desktopNumber + 1
        table.insert(entries, {
          screenUUID = tostring(monitor["Display Identifier"] or ""),
          spaceID = spaceID,
          missionName = "Biurko " .. tostring(desktopNumber),
          systemIndex = desktopNumber,
        })
      end
    end
  end

  return entries
end

local function missionControlNameLookup(force)
  if not force then
    if not missionNameCache.bySpaceID then
      missionNameCache.bySpaceID = rebuildMissionNameLookup(missionNameCache.entries)
    end
    return missionNameCache.bySpaceID
  end

  local entries, err = spaceEntriesFromSystemPreferences()
  if not entries or #entries == 0 then
    log.w("Cannot read Spaces preferences: " .. tostring(err))
    if not missionNameCache.bySpaceID then
      missionNameCache.bySpaceID = rebuildMissionNameLookup(missionNameCache.entries)
    end
    return missionNameCache.bySpaceID
  end

  missionNameCache = {
    timestamp = os.time(),
    entries = entries,
    bySpaceID = rebuildMissionNameLookup(entries),
  }
  hs.settings.set(missionNamesKey, entries)
  return missionNameCache.bySpaceID
end

local function userSpaceRecords()
  local records, screens = {}, {}
  for _, screen in ipairs(hs.screen.allScreens()) do screens[screen:getUUID()] = screen end
  local displays, err = spaces.data_managedDisplaySpaces()
  if not displays then log.w(tostring(err)); return records end
  for _, display in ipairs(displays) do
    local uuid = display["Display Identifier"]
    local screen = screens[uuid]
    if uuid == "Main" then screen = hs.screen.primaryScreen() end
    if screen then
      local localIndex = 0
      for _, space in ipairs(display.Spaces or {}) do
        if space.type == 0 then
          localIndex = localIndex + 1
          local index = #records + 1
          records[index] = {
            spaceID = space.ManagedSpaceID or space.id64, spaceUUID = space.uuid,
            screen = screen, screenUUID = screen:getUUID(), screenName = screen:name(),
            localIndex = localIndex, systemIndex = index, missionName = "Biurko " .. index,
          }
        end
      end
    end
  end
  return records
end

local function labelForWindow(window)
  local app = window:application()
  if not app then
    return nil
  end

  local auto = config.autoName or {}
  local bundleID = app:bundleID()
  local appName = app:name()
  if bundleID and auto.ignoredBundles and auto.ignoredBundles[bundleID] then
    return nil
  end

  local subrole = window:subrole()
  if subrole and subrole ~= "AXStandardWindow" then
    return nil
  end

  if chromeProfiles:isChrome(window) then
    local profile = chromeProfiles:identify(window)
    if profile then return profile.label end
  end
  local title = window:title() or ""
  local profileLabel = browserProfileLabel(bundleID, title)
  if profileLabel then
    return profileLabel
  end

  if auto.appNameLabels and auto.appNameLabels[appName] then
    return auto.appNameLabels[appName]
  end

  if bundleID and auto.bundleLabels and auto.bundleLabels[bundleID] then
    return auto.bundleLabels[bundleID]
  end

  for _, hint in ipairs(auto.titleHints or {}) do
    for _, pattern in ipairs(hint.patterns or {}) do
      if containsText(title, pattern) then
        return hint.label
      end
    end
  end

  for _, category in ipairs(auto.categories or {}) do
    if listContains(category.bundles, bundleID) then
      return category.label
    end
  end

  if title ~= "" or (appName and appName ~= "") then
    return cleanAppLabel(appName)
  end

  return nil
end

local function calculatedAutoNames(force)
  local auto = config.autoName or {}
  if not auto.enabled then
    return {}
  end

  local now = os.time()
  if not force and autoNameCache.timestamp and now - autoNameCache.timestamp < (auto.cacheSeconds or 2) then
    return autoNameCache.names
  end

  local buckets = {}
  for _, window in ipairs((manager and manager:allWindows() or hs.window.allWindows())) do
    local label = labelForWindow(window)
    local windowSpaces = label and spaces.windowSpaces(window) or nil
    if windowSpaces and #windowSpaces > 0 and #windowSpaces <= (auto.skipWindowsOnMoreThanSpaces or 3) then
      for _, spaceID in ipairs(windowSpaces) do
        if spaces.spaceType(spaceID) == "user" then
          buckets[spaceID] = buckets[spaceID] or { counts = {}, labels = {} }
          if not buckets[spaceID].counts[label] then
            table.insert(buckets[spaceID].labels, label)
            buckets[spaceID].counts[label] = 0
          end
          buckets[spaceID].counts[label] = buckets[spaceID].counts[label] + 1
        end
      end
    end
  end

  local names = {}
  for spaceID, bucket in pairs(buckets) do
    table.sort(bucket.labels, function(a, b)
      local countA = bucket.counts[a] or 0
      local countB = bucket.counts[b] or 0
      if countA == countB then
        return a < b
      end
      return countA > countB
    end)

    local selected = {}
    for index, label in ipairs(bucket.labels) do
      if index > (auto.maxLabels or 2) then
        break
      end
      table.insert(selected, label)
    end
    if #selected > 0 then
      names[spaceID] = table.concat(selected, " + ")
    end
  end

  autoNameCache = { timestamp = now, names = names }
  return names
end

local function applyWorkspaceNames()
  local records = userSpaceRecords()
  local autoNames = calculatedAutoNames(false)
  local count = #records > 0 and #records or #config.workspaces
  workspaces = {}

  for index = 1, count do
    local defaults = config.workspaces[index] or {}
    local record = records[index] or {}
    local systemIndex = record.systemIndex or index
    local defaultsForSystemIndex = config.workspaces[systemIndex] or defaults
    local id = record.spaceUUID and ("space-" .. record.spaceUUID) or ("space-id-" .. tostring(record.spaceID))
    local defaultName = defaultsForSystemIndex.defaultName or defaultsForSystemIndex.name or ("Biurko " .. tostring(systemIndex))
    local autoName = record.spaceID and autoNames[record.spaceID] or nil

    table.insert(workspaces, {
      id = id,
      index = systemIndex,
      key = defaultsForSystemIndex.key or (config.shortcutKeys and config.shortcutKeys[systemIndex]) or nil,
      defaultName = defaultName,
      name = workspaceNames[id] or autoName or defaultName,
      autoName = autoName,
      hasManualName = workspaceNames[id] ~= nil,
      screen = record.screen or defaults.screen,
      screenName = record.screenName,
      screenUUID = record.screenUUID,
      localIndex = record.localIndex,
      missionName = record.missionName,
      spaceID = record.spaceID,
      spaceUUID = record.spaceUUID,
    })
  end
end

applyWorkspaceNames()

local function refreshWorkspaceMap()
  missionNameCache.timestamp = 0
  missionControlNameLookup(true)
  autoNameCache.timestamp = 0
  applyWorkspaceNames()
end

local function desktopNumberFromWorkspaceRef(ref)
  if type(ref) == "number" then
    return ref
  end
  return tonumber(tostring(ref or ""):match("^desktop%-(%d+)$"))
end

local function workspaceByDesktopNumber(number)
  applyWorkspaceNames()

  for _, workspace in ipairs(workspaces) do
    if workspace.index == number then
      return workspace
    end
  end
  return nil
end

local function workspaceByName(name)
  local desktopNumber = desktopNumberFromWorkspaceRef(name)
  if desktopNumber then
    return workspaceByDesktopNumber(desktopNumber)
  end

  applyWorkspaceNames()

  for _, workspace in ipairs(workspaces) do
    if workspace.id == name or workspace.name == name or workspace.defaultName == name
        or (config.workspaces[workspace.index] or {}).id == name then
      return workspace
    end
  end
  return nil
end

local function spaceIDForWorkspace(workspace)
  if not workspace then
    return nil
  end
  if workspace.spaceID then
    return workspace.spaceID
  end

  applyWorkspaceNames()
  for _, item in ipairs(workspaces) do
    if item.id == workspace.id or item.index == workspace.index then
      return item.spaceID
    end
  end
  return nil
end

local function workspaceForRule(rule)
  applyWorkspaceNames()
  return policy.resolve(rule, workspaces)
end

local function setRuleTarget(rule, workspace)
  rule.spaceID = workspace.spaceID
  rule.spaceUUID = workspace.spaceUUID
  rule.screenUUID = workspace.screenUUID
  rule.workspace = workspace.id
  rule.desktopNumber = nil
end

local function workspaceForSpaceID(spaceID, skipRefresh)
  if not spaceID then
    return nil
  end
  if not skipRefresh then
    applyWorkspaceNames()
  end
  for _, workspace in ipairs(workspaces) do
    if spaceIDForWorkspace(workspace) == spaceID then
      return workspace
    end
  end
  return nil
end

local function currentWorkspace()
  applyWorkspaceNames()
  return workspaceForSpaceID(spaces.focusedSpace(), true)
end

local function screenCenter(screen)
  if not screen then
    return nil
  end

  local frame = screen:frame()
  return {
    x = frame.x + frame.w / 2,
    y = frame.y + frame.h / 2,
  }
end

local function focusTargetScreen(screen)
  local point = screenCenter(screen)
  if point then
    hs.mouse.absolutePosition(point)
  end
end

-- All preview shortcuts and actions use the same Space gallery.
local function drawPreviewLabels()
  if workspacePanel then
    if workspacePanel.visible then workspacePanel:refresh(false)
    else workspacePanel:show() end
  end
end

local function showMissionControlPreview()
  if workspacePanel then workspacePanel:hide() end
  spaces.openMissionControl()
end

local function showQuickNameBubbles()
  if workspacePanel then workspacePanel:toggle() end
end

local function screenForSpaceID(spaceID)
  local uuid = spaces.spaceDisplay(spaceID)
  if not uuid then
    return hs.screen.primaryScreen()
  end
  for _, screen in ipairs(hs.screen.allScreens()) do
    if screen:getUUID() == uuid then
      return screen
    end
  end
  return hs.screen.primaryScreen()
end

local function unitToFrame(screen, unit)
  local frame = (screen or hs.screen.primaryScreen()):frame()
  return {
    x = frame.x + frame.w * unit.x,
    y = frame.y + frame.h * unit.y,
    w = frame.w * unit.w,
    h = frame.h * unit.h,
  }
end

local function applyFrame(window, frameName, targetScreen)
  if not frameName then
    return
  end

  local unit = type(frameName) == "table" and frameName or config.frames[frameName]
  if not unit then
    log.w("Unknown frame: " .. tostring(frameName))
    return
  end

  window:setFrame(unitToFrame(targetScreen or window:screen(), unit), 0)
end

local function windowMatchesRule(window, rule)
  local app = window:application()
  if not app then
    return false
  end

  if chromeProfiles:isChrome(window) then
    local profile = chromeProfiles:identify(window)
    -- Legacy whole-Chrome/title-only rules cannot override profile isolation.
    if not profile or rule.profileDirectory ~= profile.directory then return false end
  elseif rule.profileDirectory then
    return false
  end

  if rule.bundleID and app:bundleID() ~= rule.bundleID then
    return false
  end
  if not rule.bundleID and rule.app and app:name() ~= rule.app then
    return false
  end
  if rule.title and rule.title ~= "" and not (window:title() or ""):match(rule.title) then
    return false
  end
  if rule.rejectTitle and rule.rejectTitle ~= "" and (window:title() or ""):match(rule.rejectTitle) then
    return false
  end

  return true
end

local function allRules()
  local rules = {}
  for _, rule in ipairs(userRules) do
    table.insert(rules, rule)
  end
  for _, rule in ipairs(dockedRules) do
    table.insert(rules, rule)
  end
  for _, rule in ipairs(config.rules) do
    table.insert(rules, rule)
  end
  return rules
end

local function windowShouldBeManaged(window)
  if not window or not window:id() then
    return false
  end
  if window:isFullScreen() or window:subrole() ~= "AXStandardWindow" then
    return false
  end

  local app = window:application()
  local bundleID = app and app:bundleID()
  local ignored = (config.autoDock and config.autoDock.ignoredBundles) or {}
  if bundleID and ignored[bundleID] then
    return false
  end

  if chromeProfiles:isChrome(window) and not chromeProfiles:identify(window) then
    return false
  end
  return true
end

local function appShouldBeManaged(app)
  if not app then
    return false
  end

  local bundleID = app:bundleID()
  local ignored = (config.autoDock and config.autoDock.ignoredBundles) or {}
  if bundleID and ignored[bundleID] then
    return false
  end

  return true
end

local function ruleKey(rule)
  if not rule then
    return ""
  end
  return table.concat({
    rule.bundleID or "",
    (not rule.bundleID and rule.app) or "",
    rule.title or "",
    rule.rejectTitle or "",
    rule.profileDirectory or "",
  }, "|")
end

local function ruleUsesIgnoredBundle(rule)
  local ignored = (config.autoDock and config.autoDock.ignoredBundles) or {}
  return rule and rule.bundleID and ignored[rule.bundleID] == true
end

local function normalizeStoredRule(rule)
  local changed = false

  if rule.title == "" then
    rule.title = nil
    changed = true
  end
  if rule.rejectTitle == "" then
    rule.rejectTitle = nil
    changed = true
  end
  if rule.desktopNumber == nil then
    local desktopNumber = desktopNumberFromWorkspaceRef(rule.workspace)
    if desktopNumber then
      rule.desktopNumber = desktopNumber
      changed = true
    end
  end

  return changed
end

local function sanitizeRuleList(list, blockedKeys)
  local clean = {}
  local seen = {}
  local changed = false

  for _, rule in ipairs(list or {}) do
    if ruleUsesIgnoredBundle(rule) then
      changed = true
    else
      changed = normalizeStoredRule(rule) or changed
      local key = ruleKey(rule)
      if key ~= "" and (blockedKeys and blockedKeys[key]) then
        changed = true
      elseif key ~= "" and seen[key] then
        changed = true
      else
        if key ~= "" then
          seen[key] = true
        end
        table.insert(clean, rule)
      end
    end
  end

  if #clean ~= #(list or {}) then
    changed = true
  end

  return clean, seen, changed
end

local function sanitizeStoredRules()
  local cleanUserRules, userKeys, userChanged = sanitizeRuleList(userRules)
  local cleanDockedRules, _, dockedChanged = sanitizeRuleList(dockedRules, userKeys)

  if userChanged then
    userRules = cleanUserRules
    hs.settings.set(settingsKey, userRules)
  end
  if dockedChanged then
    dockedRules = cleanDockedRules
    hs.settings.set(dockedRulesKey, dockedRules)
  end
end

sanitizeStoredRules()

local function existingRuleForWindow(window)
  for _, rule in ipairs(allRules()) do
    if windowMatchesRule(window, rule) then
      return rule
    end
  end
  return nil
end

local function existingRuleForApp(app)
  if not app then
    return nil
  end

  local bundleID = app:bundleID()
  local appName = app:name()
  for _, rule in ipairs(allRules()) do
    if (rule.bundleID and bundleID and rule.bundleID == bundleID) or (rule.app and appName and rule.app == appName) then
      if not rule.title then
        return rule
      end
    end
  end
  return nil
end

local function browserProfileRuleForWindow(window, bundleID)
  if chromeProfiles:isChrome(window) then
    local profile = chromeProfiles:identify(window)
    if not profile then return nil end
    return { bundleID = bundleID, profileDirectory = profile.directory, label = "Chrome · " .. profile.label }
  end
  local title = window:title() or ""
  local profile = browserProfileLabel(bundleID, title)
  if not profile then
    return nil
  end

  return {
    bundleID = bundleID,
    title = patternEscape(profile),
    label = profile,
  }
end

local function appUsesBrowserProfiles(app)
  local bundleID = app and app:bundleID()
  local browsers = (config.autoName or {}).browserProfileBundles or {}
  return bundleID and browsers[bundleID] ~= nil
end

local function dockRuleForWindow(window, workspace)
  local app = window:application()
  if not app or not workspace then
    return nil
  end

  local bundleID = app:bundleID()
  local rule = {
    bundleID = bundleID,
    app = app:name(),
    label = cleanAppLabel(app:name()) or app:name(),
  }

  if chromeProfiles:isChrome(window) then
    rule = browserProfileRuleForWindow(window, bundleID)
    if not rule then return nil end
    rule.app = app:name()
  end
  setRuleTarget(rule, workspace)
  rule.frame = (config.autoDock and config.autoDock.frame) or "full"
  rule.autoDocked = true
  return rule
end

local function dockRuleForApp(app, workspace)
  if not app or not workspace then
    return nil
  end

  local rule = {
    bundleID = app:bundleID(),
    app = app:name(),
    label = cleanAppLabel(app:name()) or app:name(),
    workspace = workspace.id,
    desktopNumber = workspace.index,
    frame = (config.autoDock and config.autoDock.frame) or "full",
    autoDocked = true,
  }

  return rule
end

local function saveDockedRules()
  hs.settings.set(dockedRulesKey, dockedRules)
end

local function workspaceByID(id)
  applyWorkspaceNames()
  for _, workspace in ipairs(workspaces) do
    if workspace.id == id then
      return workspace
    end
  end
  return nil
end

local function addDockedRule(rule)
  if not rule then
    return false
  end

  local key = ruleKey(rule)
  for _, existing in ipairs(dockedRules) do
    if ruleKey(existing) == key then
      existing.workspace = rule.workspace
      existing.desktopNumber = nil
      existing.spaceID = rule.spaceID
      existing.spaceUUID = rule.spaceUUID
      existing.screenUUID = rule.screenUUID
      existing.allowShared = rule.allowShared
      existing.frame = rule.frame
      existing.label = rule.label
      existing.app = existing.app or rule.app
      existing.bundleID = existing.bundleID or rule.bundleID
      existing.title = rule.title
      existing.autoDocked = true
      saveDockedRules()
      return true
    end
  end

  table.insert(dockedRules, 1, rule)
  saveDockedRules()
  return true
end

local function scheduleApply(window, allowAutoDock)
  if manager then manager:enqueue(window, allowAutoDock) end
end

local function goToWorkspace(name)
  local workspace = workspaceByName(name)
  local spaceID = spaceIDForWorkspace(workspace)
  if not spaceID then
    hs.alert.show("DeskPilot: utworz Mission Control desktop dla " .. tostring(name))
    return
  end
  if config.focusTargetScreenBeforeSwitch then
    focusTargetScreen(workspace.screen or screenForSpaceID(spaceID))
  end

  hs.timer.doAfter(0.05, function()
    local ok, err = spaces.gotoSpace(spaceID)
    if ok then
      hs.alert.show(workspace.name)
    else
      hs.alert.show("DeskPilot: nie moge przelaczyc na " .. workspace.name)
      log.w("Cannot switch space: " .. tostring(err))
    end
  end)
end

local function moveFocusedWindowToWorkspace(name)
  local window = hs.window.focusedWindow()
  if window and manager then manager:manualMove(window, workspaceByName(name)) end
end

local function saveUserRules()
  hs.settings.set(settingsKey, userRules)
end

local function addUserRule(rule)
  local key = ruleKey(rule)
  if key ~= "" then
    for index = #userRules, 1, -1 do
      if ruleKey(userRules[index]) == key then
        table.remove(userRules, index)
      end
    end
    for index = #dockedRules, 1, -1 do
      if ruleKey(dockedRules[index]) == key then
        table.remove(dockedRules, index)
      end
    end
  end

  table.insert(userRules, 1, rule)
  saveUserRules()
  saveDockedRules()
end

local function saveWorkspaceNames()
  hs.settings.set(workspaceNamesKey, workspaceNames)
end

local function renameWorkspace(workspace)
  local button, text = dialog.textPrompt(
    "Nazwa biurka",
    "Wpisz wlasna nazwe dla pozycji " .. tostring(workspace.index) .. ".",
    workspace.name,
    "Zapisz",
    "Anuluj"
  )

  local newName = trim(text)
  if button ~= "Zapisz" or newName == "" then
    return
  end

  workspaceNames[workspace.id] = newName
  applyWorkspaceNames()
  saveWorkspaceNames()
  updateMenuTitle()
  drawPreviewLabels(3)
  hs.alert.show("Nazwa: " .. newName)
end

local function resetWorkspaceNames()
  workspaceNames = {}
  applyWorkspaceNames()
  saveWorkspaceNames()
  updateMenuTitle()
  drawPreviewLabels(3)
  hs.alert.show("DeskPilot: wlaczono nazwy automatyczne")
end

local function refreshWorkspaceList()
  refreshWorkspaceMap()
  updateMenuTitle()
  drawPreviewLabels(3)
  hs.alert.show("DeskPilot: odswiezono biurka")
end

local function autoNameWorkspaces(overwriteManual)
  autoNameCache.timestamp = 0
  local autoNames = calculatedAutoNames(true)
  applyWorkspaceNames()

  local changed = 0
  for _, workspace in ipairs(workspaces) do
    local name = workspace.spaceID and autoNames[workspace.spaceID] or nil
    if name and (overwriteManual or not workspaceNames[workspace.id]) then
      workspaceNames[workspace.id] = name
      changed = changed + 1
    end
  end

  saveWorkspaceNames()
  applyWorkspaceNames()
  updateMenuTitle()
  drawPreviewLabels(3)
  hs.alert.show("DeskPilot: auto-nazwano " .. tostring(changed))
end

local function assignFocusedWindow(includeTitle, targetWorkspace)
  local window = hs.window.focusedWindow()
  local workspace = targetWorkspace or currentWorkspace()
  if not window or not workspace then
    hs.alert.show("DeskPilot: brak aktywnego okna albo biurka")
    return
  end
  if not windowShouldBeManaged(window) then
    hs.alert.show("DeskPilot: tego okna nie przypinam")
    return
  end

  local app = window:application()
  local rule = (includeTitle or chromeProfiles:isChrome(window)) and browserProfileRuleForWindow(window, app and app:bundleID()) or nil
  rule = rule or {
    bundleID = app and app:bundleID() or nil,
    app = app and app:name() or nil,
  }

  if includeTitle and not rule.title and not rule.profileDirectory then
    local title = trim(window:title() or "")
    if title == "" then
      hs.alert.show("DeskPilot: to okno nie ma tytulu do profilu")
      return
    end
    rule.title = patternEscape(title)
  end

  setRuleTarget(rule, workspace)
  rule.frame = "full"
  rule.allowShared = true

  addUserRule(rule)
  scheduleApply(window)
  hs.alert.show((includeTitle and "Przypieto okno/profil: " or "Przypieto aplikacje: ") .. workspace.name)
end

local function clearCapturedRules()
  userRules = {}
  saveUserRules()
  hs.alert.show("DeskPilot: wyczyszczono zapisane reguly")
end

local function ruleDisplayName(rule)
  return rule.label or rule.app or rule.bundleID or "Aplikacja"
end

local function moveDockedRule(ruleIndex, workspace)
  local rule = dockedRules[ruleIndex]
  if not rule or not workspace then
    return
  end

  setRuleTarget(rule, workspace)
  rule.allowShared = true
  saveDockedRules()
  hs.alert.show("Przypiecie: " .. ruleDisplayName(rule) .. " -> " .. workspace.name)

  for _, window in ipairs((manager and manager:allWindows() or hs.window.allWindows())) do
    if windowShouldBeManaged(window) and windowMatchesRule(window, rule) then
      scheduleApply(window)
    end
  end
end

local function removeDockedRule(ruleIndex)
  local rule = dockedRules[ruleIndex]
  if not rule then
    return
  end

  local label = ruleDisplayName(rule)
  table.remove(dockedRules, ruleIndex)
  saveDockedRules()
  hs.alert.show("Usunieto przypiecie: " .. label)
end

local function clearDockedRules()
  dockedRules = {}
  saveDockedRules()
  hs.alert.show("DeskPilot: wyczyszczono autodokowanie")
end

function updateMenuTitle()
  local workspace = currentWorkspace()
  local name = workspace and workspace.name or ("Space " .. tostring(spaces.focusedSpace() or "?"))
  menu:setTitle(config.menuTitlePrefix .. ": " .. name)
end

local function workspaceMenuTitle(workspace)
  return tostring(workspace.index) .. ". " .. workspace.name .. " — " .. (workspace.screenName or "monitor")
end

local function hotkeyText(mods, key)
  local glyphs = {
    ctrl = "^",
    alt = "⌥",
    cmd = "⌘",
    shift = "⇧",
  }
  local keyGlyphs = {
    up = "↑",
    down = "↓",
    left = "←",
    right = "→",
    space = "Space",
  }
  local parts = {}
  for _, mod in ipairs(mods or {}) do
    table.insert(parts, glyphs[mod] or mod)
  end
  table.insert(parts, keyGlyphs[key] or key)
  return table.concat(parts, "")
end

local function previewHotkeyTitle()
  local shortcut = config.previewHotkeys and config.previewHotkeys[1]
  if not shortcut then
    return ""
  end
  return shortcut.label or hotkeyText(shortcut.mods, shortcut.key)
end

local function showWorkspacePanel()
  if workspacePanel then workspacePanel:toggle() end
end

local function assignmentMenu(includeTitle)
  applyWorkspaceNames()
  local items = {}
  for _, item in ipairs(workspaces) do
    local target = item
    table.insert(items, {
      title = workspaceMenuTitle(target),
      fn = function()
        assignFocusedWindow(includeTitle, target)
      end,
    })
  end
  return items
end

local function moveDockedRuleMenu(ruleIndex)
  applyWorkspaceNames()
  local items = {}
  for _, workspace in ipairs(workspaces) do
    local target = workspace
    table.insert(items, {
      title = workspaceMenuTitle(target),
      fn = function()
        moveDockedRule(ruleIndex, target)
      end,
    })
  end
  return items
end

local function dockedRulesMenu()
  local items = {}

  if #dockedRules == 0 then
    table.insert(items, { title = "Brak autodokowanych aplikacji", disabled = true })
    return items
  end

  for index, rule in ipairs(dockedRules) do
    local ruleIndex = index
    local workspace = workspaceForRule(rule)
    table.insert(items, {
      title = ruleDisplayName(rule) .. " -> " .. (workspace and workspace.name or tostring(rule.workspace)),
      menu = {
        {
          title = "Przenies przypiecie do...",
          menu = moveDockedRuleMenu(ruleIndex),
        },
        {
          title = "Usun przypiecie",
          fn = function()
            removeDockedRule(ruleIndex)
          end,
        },
      },
    })
  end

  table.insert(items, { title = "-" })
  table.insert(items, {
    title = "Wyczysc autodokowanie",
    fn = clearDockedRules,
  })

  return items
end

local function chromeProfilesMenu()
  local items, seen = {}, {}
  if manager then
    for _, window in ipairs(manager:allWindows()) do
      if chromeProfiles:isChrome(window) and window:subrole() == "AXStandardWindow" then
        local profile = chromeProfiles:identify(window)
        local key = profile and profile.directory or ("unknown-" .. tostring(window:id()))
        if not seen[key] then
          seen[key] = true
          local rule = profile and existingRuleForWindow(window)
          local ws = rule and workspaceForRule(rule)
          items[#items + 1] = { disabled = true, title = profile
            and (profile.label .. (ws and (" → " .. workspaceMenuTitle(ws)) or " — oczekuje na biurko"))
            or "Nierozpoznany profil — okno pozostaje na miejscu" }
        end
      end
    end
  end
  if #items == 0 then items[1] = { title = "Brak otwartych okien Chrome", disabled = true } end
  return items
end

local function organizeNow(window)
  if workspacePanel then workspacePanel:hide() end
  return manager:organize(window)
end

local function menuItems()
  applyWorkspaceNames()
  local workspace = currentWorkspace()
  local items = {
    { title = "Panel biurek    ^⌥Space", fn = showWorkspacePanel },
    { title = "Aktywne: " .. (workspace and workspace.name or "poza lista"), disabled = true },
    { title = "Wykryte biurka: " .. tostring(#workspaces), disabled = true },
    { title = manager and (manager.paused and "Wznow automatyke" or "Wstrzymaj automatyke") or "Automatyka",
      fn = function() if manager.paused then manager:resume() else manager:pause() end end },
    { title = "Usun puste, nieaktywne biurka", fn = function() manager:cleanup() end },
    { title = "Organizuj teraz — rozdziel aplikacje i profile", disabled = manager.paused or manager.busy or manager.organizing,
      fn = function() organizeNow() end },
    { title = "Podążaj za nowym oknem", checked = manager.followEnabled,
      fn = function() manager:setFollowEnabled(not manager.followEnabled) end },
    { title = "Profile Chrome — osobne biurka", menu = chromeProfilesMenu() },
    { title = "Pamięć układu i start programów", menu = {
      { title = manager.session and "Przywracanie po zalogowaniu: włączone"
          or "Przywracanie: niedostępne — sprawdź status", disabled = true },
      { title = "Teams, wiadomości, hasła, ustawienia, terminal → laptop", disabled = true },
      { title = "Przeglądarki → monitory zewnętrzne, gdy dostępne", disabled = true },
      { title = "Zapisz układ teraz", disabled = not manager.session or manager.paused,
        fn = function() if manager.session then
          hs.alert.show(manager.session:saveNow() and "DeskPilot: zapisano układ"
            or "DeskPilot: układ jeszcze się zmienia — spróbuj za chwilę")
        end end },
      { title = "Przywróć zapisany układ", disabled = not manager.session or manager.paused,
        fn = function() if manager.session then
          hs.alert.show(manager.session:requestRestore() and "DeskPilot: przygotowuję przywracanie układu"
            or "DeskPilot: brak gotowego zapisu lub trwa zmiana monitorów")
        end end },
    } },
    { title = "-" },
  }

  if manager and not manager.paused and not manager.cleanupEnabled then
    table.insert(items, 5, { title = "Wznów automatyczne sprzątanie", fn = function() manager:resume() end })
  end

  for _, item in ipairs(workspaces) do
    local target = item
    local title = workspaceMenuTitle(target)
    if target.key then
      title = title .. "    " .. hotkeyText(config.switchMods, target.key)
    end
    table.insert(items, {
      title = title,
      checked = workspace and workspace.id == target.id or false,
      fn = function()
        goToWorkspace(target.id)
      end,
    })
  end

  table.insert(items, { title = "-" })
  table.insert(items, {
    title = "Biurka i podglądy    " .. previewHotkeyTitle(),
    fn = showQuickNameBubbles,
  })
  table.insert(items, {
    title = "Zmień kolejność w Mission Control",
    fn = showMissionControlPreview,
  })
  table.insert(items, {
    title = "Odswiez liste biurek",
    fn = refreshWorkspaceList,
  })
  table.insert(items, {
    title = "Nazwij biurka",
    menu = (function()
      local renameItems = {}
      for _, item in ipairs(workspaces) do
        local target = item
        table.insert(renameItems, {
          title = workspaceMenuTitle(target),
          fn = function()
            renameWorkspace(target)
          end,
        })
      end
      table.insert(renameItems, { title = "-" })
      table.insert(renameItems, {
        title = "Auto-nazwij nieustawione",
        fn = function()
          autoNameWorkspaces(false)
        end,
      })
      table.insert(renameItems, {
        title = "Auto-nazwij wszystkie",
        fn = function()
          autoNameWorkspaces(true)
        end,
      })
      table.insert(renameItems, {
        title = "Wyczysc reczne nazwy",
        fn = resetWorkspaceNames,
      })
      return renameItems
    end)(),
  })
  table.insert(items, { title = "-" })
  table.insert(items, {
    title = "Przypisz aplikacje do aktywnego biurka",
    fn = function()
      assignFocusedWindow(false)
    end,
  })
  table.insert(items, {
    title = "Przypisz aplikacje do...",
    menu = assignmentMenu(false),
  })
  table.insert(items, {
    title = "Przypisz to okno/profil po tytule",
    fn = function()
      assignFocusedWindow(true)
    end,
  })
  table.insert(items, {
    title = "Przypisz to okno/profil do...",
    menu = assignmentMenu(true),
  })
  table.insert(items, {
    title = "Autodokowane aplikacje",
    menu = dockedRulesMenu(),
  })
  table.insert(items, {
    title = "Uloz wszystkie widoczne okna",
    fn = function()
      for _, window in ipairs((manager and manager:allWindows() or hs.window.allWindows())) do
        scheduleApply(window, false)
      end
    end,
  })
  table.insert(items, {
    title = "Wyczysc reguly zapisane z menu",
    fn = clearCapturedRules,
  })
  table.insert(items, { title = "-" })
  table.insert(items, {
    title = "Reload Hammerspoon",
    fn = hs.reload,
  })

  return items
end

menu:setTooltip("DeskPilot — podgląd biurek (⌃⌥Space). Option + klik: ustawienia.")
settingsMenu:setMenu(menuItems)
menu:setClickCallback(function(modifiers)
  if modifiers and modifiers.alt then
    if workspacePanel then workspacePanel:hide() end
    settingsMenu:popupMenu(hs.mouse.absolutePosition())
  else showWorkspacePanel() end
end)
updateMenuTitle()

local function workspaceForShortcutIndex(index)
  applyWorkspaceNames()
  return workspaceByName("desktop-" .. tostring(index)) or workspaces[index]
end

local function handleWorkspaceShortcut(index, moveWindow)
  local now = hs.timer.secondsSinceEpoch()
  if lastShortcut.index == index and lastShortcut.moveWindow == moveWindow and now - lastShortcut.timestamp < 0.25 then
    return
  end
  lastShortcut = { index = index, moveWindow = moveWindow, timestamp = now }

  local workspace = workspaceForShortcutIndex(index)
  if not workspace then
    hs.alert.show("DeskPilot: nie ma biurka " .. tostring(index))
    return
  end

  if moveWindow then
    moveFocusedWindowToWorkspace(workspace.id)
  else
    goToWorkspace(workspace.id)
  end
end

local function startWorkspaceHotkeys()
  for _, hotkey in ipairs(workspaceHotkeys) do
    hotkey:delete()
  end
  workspaceHotkeys = {}

  for index, key in pairs(config.shortcutKeys or {}) do
    table.insert(workspaceHotkeys, hs.hotkey.bind(config.switchMods, key, function()
      handleWorkspaceShortcut(index, false)
    end))
    table.insert(workspaceHotkeys, hs.hotkey.bind(config.moveMods, key, function()
      handleWorkspaceShortcut(index, true)
    end))
  end
end

local function startWorkspaceShortcutTap()
  local keycodeToIndex = {}
  for index, key in pairs(config.shortcutKeys or {}) do
    local keycode = hs.keycodes.map[key]
    if keycode then
      keycodeToIndex[keycode] = index
    end
  end

  if workspaceShortcutTap then
    workspaceShortcutTap:stop()
  end

  workspaceShortcutTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    local index = keycodeToIndex[event:getKeyCode()]
    if not index then
      return false
    end

    local flags = event:getFlags()
    if not flags.ctrl or flags.cmd or flags.alt or flags.fn then
      return false
    end

    handleWorkspaceShortcut(index, flags.shift == true)
    return true
  end)
  workspaceShortcutTap:start()
end

local function workspaceSnapshot()
  applyWorkspaceNames()
  local snapshot = {}
  for _, workspace in ipairs(workspaces) do
    table.insert(snapshot, {
      index = workspace.index,
      id = workspace.id,
      name = workspace.name,
      defaultName = workspace.defaultName,
      autoName = workspace.autoName,
      spaceID = workspace.spaceID,
      missionName = workspace.missionName,
      key = workspace.key,
      screenUUID = workspace.screenUUID,
      localIndex = workspace.localIndex,
      screenName = workspace.screenName,
      spaceUUID = workspace.spaceUUID,
    })
  end
  return snapshot
end

manager = require("deskpilot_manager").new({
  workspaces = function() applyWorkspaceNames(); return workspaces end,
  refresh = function() autoNameCache.timestamp = 0; applyWorkspaceNames() end,
  managed = windowShouldBeManaged,
  groupKey = function(window) return chromeProfiles:groupKey(window) end,
  isGroupedApplication = function(window) return chromeProfiles:isChrome(window) end,
  forgetWindow = function(id) chromeProfiles:forget(id) end,
  groupKeyForWindowID = function(id, pid) return chromeProfiles:groupKeyForWindowID(id, pid) end,
  rule = existingRuleForWindow,
  preferredScreen = function(window, rule)
    return manager and manager.preferredSessionScreen and manager.preferredSessionScreen(window, rule)
  end,
  prepareFollow = function(window) return windowFollow and windowFollow:begin(window) end,
  organized = function(window, workspace)
    local rule = existingRuleForWindow(window)
    if rule then
      setRuleTarget(rule, workspace)
      rule.allowShared = false
      rule.manualMonitorSessionID = manager.sessionToken
      saveUserRules(); saveDockedRules()
    end
  end,
  layoutAdopted = function(movedSpaces)
    local changed = false
    for _, moved in ipairs(movedSpaces) do
      for _, rule in ipairs(allRules()) do
        if moved.spaceUUID and rule.spaceUUID == moved.spaceUUID and rule.screenUUID == moved.fromScreenUUID then
          rule.screenUUID = moved.toScreenUUID
          rule.spaceID = moved.spaceID
          rule.manualMonitorSessionID = manager.sessionToken
          if manager.session and rule.bundleID then
            manager.session:cancelGroup(rule.bundleID
              .. (rule.profileDirectory and ('::' .. rule.profileDirectory) or ''))
          end
          changed = true
        end
      end
    end
    if changed then saveUserRules(); saveDockedRules() end
  end,
  remember = function(window, workspace, manual)
    local rule = existingRuleForWindow(window)
    if rule then
      setRuleTarget(rule, workspace)
      if chromeProfiles:isChrome(window) then
        local profile = chromeProfiles:identify(window)
        if profile then rule.label = "Chrome · " .. profile.label end
      end
      if manual then
        rule.manualMonitorSessionID = manager.sessionToken
        rule.allowShared = true
        for _, otherRule in ipairs(allRules()) do
          local target = workspaceForRule(otherRule)
          if target and target.spaceID == workspace.spaceID then otherRule.allowShared = true end
        end
      end
      saveUserRules(); saveDockedRules()
    else
      rule = dockRuleForWindow(window, workspace)
      if rule then
        rule.allowShared = manual == true
        if manual then rule.manualMonitorSessionID = manager.sessionToken end
        addDockedRule(rule)
      end
    end
  end,
  release = function(workspace)
    for _, rule in ipairs(allRules()) do
      if (workspace.spaceUUID and rule.spaceUUID == workspace.spaceUUID)
          or (not rule.spaceUUID and workspace.spaceID and rule.spaceID == workspace.spaceID) then
        rule.spaceID = nil; rule.spaceUUID = nil; rule.workspace = nil
      end
    end
    saveUserRules(); saveDockedRules()
  end,
})

local savedSession, sessionError = require('deskpilot_session_adapter').attach(hs, manager, {
  workspaces = function() applyWorkspaceNames(); return workspaces end,
  refresh = function() autoNameCache.timestamp = 0; applyWorkspaceNames() end,
  managed = windowShouldBeManaged,
  knownProfile = function(directory)
    chromeProfiles:refresh(true)
    if chromeProfiles.loadError or not chromeProfiles.resolver then return false end
    for _, known in pairs(chromeProfiles.resolver.names) do if known == directory then return true end end
    return false
  end,
  identity = function(window)
    local app = window and window:application()
    local bundle = app and app:bundleID()
    if not bundle then return nil end
    if chromeProfiles:isChrome(window) then
      local profile = chromeProfiles:identify(window)
      if not profile then return nil end
      return { key = bundle .. '::' .. profile.directory, bundleID = bundle, profileDirectory = profile.directory }
    end
    return { key = bundle, bundleID = bundle }
  end,
})
if not savedSession then manager.lastError = sessionError end
manager:configureFollowSession(manager.sessionToken)
windowFollow = require('deskpilot_follow').new(hs, {
  managed = windowShouldBeManaged,
  blocked = function(ownSpaceSwitch) return manager:followBlocked(ownSpaceSwitch) end,
  generation = function() return manager.generation end,
  resolve = function(target)
    applyWorkspaceNames()
    for _, workspace in ipairs(workspaces) do
      if workspace.spaceUUID == target.spaceUUID and workspace.screenUUID == target.screenUUID then
        return workspace
      end
    end
  end,
})

local function panelWindowLabel(window)
  if chromeProfiles:isChrome(window) then
    local profile = chromeProfiles:identify(window)
    return profile and ("Chrome · " .. profile.label) or "Chrome · nierozpoznany profil"
  end
  local app = window:application()
  return app and cleanAppLabel(app:name()) or "Okno"
end

workspacePanel = require("deskpilot_panel").new({
  workspaces = function() applyWorkspaceNames(); return workspaces end,
  windows = function() return manager:allWindows() end,
  metadata = function()
    manager:refreshMetadata()
    if manager.metadataAt and hs.timer.secondsSinceEpoch() - manager.metadataAt < 5 then return manager.metadata end
  end,
  label = panelWindowLabel,
  previewAllowed = function(window)
    -- Showing a Chrome window does not assign it to a profile or move it.
    -- The user has enabled browser previews even before profile discovery.
    return window:application() ~= nil
  end,
  metadataLabel = function(id, pid, bundle)
    if bundle == "com.google.Chrome" then
      local binding = chromeProfiles.bindings[id]
      return binding and binding.pid == pid and ("Chrome · " .. binding.profile.label) or "Chrome · nierozpoznany profil"
    end
  end,
  managed = windowShouldBeManaged,
  status = function() return manager:status() end,
  pause = function() manager:pause() end,
  resume = function() manager:resume() end,
  toggleFollow = function() manager:setFollowEnabled(not manager.followEnabled) end,
  organize = organizeNow,
  switch = function(workspace) goToWorkspace(workspace.id) end,
  move = function(window, workspace) manager:manualMove(window, workspace) end,
  rename = renameWorkspace,
  missionControl = showMissionControlPreview,
  anchor = function() return menu:frame() end,
  settings = function()
    hs.timer.doAfter(0.12, function() settingsMenu:popupMenu(hs.mouse.absolutePosition()) end)
  end,
})
hs.hotkey.bind({ "ctrl", "alt" }, "space", showWorkspacePanel)

_G.DeskPilot = {
  showPanel = showWorkspacePanel,
  hidePanel = function() workspacePanel:hide() end,
  panelData = function() return workspacePanel:snapshot() end,
  panelStatus = function() return workspacePanel:diagnostics() end,
  refresh = refreshWorkspaceList,
  refreshMap = refreshWorkspaceMap,
  showNames = showQuickNameBubbles,
  workspaces = workspaceSnapshot,
  rules = function() return { userRules = userRules, dockedRules = dockedRules } end,
  switch = function(index) handleWorkspaceShortcut(index, false) end,
  moveFocused = function(index) handleWorkspaceShortcut(index, true) end,
  moveWindow = function(id, index)
    local window = hs.window.get(id)
    if not window then
      for _, candidate in ipairs(manager:allWindows()) do if candidate:id() == id then window = candidate; break end end
    end
    if window then return manager:manualMove(window, workspaceForShortcutIndex(index)) end
  end,
  chromeProfiles = function()
    local result = {}
    for _, window in ipairs(manager:allWindows()) do
      if chromeProfiles:isChrome(window) and window:subrole() == "AXStandardWindow" then
        local profile, reason = chromeProfiles:identify(window)
        result[#result + 1] = { windowID = window:id(),
          directory = profile and profile.directory, profile = profile and profile.label,
          reason = reason, spaces = spaces.windowSpaces(window),
          screenUUID = window:screen() and window:screen():getUUID() }
      end
    end
    return result
  end,
  status = function() return manager:status() end,
  pause = function() manager:pause() end,
  resume = function() manager:resume() end,
  occupancy = function() return manager:occupancy() end,
  cleanup = function() manager:cleanup() end,
  sessionStatus = function() return manager.session and manager.session:status() end,
  saveLayout = function() return manager.session and manager.session:saveNow() end,
  restoreLayout = function() return manager.session and manager.session:requestRestore() end,
  arrange = organizeNow,
  organize = organizeNow,
  setFollowEnabled = function(enabled) return manager:setFollowEnabled(enabled) end,
}

startWorkspaceShortcutTap()
for _, shortcut in ipairs(config.previewHotkeys or {}) do
  hs.hotkey.bind(shortcut.mods, shortcut.key, showQuickNameBubbles)
end
manager:start()
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "p", function()
  manager:pause(); hs.alert.show("DeskPilot: automatyka wstrzymana")
end)
hs.timer.doEvery(2, updateMenuTitle)
hs.alert.show(manager.paused and "DeskPilot: automatyka wstrzymana" or "DeskPilot zaladowany")
