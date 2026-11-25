-- Headless test for STARTING FROM THE PIT STALLS (server side).
-- Run from the repo root: lua5.3 tests/pit_start_test.lua
--
-- Asked for: qualifying in the pits and the race on the track grid, and the
-- race in the pits too, each its own switch. Stall n is Pn.
--
-- The part that needs pinning is fairness. A start from the pits opens with an
-- out lap that sends EVERY car to the same first checkpoint. A car standing
-- past that checkpoint never crosses it on the way out, so its out lap would be
-- a lap longer than everybody else's -- and in a race lap 1 counts. The server
-- refuses to grid a field in the stalls when a gate of that checkpoint (main or
-- branch) runs between two stalls in use, and says why.

local connected = { [1] = 'Alice', [2] = 'Bob', [3] = 'Cara' }
local lastState = nil
local gridSent  = {}   -- [pid] = list of RM_GridAssign payloads, in order
local holdSent  = {}   -- [pid] = last RM_HoldCorrect payload
local chats     = {}   -- [pid] = list of chat lines (-1 = everyone)
local lastApplied = nil
local timers    = {}

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg)
    chats[target] = chats[target] or {}
    table.insert(chats[target], msg)
  end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then lastState = payload end
    if event == 'RM_GridAssign' then
      gridSent[target] = gridSent[target] or {}
      table.insert(gridSent[target], payload)
    end
    if event == 'RM_HoldCorrect' then holdSent[target] = payload end
    if event == 'RM_ApplyLayout' then lastApplied = payload end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name) timers[name] = true end,
  CancelEventTimer = function (name) timers[name] = nil end,
  Settings = { Map = 0 },
  Get = function () return '/levels/gridmap_v2/info.json' end,
}

Util = {
  JsonEncode = function (t) return t end,
  JsonDecode = function (s)
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    return load('return ' .. body)()
  end,
}

