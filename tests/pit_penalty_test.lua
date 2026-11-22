-- Headless test for SERVING PENALTY SECONDS IN THE PITS, in
-- server/RaceManager/main.lua and lua/ge/extensions/raceManager.lua.
--
-- A checkpoint-skip penalty is seconds on the race time. With Serve in pits on,
-- a driver who owes seconds and stops in a stall is held for them on top of the
-- usual stop, and they come off. 'optional' lets them; 'required' makes them do
-- it within so many laps, or they are disqualified at the flag.
--
--   * THE CLIENT holds the stop for 5 s plus what its own row owes, and reports
--     RM_PenaltyServed only when the stop runs to the end.
--   * THE SERVER snapshots what is owed when the stop begins (RM_PitStop),
--     checks the served report against its own clock, and serves no more than
--     was owed then. It watches the window in laps and rules at the flag.
--
-- Run from the repo root: lua5.3 tests/pit_penalty_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ===========================================================================
-- PART 1: THE SERVER
-- ===========================================================================
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
local function chatHas(text)
  for _, c in ipairs(chatLog) do
    if c.msg:find(text, 1, true) then return c.msg end
  end
end
local function chatClear() chatLog = {} end
local function seconds(n)
  for _ = 1, math.floor(n * 10 + 0.5) do RM_Tick() end
end
local function skip(pid, lap, to, n)
  RM_onCheckpointSkip(pid, string.format('{"lap":%d,"from":%d,"to":%d,"skipped":%d}',
    lap, to - n, to, n))
end
local function lap(pid) RM_onLap(pid, '{"lapTime":60}') end
local function pitStop(pid) RM_onPitStop(pid, '{"stall":1}') end
local function served(pid, s) RM_onPenaltyServed(pid, string.format('{"seconds":%s}', s)) end
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
local GATES = '[{"x":0,"y":0,"z":0,"hx":0,"hy":1},{"x":100,"y":0,"z":0,"hx":1,"hy":0},'
  .. '{"x":100,"y":100,"z":0,"hx":0,"hy":-1}]'
local function loadLayout(name, withPits)
  RM_onSaveLayout(0, '{"name":"' .. name .. '","width":20,"checkpoints":' .. GATES
    .. (withPits and ',"pits":[{"x":-50,"y":0,"z":0,"hx":0,"hy":1}]' or '') .. '}')
  RM_onLoadLayout(0, '{"name":"' .. name .. '"}')
end

onInit()
check(registered.RM_PenaltyServed == 'RM_onPenaltyServed', 'RM_PenaltyServed is registered')
RM_onLogin(0, '{"password":"phoenix"}'); RM_onSetReadyCheck(0, '{"on":false}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":8}')
RM_onSetPaceLap(0, '{"enabled":false}')
RM_onSetFinishRule(0, '{"after":1,"seconds":600}')
loadLayout('Pit Lane', true)

-- ---------------------------------------------------------------------------
-- 1. Off as shipped, and the rule's fields
-- ---------------------------------------------------------------------------
local cs = lastState.cpSkip
check(cs.pitServe == 'off' and cs.pitMode == 'off' and cs.pitLaps == 3,
  'serving in the pits is off as shipped, with a 3 lap window')
check(cs.pitStalls == 1, 'and the loaded layout\'s stalls ride along')

setSkip({ enabled = true, warnings = 0, type = 'time', penaltySec = 5, pitServe = 'bogus', pitLaps = 99 })
check(lastState.cpSkip.pitServe == 'off', 'an unknown serving rule is ignored')
check(lastState.cpSkip.pitLaps == 20, 'the window is clamped at 20 laps')
setSkip({ pitLaps = 0 })
check(lastState.cpSkip.pitLaps == 1, 'and at 1')

-- Off: a stop with seconds owed serves nothing.
startRace()
skip(1, 1, 3, 1)
check(driver(1).penaltySeconds == 5, 'a skip costs 5 seconds')
check(not chatTo(1, 'serve it in the pits'), 'off: the driver is not told to pit')
pitStop(1); seconds(12); served(1, 5)
check(driver(1).penaltySeconds == 5 and driver(1).penaltyServed == nil,
  'off: a stop serves nothing')
RM_onEndRace(0)
if lastState.phase ~= 'waiting' and lastState.phase ~= 'finished' then RM_onEndRace(0) end

-- ---------------------------------------------------------------------------
-- 2. Optional
-- ---------------------------------------------------------------------------
setSkip({ pitServe = 'optional', pitLaps = 2 })
check(lastState.cpSkip.pitServe == 'optional' and lastState.cpSkip.pitMode == 'optional',
  'optional is set and in force')
