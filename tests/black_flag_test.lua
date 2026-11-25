-- Headless test for BLACK FLAGS AND DISQUALIFICATION, in
-- server/RaceManager/main.lua and lua/ge/extensions/raceManager.lua.
--
-- Race control raises a black flag on one driver (RM_Steward), or an unserved
-- lift does (checkpointSkipLiftUnserved 'black'). It is served by a stop in a
-- pit stall: the usual stop plus the flag's seconds. Past its laps unserved,
-- the car is disqualified at once; still open at the flag, the stop it did not
-- make goes on its time. Race control can also withdraw one, or disqualify a
-- driver outright.
--
--   * THE SERVER owns the flag: it rides the driver row (blackFlag, blackBy,
--     blackWhy), is timed against the stop on the server's clock, and rules.
--   * THE CLIENT holds the stop for it, reports it served, and tells the driver.
--
-- Run from the repo root: lua5.3 tests/black_flag_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- The suite shares one Data folder: start on config.json's rules, and leave
-- none of ours behind for the next test.
local RULES_FILE = 'Resources/Server/PhoenixRM Server/Data/rules.json'
os.remove(RULES_FILE)

-- ===========================================================================
-- PART 1: THE SERVER
-- ===========================================================================
local connected = { [0] = 'Admin', [1] = 'Alice', [2] = 'Bob', [3] = 'Cara', [4] = 'Dan', [5] = 'Mod' }
local lastState, chatLog, registered = nil, {}, {}
local resultsText = nil
local spectated = {}

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) chatLog[#chatLog + 1] = { to = target, msg = msg } end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' and target == -1 then lastState = payload end
    if event == 'RM_ResultsFile' then resultsText = payload.text end
    if event == 'RM_ForceSpectate' then spectated[#spectated + 1] = { to = target, p = payload } end
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
local function served(pid, s, black)
  RM_onPenaltyServed(pid, string.format('{"seconds":%s%s}', s, black and ',"black":true' or ''))
end
local function json(t)
  local parts = {}
  for k, v in pairs(t) do
    parts[#parts + 1] = string.format('"%s":%s', k,
      type(v) == 'string' and ('"' .. v .. '"') or tostring(v))
  end
  return '{' .. table.concat(parts, ',') .. '}'
end
local function steward(by, pid, action, extra)
  local t = { pid = pid, action = action }
  for k, v in pairs(extra or {}) do t[k] = v end
  RM_onSteward(by, json(t))
end
local function setSkip(t) RM_onSetCheckpointSkip(0, json(t)) end
local function endRace()
  RM_onEndRace(0)
  if lastState.phase ~= 'waiting' and lastState.phase ~= 'finished' then RM_onEndRace(0) end
end
local function startRace()
  RM_onGenerateGrid(0)
  RM_onStartCountdown(0)
  for _ = 1, 70 do
    if lastState.phase == 'racing' then break end
    RM_CountdownTick()
  end
end
local function spectatedTo(pid)
  for i = #spectated, 1, -1 do
    if spectated[i].to == pid then return spectated[i].p end
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
check(registered.RM_Steward == 'RM_onSteward', 'RM_Steward is registered')
check(registered.RM_SetBlackFlag == 'RM_onSetBlackFlag', 'RM_SetBlackFlag is registered')
RM_onLogin(0, '{"password":"phoenix"}'); RM_onSetReadyCheck(0, '{"on":false}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetSpectating(5, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":8}')
RM_onSetPaceLap(0, '{"enabled":false}')
RM_onSetFinishRule(0, '{"after":1,"seconds":600}')
RM_onSetResultsSave(0, '{"admins":true}')
loadLayout('Pit Lane', true)

-- ---------------------------------------------------------------------------
-- 1. The rule: shipped defaults, clamped, admin only, locked under way
-- ---------------------------------------------------------------------------
check(lastState.bf and lastState.bf.seconds == 10 and lastState.bf.laps == 3,
  'black flags ship as a 10 s stop within 3 laps')
check(lastState.bf.stalls == 1, 'and the loaded layout\'s stalls ride along')
check(lastState.cpSkip.liftUnserved == 'time', 'an unserved lift is time as shipped')
RM_onSetBlackFlag(0, '{"seconds":500,"laps":0}')
check(lastState.bf.seconds == 120 and lastState.bf.laps == 1, 'the rule is clamped')
RM_onSetBlackFlag(0, '{"seconds":15,"laps":2}')
RM_onSetBlackFlag(1, '{"seconds":99}')
check(lastState.bf.seconds == 15 and lastState.bf.laps == 2, 'only race control sets it')

startRace()
check(lastState.phase == 'racing', 'a race is running')
chatClear()
RM_onSetBlackFlag(0, '{"seconds":30}')
check(lastState.bf.seconds == 15 and chatTo(0, 'locked while a session') ~= nil,
  'locked while a session runs')

-- ---------------------------------------------------------------------------
-- 2. Raising one
-- ---------------------------------------------------------------------------
chatClear()
local lapNow = driver(1).currentLap
steward(0, 1, 'black', { reason = 'Avoidable contact' })
check(driver(1).blackFlag == 15, 'a black flag holds the rule\'s seconds')
check(driver(1).blackBy == lapNow + 2, 'and must be served within the rule\'s laps')
check(driver(1).blackWhy == 'Avoidable contact', 'with the reason given')
check(chatTo(-1, 'BLACK FLAG for Alice: Avoidable contact') ~= nil, 'the field is told')
check(chatTo(1, 'stop in a pit stall for 15s by lap ' .. (lapNow + 2)) ~= nil, 'the driver is told what to do')
check(chatHas('Race control: Alice black flag, 15s') ~= nil, 'and race control')

steward(2, 3, 'black')
check(driver(3).blackFlag == nil, 'a driver who is not logged in cannot raise one')

chatClear()
steward(0, 1, 'black', { seconds = 5 })
check(driver(1).blackFlag == 20, 'a second one adds its seconds: one stop serves both')
check(chatTo(1, 'added to the one already out') ~= nil, 'and says so')

steward(0, 2, 'black', { reason = 'Bad   line <b>x</b> #1' })
check(driver(2).blackWhy == 'Bad line bxb 1', 'the reason is cleaned to plain ASCII text: '
  .. tostring(driver(2).blackWhy))
steward(0, 3, 'black', { seconds = 0 })
check(driver(3).blackFlag == 0, 'a 0 second flag is still a flag (the usual stop alone)')

-- ---------------------------------------------------------------------------
-- 3. Serving it in a stall
-- ---------------------------------------------------------------------------
pitStop(1); seconds(5); served(1, 0, true)
check(driver(1).blackFlag == 20, 'a report sooner than its seconds is refused')
pitStop(2); seconds(20); served(2, 0, false)
check(driver(2).blackFlag == 15, 'a stop that does not say it held the flag serves nothing')
chatClear()
pitStop(1); seconds(21); served(1, 0, true)
check(driver(1).blackFlag == nil and driver(1).blackBy == nil, 'a full stop serves it')
check(chatTo(1, 'Black flag served - carry on') ~= nil, 'the driver is told')
check(chatHas('Race control: Alice served the black flag') ~= nil, 'and race control')
pitStop(3); served(3, 0, true)
check(driver(3).blackFlag == nil, 'a 0 second flag is served by the usual stop')

-- Raised while held: the stop serves what it began with, the rest waits.
steward(0, 3, 'black', { seconds = 10 })
pitStop(3)
steward(0, 3, 'black', { seconds = 5 })
seconds(11); served(3, 0, true)
check(driver(3).blackFlag == 5, 'seconds added during a stop wait for the next one')
steward(0, 3, 'clear')
-- A 0 second flag raised during the stop adds no seconds, and is still a flag.
steward(0, 3, 'black', { seconds = 10 })
pitStop(3)
steward(0, 3, 'black', { seconds = 0 })
chatClear()
seconds(11); served(3, 0, true)
check(driver(3).blackFlag == 0 and driver(3).blackBy ~= nil,
  'a 0 second flag raised during the stop stays out for the next one')
check(chatTo(3, 'one raised during the stop is still out') ~= nil, 'and the driver is told')
pitStop(3); served(3, 0, true)
check(driver(3).blackFlag == nil, 'which the next stop serves')

-- ---------------------------------------------------------------------------
-- 4. Withdrawn
-- ---------------------------------------------------------------------------
chatClear()
steward(0, 2, 'clear')
check(driver(2).blackFlag == nil, 'race control withdraws a black flag')
check(chatHas('Black flag withdrawn for Bob') ~= nil, 'and the field is told')
chatClear()
steward(0, 2, 'clear')
check(chatTo(0, 'has no black flag out') ~= nil, 'withdrawing one that is not out is refused, and said')

-- ---------------------------------------------------------------------------
-- 5. Ignored: disqualified at once
-- ---------------------------------------------------------------------------
steward(0, 4, 'black')
local by = driver(4).blackBy
while (driver(4).currentLap or 0) <= by do lap(4) end
chatClear()
seconds(0.2)
check(driver(4).status == 'dsq', 'past its last lap unserved, the driver is disqualified')
check(driver(4).outReason == 'Disqualified - Black Flag Ignored', 'with the reason')
check(spectatedTo(4) and spectatedTo(4).out == 'dsq', 'sent to spectate as ruled out, not finished')
check(chatTo(4, 'Black flag not served in time') ~= nil, 'and told why')
check(driver(4).blackFlag == nil, 'the flag goes with the car')

-- ---------------------------------------------------------------------------
-- 6. Race control disqualifies
-- ---------------------------------------------------------------------------
chatClear()
steward(0, 2, 'dq', { reason = 'Avoidable contact' })
check(driver(2).status == 'dsq' and driver(2).outReason == 'Disqualified - Avoidable contact',
  'race control disqualifies a car on track, with the reason')
check(spectatedTo(2) and spectatedTo(2).out == 'dsq', 'which goes to spectate')
check(chatHas('Bob DISQUALIFIED: Avoidable contact') ~= nil, 'and the field is told')
chatClear()
steward(0, 4, 'dq')
check(chatTo(0, 'is not racing or home') ~= nil, 'a driver already out cannot be ruled out again')

-- ---------------------------------------------------------------------------
-- 7. Open at the flag, and a car already home
-- ---------------------------------------------------------------------------
while (driver(3).currentLap or 0) < 8 do lap(3) end
steward(0, 3, 'black', { seconds = 10 })
chatClear()
lap(3)
check(driver(3).status == 'finished', 'Cara takes the flag with a black flag open')
check(driver(3).penaltySeconds == 15, 'its seconds and the usual 5 s stop go on her time')
check(chatTo(3, 'Black flag not served by the flag: +15.0s') ~= nil, 'and she is told')
local before = #spectated
steward(0, 3, 'dq')
check(driver(3).status == 'dsq' and driver(3).outReason == 'Disqualified - Race Control',
  'a car already home can be disqualified')
check(#spectated == before, 'and is not sent to spectate again')

-- The last car out ends the session, results and all.
steward(0, 1, 'dq')
check(lastState.phase ~= 'racing', 'disqualifying the last car on track ends the race')
resultsText = resultsText or ''
check(resultsText:find('Race control (black flags: stop 15s, within 2 laps):', 1, true) ~= nil,
  'the results file has a race control block')
check(resultsText:find('Alice black flag, 15s (Avoidable contact)', 1, true) ~= nil
  and resultsText:find('Dan disqualified: Black Flag Ignored', 1, true) ~= nil,
  'listing each ruling')

chatClear()
steward(0, 1, 'black')
check(chatTo(0, 'black flags are for a running race') ~= nil, 'no black flag outside a race')

-- ---------------------------------------------------------------------------
-- 8. A black flag needs a stall
-- ---------------------------------------------------------------------------
loadLayout('No Pits', false)
check(lastState.bf.stalls == 0, 'the panel hears there are no stalls')
startRace()
chatClear()
steward(0, 1, 'black')
check(driver(1).blackFlag == nil and chatTo(0, 'no pit stalls') ~= nil,
  'with nowhere to serve it, a black flag is refused')

-- An unserved lift with nowhere to serve a black flag is time.
endRace()
setSkip({ enabled = true, warnings = 0, type = 'lift', liftWindow = 5, penaltySec = 5,
  liftUnserved = 'black' })
check(lastState.cpSkip.liftUnserved == 'black' and lastState.cpSkip.liftBlack == false,
  'set to black, but not in force without stalls')
startRace()
skip(1, driver(1).currentLap, 3, 1)
seconds(6)
check(driver(1).penaltySeconds == 5 and driver(1).blackFlag == nil,
  'no stalls: an unserved lift is time')
endRace()

-- ---------------------------------------------------------------------------
-- 9. An unserved lift is a black flag
-- ---------------------------------------------------------------------------
loadLayout('Pit Lane', true)
check(lastState.cpSkip.liftBlack == true, 'with a stall, an unserved lift is a black flag')
startRace()
skip(1, driver(1).currentLap, 3, 1)
check(driver(1).liftOwed == 1, 'a lift is owed')
seconds(6)
check(driver(1).blackFlag == 15 and driver(1).blackWhy == 'Lift not served',
  'the window ran out: a black flag')
check(driver(1).liftOwed == nil and driver(1).penaltySeconds == nil, 'instead of the seconds')

-- ---------------------------------------------------------------------------
-- 10. A moderator runs the race
-- ---------------------------------------------------------------------------
RM_onChangePassword(0, '{"password":"tuesday","role":"moderator"}')
RM_onLogin(5, '{"password":"tuesday"}')
steward(5, 2, 'black')
check(driver(2).blackFlag == 15, 'a moderator can raise a black flag')
steward(5, 2, 'dq')
check(driver(2).status == 'dsq', 'and disqualify')

-- ---------------------------------------------------------------------------
-- 11. A new session starts clean
-- ---------------------------------------------------------------------------
endRace()
startRace()
check(driver(1).blackFlag == nil and driver(2).status == 'racing',
  'a new race clears the flags and the disqualifications')
endRace()

RM_onChangePassword(0, '{"password":"","role":"moderator"}')
setSkip({ enabled = false, type = 'time', liftWindow = 30, liftUnserved = 'time' })
RM_onSetBlackFlag(0, '{"seconds":10,"laps":3}')
RM_onSetResultsSave(0, '{"admins":false}')
os.remove(RULES_FILE)

local serverChecks, serverFails = checks, fails
print(string.format('black_flag_test (server): %d checks, %d failures', serverChecks, serverFails))

-- ===========================================================================
-- PART 2: THE CLIENT
-- ===========================================================================
local sent, handlers, notices, hud, lights = {}, {}, {}, {}, {}
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
  if e == 'Message' then hud[#hud + 1] = p end
  if e == 'RaceManagerLights' then lights[#lights + 1] = p end
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
local function noticeOf(text)
  for _, n in ipairs(notices) do
    if type(n.msg) == 'string' and n.msg:find(text, 1, true) then return n end
  end
end
local function hudLine(category)
  local line = nil
  for _, m in ipairs(hud) do
    if m.category == category then line = m.msg end
  end
  return line
end
local function lastLight() return lights[#lights] end
local function momentShown(name)
  for _, l in ipairs(lights) do if l.moment == name then return l end end
end
-- The server's push, with a black flag on our row when `t.black` is set.
local function state(t)
  t = t or {}
  local me = { id = 1, name = 'Me', status = 'racing', currentLap = 2 }
  if t.black then me.blackFlag, me.blackBy, me.blackWhy = t.black, t.by or 4, t.why end
  local s = { rmProtocol = 2, raceTime = 0, phase = 'racing', sessionKind = 'race',
    maxResets = -1, totalLaps = 5, flag = 'green',
    cpSkip = { enabled = false }, bf = { seconds = 10, laps = 3, stalls = 1 },
    drivers = { me } }
  for k, v in pairs(t.extra or {}) do s[k] = v end
  handlers['RM_Update'](s)
end
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
-- Raised: told on the edge, held on the HUD, shown as the driver's flag
-- ---------------------------------------------------------------------------
state()
frames(0.3)
notices, hud, lights = {}, {}, {}
state({ black = 10, by = 4, why = 'Contact' })
local n = noticeOf('BLACK FLAG')
check(n and n.kind == 'flag' and n.color == 'black', 'a black flag flashes, in black')
check(n and n.sub == 'Stop in a pit stall: 10s, by lap 4 (Contact)', 'saying what to do, by when and why')
check(lastUpdate.driverFlag == 'black', 'it is the driver\'s flag')
check(lastUpdate.myBlack and lastUpdate.myBlack.sec == 10 and lastUpdate.myBlack.by == 4,
  'and the driver bar gets it')
check(lastLight() and lastLight().light == 'black' and lastLight().black.by == 4,
  'Race Lights shows the black flag and the lap')
notices = {}
state({ black = 10, by = 4, why = 'Contact' })
check(noticeOf('BLACK FLAG') == nil, 'told once, not on every push')
frames(0.5)
check((hudLine('raceManager_black') or ''):find('BLACK FLAG - stop in a pit stall for 10s by lap 4', 1, true),
  'the HUD holds the line')
hud = {}
frames(200, 0.5)
hud = {}
frames(3)
check(hudLine('raceManager_black') ~= nil, 'and it does not time out')
state({ black = 15, by = 5, why = 'Contact' })
check(noticeOf('BLACK FLAG') ~= nil, 'a second one added to it is told again')

-- ---------------------------------------------------------------------------
-- Served by a stop: the usual 5 s plus its seconds
-- ---------------------------------------------------------------------------
state({ black = 10 })
notices, sent, lights = {}, {}, {}
intoStall()
frames(0.2)
check(routeState.pitActive == true, 'the stop begins')
check(lastSent('RM_PitStop') and lastSent('RM_PitStop').black == 10, 'RM_PitStop says it holds the flag')
check(noticeOf('PIT STOP: 5s + BLACK FLAG 10s') ~= nil, 'and the driver is told the length')
frames(9)
check(routeState.pitActive == true and countSent('RM_PenaltyServed') == 0, 'still held after 9 s')
frames(6.5)
check(routeState.pitActive ~= true, 'released after 5 + 10 s')
local p = lastSent('RM_PenaltyServed')
check(p and p.black == true and p.seconds == 0, 'and reports the black flag served')
check(noticeOf('BLACK FLAG SERVED - GO!') ~= nil, 'GO says so')
check(momentShown('blackServed') ~= nil, 'and Race Lights has the moment')
notices = {}
state()
check(noticeOf('withdrawn') == nil, 'the row clearing after a stop is not told as withdrawn')
leaveStall()

-- Penalty seconds and a black flag in one stop.
state({ black = 10, extra = { cpSkip = { enabled = true, warnings = 0, type = 'time', penaltySec = 5,
  liftSec = 3, liftWindow = 30, maxGates = 2, pitServe = 'optional', pitMode = 'optional',
  pitLaps = 3, pitStalls = 1 } } })
handlers['RM_Update']({ rmProtocol = 2, raceTime = 0, phase = 'racing', sessionKind = 'race',
  maxResets = -1, totalLaps = 5, flag = 'green', bf = { seconds = 10, laps = 3, stalls = 1 },
  cpSkip = { enabled = true, warnings = 0, type = 'time', penaltySec = 5, liftSec = 3,
    liftWindow = 30, maxGates = 2, pitServe = 'optional', pitMode = 'optional', pitLaps = 3,
    pitStalls = 1 },
  drivers = { { id = 1, name = 'Me', status = 'racing', currentLap = 2, penaltySeconds = 5,
    blackFlag = 10, blackBy = 4 } } })
notices, sent = {}, {}
intoStall()
frames(0.2)
check(noticeOf('PIT STOP: 5s + PENALTY 5.0s + BLACK FLAG 10s') ~= nil, 'both, in one stop')
frames(20.5)
p = lastSent('RM_PenaltyServed')
check(p and p.seconds == 5 and p.black == true, 'and both are reported served')
state()
leaveStall()

-- Withdrawn with no stop behind it.
state({ black = 10 })
notices = {}
state()
check(noticeOf('Black flag withdrawn') ~= nil, 'a flag gone without our stop was withdrawn, and said')
check(lastUpdate.driverFlag ~= 'black', 'and the driver\'s flag goes back')

-- Served in part (one was raised during the stop), then withdrawn later: told.
state({ black = 10 })
intoStall()
frames(15.5)
check(lastSent('RM_PenaltyServed') and lastSent('RM_PenaltyServed').black == true, 'a stop serves the flag')
state({ black = 0 })
leaveStall()
frames(5)
notices = {}
state()
check(noticeOf('Black flag withdrawn') ~= nil,
  'one left out after a serve and withdrawn later is told as withdrawn')

-- Not in qualifying: a stop there holds the usual 5 s.
state({ black = 10, extra = { sessionKind = 'quali', phase = 'qualifying' } })
sent = {}
intoStall()
frames(0.2)
p = lastSent('RM_PitStop')
check(p and p.black == nil, 'qualifying: the stop holds no black flag')
frames(5.5)
check(routeState.pitActive ~= true and countSent('RM_PenaltyServed') == 0,
  'released after the usual 5 s, nothing reported')
leaveStall()
state()

-- ---------------------------------------------------------------------------
-- The panel's senders
-- ---------------------------------------------------------------------------
sent = {}
RM.steward(2, 'dq', nil, 'Contact')
p = lastSent('RM_Steward')
check(p and p.pid == 2 and p.action == 'dq' and p.reason == 'Contact', 'race control sends the ruling')
RM.steward(2, 'black', 20)
check(lastSent('RM_Steward').seconds == 20, 'with the seconds for a black flag')
sent = {}
RM.steward(2, 'kick')
check(countSent('RM_Steward') == 0, 'an unknown ruling is never sent')
RM.setBlackFlag(20, 4)
p = lastSent('RM_SetBlackFlag')
check(p and p.seconds == 20 and p.laps == 4, 'the black flag rule goes to the server')
RM.setCheckpointSkip(true, 0, 'lift', 5, 3, 30, 'off', 3, 'black')
check(lastSent('RM_SetCheckpointSkip').liftUnserved == 'black', 'and what an unserved lift becomes')
RM.setCheckpointSkip(true, 0, 'lift', 5, 3, 30)
check(lastSent('RM_SetCheckpointSkip').liftUnserved == nil, 'left out, the server keeps its own')

-- ---------------------------------------------------------------------------
-- Disqualified: no checkered flag
-- ---------------------------------------------------------------------------
state({ black = 10 })
notices, lights = {}, {}
handlers['RM_ForceSpectate']({ reason = 'Disqualified - Contact', source = 'race', out = 'dsq' })
n = noticeOf('DISQUALIFIED')
check(n and n.color == 'black' and n.sub == 'Disqualified - Contact', 'a DQ is told as one, with the reason')
check(noticeOf('CHECKERED FLAG') == nil, 'and is no checkered flag')
check(momentShown('dsq') ~= nil, 'Race Lights says DISQUALIFIED')

print(string.format('black_flag_test (client): %d checks, %d failures',
  checks - serverChecks, fails - serverFails))
print(string.format('black_flag_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
