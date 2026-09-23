-- Run with: lua mac-deskpilot/tests/chrome_profiles_test.lua
local source = debug.getinfo(1, "S").source:sub(2)
local directory = source:match("^(.*[/\\])") or "./"
local P = dofile(directory .. "../deskpilot_chrome_profiles.lua")
local passed = 0

local function test(name, run)
  local ok, failure = pcall(run)
  if not ok then error(name .. ": " .. tostring(failure), 0) end
  passed = passed + 1
  print("ok " .. passed .. " - " .. name)
end

local function equal(actual, expected)
  assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function cache()
  return {
    Default = { name = "[Główny]", gaia_given_name = "Michał", gaia_name = "Michał Kowalski" },
    ["Profile 51"] = { name = "Michał" },
    ["Profile 11"] = { name = "WGB" },
    ["Profile 42"] = { name = "[ADM MASTERCOMP]" },
    ["Profile 47"] = { name = "BNG" },
    ["Profile 54"] = { name = "BNG" },
  }
end

local resolver = P.new(cache())
local function resolves(title, expectedDirectory, expectedLabel, subject)
  local result, reason = (subject or resolver):resolve(title)
  assert(result, tostring(reason))
  equal(reason, nil)
  equal(result.directory, expectedDirectory)
  equal(result.label, expectedLabel)
end

local function unresolved(title, expectedReason, subject)
  local result, reason = (subject or resolver):resolve(title)
  equal(result, nil)
  equal(reason, expectedReason)
end

test("qualified main profile remains separate from the Michal profile", function()
  resolves("Strona – Google Chrome – Michał ([Główny])", "Default", "Michał ([Główny])")
  resolves("Strona – Google Chrome – Michał", "Profile 51", "Michał")
end)

test("exact local profile names and brackets resolve", function()
  unresolved("Strona – Google Chrome – [Główny]", "unknown_profile")
  resolves("Strona – Google Chrome – WGB", "Profile 11", "WGB")
  resolves("Strona – Google Chrome – [ADM MASTERCOMP]", "Profile 42", "[ADM MASTERCOMP]")
end)

test("all supported literal separators preserve UTF-8 names", function()
  for _, separator in ipairs({ "-", "–", "—", "|", ":" }) do
    resolves("Strona — Google Chrome " .. separator .. " Michał", "Profile 51", "Michał")
  end
end)

test("formatting whitespace does not become part of a label", function()
  resolves("Google Chrome   —  Michał ([Główny])  ", "Default", "Michał ([Główny])")
  resolves("Google Chrome:WGB", "Profile 11", "WGB")
end)

test("page and tab title changes keep the profile directory stable", function()
  resolves("Poczta – Google Chrome – WGB", "Profile 11", "WGB")
  resolves("Kalendarz | Michał ([Główny]) – Google Chrome – WGB", "Profile 11", "WGB")
end)

test("profile names in the page title do not identify a window", function()
  unresolved("Michał ([Główny]) – Google Chrome", "missing_profile_suffix")
  unresolved("WGB — Michał — [ADM MASTERCOMP]", "missing_profile_suffix")
  unresolved("Michał – Google Chrome – Nieznany", "unknown_profile")
end)

test("only the final Chrome marker can provide the suffix", function()
  resolves("Google Chrome – Michał – Google Chrome – WGB", "Profile 11", "WGB")
  unresolved("Google Chrome – WGB – Google Chrome", "missing_profile_suffix")
  unresolved("Google Chrome – WGB – Google Chrome – Nieznany", "unknown_profile")
end)

test("absent or empty suffixes remain unresolved", function()
  for _, title in ipairs({ "", "Google Chrome", "Google Chrome   ", "Google Chrome – ", "Google Chrome :" }) do
    unresolved(title, "missing_profile_suffix")
  end
end)

test("unsupported separators and extra suffix text are not guessed", function()
  unresolved("Google Chrome / WGB", "missing_profile_suffix")
  unresolved("Google Chrome WGB", "missing_profile_suffix")
  unresolved("Google Chromeless – WGB", "missing_profile_suffix")
  unresolved("Google Chrome – WGB – coś innego", "unknown_profile")
end)

test("matching is exact and case sensitive", function()
  unresolved("Google Chrome – wgb", "unknown_profile")
  unresolved("Google Chrome – [ADM", "unknown_profile")
  unresolved("Google Chrome – Michal", "unknown_profile")
  unresolved("Google Chrome – Michał [Główny]", "unknown_profile")
end)

test("duplicate profile names are explicitly ambiguous", function()
  unresolved("Google Chrome – BNG", "ambiguous")
  local duplicate = P.new({ a = { name = "BNG" }, b = { name = "BNG" }, c = { name = "BNG" } })
  unresolved("Google Chrome – BNG", "ambiguous", duplicate)
end)