startRace()
chatClear()
skip(1, 1, 3, 1)
check(chatTo(1, '+5.0s penalty - serve it in the pits to clear it') ~= nil,
  'the penalty line says it can be served')
check(driver(1).pitServeBy == nil, 'optional has no window')

-- Too soon: the stop has not lasted the seconds owed.
pitStop(1); seconds(2); served(1, 5)
check(driver(1).penaltySeconds == 5, 'a report sooner than the seconds owed is refused')
-- A report with no stop behind it.
served(1, 5)
check(driver(1).penaltySeconds == 5, 'a report with no stop begun is ignored')

chatClear()
pitStop(1); seconds(10); served(1, 5)
check(driver(1).penaltySeconds == nil, 'a full stop clears the seconds')
check(driver(1).penaltyServed == 5, 'and records them served')
check(chatTo(1, 'Penalty served: 5.0s') ~= nil, 'the driver is told')
check(chatHas('Race control: Alice served 5.0s in the pits') ~= nil, 'and race control')

-- Claiming more than was owed serves what was owed.
skip(2, 1, 3, 1)
pitStop(2); seconds(30); served(2, 50)
check(driver(2).penaltySeconds == nil and driver(2).penaltyServed == 5,
  'a claim over the seconds owed serves only what was owed')

-- Seconds added during a stop wait for the next one.
skip(3, 1, 3, 1)
pitStop(3)
skip(3, 1, 3, 2)                      -- a second report on the same crossing: ignored
seconds(6); served(3, 5)
check(driver(3).penaltySeconds == nil, 'Cara served her 5 seconds')

-- Part served: a client held for less than it owed.
skip(4, 1, 3, 2)
check(driver(4).penaltySeconds == 10, 'two skips owe 10 seconds')
chatClear()
pitStop(4); seconds(6); served(4, 5)
check(driver(4).penaltySeconds == 5 and driver(4).penaltyServed == 5,
  'serving 5 of 10 leaves 5 owed')
check(chatTo(4, '(5.0s still owed)') ~= nil, 'and says so')

-- The results file. Alice takes the flag first, so End Race classifies the
-- rest where they stand rather than as DNFs.
RM_onSetResultsSave(0, '{"admins":true}')
for _ = 1, 8 do lap(1) end
check(driver(1).status == 'finished', 'Alice is home')
RM_onEndRace(0)
if lastState.phase ~= 'finished' then RM_onEndRace(0) end
resultsText = resultsText or ''
check(resultsText:find('Penalty seconds: could be served in the pits', 1, true) ~= nil,
  'the results header states the serving rule')
-- The race block only: qualifying lists the same names above it.
local raceBlock = resultsText:match('%-%-%- RACE RESULTS %-%-%-(.*)$') or ''
local aliceLine = raceBlock:match('\n(P%d [^\n]*Alice[^\n]*)') or ''
check(aliceLine:find('5.0s served in pit', 1, true) ~= nil, 'Alice\'s Track cuts cell shows it')
check(aliceLine:find('pen)', 1, true) == nil, 'and her time carries no penalty')
local danLine = raceBlock:match('\n(P%d [^\n]*Dan[^\n]*)') or ''
check(danLine:find('(+5.0s pen)', 1, true) ~= nil, 'Dan\'s unserved 5 seconds are on his time')
RM_onSetResultsSave(0, '{"admins":false}')

-- ---------------------------------------------------------------------------
-- 3. Required
-- ---------------------------------------------------------------------------
setSkip({ pitServe = 'required', pitLaps = 2 })
check(lastState.cpSkip.pitMode == 'required', 'required is in force with a stall on the track')
startRace()
chatClear()
skip(4, 1, 3, 1)
check(chatTo(4, 'serve it in the pits within 2 laps') ~= nil, 'the line gives the window')
check(driver(4).pitServeBy == 3, 'on lap 1 with 2 laps, the last lap a stop counts on is 3')

-- A new penalty restarts the window.
skip(1, 1, 3, 1)
lap(1); lap(1)
skip(1, 3, 3, 1)
check(driver(1).pitServeBy == 5, 'a second penalty on lap 3 moves the window to lap 5')

-- Bob serves in time and is classified.
skip(2, 1, 3, 1)
lap(2)
pitStop(2); seconds(6); served(2, 5)
check(driver(2).pitServeBy == nil and driver(2).penaltySeconds == nil,
  'served inside the window: nothing owed, no window')

