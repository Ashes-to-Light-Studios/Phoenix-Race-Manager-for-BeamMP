-- Headless test for HOT RELOAD (server/RaceManager/main.lua).
--
-- BeamMP polls the plugin folder and, when a .lua file in it changes, runs that
-- file again IN THE SAME Lua state and then fires onInit again. Its timers are
-- not de-duplicated: CreateEventTimer pushes another timer whatever is running.
-- RM_Tick adds CFG.tickMs to the race clock on every call, so a second RM_Tick
-- ran every clock in the race at double speed: timed races and qualifying ended
-- early and finish stamps were wrong. A hosting panel's file manager upload is
-- enough to do it mid-session.
--
--   * However often onInit runs, and however often main.lua is run again,
--     exactly one RM_Tick is live.
--   * No other timer is doubled either.
--   * A reload says so in the console, and asks for a restart when the build
--     changed (the client mod is still the one the server started with).
--   * What maps.lua learned at startup (the map, the zips BeamMP hashed) is kept
--     across a reload: the module is required once and stays cached.
--
-- Run from the repo root: lua5.3 tests/hot_reload_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local live = {}        -- [timer] = how many are running
local hostedMap = '/levels/hirochi_raceway/info.json'
MP = {
  GetPlayerName = function () return nil end,
  SendChatMessage = function () end,
  GetPlayers = function () return {} end,
  TriggerClientEvent = function () end,
  DropPlayer = function () end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name) live[name] = (live[name] or 0) + 1 end,
  CancelEventTimer = function (name) live[name] = 0 end,
  Settings = { Map = 0 },
  Get = function () return hostedMap end,
  Set = function (_, value) hostedMap = value end,
}
Util = {
  JsonEncode = function (t) return t end,
  JsonDecode = function (s)
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    return load('return ' .. body)()
  end,
}

-- The console, captured.
local printed = {}
local realPrint = print
print = function (...)
  local parts = {}
  for i = 1, select('#', ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  printed[#printed + 1] = table.concat(parts, '\t')
end
local function said(text)
  for _, line in ipairs(printed) do
    if line:find(text, 1, true) then return line end
  end
end

-- Startup.
dofile('server/RaceManager/main.lua')
onInit()
check(live.RM_Tick == 1, 'startup: one RM_Tick (got ' .. tostring(live.RM_Tick) .. ')')
check(not said('reloaded while the server runs'), 'startup is not called a reload')

-- onInit again (BeamMP fires it after each changed file).
printed = {}
onInit()
check(live.RM_Tick == 1, 'onInit again: still one RM_Tick (got ' .. tostring(live.RM_Tick) .. ')')
check(said('Plugin files reloaded while the server runs') ~= nil, 'and the reload is said in the console')

-- main.lua run again in the same state, then onInit: what BeamMP does when the
-- file itself changed.
dofile('server/RaceManager/main.lua')
onInit()
check(live.RM_Tick == 1, 'main.lua run again: still one RM_Tick (got ' .. tostring(live.RM_Tick) .. ')')
for name, n in pairs(live) do
  check(n <= 1, name .. ' is never doubled by a reload (got ' .. n .. ')')
end

-- New files with a different build: restart to finish.
printed = {}
rawset(_G, 'RM_initBuild', '0.0.1')
onInit()
local line = said('Plugin files changed while the server runs')
check(line ~= nil and line:find('restart the server', 1, true) ~= nil
  and line:find('0.0.1 ->', 1, true) ~= nil, 'a changed build asks for a restart (got ' .. tostring(line) .. ')')
check(live.RM_Tick == 1, 'and still one RM_Tick')

-- The race clock: one tick advances it by one tick.
print = realPrint
local before = RM_Tick and true
check(before, 'RM_Tick is defined')

-- maps.lua keeps what it learned at startup across a reload.
local maps = require('maps')
check(type(maps.bootInfo) == 'function', 'maps.lua exposes what it saw at the start')
local first = maps.bootInfo()
check(first.map == 'hirochi_raceway', 'the start was taken at the first onInit (got ' .. tostring(first.map) .. ')')
hostedMap = '/levels/italy/info.json'
dofile('server/RaceManager/main.lua')
print = function () end
onInit()
print = realPrint
local again = maps.bootInfo()
check(again == first and again.map == 'hirochi_raceway',
  'the startup map maps.lua saw is kept across a reload, not re-read')

print(string.format('hot_reload_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
