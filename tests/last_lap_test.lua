-- Headless test for the lap data the BROADCAST FEED reads off every driver row
-- (server/RaceManager/main.lua): the last lap's time, the crossing it was
-- completed on, and pit stops.
--
--   * lastLap is the time of the lap just completed, to the millisecond, or nil
--     when that lap set none: a race's standing-start lap, a cut lap.
--   * lastLapOn is the crossing it belongs to, stamped even when the lap has no
--     time, so a feed can tell a new lap from the same time twice.
--   * The qualifying out lap touches neither.
--   * pitStops rides the wire, and zero goes out as nil like the other tallies.
--   * A new grid, the green and sitting a race out all start them over.
--
-- Run from the repo root: lua5.3 tests/last_lap_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local connected = { [0] = 'Admin', [1] = 'Alice', [2] = 'Bob', [3] = 'Cara' }
local lastState  = nil
local timers     = {}

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function () end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then lastState = payload end
  end,
  RegisterEvent = function () end,
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
local function lap(pid, t, cut)
  RM_onLap(pid, string.format('{"lapTime":%.4f%s}', t or 60, cut and ',"cut":true' or ''))
end
local function pit(pid) RM_onPitStop(pid, '{"stall":1}') end
local function startRace()
  RM_onGenerateGrid(0)
  RM_onStartCountdown(0)
  for _ = 1, 70 do
    if lastState.phase == 'racing' then break end
    RM_CountdownTick()
  end
end

onInit()
RM_onLogin(0, '{"password":"phoenix"}'); RM_onSetReadyCheck(0, '{"on":false}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":5}')
RM_onSetPaceLap(0, '{"enabled":false}')
-- The client's cut flag counts only with the checkpoint-skip rule on, and the
-- rule is locked once a session runs. Warnings to spare: a cut costs nothing else.
RM_onSetCheckpointSkip(0, '{"enabled":true,"warnings":5}')

-- ---------------------------------------------------------------------------
-- 1. A race: the standing start sets no time, the laps after it do
-- ---------------------------------------------------------------------------
startRace()
check(lastState.phase == 'racing', 'a race is running')
check(driver(1).lastLap == nil and driver(1).lastLapOn == nil,
  'nothing completed yet: no last lap and no crossing')
check(driver(1).pitStops == nil, 'no stops: zero goes out as nil')

lap(1, 71.5)
check(driver(1).lastLap == nil, 'the standing-start lap counts but sets no last-lap time')
check(driver(1).lastLapOn == 1, 'its crossing is stamped all the same')

lap(1, 62.12345)
check(driver(1).lastLap == 62.123, 'a timed lap is the last lap, to the millisecond')
check(driver(1).lastLapOn == 2, 'on crossing 2')

lap(1, 62.123)
check(driver(1).lastLap == 62.123 and driver(1).lastLapOn == 3,
  'the same time again is a new crossing: lastLapOn moves on')

-- ---------------------------------------------------------------------------
-- 2. A cut lap: no time, the crossing still stamped
-- ---------------------------------------------------------------------------
lap(1, 55.0, true)
check(driver(1).lastLap == nil, 'a cut lap leaves no last-lap time')
check(driver(1).lastLapOn == 4, 'but its crossing is stamped')
check(driver(1).raceBest == 62.123, 'and the best is untouched')

-- ---------------------------------------------------------------------------
-- 3. Pit stops ride the wire
-- ---------------------------------------------------------------------------
pit(2)
check(driver(2).pitStops == 1, 'one stop is on the wire')
pit(2)
check(driver(2).pitStops == 2, 'two stops')
check(driver(3).pitStops == nil, 'a car that never stopped still sends nil')

-- ---------------------------------------------------------------------------
-- 4. The final crossing: currentLap stays, lastLapOn still names it
-- ---------------------------------------------------------------------------
lap(1, 60.5)
check(driver(1).status == 'finished', 'Alice takes the flag on lap 5')
check(driver(1).lastLap == 60.5 and driver(1).lastLapOn == 5,
  'the last lap and the crossing it was are on the wire at the flag')
RM_onEndRace(0)
if lastState.phase ~= 'waiting' and lastState.phase ~= 'finished' then RM_onEndRace(0) end

-- ---------------------------------------------------------------------------
-- 5. A new grid starts them over; sitting a race out clears them too
-- ---------------------------------------------------------------------------
RM_onSetSpectating(2, '{"spectating":true}')
RM_onGenerateGrid(0)
check(lastState.phase == 'grid', 'a new grid forms')
check(driver(1).lastLap == nil and driver(1).lastLapOn == nil,
  'the grid clears the last lap and its crossing')
check(driver(2).pitStops == nil, 'a driver sitting this one out keeps no stops from the last')
RM_onStartCountdown(0)
for _ = 1, 70 do
  if lastState.phase == 'racing' then break end
  RM_CountdownTick()
end
check(lastState.phase == 'racing', 'and goes green')
check(driver(1).lastLap == nil and driver(1).lastLapOn == nil and driver(1).pitStops == nil,
  'nothing carried over to the green')
RM_onEndRace(0)
if lastState.phase ~= 'waiting' and lastState.phase ~= 'finished' then RM_onEndRace(0) end
RM_onSetSpectating(2, '{"spectating":false}')

-- ---------------------------------------------------------------------------
-- 6. Behind the pace car: the formation crossing is crossing 1, no time
-- ---------------------------------------------------------------------------
RM_onSetPaceLap(0, '{"enabled":true}')
RM_onGenerateGrid(0)
RM_onStartRace(0)
check(lastState.pacing == true, 'the field is on its pace lap')
lap(3, 90)
check(driver(3).lastLap == nil and driver(3).lastLapOn == 1,
  'the formation crossing is stamped with no time')
RM_onEndRace(0)
if lastState.phase ~= 'waiting' and lastState.phase ~= 'finished' then RM_onEndRace(0) end
RM_onSetPaceLap(0, '{"enabled":false}')

-- ---------------------------------------------------------------------------
-- 7. Qualifying: the out lap touches neither field; timed laps do
-- ---------------------------------------------------------------------------
RM_onSetQualiLimits(0, '{"laps":3,"seconds":0}')
RM_onStartQualifying(0)
RM_onStartCountdown(0)
for _ = 1, 70 do
  if lastState.phase == 'qualifying' then break end
  RM_CountdownTick()
end
check(lastState.phase == 'qualifying', 'qualifying is running')
lap(1, 80)
check(driver(1).lastLap == nil and driver(1).lastLapOn == nil,
  'the qualifying out lap leaves both untouched')
lap(1, 58.25)
check(driver(1).lastLap == 58.25 and driver(1).lastLapOn ~= nil,
  'the first timed qualifying lap is the last lap')
RM_onEndRace(0)

print(string.format('last_lap_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
