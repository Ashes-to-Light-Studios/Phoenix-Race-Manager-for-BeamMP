-- Headless test for MANDATORY PIT STOPS (server side).
-- Run from the repo root: lua5.3 tests/pit_stops_required_test.lua
--
-- An admin can require N pit stops in a race. At most one counts per lap: two
-- stalls on one visit is one stop. A finisher short of N is disqualified at the
-- flag (the default) or given seconds per missing stop. Like Required serving,
-- it needs stalls: with none on the loaded layout it does not run.

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local connected = { [0] = 'Admin', [1] = 'Alice', [2] = 'Bob', [3] = 'Cara', [4] = 'Dan' }
local lastState, chatLog, registered = nil, {}, {}
local resultsText = nil

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) chatLog[#chatLog + 1] = { to = target, msg = msg } end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (_, event, payload)
    if event == 'RM_Update' then lastState = payload end
    if event == 'RM_ResultsFile' then resultsText = payload.text end
  end,
  RegisterEvent = function (event, fn) registered[event] = fn end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
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

-- Rules outlive a boot (rules.lua): start from config.json's, not the last test's.
os.remove('Resources/Server/PhoenixRM Server/Data/rules.json')
dofile('server/RaceManager/main.lua')

local function driver(pid)
  for _, d in ipairs(lastState.drivers) do
    if d.id == pid then return d end
  end
end
local function chatTo(pid, text)
  for _, c in ipairs(chatLog) do
    if c.to == pid and c.msg:find(text, 1, true) then return c.msg end
  end
end
local function chatClear() chatLog = {} end
local function seconds(n)
  for _ = 1, math.floor(n * 10 + 0.5) do RM_Tick() end
end
local function lap(pid) RM_onLap(pid, '{"lapTime":60}') end
local function pitStop(pid) RM_onPitStop(pid, '{"stall":1}') end
local function setRule(pid, json) RM_onSetPitStopRule(pid, json) end
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
  if lastState.phase ~= 'finished' then RM_onEndRace(0) end
end
local function raceBlock()
  return (resultsText or ''):match('%-%-%- RACE RESULTS %-%-%-(.*)$') or ''
end
local function lineOf(name)
  return raceBlock():match('\n([PD][%dSN][^\n]*' .. name .. '[^\n]*)') or ''
end
local GATES = '[{"x":0,"y":0,"z":0,"hx":0,"hy":1},{"x":100,"y":0,"z":0,"hx":1,"hy":0},'
  .. '{"x":100,"y":100,"z":0,"hx":0,"hy":-1}]'
local function loadLayout(name, withPits)
  RM_onSaveLayout(0, '{"name":"' .. name .. '","width":20,"checkpoints":' .. GATES
    .. (withPits and ',"pits":[{"x":-50,"y":0,"z":0,"hx":0,"hy":1},{"x":-50,"y":-8,"z":0,"hx":0,"hy":1}]' or '')
    .. '}')
  RM_onLoadLayout(0, '{"name":"' .. name .. '"}')
end

onInit()
check(registered.RM_SetPitStopRule == 'RM_onSetPitStopRule', 'RM_SetPitStopRule is registered')
RM_onLogin(0, '{"password":"phoenix"}'); RM_onSetReadyCheck(0, '{"on":false}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":8}')
RM_onSetPaceLap(0, '{"enabled":false}')
RM_onSetFinishRule(0, '{"after":1,"seconds":600}')
RM_onSetResultsSave(0, '{"admins":true}')

-- ---------------------------------------------------------------------------
-- 1. The setting: off as shipped, admin only, clamped, and it needs stalls
-- ---------------------------------------------------------------------------
loadLayout('No Pits', false)
local r = lastState.pitStopRule
check(r and r.required == 0 and r.missed == 'dsq' and r.seconds == 30 and r.active == 0,
  'off as shipped: none required, disqualify if missed, 30 s per stop')

setRule(1, '{"required":2}')
check(lastState.pitStopRule.required == 0, 'a driver cannot set the rule')
setRule(0, '{"required":99,"missed":"bogus","seconds":5000}')
check(lastState.pitStopRule.required == 10 and lastState.pitStopRule.missed == 'dsq'
  and lastState.pitStopRule.seconds == 600,
  'the count is clamped at 10, the seconds at 600, and an unknown outcome is ignored')
setRule(0, '{"required":2,"seconds":30}')
check(lastState.pitStopRule.required == 2 and lastState.pitStopRule.active == 0,
  'on a layout with no stalls the rule is set but not in force')

loadLayout('Pit Lane', true)
check(lastState.pitStopRule.active == 2, 'with stalls loaded, 2 stops are in force')

-- ---------------------------------------------------------------------------
-- 2. Counting: one per lap. Disqualified at the flag when short.
-- ---------------------------------------------------------------------------
chatClear()
startRace()
check(lastState.phase == 'racing', 'the race is on')
check(chatTo(-1, '2 pit stops required, one per lap: missing one disqualifies at the flag') ~= nil,
  'the rule is announced at GO')

setRule(0, '{"required":1}')
check(lastState.pitStopRule.required == 2 and chatTo(0, 'locked while a session') ~= nil,
  'the rule cannot be changed while the race runs')

-- Alice: two stalls on one visit, then a stop on the next lap.
chatClear()
pitStop(1)
pitStop(1)
check(driver(1).pitCounted == 1, 'two stops on the same lap count once')
check(chatTo(1, 'Pit stop 1 of 2 done') ~= nil and chatTo(1, 'Same lap as your last stop') ~= nil,
  'and the driver is told which counted and which did not')
lap(1)
pitStop(1)
check(driver(1).pitCounted == 2 and chatTo(1, 'all required stops made') ~= nil,
  'a stop on the next lap counts, and completes the requirement')
check(driver(1).pitStops == 3, 'every stop is still recorded for the board and the feed')

-- Bob one stop, Cara none, Dan two on separate laps.
pitStop(2)
lap(4); pitStop(4); lap(4); pitStop(4)

-- Alice takes the flag; End Race classifies the rest where they stand.
for _ = 1, 7 do lap(1) end
check(driver(1).status == 'finished', 'Alice is home')
chatClear()
endRace()
check(driver(1).status == 'finished', 'Alice, with 2 of 2, is classified')
check(driver(4).status == 'finished', 'Dan, with 2 of 2, is classified')
check(driver(2).status == 'dsq' and driver(2).outReason == 'Disqualified - Pit Stop Not Made',
  'Bob, with 1 of 2, is disqualified at the flag')
check(driver(3).status == 'dsq', 'Cara, with none, is disqualified too')
check(chatTo(2, '1 required pit stop not made: disqualified at the flag') ~= nil,
  'and Bob is told why')
check((resultsText or ''):find('Mandatory pit stops: 2, one per lap; missed: disqualified', 1, true) ~= nil,
  'the results header states the rule')
check(lineOf('Alice'):find('2/2', 1, true) ~= nil and lineOf('Bob'):find('1/2', 1, true) ~= nil,
  'and a Pits column shows each driver\'s count')

-- ---------------------------------------------------------------------------
-- 3. The time rule: seconds per missing stop, in the classification
-- ---------------------------------------------------------------------------
setRule(0, '{"required":2,"missed":"time","seconds":30}')
check(lastState.pitStopRule.missed == 'time', 'the admin switches to a time penalty')
resultsText = nil
chatClear()
startRace()
check(chatTo(-1, 'each one missed adds 30.0s') ~= nil, 'the time rule is announced at GO')
check(driver(1).pitCounted == nil, 'the counts start over with the race')

-- Bob makes no stops and takes the flag first; Alice makes both and arrives
-- 10 s later. Bob's 60 s puts him behind her.
pitStop(1); lap(1); pitStop(1)
pitStop(3)
for _ = 1, 8 do lap(2) end
check(driver(2).status == 'finished' and driver(2).pitStopPenalty == 60,
  'Bob, home with 0 of 2, carries 60 s')
check(chatTo(2, '2 required pit stops not made: +60.0s on your race time') ~= nil,
  'and is told so as he finishes')
seconds(10)
for _ = 1, 7 do lap(1) end
check(driver(1).status == 'finished' and driver(1).pitStopPenalty == nil, 'Alice is home with none')
endRace()
check(driver(2).status == 'finished', 'a time penalty does not disqualify')
check(driver(3).status == 'finished' and driver(3).pitStopPenalty == 30,
  'Cara, classified where she stood with 1 of 2, carries 30 s')
check(lineOf('Alice'):match('^P1 ') ~= nil,
  'Alice wins: Bob was first on the road, but not by 60 seconds (' .. lineOf('Alice') .. ')')
check(lineOf('Bob'):find('(+60.0s pit)', 1, true) ~= nil, 'Bob\'s time shows the 60 s')
check((resultsText or ''):find('missed: +30.0s per stop', 1, true) ~= nil,
  'and the header states the time rule')
-- The Discord post says the same: the gap is on the time with the 60 s in it.
do
  local post = require('discord').build.race({ file = 'results.txt' })
  local desc = post and post.embed and post.embed.description or ''
  local bobRow = desc:match('\n(P%d+ +Bob[^\n]*)') or ''
  check(bobRow:find('(+60.0s pit)', 1, true) ~= nil, 'the Discord post notes Bob\'s 60 s ('
    .. bobRow .. ')')
  check(bobRow:match('^P%d+ +Bob +%S+ +%+%d') ~= nil,
    'and his gap to the winner counts it, so it is behind her, not ahead')
end

-- ---------------------------------------------------------------------------
-- 3b. A missed stop's seconds ADD to a checkpoint penalty
-- ---------------------------------------------------------------------------
-- Requested: at the end of the race the pit stop penalty goes on top of the
-- penalties for missed checkpoints, and everything that states a penalty says
-- the total, not two figures to add up by hand.
RM_onSetCheckpointSkip(0, '{"enabled":true,"warnings":0,"type":"time","penaltySec":5}')
resultsText = nil
chatClear()
startRace()
pitStop(1); lap(1); pitStop(1)
pitStop(3)
RM_onCheckpointSkip(2, '{"lap":1,"from":2,"to":3,"skipped":1}')
check(driver(2).penaltySeconds == 5, 'Bob skips a checkpoint: +5 s')
for _ = 1, 8 do lap(2) end
check(driver(2).status == 'finished' and driver(2).penaltySeconds == 5
  and driver(2).pitStopPenalty == 60,
  'home with no stops: 60 s more, and the checkpoint 5 s are kept')
check(chatTo(2, '+60.0s on your race time (65.0s of time penalties in all)') ~= nil,
  'and he is told the total')
seconds(10)
for _ = 1, 7 do lap(1) end
endRace()
check(lineOf('Bob'):find('(+65.0s pen incl. 60.0s pit)', 1, true) ~= nil,
  'the results file gives Bob one penalty, the two added up (' .. lineOf('Bob') .. ')')
check(lineOf('Alice'):match('^P1 ') ~= nil and lineOf('Bob'):match('^P2 ') ~= nil,
  'and the classification counts all 65 s: Alice, 10 s behind on the road, wins')
do
  local post = require('discord').build.race({ file = 'results.txt' })
  local desc = post and post.embed and post.embed.description or ''
  local bobRow = desc:match('\n(P%d+ +Bob[^\n]*)') or ''
  check(bobRow:find('(+65.0s pen incl. 60.0s pit)', 1, true) ~= nil,
    'the Discord post says the same total (' .. bobRow .. ')')
end
-- Back as shipped (off, 1 warning): the suite shares one rules.json.
RM_onSetCheckpointSkip(0, '{"enabled":false,"warnings":1}')

-- ---------------------------------------------------------------------------
-- 4. Qualifying ignores it
-- ---------------------------------------------------------------------------
chatClear()
RM_onStartQualifying(0)
RM_onStartCountdown(0)
for _ = 1, 70 do
  if lastState.phase == 'qualifying' then break end
  RM_CountdownTick()
end
check(lastState.phase == 'qualifying', 'qualifying is running')
check(lastState.pitStopRule.active == 0, 'no stops are in force in qualifying')
pitStop(1)
check(chatTo(1, 'Pit stop') == nil and driver(1).pitCounted == nil, 'and a stop there counts nothing')
RM_onEndRace(0)

if fails == 0 then
  print('pit_stops_required_test: ' .. checks .. ' checks, 0 failures')
else
  print('pit_stops_required_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
