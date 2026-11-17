-- Headless test for THE CAUTION RULE and PASSES UNDER CAUTION in
-- server/RaceManager/main.lua.
--
-- Two things a league asked for:
--
--   * A caution FROZEN AT THE CALL. Racing back to the line is the default
--     (tests/caution_test.lua), and leagues that do not race back need the
--     field locked where it stands the moment Caution is pressed.
--   * Seeing passes made under yellow. The board already ignores them while
--     the caution is out -- but the green thaws it back to the road, so a
--     place taken under yellow and never given back is a place KEPT. The
--     server cannot stop a car, so it watches: every car locked behind another
--     is compared with it on the road, and a pass is told to the driver and to
--     race control, and so is giving it back. Whatever is still owed at the
--     green is reported then, and every pass goes in the results file.
--
-- Also the review's two fixes: the results file's laps under caution are the
-- whole race's, not the last caution's; and the advisory yellow no longer tells
-- a field to race back to the line when nothing is frozen.
--
-- Run from the repo root: lua5.3 tests/caution_freeze_test.lua
local connected = { [0] = 'Admin', [1] = 'Alice', [2] = 'Bob', [3] = 'Cara', [4] = 'Dan' }
local lastState = nil
local chatLog   = {}
local lapCredits = {}
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
    if event == 'RM_LapCredit' then lapCredits[target] = payload.lap end
  end,
  RegisterEvent = function () end,
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

local RESULTS_DIR = 'Resources/Server/PhoenixRM Server/Data/results'
os.execute(package.config:sub(1, 1) == '\\'
  and ('rmdir /s /q "' .. RESULTS_DIR:gsub('/', '\\') .. '" 2>nul')
  or  ('rm -rf "' .. RESULTS_DIR .. '"'))

dofile('server/RaceManager/main.lua')

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function driver(pid)
  for _, d in ipairs(lastState.drivers) do
    if d.id == pid then return d end
  end
end
-- A chat line containing `text`, to `pid` (or to anyone with pid nil).
local function chatTo(pid, text)
  for _, m in ipairs(chatLog) do
    if (pid == nil or m.to == pid) and m.msg:find(text, 1, true) then return m.msg end
  end
  return nil
end
local function chatClear() chatLog = {} end
local function seconds(n)
  for _ = 1, math.floor(n * 10) do RM_Tick() end
end
local function lap(pid) RM_onLap(pid, '{"lapTime":60.0}') end
local function report(pid, lapNum, cp, dist)
  RM_onProgress(pid, string.format('{"lap":%d,"cp":%d,"dist":%.1f}', lapNum, cp, dist))
