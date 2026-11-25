-- Headless test for NO CAR, NO GRID in server/RaceManager/main.lua (Lua 5.3,
-- same as BeamMP). Run from the repo root: lua5.3 tests/no_car_test.lua
--
-- A player with no car spawned is left out of every field that forms: the race
-- and qualifying grids, the heat draw, a derby. A car spawned LATER does not
-- put them in: they press Join (the back of the grid, placed at once), or an
-- admin places them, or adds them with or without a car until they leave.
-- Until then they are on no board: no place, unlisted, not in the results.
--
-- BeamMP is asked through MP.GetPlayerVehicles, faked here per player id. A
-- server without it counts everyone as in a car (fails open), which is what
-- every other suite, whose fake MP lacks it, relies on.

local connected = { [1] = 'Alice', [2] = 'Bob', [3] = 'Cara', [4] = 'Dan' }
local PICKUP = '{"jbm":"pickup","vcf":{"parts":{}}}'
local cars = {          -- [pid] = what MP.GetPlayerVehicles returns
  [1] = { [0] = PICKUP }, [2] = { [0] = PICKUP }, [3] = { [0] = PICKUP },
}
local lastState  = nil
local lastDerby  = nil
local chats      = {}   -- { to, msg }
local gridAssign = {}   -- [pid] = last slot assigned (false = stood down)
local resultsText = nil
local timers     = {}
local hostedMap  = '/levels/gridmap_v2/info.json'

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) chats[#chats + 1] = { to = target, msg = msg } end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  GetPlayerVehicles = function (pid) return cars[pid] end,
  RemoveVehicle = function () end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then lastState = payload end
    if event == 'RM_DerbyUpdate' then lastDerby = payload end
    if event == 'RM_GridAssign' then gridAssign[target] = payload.slot or false end
    if event == 'RM_ResultsFile' then resultsText = payload.text end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name) timers[name] = true end,
  CancelEventTimer = function (name) timers[name] = nil end,
  Settings = { Map = 0 },
  Get = function () return hostedMap end,
}

Util = {
  JsonEncode = function (t) return t end,
  JsonDecode = function (s)
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    return load('return ' .. body)()
  end,
}

-- A Garage List left by another suite would police the spawns below.
local GARAGE_FILE = 'Resources/Server/PhoenixRM Server/Data/garage.json'
os.remove(GARAGE_FILE)

dofile('server/RaceManager/main.lua')

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function driver(name)
  for _, d in ipairs(lastState.drivers) do
    if d.name == name then return d end
  end
end
local function toldTo(pid, text)
  for _, c in ipairs(chats) do
    if c.to == pid and c.msg:find(text, 1, true) then return true end
  end
  return false
end
local function spawn(pid, packet)
  packet = packet or PICKUP
  cars[pid] = cars[pid] or {}
  cars[pid][0] = packet
  return RM_onVehicleSpawn(pid, 0, packet)
end
-- BeamMP may still list the car while onVehicleDeleted runs: the handler is
-- given its id to leave out, so the fake keeps it here on purpose.
local function delete(pid)
  RM_onVehicleDeleted(pid, 0)
end
local function gone(pid)
  cars[pid] = nil
  RM_onVehicleDeleted(pid, 0)
end

onInit()
RM_onLogin(1, '{"password":"phoenix"}'); RM_onSetReadyCheck(1, '{"on":false}')
for id in pairs(connected) do RM_onPlayerJoin(id) end

-- ===========================================================================
-- 1. Joining with no car: out of the field, and on no board
-- ===========================================================================
check(lastState.entrants == 3, 'three in a car are the field (got ' .. tostring(lastState.entrants) .. ')')
check(driver('Dan').noCar == true, 'Dan has no car, and the row says so')
check(driver('Dan').unlisted == true, 'and he is on no board')
check(driver('Alice').noCar == nil and driver('Alice').unlisted == nil, 'Alice, in a car, is listed')

-- ===========================================================================
-- 2. The grid forms without him, and he is told
-- ===========================================================================
RM_onGenerateGrid(1)
check(lastState.phase == 'grid', 'the grid formed')
check(driver('Dan').gridPos == nil and driver('Dan').status == 'waiting', 'Dan has no slot')
check(gridAssign[4] == false, 'and is told to stand down')
check(driver('Dan').position == nil, 'and no place on the board')
check(driver('Alice').position and driver('Bob').position and driver('Cara').position,
  'the three in the field are placed')
