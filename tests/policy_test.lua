-- Run with: lua mac-deskpilot/tests/policy_test.lua (or from any working directory).
local source = debug.getinfo(1, "S").source:sub(2)
local directory = source:match("^(.*[/\\])") or "./"
local P = dofile(directory .. "../deskpilot_policy.lua")
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

local function ids(actual, expected)
  equal(#actual, #expected)
  for index, id in ipairs(expected) do equal(actual[index].spaceID, id) end
end

local function workspace(id, uuid, screen, localIndex, index)
  return { spaceID = id, spaceUUID = uuid, screenUUID = screen, localIndex = localIndex, index = index }
end

local a1 = workspace(101, "a-first", "screen-a", 1, 5)
local a2 = workspace(102, "a-second", "screen-a", 2, 6)
local a3 = workspace(103, "a-third", "screen-a", 3, 7)
local b1 = workspace(201, "b-first", "screen-b", 1, 1)
local b2 = workspace(202, "b-second", "screen-b", 2, 2)
local all = { a1, a2, a3, b1, b2 }

test("UUID survives changed numbering and runtime ID", function()
  equal(P.resolve({ spaceUUID = "a-second", spaceID = 2, screenUUID = "screen-a", index = 99 }, all), a2)
end)

test("UUID takes precedence over another valid numeric ID", function()
  equal(P.resolve({ spaceUUID = "a-first", spaceID = 102, screenUUID = "screen-a" }, all), a1)
end)

test("missing UUID never falls back to recycled runtime ID", function()
  equal(P.resolve({ spaceUUID = "removed", spaceID = 102, screenUUID = "screen-a" }, all), nil)
  equal(P.resolve({ spaceUUID = "a-second", spaceID = 102, screenUUID = "screen-a" }, {
    workspace(102, nil, "screen-a", 2, 6),
  }), nil)
end)

test("missing and changed screens never match", function()
  equal(P.resolve({ spaceUUID = "a-first", spaceID = 101, screenUUID = "missing-screen" }, all), nil)
  equal(P.resolve({ spaceUUID = "a-first", spaceID = 101, screenUUID = "screen-b" }, all), nil)
  equal(P.resolve({ spaceUUID = "a-first", spaceID = 101 }, all), nil)
  equal(P.resolve({ spaceUUID = "a-first", spaceID = 101, screenUUID = "" }, all), nil)
end)

test("legacy ID requires its original screen", function()
  equal(P.resolve({ spaceID = 101, screenUUID = "screen-a" }, all), a1)
  equal(P.resolve({ spaceID = 101, screenUUID = "screen-b" }, all), nil)
end)

test("desktop labels cannot resolve a workspace", function()
  equal(P.resolve({ index = 5, desktopNumber = 5, screenUUID = "screen-a" }, all), nil)
  equal(P.resolve({ spaceID = 999, index = 5, desktopNumber = 5, screenUUID = "screen-a" }, all), nil)
end)

test("firstFree searches requested screen in local order", function()
  local shuffled = { b1, a3, a2, a1, b2 }
  equal(P.firstFree(shuffled, "screen-a", { [101] = false, [102] = false, [103] = false, [201] = false }, {}), a1)
  equal(shuffled[2], a3) -- Decisions do not mutate the caller's list.
end)

test("occupied and unknown Spaces are not free", function()
  equal(P.firstFree(all, "screen-a", { [101] = true, [103] = false }, {}), a3)
  equal(P.firstFree(all, "screen-a", {}, {}), nil)
  equal(P.firstFree(all, "screen-a", { [101] = 0 }, {}), nil)
end)

test("reserved Spaces are not free", function()
  equal(P.firstFree(all, "screen-a", { [101] = false, [102] = false }, { [101] = true }), a2)
  equal(P.firstFree(all, "screen-a", { [101] = false }, { [101] = true }), nil)
end)

test("firstFree never borrows another monitor", function()
  equal(P.firstFree(all, "screen-a", { [201] = false }, {}), nil)
  equal(P.firstFree(all, "missing-screen", { [201] = false }, {}), nil)
  equal(P.firstFree(all, nil, { [201] = false }, {}), nil)
end)

local empty = { [101] = false, [102] = false, [103] = false, [201] = false, [202] = false }
local old = { [101] = 10, [102] = 10, [103] = 10, [201] = 10, [202] = 10 }

test("cleanup keeps first user Space on every entirely empty monitor", function()
  ids(P.cleanupCandidates(all, empty, {}, {}, old, 100, 30), { 103, 102, 202 })
end)

test("cleanup sorts backwards locally without changing caller order", function()
  local shuffled = { a2, a1, a3, b2, b1 }
  ids(P.cleanupCandidates(shuffled, empty, {}, {}, old, 100, 30), { 103, 102, 202 })
  equal(shuffled[1], a2)
end)

test("fullscreen active Space still leaves one user Space per monitor", function()
  ids(P.cleanupCandidates(all, empty, {}, { [999] = true }, old, 100, 30), { 103, 102, 202 })
  ids(P.cleanupCandidates({ a1, b1 }, empty, {}, { [999] = true }, old, 100, 30), {})
end)

test("active and reserved Spaces are protected", function()
  ids(P.cleanupCandidates(all, empty, { [102] = true }, { [103] = true, [202] = true }, old, 100, 30), { 101, 201 })
end)

test("cleanup removes interior gaps without moving occupied Spaces", function()
  local occupied = { [101] = true, [102] = false, [103] = true, [201] = true, [202] = false }
  ids(P.cleanupCandidates(all, occupied, {}, {}, old, 100, 30), { 102, 202 })
end)

test("cleanup never treats unknown occupancy as empty", function()
  ids(P.cleanupCandidates(all, { [102] = false }, {}, {}, old, 100, 30), { 102 })
  ids(P.cleanupCandidates(all, {}, {}, {}, old, 100, 30), {})
end)

test("cleanup honors grace including exact boundary", function()
  local since = { [101] = 71, [102] = 70, [103] = 101, [201] = 71, [202] = 71 }
  ids(P.cleanupCandidates(all, empty, {}, {}, since, 100, 30), { 102 })
  ids(P.cleanupCandidates(all, empty, {}, {}, {}, 100, 30), {})
end)

test("cleanup requires trustworthy time inputs", function()
  ids(P.cleanupCandidates(all, empty, {}, {}, old, nil, 30), {})
  ids(P.cleanupCandidates(all, empty, {}, {}, old, 100, -1), {})
end)

test("empty inputs are harmless", function()
  equal(P.resolve(nil, nil), nil)
  equal(P.firstFree(nil, "screen-a", nil, nil), nil)
  ids(P.cleanupCandidates(nil, nil, nil, nil, nil, 100, 30), {})
end)

print("Passed " .. passed .. " policy tests")