-- Dan does not.
lap(4); lap(4)
seconds(0.2)
check(not driver(4).pitMissed, 'still inside the window on its last lap')
chatClear()
lap(4)
seconds(0.2)
check(driver(4).pitMissed == true and driver(4).pitServeBy == nil, 'past it, the window is missed')
check(chatTo(4, 'disqualified at the flag') ~= nil, 'the driver is told')
check(chatHas('Race control: Dan did not serve 5.0s') ~= nil, 'and race control')
pitStop(4); seconds(12); served(4, 5)
check(driver(4).penaltySeconds == 5, 'a stop after the window serves nothing')

-- Cara owes seconds at the flag but her window is still open: they stay as time.
skip(3, 1, 3, 1)
-- Bob takes the flag, so the rest are classified where they stand.
for _ = 1, 7 do lap(2) end
check(driver(2).status == 'finished', 'Bob is home')
RM_onEndRace(0)
if lastState.phase ~= 'finished' then RM_onEndRace(0) end
check(driver(4).status == 'dsq', 'Dan is disqualified at the flag')
check(driver(4).outReason == 'Disqualified - Penalty Not Served', 'and the reason is given')
check(chatHas('Pit ruling: 1 driver disqualified') ~= nil, 'the field is told')
check(driver(2).status == 'finished', 'Bob, who served, is classified')
check(driver(3).status == 'finished' and driver(3).penaltySeconds == 5,
  'Cara, inside her window at the flag, keeps the seconds as time')

-- ---------------------------------------------------------------------------
-- 4. Required needs stalls
-- ---------------------------------------------------------------------------
loadLayout('No Pits', false)
check(lastState.cpSkip.pitServe == 'required' and lastState.cpSkip.pitMode == 'optional',
  'with no stalls on the loaded layout, required runs as optional')
check(lastState.cpSkip.pitStalls == 0, 'and the panel hears there are none')

-- ---------------------------------------------------------------------------
-- 5. A new session starts clean
-- ---------------------------------------------------------------------------
loadLayout('Pit Lane', true)
startRace()
check(driver(4).pitMissed == nil and driver(4).penaltyServed == nil and driver(4).pitServeBy == nil,
  'a new race clears the served seconds, the window and a missed one')
RM_onEndRace(0)
if lastState.phase ~= 'finished' then RM_onEndRace(0) end

local serverChecks, serverFails = checks, fails
print(string.format('pit_penalty_test (server): %d checks, %d failures', serverChecks, serverFails))

