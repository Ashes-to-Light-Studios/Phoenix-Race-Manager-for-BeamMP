-- Headless test for CHECKPOINT SKIPS: the optional track-cut warning and
-- penalty, in server/RaceManager/main.lua and lua/ge/extensions/raceManager.lua.
--
-- A driver who cuts the track crosses a gate AHEAD of the one they are due.
-- Without the rule nothing sees it: only the armed gate is tested, so the car
-- stays armed on the gate it missed until it drives back. With the rule on:
--
--   * THE CLIENT sees the cut (only it has the car). A forward crossing of a
--     gate up to maxGates past the armed one is a crossing of THAT gate: the
--     car is moved on, the lap is marked cut, and RM_CheckpointSkip goes up.
--     Never on an out lap, a pace lap, a reset or a teleport, never backwards,
--     and the S/F line is no target before the car has cleared a gate (a grid
--     behind the line drives over it first).
--   * THE SERVER rules on it: warnings first, then the admin's penalty, which
--     is TIME (seconds on the race time, counted in the classification), a
--     LIFT (off the throttle for a few seconds, or the time instead) or both.
--     A cut lap counts toward the distance and sets no time.
--   * Everything lands on the driver's own row; the client tells the driver
--     from it, and serves a lift by watching the throttle.
--
-- With the rule OFF, nothing may change at all, and the first case of each half
-- pins that.
--
-- Two halves in one file, one Lua state: the server is driven through its
-- handlers like tests/caution_test.lua, the client frame by frame like
-- tests/joker_test.lua. Neither touches the other's globals.
--
-- Run from the repo root: lua5.3 tests/checkpoint_skip_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ===========================================================================
-- PART 1: THE SERVER
-- ===========================================================================
local connected = { [0] = 'Admin', [1] = 'Alice', [2] = 'Bob', [3] = 'Cara', [4] = 'Dan' }
local lastState  = nil
local chatLog    = {}
local timers     = {}
local registered = {}
local spectated  = {}    -- [pid] = the RM_ForceSpectate payload
local resultsText = nil

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) chatLog[#chatLog + 1] = { to = target, msg = msg } end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then lastState = payload end
    if event == 'RM_ForceSpectate' then spectated[target] = payload end
    if event == 'RM_ResultsFile' then resultsText = payload.text end
  end,
  RegisterEvent = function (event, fn) registered[event] = fn end,
  CreateEventTimer = function (name) timers[name] = true end,
  CancelEventTimer = function (name) timers[name] = nil end,
  RemoveVehicle = function () end,
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

dofile('server/RaceManager/main.lua')

local function driver(pid)
  for _, d in ipairs(lastState.drivers) do
    if d.id == pid then return d end
  end
end
-- The driver ids in board order, participants only.
local function order()
  local out = {}
  for _, d in ipairs(lastState.drivers) do
    if not d.spectating then out[#out + 1] = d.id end
  end
  return table.concat(out, ',')
end
local function chatTo(pid, text)
  for _, c in ipairs(chatLog) do
    if c.to == pid and c.msg:find(text, 1, true) then return c.msg end
  end
  return nil
end
local function chatHas(text)
  for _, c in ipairs(chatLog) do
    if c.msg:find(text, 1, true) then return c.msg end
  end
  return nil
end
local function chatClear() chatLog = {} end
local function seconds(n)
  for _ = 1, math.floor(n * 10 + 0.5) do RM_Tick() end
end
-- A skip, as the client reports it: on lap `lap`, crossing gate `to`, `n`
-- gates past the armed one.
local function skip(pid, lap, to, n)
  RM_onCheckpointSkip(pid, string.format('{"lap":%d,"from":%d,"to":%d,"skipped":%d}',
    lap, to - n, to, n))
end
local function lap(pid, t, cut)
  RM_onLap(pid, string.format('{"lapTime":%.3f%s}', t or 60, cut and ',"cut":true' or ''))
end
local function setSkip(t)
  local parts = {}
  for k, v in pairs(t) do
    parts[#parts + 1] = string.format('"%s":%s', k,
      type(v) == 'string' and ('"' .. v .. '"') or tostring(v))
  end
  RM_onSetCheckpointSkip(0, '{' .. table.concat(parts, ',') .. '}')
end
local function startRace()
  RM_onGenerateGrid(0)
  RM_onStartCountdown(0)
  for _ = 1, 70 do
    if lastState.phase == 'racing' then break end
    RM_CountdownTick()
  end
end
local function endRace()
  RM_onEndRace(0)
  if lastState.phase ~= 'waiting' and lastState.phase ~= 'finished' then RM_onEndRace(0) end
end

onInit()
check(registered.RM_SetCheckpointSkip == 'RM_onSetCheckpointSkip'
  and registered.RM_CheckpointSkip == 'RM_onCheckpointSkip'
  and registered.RM_LiftServed == 'RM_onLiftServed',
  'the three checkpoint-skip events are registered')
RM_onLogin(0, '{"password":"phoenix"}'); RM_onSetReadyCheck(0, '{"on":false}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":5}')
RM_onSetPaceLap(0, '{"enabled":false}')
RM_onSetFinishRule(0, '{"after":1,"seconds":600}')

-- ---------------------------------------------------------------------------
-- 1. Off as shipped, and OFF CHANGES NOTHING
-- ---------------------------------------------------------------------------
local cs = lastState.cpSkip
check(cs and cs.enabled == false, 'the rule is off as shipped')
check(cs and cs.warnings == 1 and cs.type == 'time' and cs.penaltySec == 5
  and cs.liftSec == 3 and cs.liftWindow == 30 and cs.maxGates == 2,
  'and its defaults ride every update: 1 warning, time, 5s, lift 3s in 30s, 2 gates')

startRace()
check(lastState.phase == 'racing', 'a race is running')
chatClear()
skip(1, 1, 3, 1)
check(driver(1).checkpointWarningsUsed == nil and driver(1).penaltySeconds == nil
  and driver(1).liftOwed == nil, 'off: a skip report costs nothing')
check(not chatHas('Track Cut') and not chatHas('Race control: Alice skipped'),
  'off: and nobody is told anything')
lap(1, 61.0)                 -- lap 1: off the grid, untimed as always
lap(1, 58.5, true)           -- a lap the client marked cut
check(driver(1).raceBest == 58.5, 'off: a lap marked cut sets a best exactly as before')
check(lastState.bestLapTime == 58.5, 'off: and the fastest lap')
endRace()

-- ---------------------------------------------------------------------------
-- 2. The setting: admin only, clamped, locked under way
-- ---------------------------------------------------------------------------
RM_onSetCheckpointSkip(1, '{"enabled":true}')
check(lastState.cpSkip.enabled == false, 'only race control sets the rule')
setSkip({ enabled = true, warnings = -3, type = 'bogus', penaltySec = 1000, liftSec = 0.74,
  liftWindow = 2 })
cs = lastState.cpSkip
check(cs.enabled == true, 'an admin turns it on')
check(cs.warnings == 0, 'warnings are clamped at 0')
check(cs.type == 'time', 'an unknown penalty type is ignored')
check(cs.penaltySec == 300, 'penalty seconds are clamped at 300')
check(cs.liftSec == 0.5, 'lift seconds are clamped at 0.5 and rounded to a half second')
check(cs.liftWindow == 5, 'the serve window is clamped at 5s')
setSkip({ penaltySec = 5.2, liftSec = 2.8 })
check(lastState.cpSkip.penaltySec == 5 and lastState.cpSkip.liftSec == 3,
  'half-second fields round to the nearest 0.5')
check(lastState.cpSkip.warnings == 0 and lastState.cpSkip.enabled == true,
  'a field left out keeps its value')
setSkip({ enabled = true, warnings = 2, type = 'time', penaltySec = 5, liftSec = 3, liftWindow = 30 })

startRace()
chatClear()
setSkip({ warnings = 9 })
check(lastState.cpSkip.warnings == 2, 'the rule is locked while a session runs')
check(chatTo(0, 'locked while a session') ~= nil, 'and the admin is told why')

-- ---------------------------------------------------------------------------
-- 3. Warnings run out (W = 2), then time
-- ---------------------------------------------------------------------------
chatClear()
skip(1, 1, 3, 1)
local d = driver(1)
check(d.checkpointWarningsUsed == 1 and d.penaltySeconds == nil, 'skip 1: warning 1/2, no penalty')
check(chatTo(1, 'Track Cut Warning (1/2) - next skip: +5.0s') ~= nil, 'the driver is warned')
check(chatTo(0, 'Race control: Alice skipped CP 2 on lap 1: warning 1/2') ~= nil,
  'and race control is told who, where and what')
skip(1, 1, 3, 1)
check(driver(1).checkpointWarningsUsed == 1, 'the same crossing reported twice is ruled on once')
skip(1, 2, 4, 1)
check(driver(1).checkpointWarningsUsed == 1, 'a report on another lap than the server\'s is stale')
skip(1, 1, 7, 3)
check(driver(1).checkpointWarningsUsed == 1, 'a skip wider than the look-ahead window is refused')
skip(1, 1, 4, 1)
check(driver(1).checkpointWarningsUsed == 2 and driver(1).penaltySeconds == nil,
  'skip 2: warning 2/2, still no penalty')
lap(1)                       -- lap 1 done (it had skips: cut)
chatClear()
skip(1, 2, 3, 1)
check(driver(1).penaltySeconds == 5, 'skip 3: the warnings are gone, +5s')
check(chatTo(1, 'Checkpoint skipped: +5.0s penalty (warnings used up)') ~= nil,
  'the driver is told the penalty')
check(chatTo(0, 'Race control: Alice skipped CP 2 on lap 2: +5.0s') ~= nil,
  'and race control the ruling')

-- A MULTI-GATE CUT ACROSS THE THRESHOLD: at 1/2, skipping two gates uses the
-- last warning on the first and penalises the second.
skip(2, 1, 3, 1)
chatClear()
skip(2, 1, 5, 2)
d = driver(2)
check(d.checkpointWarningsUsed == 2 and d.penaltySeconds == 5,
  'two gates at 1/2: the last warning, and +5s for one')
check(chatTo(2, 'Track Cut: last warning used, +5.0s for 1 more checkpoint') ~= nil,
  'the driver hears both halves in one line')
check(chatTo(0, 'Bob skipped CPs 3-4 on lap 1: warning 2/2, +5.0s') ~= nil,
  'race control too')

-- ---------------------------------------------------------------------------
-- 4. A cut lap counts toward the distance and sets no time
-- ---------------------------------------------------------------------------
lap(1, 50.0)                 -- Alice's lap 2: a skip was reported on it, no flag
check(driver(1).raceBest == nil, 'a lap with a skip reported sets no best, even unflagged')
check(lastState.bestLapTime == nil, 'nor the fastest lap')
check(driver(1).currentLap == 3, 'but it counts toward the distance')
lap(1, 57.0)                 -- lap 3: clean
check(driver(1).raceBest == 57.0, 'the next clean lap is timed')
lap(3, 61.0); lap(3, 49.0, true)   -- Cara: the client flags a cut lap on its own
check(driver(3).raceBest == nil, 'a lap the client flags cut sets no best')
check(lastState.bestLapTime == 57.0, 'and the fastest lap is still the clean one')
check(driver(1).penaltySeconds == 5 and driver(3).penaltySeconds == nil,
  'zero penalty goes over the wire as nil')

-- ---------------------------------------------------------------------------
-- 5. Classification: the penalty counts between finishers on the same lap, and
--    never puts a car above one with more laps
-- ---------------------------------------------------------------------------
-- Alice 3 done, Bob 0, Cara 2, Dan 0. Bring them up: Alice, Bob and Dan to the
-- last lap, Cara a lap behind them.
lap(1, 60)                                           -- Alice: 4 done
for _ = 1, 4 do lap(2, 60) end                       -- Bob: 4 done
for _ = 1, 4 do lap(4, 60) end                       -- Dan: 4 done
lap(3, 60)                                           -- Cara: 3 done
RM_onSetResultsSave(0, '{"admins":true}')
spectated = {}
seconds(1)
lap(1, 60)                   -- Alice takes the flag first, with +5s
check(driver(1).status == 'finished', 'Alice is home')
check(spectated[1] and spectated[1].place == 1 and spectated[1].provisional == true,
  'told P1, as provisional: a car still out can finish inside her penalty')
seconds(2)
lap(4, 60)                   -- Dan, 2s later and clean
check(spectated[4] and spectated[4].place == 1 and spectated[4].provisional == nil,
  'Dan is P1: home 2s later, but Alice carries 5s; his place is no provisional one')
check(order():find('^4,1') ~= nil, 'the board has Dan ahead of Alice')
seconds(1)
lap(2, 60)                   -- Bob, 3s after Alice, with +5s
check(order():find('^4,1,2') ~= nil, 'Bob, +5s at 3s back, is behind Alice (5s at 0)')
check(driver(3).position == 4, 'Cara, a lap down and clean, is behind every car on the lead lap')
-- Close it: Cara is classified where she stands.
RM_onEndRace(0)
check(lastState.phase == 'finished', 'the race is closed')
check(order():find('^4,1,2,3') ~= nil, 'final order: Dan, Alice, Bob, then Cara a lap down')

-- The results file says what happened.
check(resultsText ~= nil, 'the results were copied to the admin')
resultsText = resultsText or ''
check(resultsText:find(' Checkpoint skips: 2 warnings, then +5.0s per skipped checkpoint', 1, true) ~= nil,
  'the header states the rule')
check(resultsText:find('Track cuts', 1, true) ~= nil, 'there is a Track cuts column')
local aliceLine = resultsText:match('\n(P2 [^\n]*Alice[^\n]*)') or ''
check(aliceLine:find('(+5.0s pen)', 1, true) ~= nil, 'Alice\'s race time carries the penalty note')
check(aliceLine:find('W 2/2', 1, true) and aliceLine:find('3 skips', 1, true)
  and aliceLine:find('2 cut laps', 1, true),
  'and her cuts cell the skips, warnings and cut laps (' .. aliceLine .. ')')
local danLine = resultsText:match('\n(P1 [^\n]*Dan[^\n]*)') or ''
check(danLine:find('RACE WINNER', 1, true) ~= nil and danLine:find('pen', 1, true) == nil,
  'Dan won, with no penalty note')
RM_onSetResultsSave(0, '{"admins":false}')

-- ---------------------------------------------------------------------------
-- 6. Resets: Generate Grid zeroes every tally
-- ---------------------------------------------------------------------------
RM_onGenerateGrid(0)
local clean = true
for pid = 1, 4 do
  local r = driver(pid)
  if r.penaltySeconds or r.checkpointWarningsUsed or r.liftOwed or r.liftWindowLeft then clean = false end
end
check(clean, 'Generate Grid zeroes warnings, penalties and lifts')
RM_onEndRace(0)

-- ---------------------------------------------------------------------------
-- 7. No warnings, and THE LIFT
-- ---------------------------------------------------------------------------
setSkip({ enabled = true, warnings = 0, type = 'lift', penaltySec = 5, liftSec = 3, liftWindow = 30 })
startRace()
check(driver(1).penaltySeconds == nil and driver(1).checkpointWarningsUsed == nil,
  'GO starts everyone clean')
chatClear()
skip(1, 1, 3, 2)
d = driver(1)
check(d.liftOwed == 2 and d.penaltySeconds == nil, 'no warnings: two gates owe two lifts at once')
check(d.liftWindowLeft == 30, 'with the whole serve window to do it in')
check(chatTo(1, '2 checkpoints skipped: LIFT OFF THE THROTTLE for 2 x 3.0s within 30s') ~= nil,
  'the driver is told to lift')
check(chatTo(0, 'Alice skipped CPs 1-2 on lap 1: lift 2 x 3.0s owed') ~= nil, 'and race control')
RM_onLiftServed(1, '{"lap":1}')
check(driver(1).liftOwed == 2, 'a lift reported served sooner than it can be is ignored')
seconds(3)
chatClear()
RM_onLiftServed(1, '{"lap":1}')
check(driver(1).liftOwed == 1, 'served: one lift left')
check(chatTo(1, 'Lift served - carry on') ~= nil, 'the driver is told to carry on')
check(chatTo(0, 'Alice lift served (1 more owed)') ~= nil, 'race control hears it')
RM_onLiftServed(1, '{"lap":1}')
check(driver(1).liftOwed == 1, 'the next one is timed from the last one served')
seconds(3)
RM_onLiftServed(1, '{"lap":1}')
check(driver(1).liftOwed == nil and driver(1).liftWindowLeft == nil, 'both served: nothing owed')
check(driver(1).penaltySeconds == nil, 'and served lifts cost no time')

-- NOT SERVED IN THE WINDOW: it becomes time.
skip(2, 1, 3, 1)
seconds(29.5)
check(driver(2).liftOwed == 1, 'still owed half a second before the window shuts')
check(driver(2).liftWindowLeft and driver(2).liftWindowLeft <= 1, 'the board counts it down')
chatClear()
seconds(1)
check(driver(2).liftOwed == nil and driver(2).penaltySeconds == 5,
  'not served in 30s: converted to +5s')
check(chatTo(2, 'Lift not served: +5.0s penalty') ~= nil, 'the driver is told')
check(chatTo(0, 'Bob lift converted to +5.0s') ~= nil, 'and race control')

-- PAUSED UNDER RED: the window only runs on green.
skip(3, 1, 3, 1)
seconds(10)
RM_onSetFlag(0, '{"flag":"red"}')
seconds(60)
check(driver(3).liftOwed == 1, 'a red flag pauses the serve window')
check(math.abs((driver(3).liftWindowLeft or 0) - 20) < 0.25,
  'with what was left of it kept (' .. tostring(driver(3).liftWindowLeft) .. ')')
RM_onSetFlag(0, '{"flag":"green"}')
seconds(19.5)
check(driver(3).liftOwed == 1, 'back under green the rest of the window runs')
seconds(1)
check(driver(3).liftOwed == nil and driver(3).penaltySeconds == 5, 'and then it converts')

-- PAUSED WHILE A CAUTION IS CALLED.
skip(4, 1, 3, 1)
RM_onCaution(0)
check(lastState.cautionPending == true, 'a caution is called')
seconds(60)
check(driver(4).liftOwed == 1, 'a caution called pauses the serve window')
RM_onSetFlag(0, '{"flag":"green"}')       -- withdrawn before it went official
check(lastState.cautionPending ~= true, 'the caution is withdrawn')

-- STILL OWED AT THE FLAG: converted before the place is decided.
for _ = 1, 4 do lap(4, 60) end
spectated = {}
lap(4, 60)
check(driver(4).status == 'finished' and driver(4).liftOwed == nil and driver(4).penaltySeconds == 5,
  'a lift still owed at the flag becomes +5s as the car finishes')
check(spectated[4] and spectated[4].provisional == true, 'so the place is told as provisional')

-- DNF ON DISCONNECT keeps the penalty and drops the lift (Alice: one more lift).
skip(1, 1, 4, 1)
check(driver(1).liftOwed == 1, 'Alice owes a lift')
RM_onPlayerDisconnect(1)
connected[1] = nil
check(driver(1).status == 'dnf', 'Alice is out on disconnect')
check(driver(1).liftOwed == nil, 'and the lift she owed is discarded')
RM_onEndRace(0)
connected[1] = 'Alice'
RM_onPlayerJoin(1)

-- ---------------------------------------------------------------------------
-- 8. Lift + time: both at once, and more time for a lift not served
-- ---------------------------------------------------------------------------
setSkip({ enabled = true, warnings = 0, type = 'liftAndTime', penaltySec = 5, liftSec = 3, liftWindow = 30 })
startRace()
chatClear()
skip(2, 1, 3, 1)
d = driver(2)
check(d.penaltySeconds == 5 and d.liftOwed == 1, 'lift + time: +5s now and a lift owed')
check(chatTo(2, 'Checkpoint skipped: +5.0s and LIFT OFF for 3.0s') ~= nil, 'said as both')
check(chatTo(0, 'Bob skipped CP 2 on lap 1: +5.0s, lift 3.0s owed') ~= nil, 'race control too')
for _ = 1, 5 do lap(2, 60) end
check(driver(2).status == 'finished' and driver(2).penaltySeconds == 10,
  'the lift not served at the flag adds its 5s on top')
RM_onEndRace(0)

-- ---------------------------------------------------------------------------
-- 9. Qualifying: the lap is not timed, nothing else
-- ---------------------------------------------------------------------------
setSkip({ enabled = true, warnings = 0, type = 'time', penaltySec = 5, liftSec = 3, liftWindow = 30 })
RM_onSetQualiLimits(0, '{"laps":3,"seconds":0}')
RM_onStartQualifying(0)
RM_onStartCountdown(0)
for _ = 1, 70 do
  if lastState.phase == 'qualifying' then break end
  RM_CountdownTick()
end
check(lastState.phase == 'qualifying', 'qualifying is running')
lap(1, 70)                   -- the out lap
chatClear()
skip(1, 2, 3, 1)
check(driver(1).penaltySeconds == nil and driver(1).checkpointWarningsUsed == nil,
  'qualifying: a skip costs no warning and no penalty')
check(not chatHas('Track Cut') and not chatHas('Race control'), 'and nobody is told of one')
lap(1, 55.0)
check(driver(1).qualiBest == nil, 'the cut lap sets no qualifying time')
check(driver(1).qualiLaps == 1, 'but it is one of the laps run')
check(chatTo(1, 'Lap not timed') ~= nil, 'and the driver is told why')
lap(1, 56.0)
check(driver(1).qualiBest == 56.0, 'the next clean lap is timed')
RM_onEndRace(0)

-- ---------------------------------------------------------------------------
-- 10. The pace lap is nobody's race
-- ---------------------------------------------------------------------------
RM_onSetPaceLap(0, '{"enabled":true}')
RM_onGenerateGrid(0)
RM_onStartRace(0)
check(lastState.pacing == true, 'the field is on its pace lap')
skip(1, 1, 3, 1)
check(driver(1).penaltySeconds == nil, 'a skip on the formation lap costs nothing')
RM_onEndRace(0)
RM_onSetPaceLap(0, '{"enabled":false}')
setSkip({ enabled = false })

print(string.format('checkpoint_skip_test (server): %d checks, %d failures', checks, fails))

-- ===========================================================================
-- PART 2: THE CLIENT
-- ===========================================================================
local serverChecks, serverFails = checks, fails
local sent, handlers = {}, {}
local notices, hud = {}, {}
local routeState = nil
local VEH_ID = 7
local vm = { throttle = 0, silent = false }
local veh = { id = VEH_ID, x = 0, y = 0, z = 0, speed = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = self.speed, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation(x, y, z) self.x, self.y, self.z = x, y, z end
-- The vehicle VM, as far as the lift probe goes: it answers with the throttle
-- input (unless told to stay silent, as a reloading VM would).
function veh:queueLuaCommand(cmd)
  if cmd:find('onLiftThrottle', 1, true) and not vm.silent then
    raceManager.onLiftThrottle(vm.throttle)
  end
end
function veh:setMeshAlpha() end
function veh:getSpawnWorldOOBB() return nil end

getPlayerVehicle = function () return veh end
be = { getPlayerVehicle = function () return veh end, enterVehicle = function () end }
getAllVehicles = function () return { veh } end
getObjectByID = function (id) return id == VEH_ID and veh or nil end
MPVehicleGE = {
  isOwn = function (id) return id == VEH_ID end,
  getVehicles = function () return { { ownerID = 1, gameVehicleID = VEH_ID } } end,
}
core_vehicleBridge = { executeAction = function () end }
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
core_vehicles = { removeCurrent = function () end }
beamng_version = '0.39.4.0'
local V = {}
V.__index = V
V.__add = function (a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }, V) end
V.__mul = function (a, s) return setmetatable({ x = a.x * s, y = a.y * s, z = a.z * s }, V) end
vec3 = function (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log = function () end
guihooks = { trigger = function (e, p)
  if e == 'RaceManagerRoute' then routeState = p end
  if e == 'RaceManagerNotice' then notices[#notices + 1] = p end
  if e == 'Message' then hud[#hud + 1] = p end
end }
ColorF = function () return {} end
ColorI = function () return {} end
String = function (s) return s end
debugDrawer = {
  drawCylinder = function () end, drawTextAdvanced = function () end,
  drawSphere = function () end, drawLine = function () end,
  drawQuadSolid = function () end, drawTriSolid = function () end,
}
MPGameNetwork = {}
MPConfig = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
AddEventHandler = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
raceManager = RM          -- the VM calls back through the extension's global name
RM.onExtensionLoaded()

local function frames(secs, step)
  step = step or 0.1
  for _ = 1, math.floor(secs / step + 0.5) do RM.onUpdate(step) end
end
-- Driven, not teleported: steps of a few meters, a frame each, so the skip
-- watch (which ignores any segment over 30 m) sees every crossing.
local function driveTo(x, y)
  local x0, y0 = veh.x, veh.y
  local dx, dy = x - x0, y - y0
  local n = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy) / 5))
  for i = 1, n do
    veh.x, veh.y = x0 + dx * i / n, y0 + dy * i / n
    RM.onUpdate(0.05)
  end
end
-- Back to the start the long way round, out at x = -200 where no gate is, or
-- every gate would be crossed again backwards.
local function toStart()
  veh.x, veh.y = -200, 450; RM.onUpdate(0.05)
  veh.x, veh.y = -200, -50; RM.onUpdate(0.05)
  veh.x, veh.y = 0, -50;    RM.onUpdate(0.05)
  veh.x, veh.y = 0, 0;      RM.onUpdate(0.05)
end
local function sentOf(e)
  local out = {}
  for _, x in ipairs(sent) do if x.event == e then out[#out + 1] = x.payload end end
  return out
end
local function indexOf(e)
  for i, x in ipairs(sent) do if x.event == e then return i end end
  return nil
end
local function clearLog() sent, notices, hud = {}, {}, {} end
local function noticeHas(text)
  for _, n in ipairs(notices) do
    if (n.msg or ''):find(text, 1, true) or (n.sub or ''):find(text, 1, true) then return n end
  end
  return nil
end
local function lastLiftLine()
  local line = nil
  for _, m in ipairs(hud) do
    if m.category == 'raceManager_lift' then line = m.msg end
  end
  return line
end

-- The rules, and our row on the board. `row` adds fields to our row.
local CP = { enabled = true, warnings = 2, type = 'time', penaltySec = 5, liftSec = 3,
  liftWindow = 30, maxGates = 2 }
local function cpWith(t)
  local c = {}
  for k, v in pairs(CP) do c[k] = v end
  for k, v in pairs(t or {}) do c[k] = v end
  return c
end
local lastUpdate = nil
local function state(extra, row, cp)
  local me = { id = 1, status = 'racing' }
  for k, v in pairs(row or {}) do me[k] = v end
  local t = { rmProtocol = 2, raceTime = 0, phase = 'racing', maxResets = -1, totalLaps = 5,
    flag = 'green', drivers = { me }, cpSkip = cp or CP }
  for k, v in pairs(extra or {}) do t[k] = v end
  lastUpdate = t
  handlers['RM_Update'](t)
end
-- A fresh session: through 'waiting', so the lap tracking starts over.
local function newSession(extra, cp)
  veh.x, veh.y = 0, 0
  RM.onUpdate(0.05)
  state({ phase = 'waiting' }, nil, cp)
  state(extra, nil, cp)
  RM.onUpdate(0.05)
  clearLog()
end
-- Around a gate at height y, without crossing it (gates are 20 m wide at x 0).
local function around(y)
  driveTo(35, y - 20)
  driveTo(35, y + 20)
  driveTo(0, y + 45)
end

-- TRACK A: four gates up the y axis, all facing +y. The last is the line.
RM.setEditorTarget('main')
for _, y in ipairs({ 100, 200, 300, 400 }) do
  RM.editorAdd({ x = 0, y = y, z = 0, hx = 0, hy = 1 })
end
check(#routeState.waypoints == 4, 'client: a four-gate track, the fourth the S/F line')

-- ---------------------------------------------------------------------------
-- C1. Off: a cut leaves the car armed on the gate it missed, as always
-- ---------------------------------------------------------------------------
newSession(nil, cpWith({ enabled = false }))
driveTo(0, 150)
check(routeState.nextWp == 2, 'CP 1 is cleared the ordinary way')
around(200)
driveTo(0, 330)
check(routeState.nextWp == 2, 'off: crossing CP 3 after cutting CP 2 leaves the car armed on CP 2')
check(#sentOf('RM_CheckpointSkip') == 0, 'off: and nothing is reported')
driveTo(0, 420)
check(#sentOf('RM_Lap') == 0, 'off: nor does crossing the line complete a lap')

-- ---------------------------------------------------------------------------
-- C2. On: the skip moves the car on, is reported, and cuts the lap
-- ---------------------------------------------------------------------------
newSession()
driveTo(0, 150)
around(200)
driveTo(0, 330)
local rep = sentOf('RM_CheckpointSkip')[1]
check(rep and rep.lap == 1 and rep.from == 2 and rep.to == 3 and rep.skipped == 1,
  'cutting CP 2 reports { lap 1, from 2, to 3, skipped 1 }')
check(routeState.nextWp == 4, 'and the car is armed on the gate after the one it crossed')
driveTo(0, 420)
local lapRep = sentOf('RM_Lap')[1]
check(lapRep and lapRep.cut == true, 'the lap it completes is reported cut')
toStart(); clearLog()
driveTo(0, 420)
lapRep = sentOf('RM_Lap')[1]
check(lapRep and lapRep.cut == nil, 'the next lap starts clean: no cut on a clean lap')
check(#sentOf('RM_CheckpointSkip') == 0, 'and a clean lap reports no skip')

-- C3. CUTTING THE LAST CORNER INTO THE LINE: one skip, the lap completes.
toStart(); clearLog()
driveTo(0, 250)
around(300)
driveTo(0, 420)
rep = sentOf('RM_CheckpointSkip')[1]
check(rep and rep.lap == 3 and rep.from == 3 and rep.to == 4 and rep.skipped == 1,
  'cutting CP 3 into the line is one skip, landing on the line')
lapRep = sentOf('RM_Lap')[1]
check(lapRep and lapRep.cut == true, 'it completes the lap, reported cut')
check(indexOf('RM_CheckpointSkip') and indexOf('RM_Lap')
  and indexOf('RM_CheckpointSkip') < indexOf('RM_Lap'),
  'and the skip goes up BEFORE the lap: the server rules on the lap it was on')
check(routeState.nextWp == 1, 'the car is armed on CP 1 of the next lap')

-- C4. OUTSIDE THE WINDOW: with a one-gate window, cutting two is ignored.
newSession(nil, cpWith({ maxGates = 1 }))
driveTo(0, 150)
around(200)
around(300)
driveTo(0, 420)
check(#sentOf('RM_CheckpointSkip') == 0 and #sentOf('RM_Lap') == 0,
  'a crossing past the window is no skip, as always')
check(routeState.nextWp == 2, 'the car is still armed on CP 2')

-- C5. REVERSING through the gate just cleared, or the one before it: nothing.
newSession()
driveTo(0, 250)
check(routeState.nextWp == 3, 'CP 1 and CP 2 cleared')
driveTo(0, 50)               -- backwards through CP 2 and CP 1
driveTo(0, 250)              -- and forwards again
check(#sentOf('RM_CheckpointSkip') == 0 and routeState.nextWp == 3,
  'reversing through gates already cleared changes nothing')

-- C6. RESETS AND TELEPORTS are never a skip.
newSession()
driveTo(0, 150)
around(200)
driveTo(0, 295)
RM.onVehicleResetted(VEH_ID)
driveTo(0, 305)
check(#sentOf('RM_CheckpointSkip') == 0, 'crossing CP 3 straight after our own reset is no skip')
check(routeState.nextWp == 2, 'and the car is still armed on CP 2')
driveTo(0, 295)              -- back behind CP 3
frames(1.0)                  -- the reset is long gone
driveTo(0, 305)
check(#sentOf('RM_CheckpointSkip') == 1, 'once it has settled, the same crossing is a skip')
newSession()
driveTo(0, 150)
driveTo(25, 250)
clearLog()
veh.x, veh.y = 0, 320; RM.onUpdate(0.05)    -- 74 m in one frame, through CP 3
check(#sentOf('RM_CheckpointSkip') == 0, 'a teleport through a gate is no skip')

-- C7. AGAINST THE GATES: a car running the route backwards raises no skip.
newSession()
veh.x, veh.y = 0, 470; RM.onUpdate(0.05)
driveTo(0, -60)
check(#sentOf('RM_CheckpointSkip') == 0, 'running the course the wrong way raises no skip')

-- C8. THE GRID BEHIND THE LINE (track B): the line is driven over first.
-- (The editor is shut while a session runs: between sessions to rebuild.)
state({ phase = 'waiting' })
RM.clearTrackState()
RM.setEditorTarget('main')
RM.editorAdd({ x = 0, y = 100, z = 0, hx = 0, hy = 1 })
RM.editorAdd({ x = 0, y = 200, z = 0, hx = 0, hy = 1 })
RM.editorAdd({ x = 0, y = 10, z = 0, hx = 0, hy = 1 })    -- the line, just ahead of the grid
check(#routeState.waypoints == 3, 'track B: two gates and the line just ahead of the grid')
newSession()
driveTo(0, 50)
check(#sentOf('RM_CheckpointSkip') == 0 and #sentOf('RM_Lap') == 0,
  'crossing the line just after GO is not a skip')
driveTo(0, 150)
check(routeState.nextWp == 2, 'and CP 1 is then cleared the ordinary way')

-- Back to track A, with a joker loop beside it and branch gates.
state({ phase = 'waiting' })
RM.clearTrackState()
RM.setEditorTarget('main')
for _, y in ipairs({ 100, 200, 300, 400 }) do
  RM.editorAdd({ x = 0, y = y, z = 0, hx = 0, hy = 1 })
end
RM.setEditorTarget('joker')
RM.editorAdd({ x = 80, y = 200, z = 0, hx = 0, hy = 1 })
RM.editorAdd({ x = 80, y = 300, z = 0, hx = 0, hy = 1 })
-- Slot 3, two more ways: a lane at x = 60 facing the same way, and a head-on
-- lane's gate in the main corridor facing back down it.
RM.setEditorTarget('branch')
RM.setBranchSlot(3)
RM.editorAdd({ x = 60, y = 300, z = 0, hx = 0, hy = 1 })
RM.setBranchSlot(3)
RM.editorAdd({ x = 0, y = 250, z = 0, hx = 0, hy = -1 })
RM.setEditorTarget('main')
check(#routeState.waypoints == 4 and #routeState.jokerRoute == 2 and #routeState.branches == 2,
  'track A again, with a joker loop and two branch gates for CP 3')

-- C9. BRANCH GATES: a branch gate driven its way is a skip; against it, not.
newSession()
driveTo(0, 150)
around(200)
driveTo(0, 245)              -- just before the head-on gate at y = 250
clearLog()
driveTo(0, 260)              -- through it, against its heading
check(#sentOf('RM_CheckpointSkip') == 0, 'a branch gate crossed against its heading is no skip')
newSession()
driveTo(0, 150)
driveTo(35, 180); driveTo(60, 260)
driveTo(60, 320)             -- the x = 60 lane's gate for CP 3, its way
rep = sentOf('RM_CheckpointSkip')[1]
check(rep and rep.to == 3 and rep.skipped == 1, 'a branch gate driven its way lands a skip like the main one')

-- C10. THE JOKER ROUTE is never a skip.
newSession({ jokerEnabled = true })
driveTo(0, 150)
driveTo(80, 170); driveTo(80, 330); driveTo(0, 360)
check(#sentOf('RM_CheckpointSkip') == 0, 'the joker route is never counted as a skip')

-- C11. OUT LAPS: no detection on qualifying's out lap or the pace lap.
newSession({ phase = 'qualifying', qualiOutLap = true })
driveTo(0, 150)
around(200)
driveTo(0, 330)
check(#sentOf('RM_CheckpointSkip') == 0, 'qualifying: no skip on the out lap')
check(routeState.nextWp == 2, 'the out lap is left armed on the gate it missed')
driveTo(0, 190)              -- back through CP 2 (either direction clears it)
driveTo(0, 420)              -- CP 3, the line: the out lap is done
check(#sentOf('RM_Lap') == 1, 'the out lap completes')
toStart(); clearLog()
driveTo(0, 150)
around(200)
driveTo(0, 330)
check(#sentOf('RM_CheckpointSkip') == 1, 'qualifying: a skip on a timed lap is reported')
check(noticeHas('CHECKPOINT SKIPPED') and noticeHas('This lap will not be timed'),
  'and the driver is told the lap will not be timed')
newSession({ paceLap = true, pacing = true, qualiOutLap = true, flag = 'yellow' })
driveTo(0, 150)
around(200)
driveTo(0, 330)
check(#sentOf('RM_CheckpointSkip') == 0, 'the pace lap: no skip')

-- ---------------------------------------------------------------------------
-- C12. What the driver is told as their row changes
-- ---------------------------------------------------------------------------
newSession()
state(nil, { checkpointWarningsUsed = 1 })
check(noticeHas('Track Cut Warning (1/2) - next skip: +5.0s'), 'a warning, from the row')
local n = noticeHas('Track Cut Warning')
check(n and n.kind == 'penalty', 'as a penalty notice')
local onHud = false
for _, m in ipairs(hud) do
  if m.category == 'raceManager_penalty' and m.msg:find('Track Cut Warning', 1, true) then onHud = true end
end
check(onHud, 'which reaches the HUD')
clearLog()
state(nil, { checkpointWarningsUsed = 2, penaltySeconds = 5 })
check(noticeHas('Track Cut: last warning used, +5.0s for 1 more checkpoint'), 'the last warning and a penalty')
check(lastUpdate.myCpSkip and lastUpdate.myCpSkip.pen == 5 and lastUpdate.myCpSkip.warn == 2,
  'and the header readout gets our own tallies')
clearLog()
state(nil, { checkpointWarningsUsed = 2, penaltySeconds = 15 })
check(noticeHas('2 checkpoints skipped: +10.0s penalty (warnings used up)'), 'a two-gate penalty')
clearLog()
state(nil, { checkpointWarningsUsed = 2, penaltySeconds = 15 })
check(#notices == 0, 'an unchanged row says nothing')

-- ---------------------------------------------------------------------------
-- C13. THE LIFT
-- ---------------------------------------------------------------------------
local LIFT = cpWith({ type = 'lift', warnings = 0 })
newSession(nil, LIFT)
veh.speed, vm.throttle = 30, 0
state(nil, { liftOwed = 1, liftWindowLeft = 30 }, LIFT)
check(noticeHas('Checkpoint skipped: LIFT OFF THE THROTTLE for 3.0s within 30s'),
  'the lift is announced off the row')
frames(0.5)
check((lastLiftLine() or ''):find('LIFT OFF THE THROTTLE: ', 1, true) ~= nil,
  'the HUD holds the lift line, counting down')
frames(2.0)
check(#sentOf('RM_LiftServed') == 0, 'not served before 3 seconds off the throttle')
frames(0.7)
check(#sentOf('RM_LiftServed') == 1, 'served after 3 seconds off the throttle at speed')
check(noticeHas('LIFT SERVED - carry on'), 'and the driver is told to carry on')
frames(5)
check(#sentOf('RM_LiftServed') == 1, 'served once, not again while the server catches up')
clearLog()
state(nil, {}, LIFT)                     -- the server took it off
check(#notices == 0, 'the row catching up says nothing more')

-- A BLIP is forgiven; holding the throttle restarts the lift.
state(nil, { liftOwed = 1, liftWindowLeft = 30 }, LIFT)
clearLog()
frames(1.5)
vm.throttle = 1; frames(0.1)
vm.throttle = 0; frames(1.6)
check(#sentOf('RM_LiftServed') == 1, 'a blip shorter than the grace does not restart it')
state(nil, {}, LIFT)
state(nil, { liftOwed = 1, liftWindowLeft = 30 }, LIFT)
clearLog()
frames(1.5)
vm.throttle = 1; frames(0.5)
check((lastLiftLine() or ''):find('THROTTLE ON - lift restarted (3.0s)', 1, true) ~= nil,
  'back on the throttle: the line says the lift restarted')
vm.throttle = 0; frames(2.8)
check(#sentOf('RM_LiftServed') == 0, 'held on past the grace: the lift starts over')
frames(0.4)
check(#sentOf('RM_LiftServed') == 1, 'and is served three seconds after the throttle came off')
state(nil, {}, LIFT)

-- PAUSED: under caution, under red, when stopped, and with no reading.
state(nil, { liftOwed = 1, liftWindowLeft = 30 }, LIFT)
clearLog()
frames(1.0)
state({ caution = true, flag = 'yellow' }, { liftOwed = 1 }, LIFT)
frames(5.0)
check(#sentOf('RM_LiftServed') == 0, 'a caution pauses the lift')
state({ flag = 'red' }, { liftOwed = 1 }, LIFT)
frames(5.0)
check(#sentOf('RM_LiftServed') == 0, 'so does a red flag')
state(nil, { liftOwed = 1 }, LIFT)
veh.speed = 0
frames(5.0)
check(#sentOf('RM_LiftServed') == 0, 'a stopped car (a pit stall, a spin) is not serving it')
check((lastLiftLine() or ''):find('(paused)', 1, true) ~= nil, 'and the line says it is paused')
veh.speed, vm.silent = 30, true
frames(5.0)
check(#sentOf('RM_LiftServed') == 0, 'no throttle reading from the vehicle: paused')
vm.silent = false
frames(2.2)
check(#sentOf('RM_LiftServed') == 1, 'and it resumes with what was left (about 2s)')
state(nil, {}, LIFT)

-- STACKED: two owed are served one after the other.
state(nil, { liftOwed = 2, liftWindowLeft = 30 }, LIFT)
clearLog()
frames(0.5)
check((lastLiftLine() or ''):find('(1 more after this)', 1, true) ~= nil, 'two owed: the line says so')
frames(3.0)
check(#sentOf('RM_LiftServed') == 1, 'the first is served')
frames(3.2)
check(#sentOf('RM_LiftServed') == 2, 'then the second')
state(nil, {}, LIFT)

-- IT DOES NOT EXPIRE like the other HUD lines: still there after 200 s.
state(nil, { liftOwed = 1, liftWindowLeft = 30 }, LIFT)
veh.speed = 0
frames(200, 0.5)
hud = {}
frames(1, 0.5)
check((lastLiftLine() or ''):find('LIFT OFF THE THROTTLE', 1, true) ~= nil,
  'the lift line is still on the HUD after 200 s')
veh.speed = 30

-- NOT SERVED: the server turns it into time, and the driver hears it.
clearLog()
state(nil, { penaltySeconds = 5 }, LIFT)
check(noticeHas('Lift not served: +5.0s penalty'), 'a lift turned into time is told')
frames(1)
check(#sentOf('RM_LiftServed') == 0, 'and nothing is left to serve')

-- ---------------------------------------------------------------------------
-- C14. The place at the flag, provisional under a penalty
-- ---------------------------------------------------------------------------
clearLog()
handlers['RM_ForceSpectate']({ reason = 'You finished the race', source = 'race', place = 3,
  provisional = true })
check(noticeHas('You placed 3rd (provisional: penalty applied)'),
  'a place with a penalty on it is told as provisional')

print(string.format('checkpoint_skip_test (client): %d checks, %d failures',
  checks - serverChecks, fails - serverFails))
print(string.format('checkpoint_skip_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