end
local function order()
  local out = {}
  for _, d in ipairs(lastState.drivers) do
    if not d.spectating then out[#out + 1] = d.id end
  end
  return table.concat(out, ',')
end

onInit()
RM_onLogin(0, '{"password":"phoenix"}'); RM_onSetReadyCheck(0, '{"on":false}')
RM_onSetResultsSave(0, '{"server":true}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":20}')

-- ---------------------------------------------------------------------------
-- 1. THE RULE IS A SETTING, AND AN ADMIN'S
-- ---------------------------------------------------------------------------
RM_onRequestState(0)
check(lastState.cautionMode == 'line', 'racing back to the line is the default')
RM_onSetCautionMode(3, '{"mode":"call"}')
check(lastState.cautionMode == 'line', 'a driver cannot change it')
RM_onSetCautionMode(0, '{"mode":"sideways"}')
check(lastState.cautionMode == 'line', 'nor can a rule that does not exist')
RM_onSetCautionMode(0, '{"mode":"call"}')
check(lastState.cautionMode == 'call', 'an admin sets freeze at the call')

-- Alice, Bob, Cara on the lead lap; Dan a lap down (as caution_test).
RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
lap(1); lap(2); lap(3); lap(4)
lap(1); lap(2); lap(3)
report(1, 3, 2, 100.0)
report(2, 3, 1, 50.0)
report(3, 3, 1, 300.0)
report(4, 2, 1, 50.0)
seconds(0.5)
check(order() == '1,2,3,4', 'the live order is Alice, Bob, Cara, Dan (got ' .. order() .. ')')

-- ---------------------------------------------------------------------------
-- 2. FROZEN AT THE CALL: no race back, no pending yellow
-- ---------------------------------------------------------------------------
chatClear()
RM_onCaution(0)
check(lastState.caution == true, 'the caution is official the moment it is called')
check(lastState.cautionPending ~= true, 'with nothing pending: nobody races back')
check(chatTo(-1, 'FROZEN AS OF NOW') ~= nil, 'and the field is told so')
check(chatTo(-1, 'RACE BACK') == nil, 'and is not told to race back')
check(order() == '1,2,3,4', 'the board is the order at the call')
check(driver(4).cautionDown == 1, 'Dan is a lap down at the call')
check(driver(1).cautionDown == 0 and driver(3).cautionDown == 0, 'the rest are on the lead lap')

RM_onSetCautionMode(0, '{"mode":"line"}')
check(lastState.cautionMode == 'call', 'the rule cannot change under a caution')
check(chatTo(0, 'Not while a caution is out') ~= nil, 'and the admin is told why')

-- ---------------------------------------------------------------------------
-- 3. A PASS UNDER CAUTION IS SEEN, AND TOLD
-- ---------------------------------------------------------------------------
-- Side by side is not a pass: Bob draws level with Alice, 2 m up the road.
report(2, 3, 2, 98.0)
seconds(2)
check(driver(2).ucPassed == nil, 'two cars alongside, inside the margin, are not a pass')
report(2, 3, 1, 50.0)

-- Cara goes by Bob (a checkpoint further round), still behind Alice.
chatClear()
report(3, 3, 2, 150.0)
seconds(0.4)
check(order() == '1,2,3,4', 'the board does not move: the pass does not count')
check(driver(3).ucPassed == nil, 'and a moment ahead is not yet a pass (telemetry jitter)')
seconds(1.5)
check(driver(3).ucPassed == 'Bob', 'held for a second, it is a pass, on Cara\'s row (got '
  .. tostring(driver(3).ucPassed) .. ')')
check(chatTo(3, 'PASSED UNDER CAUTION') ~= nil, 'Cara is told to give it back')
check(chatTo(0, 'Cara passed Bob under caution') ~= nil, 'race control is told who and whom')
check(lastState.cautionPasses and #lastState.cautionPasses == 1
  and lastState.cautionPasses[1].restored == false, 'and it is on the race control list')
check(order() == '1,2,3,4', 'the board still holds the frozen order')

-- A lead-lap car going by a backmarker on the road is no pass, and nor is the
-- backmarker getting ahead on the road: race distance decides.
report(4, 2, 3, 10.0)
seconds(2)
check(driver(4).ucPassed == nil, 'a car a lap down ahead on the road has passed nobody')

-- Cara drops back behind Bob: the place is given back.
chatClear()
report(3, 3, 1, 100.0)
seconds(0.5)
check(driver(3).ucPassed == nil, 'back behind Bob, Cara owes nothing')
check(chatTo(3, 'Place given back to Bob') ~= nil, 'Cara is told')
check(chatTo(0, 'Cara gave the place back to Bob') ~= nil, 'and so is race control')
check(lastState.cautionPasses[1].restored == true, 'the list says given back')

-- The leader runs a lap under this caution.
lap(1)
seconds(0.3)
check(lastState.cautionLaps == 1, 'one lap under the first caution')

-- ---------------------------------------------------------------------------
-- 4. A PASS STILL OWED AT THE GREEN IS REPORTED
-- ---------------------------------------------------------------------------
-- Cara goes by again and keeps it. The green thaws the board to the road, so
-- this is the place she takes with her: nothing can take it away, but race
-- control hears of it before the order thaws.
report(3, 3, 2, 140.0)
seconds(1.5)
check(driver(3).ucPassed == 'Bob', 'Cara passes Bob a second time')
chatClear()
RM_onSetFlag(0, '{"flag":"green"}')
check(lastState.caution == false, 'the green restarts the race')
check(chatTo(0, 'at the green, Cara is still ahead of Bob') ~= nil,
  'race control is told who restarted ahead of a car they passed under yellow')
check(driver(3).ucPassed == nil, 'and nobody owes anything under green')
check(#lastState.cautionPasses == 2, 'both passes stay on the list for the race')

-- ---------------------------------------------------------------------------
-- 5. THE FREE PASS, DECIDED AT THE CALL
-- ---------------------------------------------------------------------------
RM_onSetLuckyDog(0, '{"enabled":true}')
report(1, 3, 2, 100.0); report(2, 3, 2, 120.0); report(3, 3, 2, 130.0)
report(4, 2, 1, 50.0)
seconds(0.5)
chatClear()
RM_onCaution(0)
check(lapCredits[4] ~= nil, 'the first car a lap down gets its lap back at once')
check(driver(4).cautionDown == 0, 'and is on the lead lap')
check(order() == '1,2,3,4', 'at its tail')
-- On the road the free pass car is wherever it was; it is not a passer.
report(4, 3, 3, 10.0)
seconds(2)
check(driver(4).ucPassed == nil, 'the free pass car is never flagged for dropping back')
lap(1)
seconds(0.3)
check(lastState.cautionLaps == 1, 'the panel counts this caution\'s laps from one again')
RM_onSetFlag(0, '{"flag":"green"}')

-- ---------------------------------------------------------------------------
-- 6. RACING BACK: passes on the way to the line are the rule
-- ---------------------------------------------------------------------------
RM_onSetCautionMode(0, '{"mode":"line"}')
check(lastState.cautionMode == 'line', 'back to racing to the line')
report(1, 3, 3, 100.0); report(2, 3, 2, 50.0); report(3, 3, 2, 80.0)
seconds(0.5)
RM_onCaution(0)
check(lastState.cautionPending == true, 'the caution is pending: the field races back')
report(3, 3, 2, 10.0)   -- Cara by Bob on the way to the line
seconds(2)
check(driver(3).ucPassed == nil, 'a pass while racing back to the line is no pass at all')

-- A red over a caution still being raced back to, lifted, is that caution
-- again: not a green with the caution left armed underneath it.
RM_onSetFlag(0, '{"flag":"red"}')
RM_onSetFlag(0, '{"flag":"green"}')
check(lastState.flag == 'yellow' and lastState.cautionPending == true,
  'lifting a red goes back to the caution being raced back to')
-- A green before it goes official withdraws it, and it is not counted.
RM_onSetFlag(0, '{"flag":"green"}')
check(lastState.flag == 'green' and lastState.cautionPending ~= true,
  'a green before the leader makes it official withdraws the caution')
lap(1)
seconds(0.3)
check(lastState.caution ~= true, 'so the leader\'s crossing freezes nothing under green')

-- ---------------------------------------------------------------------------
-- 6b. THE RED FLAG AGAINST THE CAUTION
-- ---------------------------------------------------------------------------
-- Caution pressed while a red is out used to overwrite the red with the yellow:
-- the clock ran again, and a field told to stop was told to race back. The
-- red stands now, and lifting it is what puts the field under the caution.
RM_onSetFlag(0, '{"flag":"red"}')
chatClear()
RM_onCaution(0)
check(lastState.flag == 'red' and lastState.clockStopped == true,
  'racing back: a caution called under a red leaves the red out and the clock stopped')
check(lastState.cautionPending == true, 'with the caution pending underneath')
check(chatTo(-1, 'UNDER THE RED FLAG: stay stopped') ~= nil, 'and the field is told to stay stopped')
RM_onSetFlag(0, '{"flag":"green"}')
check(lastState.flag == 'yellow' and lastState.cautionPending == true,
  'lifting the red puts the field under the caution, racing back')
RM_onSetFlag(0, '{"flag":"green"}')   -- withdrawn before it went official

RM_onSetCautionMode(0, '{"mode":"call"}')
report(1, 3, 3, 100.0); report(2, 3, 2, 50.0); report(3, 3, 2, 80.0)
seconds(0.5)
RM_onSetFlag(0, '{"flag":"red"}')
chatClear()
RM_onCaution(0)
check(lastState.flag == 'red' and lastState.clockStopped == true,
  'frozen at the call: a caution called under a red leaves the red out too')
check(lastState.caution == true, 'with the order frozen where the field stands')
check(chatTo(-1, 'frozen where you stand') ~= nil, 'and the field is told so')

-- A car driving past a stopped field under the red, over a caution, is caught,
-- and told to give it back once the red is lifted rather than now.
chatClear()
report(3, 3, 2, 30.0)
seconds(2)
check(driver(3).ucPassed == 'Bob', 'a pass under the red over a caution is seen')
check(chatTo(3, 'give the place back when the red is lifted') ~= nil,
  'the driver is told to stay stopped and give it back after the red')
check(chatTo(0, 'Cara passed Bob under the red flag') ~= nil, 'race control is told it was under the red')
RM_onSetFlag(0, '{"flag":"green"}')
check(lastState.flag == 'yellow' and lastState.caution == true, 'lifting the red returns to the caution')
report(3, 3, 2, 90.0)
seconds(0.5)
check(driver(3).ucPassed == nil, 'and the place can be given back under it')
RM_onSetFlag(0, '{"flag":"green"}')
check(lastState.caution == false, 'then the green restarts the race')
RM_onSetCautionMode(0, '{"mode":"line"}')

-- ---------------------------------------------------------------------------
-- 7. THE ADVISORY YELLOW IS A HAZARD, NOT A RACE BACK
-- ---------------------------------------------------------------------------
chatClear()
RM_onSetFlag(0, '{"flag":"yellow"}')
check(lastState.caution ~= true and lastState.cautionPending ~= true, 'a plain yellow freezes nothing')
check(chatTo(-1, 'hazard on track') ~= nil and chatTo(-1, 'race back') == nil,
  'and does not tell the field to race back to the line')
RM_onSetFlag(0, '{"flag":"green"}')
RM_onEndRace(0)

-- ---------------------------------------------------------------------------
-- 8. THE RESULTS FILE
-- ---------------------------------------------------------------------------
-- The written file, named in the chat line that announced it.
local path = nil
for _, m in ipairs(chatLog) do
  path = path or m.msg:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
end
local f = path and io.open(path, 'r')
local text = f and f:read('*a') or ''
if f then f:close() end
check(text:find('Cautions: 3,', 1, true) ~= nil,
  'the results count the three cautions that went official, not the two withdrawn')
check(text:find('Cara on Bob, lap 3, under the red flag (given back)', 1, true) ~= nil,
  'a pass under the red is marked so')
check(text:find('over 2 laps', 1, true) ~= nil,
  'over every lap run under them, not only the last caution\'s (got: '
    .. tostring(text:match('Cautions:[^\n]*')) .. ')')
check(text:find('(frozen at the call, and raced back to the line)', 1, true) ~= nil,
  'and under which rules, both used here')
check(text:find('Passed under caution: Cara on Bob, lap 3 (given back)', 1, true) ~= nil,
  'and list the pass that was given back')
check(text:find('Passed under caution: Cara on Bob, lap 3 (NOT given back)', 1, true) ~= nil,
  'and the one that was not')
-- A lap handed back is in the file too: Dan finished on the lead lap without
-- driving all of it.
check(text:find('Free pass, caution 2: Dan +1 lap', 1, true) ~= nil,
  'and the free pass, with the caution it came from (got: '
    .. tostring(text:match('Free pass[^\n]*')) .. ')')

os.execute(package.config:sub(1, 1) == '\\'
  and ('rmdir /s /q "' .. RESULTS_DIR:gsub('/', '\\') .. '" 2>nul')
  or  ('rm -rf "' .. RESULTS_DIR .. '"'))
print(string.format('caution_freeze_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
