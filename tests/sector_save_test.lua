-- Headless test for SECTORS ON THE SERVER (race.sanitizeSectors and the
-- layout save in server/RaceManager/main.lua).
--
-- The server times nothing by sectors: each client does. What it owns is the
-- layout, so the sectors have to survive the save, the file and a restart, and
-- reach every client with RM_ApplyLayout. A sector that does not fit the route
-- is turned away rather than repaired, the way a branch gate is: moved to
-- another corner it is not the sector anybody saved.
--
-- Run from the repo root: lua5.3 tests/sector_save_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- A map of its own, so a run starts from no layouts and leaves the others be.
local MAP_FILE = 'Resources/Server/RaceManager/Data/Race Layout/sector_test.json'
os.remove(MAP_FILE)

local applied, held, lastChat = nil, nil, nil
MP = {
  GetPlayerName = function (pid) return pid == 0 and 'Admin' or nil end,
  SendChatMessage = function (_, msg) lastChat = msg end,
  GetPlayers = function () return { [0] = 'Admin' } end,
  TriggerClientEvent = function (_, event, payload)
    if event == 'RM_ApplyLayout' then applied = payload end
    if event == 'RM_SaveHeld' then held = payload end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
  RemoveVehicle = function () end,
  Settings = { Map = 0 },
  Get = function () return '/levels/sector_test/info.json' end,
}
Util = {
  JsonEncode = function (t) return t end,
  JsonDecode = function (s)
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    return load('return ' .. body)()
  end,
}

local function boot()
  dofile('server/RaceManager/main.lua')
  onInit()
  RM_onLogin(0, '{"password":"phoenix"}')
  RM_onPlayerJoin(0)
end

-- Six gates: CP 1 to CP 5 and the line. A sector end is 0..5, 0 the line.
local GATES = {}
for i = 1, 6 do GATES[i] = string.format('{"x":0,"y":%d,"z":0,"hx":0,"hy":1}', i * 100) end
local function save(name, sectors, extra)
  RM_onSaveLayout(0, '{"name":"' .. name .. '","width":20,"checkpoints":['
    .. table.concat(GATES, ',') .. ']'
    .. (sectors and (',"sectors":' .. sectors) or '') .. (extra or '') .. '}')
end
local function loaded(name)
  applied = nil
  RM_onLoadLayout(0, '{"name":"' .. name .. '"}')
  return applied
end
local THREE = '[{"from":0,"to":2},{"from":2,"to":5},{"from":5,"to":0}]'

boot()

-- ---------------------------------------------------------------------------
-- 1. SAVED, LOADED, AND STILL THERE AFTER A RESTART
-- ---------------------------------------------------------------------------
save('Sectored', THREE)
local l = loaded('Sectored')
check(l and type(l.sectors) == 'table' and #l.sectors == 3,
  'the three sectors go out with the layout')
check(l and l.sectors[3].from == 5 and l.sectors[3].to == 0, 'ends and all, the line as 0')

boot()
l = loaded('Sectored')
check(l and l.sectors and #l.sectors == 3, 'and they are read back from the file after a restart')

save('Plain', nil)
l = loaded('Plain')
check(l and l.sectors == nil, 'a layout saved without sectors has none')

-- ---------------------------------------------------------------------------
-- 2. A SECTOR THAT DOES NOT FIT IS REFUSED, AND THE SAVED ONE KEPT
-- ---------------------------------------------------------------------------
local function refused(sectors, why)
  lastChat = nil
  save('Sectored', sectors)
  -- Read before the load below, which says something of its own.
  check(lastChat and lastChat:find('sectors', 1, true) ~= nil, why .. ': the admin is told')
  local kept = loaded('Sectored')
  check(kept and kept.sectors and #kept.sectors == 3 and kept.sectors[1].to == 2,
    why .. ': the save is refused and the stored sectors stand')
end
refused('[{"from":3,"to":3}]', 'one starting and ending at the same gate')
refused('[{"from":0,"to":6}]', 'one naming the line by its number')
refused('[{"from":-1,"to":2}]', 'a negative gate')
refused('[{"from":0}]', 'one with an end missing')
refused('"S1"', 'sectors that are not a list')
local many = {}
for i = 1, 21 do many[i] = '{"from":0,"to":1}' end
refused('[' .. table.concat(many, ',') .. ']', 'more than 20')

-- ---------------------------------------------------------------------------
-- 3. AN OLDER CLIENT CANNOT DROP THEM WITHOUT ASKING
-- ---------------------------------------------------------------------------
-- A client from before sectors sends none. Saving over a layout that has them
-- would delete them, so it is held for the admin, as for every other section.
held = nil
save('Sectored', nil)
check(held and held.lost and held.lost.sectors == 3,
  'a save that would drop the sectors is held, naming them')
l = loaded('Sectored')
check(l and l.sectors and #l.sectors == 3, 'and nothing is written until the admin says so')

save('Sectored', nil, ',"confirmDrop":true')
l = loaded('Sectored')
check(l and l.sectors == nil, 'confirmed, the sectors go')

os.remove(MAP_FILE)
print(string.format('sector_save_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