-- Rules outlive a boot (rules.lua): start from config.json's, not the last test's.
os.remove('Resources/Server/PhoenixRM Server/Data/rules.json')
dofile('server/RaceManager/main.lua')

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local ADMIN = 1
local function lastSlot(pid)
  local list = gridSent[pid]
  return list and list[#list] or nil
end
local function said(text)
  for _, line in ipairs(chats[-1] or {}) do
    if line:find(text, 1, true) then return true end
  end
  return false
end
local function clearSends() gridSent, holdSent, chats = {}, {}, {} end
local function row(pid)
  for _, d in ipairs(lastState.drivers) do
    if d.id == pid then return d end
  end
end

-- A two-gate circuit facing +y: CP 1 at y=100, the line at y=200. Four start
-- positions on the track at x=0, and a pit lane at x=-30 with four stalls,
-- stall 1 nearest the exit (highest y), 8 m apart.
local CPS = '"checkpoints":[{"x":0,"y":100,"z":0,"hx":0,"hy":1},{"x":0,"y":200,"z":0,"hx":0,"hy":1}]'
local STARTS = '"startPositions":[{"x":0,"y":0,"z":0,"hx":0,"hy":1},{"x":0,"y":-8,"z":0,"hx":0,"hy":1},'
  .. '{"x":0,"y":-16,"z":0,"hx":0,"hy":1},{"x":0,"y":-24,"z":0,"hx":0,"hy":1}]'
local PITS = '"pits":[{"x":-30,"y":50,"z":0,"hx":0,"hy":1},{"x":-30,"y":42,"z":0,"hx":0,"hy":1},'
  .. '{"x":-30,"y":34,"z":0,"hx":0,"hy":1},{"x":-30,"y":26,"z":0,"hx":0,"hy":1}]'
local function loadLayout(name, extra, cps)
  RM_onSaveLayout(ADMIN, '{"name":"' .. name .. '","width":20,"height":8,"depth":2,"confirmDrop":true,'
    .. (cps or CPS) .. ',' .. STARTS .. ',' .. PITS .. (extra and (',' .. extra) or '') .. '}')
  RM_onLoadLayout(ADMIN, '{"name":"' .. name .. '"}')
end

onInit()
RM_onLogin(ADMIN, '{"password":"phoenix"}')
RM_onSetReadyCheck(ADMIN, '{"on":false}')
for id in pairs(connected) do RM_onPlayerJoin(id) end
loadLayout('Pits')
check(lastState.qualiFromPits == false and lastState.raceFromPits == false,
  'both pit start switches are off by default')

-- ---------------------------------------------------------------------------
-- 1. The switches: admin only, one per session kind
-- ---------------------------------------------------------------------------
RM_onSetPitStart(2, '{"session":"quali","enabled":true}')
check(lastState.qualiFromPits == false, 'a driver cannot set the pit start')
RM_onSetPitStart(ADMIN, '{"session":"quali","enabled":true}')
check(lastState.qualiFromPits == true and lastState.raceFromPits == false,
  'the admin turns on the pit start for qualifying alone')

-- ---------------------------------------------------------------------------
-- 2. Qualifying from the stalls, the race from the track grid
-- ---------------------------------------------------------------------------
clearSends()
RM_onStartQualifying(ADMIN)
check(lastState.gridKind == 'pits', 'qualifying is gridded in the pit stalls')
for pid = 1, 3 do
  local p = lastSlot(pid)
  check(p and p.slot == row(pid).gridPos and p.grid == 'pits',
    connected[pid] .. ' is sent stall ' .. tostring(row(pid).gridPos) .. ' as a pit stall')
end
check(lastState.qualiOutLap == true, 'and qualifying still opens with its out lap')

-- The hold is policed against the STALL. Bob drifts 40 m off it.
local bob = row(2).gridPos
RM_onHoldPos(2, '{"x":40,"y":40,"z":0}')
local hc = holdSent[2]
local stallY = ({ 50, 42, 34, 26 })[bob]
check(hc and hc.x == -30 and hc.y == stallY,
  'a car off its stall is pulled back to the stall, not to a start position (got '
    .. tostring(hc and hc.x) .. ', ' .. tostring(hc and hc.y) .. ')')
RM_onEndRace(ADMIN)

clearSends()
RM_onGenerateGrid(ADMIN)
check(lastState.gridKind == 'grid', 'the race is gridded on the track with only the quali switch on')
check(lastSlot(1) and lastSlot(1).slot ~= nil and lastSlot(1).grid == nil,
  'and its slots are start positions')
check(lastState.qualiOutLap == false, 'and a race on a grid at the line owes no out lap')
RM_onEndRace(ADMIN)

-- ---------------------------------------------------------------------------
-- 3. The race from the stalls: an out lap that counts as lap 1
-- ---------------------------------------------------------------------------
RM_onSetPitStart(ADMIN, '{"session":"race","enabled":true}')
clearSends()
RM_onGenerateGrid(ADMIN)
check(lastState.gridKind == 'pits' and lastSlot(1) and lastSlot(1).grid == 'pits',
  'with the race switch on, the race is gridded in the stalls')
check(lastState.qualiOutLap == true and row(1).outLap == true,
  'and opens with an out lap: the pits are a grid away from the line')
local raceLaps = lastState.totalLaps
check(raceLaps ~= nil, 'the race keeps its distance')

-- And the other way round: the race switch alone leaves qualifying on the grid.
RM_onEndRace(ADMIN)
RM_onSetPitStart(ADMIN, '{"session":"quali","enabled":false}')
clearSends()
RM_onStartQualifying(ADMIN)
check(lastState.gridKind == 'grid' and lastSlot(1) and lastSlot(1).grid == nil,
  'with only the race switch on, qualifying is gridded on the track')
RM_onEndRace(ADMIN)
RM_onSetPitStart(ADMIN, '{"session":"quali","enabled":true}')
RM_onGenerateGrid(ADMIN)

-- Locked once a session is under way.
RM_onStartCountdown(ADMIN)
RM_onSetPitStart(ADMIN, '{"session":"race","enabled":false}')
check(lastState.raceFromPits == true, 'the switch cannot be changed during the countdown')
RM_onEndRace(ADMIN)
RM_onResetLeaderboard(ADMIN)
check(lastState.gridKind == 'grid', 'a session reset goes back to the track grid')

-- ---------------------------------------------------------------------------
-- 4. Not enough stalls: the track grid, and chat says why
-- ---------------------------------------------------------------------------
connected[4], connected[5] = 'Dan', 'Eve'
RM_onPlayerJoin(4); RM_onPlayerJoin(5)
clearSends()
RM_onGenerateGrid(ADMIN)
check(lastState.gridKind == 'grid', 'five drivers and four stalls: the race uses the track grid')
check(said('Race from the track grid: 5 drivers, 4 pit stalls'),
  'and chat says so, with the numbers')
RM_onEndRace(ADMIN)
connected[4], connected[5] = nil, nil
RM_onPlayerDisconnect(4); RM_onPlayerDisconnect(5)

-- ---------------------------------------------------------------------------
-- 5. THE WHOLE FIELD STARTS BEHIND THE SAME CHECKPOINT
-- ---------------------------------------------------------------------------
-- A branch gate of CP 1 across the pit lane between stalls 2 (y=42) and 3
-- (y=34): Alice and Bob would start past it, Cara behind it.
loadLayout('Split', '"branches":[{"slot":1,"x":-30,"y":38,"z":0,"hx":0,"hy":1,"width":10}]')
clearSends()
RM_onGenerateGrid(ADMIN)
check(lastState.gridKind == 'grid',
  'a CP 1 branch gate between stalls 2 and 3 keeps a three-car field off the stalls')
check(said('CP 1 runs between pit stalls 2 and 3'),
  'and chat names the checkpoint and the stalls')
RM_onEndRace(ADMIN)

-- Between stalls 3 and 4 instead: stall 4 is not in use with three cars.
loadLayout('Behind', '"branches":[{"slot":1,"x":-30,"y":30,"z":0,"hx":0,"hy":1,"width":10}]')
clearSends()
RM_onGenerateGrid(ADMIN)
check(lastState.gridKind == 'pits',
  'the same gate behind the last stall in use does not split the field')
RM_onEndRace(ADMIN)

-- The MAIN gate counts too: CP 1 moved into the lane, wide enough to span it.
loadLayout('Main', nil,
  '"checkpoints":[{"x":-20,"y":38,"z":0,"hx":0,"hy":1,"width":40},{"x":0,"y":200,"z":0,"hx":0,"hy":1}]')
clearSends()
RM_onGenerateGrid(ADMIN)
check(lastState.gridKind == 'grid' and said('CP 1 runs between pit stalls 2 and 3'),
  'a main gate between two stalls in use splits the field as a branch gate does')
RM_onEndRace(ADMIN)

-- The pit start's own first checkpoint: past the split gate, the field is
-- whole again, and the setting travels with the layout.
loadLayout('Split2', '"pitFirstCheckpoint":2,'
  .. '"branches":[{"slot":1,"x":-30,"y":38,"z":0,"hx":0,"hy":1,"width":10}]')
check(lastApplied and lastApplied.pitFirstCheckpoint == 2,
  'the pit start first checkpoint is saved with the layout and sent to clients')
clearSends()
RM_onGenerateGrid(ADMIN)
check(lastState.gridKind == 'pits',
  'with the pit start sent to CP 2, a CP 1 gate between the stalls no longer matters')
RM_onEndRace(ADMIN)

-- Out of range is dropped, as the grid's First checkpoint is.
loadLayout('Bad', '"pitFirstCheckpoint":9')
check(lastApplied and lastApplied.pitFirstCheckpoint == nil,
  'a pit start first checkpoint past the last gate is not saved')

if fails == 0 then
  print('pit_start_test: ' .. checks .. ' checks, 0 failures')
else
  print('pit_start_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
