-- Pure Chrome profile resolution. The caller supplies profile.info_cache from
-- Chrome's Local State and a window title; this module does not read files or UI.
local P = {}
local Resolver = {}
Resolver.__index = Resolver

local function nonempty(value)
  return type(value) == "string" and value:find("%S") ~= nil
end

local function trim(value)
  return value:match("^%s*(.-)%s*$")
end

local function stringValue(value)
  return type(value) == "string" and value or ""
end

local function asciiLower(value)
  return (value:gsub("[A-Z]", string.lower))
end

-- Match Chromium's ProfileAttributesEntry::GetName(), including disambiguation
-- across default-named profiles. Local names and Gaia names are not aliases:
-- accepting either independently could select a different real profile.
-- https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/profiles/profile_attributes_entry.cc
local function displayName(entry, entries)
  if entry.gaiaName == "" then return entry.localName end
  if asciiLower(entry.gaiaName) == asciiLower(entry.localName) then return entry.gaiaName end
  local showLocal = not entry.defaultName or entry.enterpriseName ~= ""
  if not showLocal then
    for _, other in ipairs(entries) do
      if other ~= entry and other.gaiaName == entry.gaiaName then
        if asciiLower(other.gaiaName) == asciiLower(other.localName) or other.defaultName then
          showLocal = true
          break
        end
      end
    end
  end
  if showLocal then return entry.gaiaName .. " (" .. entry.localName .. ")" end
  return entry.gaiaName
end

local function profileSuffix(title)
  if type(title) ~= "string" then return nil, "invalid_title" end

  -- A page title may itself mention Chrome or a profile. Only the final Chrome
  -- marker's suffix is eligible; never fall back to an earlier occurrence.
  local position, lastEnd = 1, nil
  while true do
    local first, last = title:find("Google Chrome", position, true)
    if not first then break end
    lastEnd, position = last, last + 1
  end
  if not lastEnd then return nil, "missing_profile_suffix" end

  local tail = trim(title:sub(lastEnd + 1))
  -- Literal comparisons preserve UTF-8 dashes; a Lua pattern character class
  -- would treat their individual bytes as separate characters.
  for _, separator in ipairs({ "-", "–", "—", "|", ":" }) do
    if tail:sub(1, #separator) == separator then
      local suffix = trim(tail:sub(#separator + 1))
      if suffix ~= "" then return suffix end
      break
    end
  end
  return nil, "missing_profile_suffix"
end

function P.new(infoCache)
  local names, entries = {}, {}
  local function add(label, directory)
    if not nonempty(label) then return end
    local previous = names[label]
    if previous == nil or previous == directory then
      names[label] = directory
    else
      -- false is a collision, including any subsequent third profile. Never
      -- pick whichever profile happened to appear first in an unordered table.
      names[label] = false
    end
  end

  if type(infoCache) == "table" then
    for directory, profile in pairs(infoCache) do
      if nonempty(directory) and type(profile) == "table" then
        local enterpriseName = stringValue(profile.enterprise_label)
        local localName = enterpriseName ~= "" and enterpriseName or stringValue(profile.name)
        local gaiaName = stringValue(profile.gaia_given_name)
        if gaiaName == "" then gaiaName = stringValue(profile.gaia_name) end
        if gaiaName == "" then gaiaName = stringValue(profile.oidc_identity_name) end
        if nonempty(localName) then
          entries[#entries + 1] = {
            directory = directory,
            localName = localName,
            gaiaName = gaiaName,
            enterpriseName = enterpriseName,
            defaultName = profile.is_using_default_name == true,
          }
        end
      end
    end
  end
  for _, entry in ipairs(entries) do add(displayName(entry, entries), entry.directory) end
  return setmetatable({ names = names }, Resolver)
end

function Resolver:resolve(title)
  local suffix, reason = profileSuffix(title)
  if not suffix then return nil, reason end
  local directory = self.names[suffix]
  if directory == false then return nil, "ambiguous" end
  if directory == nil then return nil, "unknown_profile" end
  -- The directory is stable across page changes and profile renames. The label
  -- is presentation only and must never be used as the workspace identity.
  return { directory = directory, label = suffix }
end

return P