test("qualified duplicates resolve only with a unique complete display form", function()
  local qualified = P.new({ a = { name = "BNG", gaia_given_name = "Anna" }, b = { name = "BNG", gaia_given_name = "Piotr" } })
  resolves("Google Chrome – Anna (BNG)", "a", "Anna (BNG)", qualified)
  resolves("Google Chrome – Piotr (BNG)", "b", "Piotr (BNG)", qualified)
  unresolved("Google Chrome – BNG", "unknown_profile", qualified)
  local duplicate = P.new({ a = { name = "BNG", gaia_given_name = "Anna" }, b = { name = "BNG", gaia_given_name = "Anna" } })
  unresolved("Google Chrome – Anna (BNG)", "ambiguous", duplicate)
end)

test("collisions between qualified and literal names are ambiguous", function()
  local collision = P.new({ a = { name = "BNG", gaia_given_name = "Anna" }, b = { name = "Anna (BNG)" } })
  unresolved("Google Chrome – Anna (BNG)", "ambiguous", collision)
end)

test("full Gaia name is used only when the given name is absent", function()
  unresolved("Google Chrome – Michał Kowalski ([Główny])", "unknown_profile")
  unresolved("Google Chrome – Michał Kowalski", "unknown_profile")
  local full = P.new({ Default = { name = "[Główny]", gaia_name = "Michał Kowalski" } })
  resolves("Google Chrome – Michał Kowalski ([Główny])", "Default", "Michał Kowalski ([Główny])", full)
end)

test("equal Gaia fields in one profile are not an ambiguity", function()
  local single = P.new({ Default = { name = "Praca", gaia_given_name = "Michał", gaia_name = "Michał" } })
  resolves("Google Chrome – Michał (Praca)", "Default", "Michał (Praca)", single)
end)

test("a local-name alias cannot capture another profile's actual display name", function()
  local distinct = P.new({
    a = { name = "Praca", gaia_given_name = "Michał" },
    b = { name = "Praca" },
  })
  resolves("Google Chrome – Michał (Praca)", "a", "Michał (Praca)", distinct)
  resolves("Google Chrome – Praca", "b", "Praca", distinct)
  unresolved("Google Chrome – Michał", "unknown_profile", distinct)
end)

test("a unique default-named profile uses only the Gaia display name", function()
  local default = P.new({ a = { name = "Person 1", gaia_given_name = "Michał", is_using_default_name = true } })
  resolves("Google Chrome – Michał", "a", "Michał", default)
  unresolved("Google Chrome – Michał (Person 1)", "unknown_profile", default)
  unresolved("Google Chrome – Person 1", "unknown_profile", default)
end)

test("shared Gaia names qualify both default-named profiles", function()
  local defaults = P.new({
    a = { name = "Person 1", gaia_given_name = "Michał", is_using_default_name = true },
    b = { name = "Person 2", gaia_given_name = "Michał", is_using_default_name = true },
  })
  resolves("Google Chrome – Michał (Person 1)", "a", "Michał (Person 1)", defaults)
  resolves("Google Chrome – Michał (Person 2)", "b", "Michał (Person 2)", defaults)
  unresolved("Google Chrome – Michał", "unknown_profile", defaults)
end)

test("Gaia-equal local name forces another default profile to be qualified", function()
  local mixed = P.new({
    a = { name = "Person 1", gaia_given_name = "Michał", is_using_default_name = true },
    b = { name = "Michał", gaia_given_name = "Michał" },
  })
  resolves("Google Chrome – Michał (Person 1)", "a", "Michał (Person 1)", mixed)
  resolves("Google Chrome – Michał", "b", "Michał", mixed)
end)

test("custom-named counterpart does not force a default name into its label", function()
  local mixed = P.new({
    a = { name = "Person 1", gaia_given_name = "Michał", is_using_default_name = true },
    b = { name = "Praca", gaia_given_name = "Michał", is_using_default_name = false },
  })
  resolves("Google Chrome – Michał", "a", "Michał", mixed)
  resolves("Google Chrome – Michał (Praca)", "b", "Michał (Praca)", mixed)
  unresolved("Google Chrome – Michał (Person 1)", "unknown_profile", mixed)
end)

test("ASCII case comparison chooses the display form without adding aliases", function()
  local same = P.new({ a = { name = "matt", gaia_given_name = "Matt" } })
  resolves("Google Chrome – Matt", "a", "Matt", same)
  unresolved("Google Chrome – matt", "unknown_profile", same)
  unresolved("Google Chrome – Matt (matt)", "unknown_profile", same)
  local unicode = P.new({ a = { name = "Łukasz", gaia_given_name = "łukasz" } })
  resolves("Google Chrome – łukasz (Łukasz)", "a", "łukasz (Łukasz)", unicode)
end)