check(lastState.drivers[#lastState.drivers].name == 'Dan', 'his row goes out last, after the board')
check(toldTo(4, 'No car spawned'), 'Dan is told why he is not on the grid')
check(toldTo(1, 'Left off the grid with no car: Dan'), 'and the admin is told who was left off')
check(driver('Dan').joinable == nil, 'with no car he cannot Join yet')

-- Join with no car: refused.
RM_onJoinField(4, '')
check(driver('Dan').gridPos == nil and toldTo(4, 'Spawn a car first'), 'Join with no car is refused')

-- ===========================================================================
-- 3. A car spawned late is NOT an entry: Join is
-- ===========================================================================
check(spawn(4) == nil, 'the spawn itself is allowed')
check(driver('Dan').noCar == nil, 'Dan has a car now')
check(driver('Dan').gridPos == nil and driver('Dan').status == 'waiting',
  'and is still not on the grid: spawning does not put him in')
check(driver('Dan').unlisted == true, 'nor on the board')
check(driver('Dan').joinable == true, 'but he can press Join')

-- Somebody else's Join is an admin's Place: refused from a driver.
RM_onJoinField(3, '{"pid":4}')
check(driver('Dan').gridPos == nil, 'a driver cannot Place somebody else')

RM_onJoinField(4, '')
check(driver('Dan').status == 'gridded' and driver('Dan').gridPos == 4,
  'Join puts him on the back of the grid, placed (got ' .. tostring(driver('Dan').gridPos) .. ')')
check(gridAssign[4] == 4, 'and sends him to the slot')
check(driver('Dan').unlisted == nil and driver('Dan').joinable == nil, 'and he is on the board now')
check(driver('Dan').position ~= nil, 'with a place')

-- ===========================================================================
-- 4. A car deleted on the grid keeps the slot; a unicycle is not a car
-- ===========================================================================
delete(2)
check(driver('Bob').noCar == true, 'Bob deleted his only car')
check(driver('Bob').gridPos ~= nil and driver('Bob').status == 'gridded',
  'his slot is kept: deleting on the grid is not leaving it')
spawn(2)
check(driver('Bob').noCar == nil, 'and he has one again')

-- Dan walks: BeamMP's walking mode is a unicycle, and that is no car.
cars[4] = { [0] = '{"jbm":"unicycle"}' }
check(spawn(4, '{"jbm":"unicycle"}') == nil, 'a unicycle spawns')
RM_onGenerateGrid(1)   -- re-formed: who is in a car NOW
check(driver('Dan').gridPos == nil and driver('Dan').noCar == true,
  'a unicycle is not a car: Dan is left off the re-formed grid')

-- ===========================================================================
-- 5. The ready check: a late spawn is still not called
-- ===========================================================================
RM_onSetReadyCheck(1, '{"on":true}')
RM_onGenerateGrid(1)
check(driver('Alice').gridPos ~= nil, 'the field is on the grid')
check(driver('Dan').status == 'waiting' and driver('Dan').gridPos == nil, 'Dan, on foot, is not')
spawn(4)
check(driver('Dan').status == 'waiting' and driver('Dan').gridPos == nil,
  'spawning while the grid is called does NOT call him: no automatic entry')
check(driver('Dan').joinable == true, 'Join is offered')

-- An admin places him instead.
RM_onJoinField(1, '{"pid":4}')
check(driver('Dan').status == 'gridded' and driver('Dan').gridPos == 4,
  'an admin\'s Place puts him on the back, placed (got ' .. tostring(driver('Dan').status) .. ')')

-- Rejoining from Spectate does not sneak a left-off driver in either.
gone(4)
RM_onGenerateGrid(1)
check(driver('Dan').gridPos == nil, 'Dan left off again (no car)')
RM_onSetSpectating(4, '{"spectating":true}')
spawn(4)
RM_onSetSpectating(4, '{"spectating":false}')
check(driver('Dan').status == 'waiting', 'pressing Race again does not call a left-off driver')
RM_onSetSpectating(4, '{"spectating":true}')
check(driver('Dan').unlisted == nil and driver('Dan').spectating == true,
  'a spectator keeps the label it had')
RM_onSetSpectating(4, '{"spectating":false}')

-- ===========================================================================
-- 6. Add: in the field with or without a car, until he leaves
-- ===========================================================================
gone(4)
RM_onGenerateGrid(1)
check(driver('Dan').gridPos == nil, 'Dan, with no car, left off')

RM_onSetAdminEntry(2, '{"pid":4,"on":true}')   -- Bob is not an admin
check(driver('Dan').adminEntry == nil, 'Add needs an admin')

RM_onSetAdminEntry(1, '{"pid":4,"on":true}')
check(driver('Dan').adminEntry == true, 'an admin added Dan')
check(driver('Dan').status == 'called' and driver('Dan').gridPos == 4,
  'called to the back of the grid, to press Ready in a car')
check(driver('Dan').unlisted == nil, 'and on the board')
check(toldTo(4, 'An admin added you to the grid'), 'Dan is told')

RM_onSetAdminEntry(1, '{"pid":4,"on":false}')
check(driver('Dan').adminEntry == nil and driver('Dan').status == 'waiting'
  and driver('Dan').gridPos == nil, 'Remove stands a car-less called driver down')
check(gridAssign[4] == false and driver('Dan').unlisted == true, 'off the slot and off the board')

-- Added and never readied: the start goes without him.
RM_onSetAdminEntry(1, '{"pid":4,"on":true}')
for pid = 1, 3 do RM_onSetReady(pid, '{"ready":true}') end
RM_onStartCountdown(1)
check(driver('Dan').status == 'waiting' and driver('Dan').gridPos == nil,
  'never ready, he sits the start out like anyone still called')
RM_onEndRace(1)
RM_onResetLeaderboard(1)

-- The Add survives Start Qualifying, which wipes every record.
RM_onSetReadyCheck(1, '{"on":false}')
RM_onStartQualifying(1)
check(driver('Dan').adminEntry == true, 'the Add survives Start Qualifying\'s wipe')
check(driver('Dan').gridPos ~= nil and driver('Dan').status == 'gridded',
  'and he is on the qualifying grid with no car')

-- ...and ends when he leaves.
RM_onPlayerDisconnect(4)
RM_onPlayerJoin(4)
check(driver('Dan').adminEntry == nil, 'the Add ends when he leaves the server')
check(driver('Dan').noCar == true, 'and he is back with no car')
RM_onEndRace(1)
RM_onResetLeaderboard(1)

-- ===========================================================================
-- 7. Results: a driver left off is not in them
-- ===========================================================================
-- A copy to the admin's PC is how the results are read here (off as shipped;
-- the setting is kept on disk, so it is put back below).
RM_onSetResultsSave(1, '{"admins":true}')
-- The race's file holds its qualifying table too (a qualifying session writes
-- none of its own). Gus joins mid-grid with no car and never joins the field.
RM_onGenerateGrid(1)
connected[5] = 'Gus'
RM_onPlayerJoin(5)
check(driver('Gus').unlisted == true and driver('Gus').gridPos == nil, 'Gus arrives with no car: left off')
spawn(5)
check(driver('Gus').joinable == true, 'he spawns and could Join, and does not')
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'racing', 'the race runs')
check(driver('Gus').unlisted == true and driver('Gus').joinable == nil,
  'Gus is on no board while it does, and cannot join a running race')
