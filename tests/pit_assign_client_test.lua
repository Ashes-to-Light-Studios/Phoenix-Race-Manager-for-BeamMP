-- Headless test for ASSIGNED PIT STALLS in lua/ge/extensions/raceManager.lua.
-- Run from the repo root: lua5.3 tests/pit_assign_client_test.lua
--
-- The server sends each driver row's pitStall (teams.lua) and the seconds a
-- stop in another driver's stall adds (pitStopRule.wrongStall). The client
-- decides the hold the moment the car stops, so the rule lives here:
--   * our own stall, or a stall nobody in the field has: the usual stop;
--   * another driver's, when we have one of our own: held that much longer;
--   * a driver with no stall uses any stall at the usual time;
--   * a race or qualifying, never practice.
-- And on track each assigned stall is labeled with who has it.

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs (as pit_test.lua)
-- ---------------------------------------------------------------------------
local sent, hooks, handlers = {}, {}, {}
local frozen = nil
local VEH_ID = 7
local HOLD = 5.0            -- TUNE.PIT_HOLD_SEC, which the harness cannot read
local labels = {}           -- texts drawn in the world this frame batch

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
core_vehicleBridge = {
  executeAction = function (_, action, value)
    if action == 'setFreeze' then frozen = value end
  end,
}
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
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }
ColorF = function () return {} end
ColorI = function () return {} end
String = function (s) return s end
debugDrawer = {
  drawCylinder = function () end,
  -- A method call: self, where, then the text.
  drawTextAdvanced = function (_, _, text) labels[#labels + 1] = tostring(text) end,
  drawSphere = function () end, drawLine = function () end,
  drawQuadSolid = function () end,
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
RM.onExtensionLoaded()

local function frames(seconds)
  for _ = 1, math.floor(seconds / 0.1 + 0.5) do RM.onUpdate(0.1) end
end
local function lastPitStop()
  for i = #sent, 1, -1 do if sent[i].event == 'RM_PitStop' then return sent[i].payload end end
end
local function lastNotice()
  for i = #hooks, 1, -1 do
    if hooks[i].event == 'RaceManagerNotice' then return tostring(hooks[i].payload.msg) end
  end
  return ''
end
local function drew(text)
  for _, l in ipairs(labels) do if l == text then return true end end
  return false
end

-- Three stalls 10 m apart at x=50; we park in one by standing on it.
RM.setEditorTarget('main')
veh.x, veh.y = 0, 200; RM.editorAdd()
veh.x, veh.y = 0, 400; RM.editorAdd()
RM.setEditorTarget('pit')
for i = 1, 3 do veh.x, veh.y = 50, -(i - 1) * 10; RM.editorAdd() end
RM.setEditorTarget('main')
veh.x, veh.y = 0, 0

-- Us (id 1) with stall 1; #12 with stall 2; stall 3 is nobody's.
local function state(phase, wrong, rows, extra)
  local t = { rmProtocol = 2, raceTime = 0, phase = phase, maxResets = -1, totalLaps = 3,
    pitStopRule = { required = 0, missed = 'dsq', seconds = 30, active = 0, wrongStall = wrong },
    drivers = rows }
  for k, v in pairs(extra or {}) do t[k] = v end
  handlers['RM_Update'](t)
end
local ASSIGNED = {
  { id = 1, name = 'Me', status = 'racing', pitStall = 1 },
  { id = 2, name = 'Rival', status = 'racing', number = '12', pitStall = 2 },
  { id = 3, name = 'Other', status = 'racing' },
}

-- Stop in stall `i`, then report how long the car was held (to 0.1 s).
local function stopIn(i)
  veh.x, veh.y = 0, 0
  frames(9.0)                          -- out of the lane, past the cooldown
  sent, hooks = {}, {}
  veh.x, veh.y = 50, -(i - 1) * 10
  frames(0.1)
  if frozen ~= true then return 0 end
  local held = 0
  while frozen == true and held < 30 do frames(0.1); held = held + 0.1 end
  return math.floor(held * 10 + 0.5) / 10
end

-- ---------------------------------------------------------------------------
-- 1. The usual stop: our own stall, and one nobody has
-- ---------------------------------------------------------------------------
state('racing', 5, ASSIGNED)
local held = stopIn(1)
check(held >= HOLD - 0.2 and held <= HOLD + 0.2, 'our own stall is the usual 5 s stop (held ' .. held .. ')')
check(lastPitStop() and lastPitStop().stall == 1 and lastPitStop().wrong == nil,
  'and is reported as a plain stop')
held = stopIn(3)
check(held <= HOLD + 0.2, 'a stall nobody has is free: the usual stop (held ' .. held .. ')')

-- ---------------------------------------------------------------------------
-- 2. Another driver's stall: 5 s longer
-- ---------------------------------------------------------------------------
sent, hooks = {}, {}
held = stopIn(2)
check(held >= HOLD + 5 - 0.2 and held <= HOLD + 5 + 0.2,
  'another driver\'s stall holds the car 5 s longer: 10 s in all (held ' .. held .. ')')
check(lastPitStop() and lastPitStop().stall == 2 and lastPitStop().wrong == 5,
  'and the server is told what it added')

-- The driver is told, as the stop starts.
veh.x, veh.y = 0, 0
frames(9.0)
hooks = {}
veh.x, veh.y = 50, -10
frames(0.1)
check(lastNotice():find('NOT YOUR STALL 5s (yours is PIT 1)', 1, true) ~= nil,
  'the driver is told it is not their stall, and which is (got "' .. lastNotice() .. '")')
frames(12)

-- ---------------------------------------------------------------------------
-- 3. No stall of our own: any stall, the usual stop
-- ---------------------------------------------------------------------------
state('racing', 5, {
  { id = 1, name = 'Me', status = 'racing' },
  { id = 2, name = 'Rival', status = 'racing', number = '12', pitStall = 2 },
})
held = stopIn(2)
check(held <= HOLD + 0.2, 'a driver with no stall uses any stall at the usual time (held ' .. held .. ')')

-- ---------------------------------------------------------------------------
-- 4. The rule off, a stall past the layout's, a rival spectating
-- ---------------------------------------------------------------------------
state('racing', 0, ASSIGNED)
held = stopIn(2)
check(held <= HOLD + 0.2, 'with the rule at 0, another driver\'s stall is the usual stop (held ' .. held .. ')')

state('racing', 5, {
  { id = 1, name = 'Me', status = 'racing', pitStall = 9 },
  { id = 2, name = 'Rival', status = 'racing', number = '12', pitStall = 2 },
})
held = stopIn(2)
check(held <= HOLD + 0.2, 'stall 9 on a three-stall layout is no stall: the usual stop (held ' .. held .. ')')

state('racing', 5, {
  { id = 1, name = 'Me', status = 'racing', pitStall = 1 },
  { id = 2, name = 'Rival', status = 'waiting', spectating = true, number = '12', pitStall = 2 },
})
held = stopIn(2)
check(held <= HOLD + 0.2, 'the stall of a driver sitting out is free (held ' .. held .. ')')

-- ---------------------------------------------------------------------------
-- 5. Qualifying too
-- ---------------------------------------------------------------------------
state('qualifying', 5, ASSIGNED, { sessionKind = 'quali' })
held = stopIn(2)
check(held >= HOLD + 5 - 0.2, 'qualifying holds a wrong-stall stop longer as well (held ' .. held .. ')')

-- ---------------------------------------------------------------------------
-- 6. On track: who has each stall
-- ---------------------------------------------------------------------------
state('racing', 5, {
  { id = 1, name = 'Me', status = 'racing', pitStall = 1 },
  { id = 2, name = 'Rival', status = 'racing', number = '12', pitStall = 2 },
  { id = 3, name = 'Other', status = 'racing' },
})
veh.x, veh.y = 0, 0
frames(9.0)
labels = {}
frames(0.2)
check(drew('PIT 1 (YOURS)'), 'our stall is labeled as ours')
check(drew('PIT 2: #12'), 'another driver\'s shows their car number')
check(not drew('PIT 3') and not drew('PIT 3: '), 'a stall nobody has carries no label')

-- Teammates sharing one: the team's code, once the team list has come.
state('racing', 5, {
  { id = 1, name = 'Me', status = 'racing', pitStall = 1 },
  { id = 2, name = 'Rival', status = 'racing', number = '12', team = 5, pitStall = 3 },
  { id = 3, name = 'Mate', status = 'racing', number = '7', team = 5, pitStall = 3 },
}, { teams = { { id = 5, name = 'Phoenix Racing', short = 'PHX', color = '#ff7a1a' } } })
labels = {}
frames(0.2)
check(drew('PIT 3: PHX'), 'a team stall shows the team\'s code')
state('racing', 5, {
  { id = 1, name = 'Me', status = 'racing', pitStall = 1 },
  { id = 2, name = 'Rival', status = 'racing', number = '12', team = 5, pitStall = 3 },
  { id = 3, name = 'Loner', status = 'racing', pitStall = 3 },
})
labels = {}
frames(0.2)
check(drew('PIT 3: #12 Loner'), 'two drivers of different teams: each by number, else by name')

if fails == 0 then
  print(('pit_assign_client_test: %d checks, 0 failures'):format(checks))
else
  print(('pit_assign_client_test: %d FAILURES of %d checks'):format(fails, checks))
  os.exit(1)
end