test("Gaia collisions are case-sensitive across profiles", function()
  local distinct = P.new({
    a = { name = "Person 1", gaia_given_name = "Matt", is_using_default_name = true },
    b = { name = "Person 2", gaia_given_name = "matt", is_using_default_name = true },
  })
  resolves("Google Chrome – Matt", "a", "Matt", distinct)
  resolves("Google Chrome – matt", "b", "matt", distinct)
end)

test("enterprise label overrides the local name and forces qualification", function()
  local enterprise = P.new({ a = {
    name = "Person 1", enterprise_label = "Firma", gaia_given_name = "Michał", is_using_default_name = true,
  } })
  resolves("Google Chrome – Michał (Firma)", "a", "Michał (Firma)", enterprise)
  unresolved("Google Chrome – Michał", "unknown_profile", enterprise)
  unresolved("Google Chrome – Firma", "unknown_profile", enterprise)
  unresolved("Google Chrome – Michał (Person 1)", "unknown_profile", enterprise)
  local localOnly = P.new({ a = { name = "Person 1", enterprise_label = "Firma" } })
  resolves("Google Chrome – Firma", "a", "Firma", localOnly)
end)

test("OIDC identity is the last display-name fallback", function()
  local oidc = P.new({ a = { name = "Praca", oidc_identity_name = "Michał" } })
  resolves("Google Chrome – Michał (Praca)", "a", "Michał (Praca)", oidc)
  local gaia = P.new({ a = { name = "Praca", gaia_name = "Anna", oidc_identity_name = "Michał" } })
  resolves("Google Chrome – Anna (Praca)", "a", "Anna (Praca)", gaia)
  unresolved("Google Chrome – Michał (Praca)", "unknown_profile", gaia)
end)

test("email and account identifiers never provide profile aliases", function()
  local single = P.new({ Default = { name = "Praca", user_name = "someone@example.invalid", email = "other@example.invalid", gaia_id = "123456" } })
  unresolved("Google Chrome – someone@example.invalid", "unknown_profile", single)
  unresolved("Google Chrome – other@example.invalid", "unknown_profile", single)
  unresolved("Google Chrome – 123456", "unknown_profile", single)
end)

test("incognito suffixes are not stripped or assigned by guessing", function()
  unresolved("Google Chrome – Incognito", "unknown_profile")
  unresolved("Google Chrome – Tryb incognito", "unknown_profile")
  unresolved("Google Chrome – Michał (Incognito)", "unknown_profile")
  unresolved("Google Chrome – WGB – Incognito", "unknown_profile")
end)

test("profile rename keeps identity and invalidates the old display name", function()
  local updated = cache()
  updated["Profile 11"].name = "WGB Praca"
  local renamed = P.new(updated)
  resolves("Google Chrome – WGB Praca", "Profile 11", "WGB Praca", renamed)
  unresolved("Google Chrome – WGB", "unknown_profile", renamed)
end)

test("input is snapshotted and successful results are independent tables", function()
  local input = cache()
  local snapshot = P.new(input)
  input["Profile 11"].name = "Zmieniona"
  local first = snapshot:resolve("Google Chrome – WGB")
  first.directory, first.label = "Wrong", "Wrong"
  resolves("Google Chrome – WGB", "Profile 11", "WGB", snapshot)
end)

test("malformed cache entries cannot provide aliases", function()
  local malformed = P.new({
    Default = { gaia_given_name = "Sam" },
    ["Profile 1"] = { name = "  " },
    ["Profile 2"] = false,
    ["Profile 3"] = { name = 123 },
    [42] = { name = "Numeric directory" },
    [""] = { name = "Empty directory" },
    ["Profile 4"] = { name = "Valid", gaia_name = {}, gaia_given_name = false },
  })
  unresolved("Google Chrome – Sam", "unknown_profile", malformed)
  unresolved("Google Chrome – 123", "unknown_profile", malformed)
  unresolved("Google Chrome – Numeric directory", "unknown_profile", malformed)
  unresolved("Google Chrome – Empty directory", "unknown_profile", malformed)
  resolves("Google Chrome – Valid", "Profile 4", "Valid", malformed)
end)

test("missing cache and invalid title inputs fail closed", function()
  unresolved("Google Chrome – WGB", "unknown_profile", P.new(nil))
  unresolved("Google Chrome – WGB", "unknown_profile", P.new(false))
  unresolved(nil, "invalid_title")
  unresolved({}, "invalid_title")
  unresolved(42, "invalid_title")
end)

print("Passed " .. passed .. " Chrome profile tests")