-- ===========================================================================
-- PART 2: THE CLIENT
-- ===========================================================================
local sent, handlers, notices = {}, {}, {}
local routeState = nil
local VEH_ID = 7
local veh = { id = VEH_ID, x = 0, y = 0, z = 0, speed = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = self.speed, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation(x, y, z) self.x, self.y, self.z = x, y, z end
function veh:queueLuaCommand() end
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
local lastUpdate = nil
guihooks = { trigger = function (e, p)
  if e == 'RaceManagerRoute' then routeState = p end
  if e == 'RaceManagerNotice' then notices[#notices + 1] = p end
  if e == 'RaceManagerUpdate' then lastUpdate = p end
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
raceManager = RM
RM.onExtensionLoaded()

local function frames(s, step)
  step = step or 0.1
  for _ = 1, math.floor(s / step + 0.5) do RM.onUpdate(step) end
end
local function lastSent(e)
  for i = #sent, 1, -1 do if sent[i].event == e then return sent[i].payload end end
end
local function countSent(e)
  local n = 0
  for _, x in ipairs(sent) do if x.event == e then n = n + 1 end end
  return n
end
local function noticeHas(text)
  for _, n in ipairs(notices) do
    if type(n.msg) == 'string' and n.msg:find(text, 1, true) then return n.msg end
  end
end
-- The server's push, with our own row owing `pen` seconds.
local function state(t)
  local s = { rmProtocol = 2, raceTime = 0, phase = 'racing', sessionKind = 'race',
    maxResets = -1, totalLaps = 5,
    cpSkip = { enabled = true, warnings = 0, type = 'time', penaltySec = 5, liftSec = 3,
      liftWindow = 30, maxGates = 2, pitServe = t.mode or 'optional', pitMode = t.mode or 'optional',
      pitLaps = 3, pitStalls = 1 },
    drivers = { { id = 1, name = 'Me', status = 'racing', currentLap = 2,
      penaltySeconds = t.pen, pitServeBy = t.serveBy, pitMissed = t.missed } } }
  for k, v in pairs(t.extra or {}) do s[k] = v end
  handlers['RM_Update'](s)
end
-- Out of the stall and past the cooldown, so the next case starts fresh.
local function leaveStall()
  veh.x, veh.y = 0, 0
  frames(9)
end
local function intoStall()
  veh.x, veh.y, veh.speed = 50, 0, 0
end

-- A two-gate circuit and one stall at (50, 0).
RM.setEditorTarget('main')
veh.x, veh.y = 0, 200; RM.editorAdd()
veh.x, veh.y = 0, 400; RM.editorAdd()
RM.setEditorTarget('pit')
veh.x, veh.y = 50, 0; RM.editorAdd()
RM.setEditorTarget('main')
veh.x, veh.y = 0, 0

-- ---------------------------------------------------------------------------
-- A stop serves what our row owes, on top of the 5 s
-- ---------------------------------------------------------------------------
state({ pen = 7.5 })
frames(0.3)
notices = {}
check(noticeHas('serve it in the pits') == nil, 'no notice before a penalty changes')
sent = {}
intoStall()
frames(0.2)
check(routeState.pitActive == true, 'the stop begins')
check(lastSent('RM_PitStop') and lastSent('RM_PitStop').serving == 7.5,
  'RM_PitStop says what it is serving')
check(noticeHas('PIT STOP: 5s + PENALTY 7.5s') ~= nil, 'and the driver is told the length')
frames(6)
check(routeState.pitActive == true, 'still held after the usual 5 s')
check(countSent('RM_PenaltyServed') == 0, 'nothing reported yet')
frames(7)
check(routeState.pitActive ~= true, 'released after 5 + 7.5 s')
check(countSent('RM_PenaltyServed') == 1 and lastSent('RM_PenaltyServed').seconds == 7.5,
  'and RM_PenaltyServed reports 7.5 s')
check(noticeHas('PENALTY SERVED (7.5s) - GO!') ~= nil, 'GO says the penalty is served')
leaveStall()

-- ---------------------------------------------------------------------------
-- Nothing is served when it should not be
-- ---------------------------------------------------------------------------
local function plainStop(why)
  sent = {}
  intoStall()
  frames(0.2)
  local p = lastSent('RM_PitStop')
  check(p == nil or p.serving == 0, why .. ': the stop serves nothing')
  frames(5.5)
  check(routeState.pitActive ~= true, why .. ': released after the usual 5 s')
  check(countSent('RM_PenaltyServed') == 0, why .. ': nothing is reported')
  leaveStall()
end
state({ pen = 5, mode = 'off' }); plainStop('rule off')
state({ pen = 0 }); plainStop('nothing owed')
state({ pen = 5, mode = 'required', missed = true }); plainStop('window missed')
state({ pen = 5, extra = { sessionKind = 'quali', phase = 'qualifying' } }); plainStop('qualifying')

-- A stop cut short by the session ending reports nothing.
state({ pen = 5 })
sent = {}
intoStall()
frames(2)
state({ pen = 5, extra = { phase = 'finished' } })
frames(0.5)
check(countSent('RM_PenaltyServed') == 0, 'a stop the session ended serves nothing')
leaveStall()

-- ---------------------------------------------------------------------------
-- What the driver is told
-- ---------------------------------------------------------------------------
state({ pen = 0 })
notices = {}
state({ pen = 5 })
check(noticeHas('+5.0s penalty - serve it in the pits to clear it') ~= nil,
  'optional: the penalty notice says it can be served')
state({ pen = 0, mode = 'required' })
notices = {}
state({ pen = 5, mode = 'required', serveBy = 4 })
check(noticeHas('serve it in the pits within 3 laps') ~= nil, 'required: and gives the window')
check(lastUpdate.myCpSkip and lastUpdate.myCpSkip.serveBy == 4
  and lastUpdate.myCpSkip.pitMode == 'required', 'the HUD readout gets the window')
notices = {}
state({ pen = 5, mode = 'required', missed = true })
check(noticeHas('PENALTY NOT SERVED IN THE PITS') ~= nil, 'a missed window is told once')
notices = {}
state({ pen = 5, mode = 'required', missed = true })
check(noticeHas('PENALTY NOT SERVED') == nil, 'and not again on the next push')
check(lastUpdate.myCpSkip and lastUpdate.myCpSkip.missed == true, 'the HUD readout says missed')

-- ---------------------------------------------------------------------------
-- The panel sends the rule
-- ---------------------------------------------------------------------------
sent = {}
RM.setCheckpointSkip(true, 0, 'time', 5, 3, 30, 'required', 4)
local p = lastSent('RM_SetCheckpointSkip')
check(p and p.pitServe == 'required' and p.pitLaps == 4, 'the rule goes to the server')
RM.setCheckpointSkip(true, 0, 'time', 5, 3, 30)
p = lastSent('RM_SetCheckpointSkip')
check(p and p.pitServe == nil and p.pitLaps == nil, 'left out, the server keeps its own')

print(string.format('pit_penalty_test (client): %d checks, %d failures',
  checks - serverChecks, fails - serverFails))
print(string.format('pit_penalty_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