resultsText = nil
RM_onEndRace(1)
check(type(resultsText) == 'string' and resultsText:find('Alice', 1, true) ~= nil,
  'the results went to the admin')
check(resultsText and not resultsText:find('Gus', 1, true),
  'and a driver who never joined is in neither table')
RM_onSetResultsSave(1, '{"admins":false}')
RM_onResetLeaderboard(1)
connected[5] = nil
RM_onPlayerDisconnect(5)

-- ===========================================================================
-- 8. The heat draw and a derby leave the car-less out too
-- ===========================================================================
gone(4)
RM_onSetHeats(1, '{"count":2,"transfer":1}')
RM_onDrawHeats(1)
check(driver('Dan').heat == nil, 'no car, no heat')
check(driver('Alice').heat ~= nil, 'the drivers in cars are drawn')
RM_onSetHeats(1, '{"count":0,"transfer":0}')

RM_onDerbyFormUp(1)
local inDerby = {}
for _, p in ipairs(lastDerby and lastDerby.players or {}) do inDerby[p.name] = true end
check(inDerby.Alice and inDerby.Bob and inDerby.Cara, 'the derby forms up with everyone in a car')
check(not inDerby.Dan, 'and without Dan, who has none')
RM_onDerbyEnd(1)

-- Drag ladders draw from the same rule (its candidates are local; pinned here).
do
  local f = io.open('server/RaceManager/drag.lua', 'r')
  local src = f:read('a'); f:close()
  local body = src:match('local function candidates%(%)(.-)\nend') or ''
  check(body:find('race.refreshCars()', 1, true) and body:find('race.inField(id)', 1, true),
    'drag candidates ask for cars and use the same entry rule')
end

-- ===========================================================================
-- 9. Everybody on foot: no grid, and the message says why
-- ===========================================================================
for pid = 1, 4 do gone(pid) end
chats = {}
check(RM_onGenerateGrid(1) == nil and lastState.phase ~= 'grid', 'no grid forms')
local said = false
for _, c in ipairs(chats) do
  if c.to == -1 and c.msg:find('Nobody in the field has a car', 1, true) then said = true end
end
check(said, 'and everyone is told nobody has a car spawned')

-- ===========================================================================
-- 10. Fails open: a server without GetPlayerVehicles grids everyone
-- ===========================================================================
MP.GetPlayerVehicles = nil
RM_onGenerateGrid(1)
check(lastState.phase == 'grid' and driver('Dan').gridPos ~= nil and driver('Alice').gridPos ~= nil,
  'with no way to ask, everyone counts as in a car')

os.remove(GARAGE_FILE)
print(string.format('no_car_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
