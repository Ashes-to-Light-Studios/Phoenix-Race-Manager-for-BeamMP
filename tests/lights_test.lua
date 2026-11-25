-- Headless test for THE LIGHTS in lua/ge/extensions/raceManager/lights.lua.
--
-- The Lights app draws one light and is told it on RaceManagerLights. What is
-- pinned here is which light, when, and that it is pushed only when it moves:
-- the app is meant to cost nothing, and a push per broadcast would be three a
-- second for a light that changes a few times a race.
--
-- The sounds ride the same transitions, so they are checked beside them.
--
-- Run from the repo root: lua5.3 tests/lights_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs
-- ---------------------------------------------------------------------------
local hooks    = {}
local handlers = {}
local sounds   = {}

local veh = { id = 7, x = 0, y = 0, z = 0, hx = 0, hy = 1, speed = 0 }
-- The vehicle VM, as far as the lift probe goes: it answers with the throttle.
local vm = { throttle = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = self.hx, y = self.hy, z = 0 } end
function veh:getVelocity() return { x = 0, y = self.speed, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation(x, y, z) self.x, self.y, self.z = x, y, z end
function veh:queueLuaCommand(cmd)
  if cmd:find('onLiftThrottle', 1, true) then raceManager.onLiftThrottle(vm.throttle) end
end
function veh:setMeshAlpha() end

be               = { getPlayerVehicle = function () return veh end }
getPlayerVehicle = function (_) return veh end
getAllVehicles   = function () return { veh } end
beamng_version   = '0.39.0.0'

vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }
Engine = { Audio = { playOnce = function (channel, event)
  sounds[#sounds + 1] = { channel = channel, event = event }
end } }

MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function () end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt   = { getConfig = function ()
  return { parts = {}, vars = {}, configName = 'Stock' }
end }

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
raceManager = RM          -- the VM calls back through the extension's global name
RM.onExtensionLoaded()

-- ---------------------------------------------------------------------------
-- Harness helpers
-- ---------------------------------------------------------------------------
local function lightPushes()
  local out = {}
  for _, h in ipairs(hooks) do
    if h.event == 'RaceManagerLights' then out[#out + 1] = h.payload end
  end
  return out
end
local function lastLight()
  local p = lightPushes()
  return p[#p]
end
local function reset() hooks = {}; sounds = {} end
local function lastSound() return sounds[#sounds] and sounds[#sounds].event end

local base = { totalLaps = 5, maxResets = -1, drivers = {}, sessionKind = 'race' }
local function serverState(t)
  local s = { rmProtocol = 2 }
  for k, v in pairs(base) do s[k] = v end
  for k, v in pairs(t) do s[k] = v end
  handlers['RM_Update'](s)
end
local function countdown(n) handlers['RM_Countdown']({ count = n }) end

-- ---------------------------------------------------------------------------
-- The countdown: red builds in, GO is green
-- ---------------------------------------------------------------------------
serverState({ phase = 'grid' })
check(lastLight() and lastLight().light == 'grid', 'the grid shows the gantry, unlit')

reset()
serverState({ phase = 'countdown' })
check(#lightPushes() == 0, 'grid to countdown is the same light, so nothing is pushed')

for _, n in ipairs({ 3, 2, 1 }) do
  reset()
  countdown(n)
  check(lastLight() and lastLight().light == 'count' .. n, 'count ' .. n .. ' is its own light')
  check(lastSound() == 'event:UI_Countdown1', 'and beeps (' .. n .. ')')
end
reset()
countdown(0)
check(lastLight() and lastLight().moment == 'go', 'GO is a moment')
check(lastLight() and lastLight().hold == 3, 'held for three seconds by the app')
check(lastSound() == 'event:UI_CountdownGo', 'with the start tone')

reset()
serverState({ phase = 'racing', flag = 'green' })
check(lastLight() and lastLight().light == 'off' and lastLight().moment == nil,
  'racing under green after GO is dark, with no second green')
reset()
serverState({ phase = 'racing', flag = 'green' })
serverState({ phase = 'racing', flag = 'green' })
check(#lightPushes() == 0, 'repeated broadcasts of the same state push nothing')
check(#sounds == 0, 'and play nothing')

-- ---------------------------------------------------------------------------
-- Behind the pace car GO is not a green
-- ---------------------------------------------------------------------------
serverState({ phase = 'finished' })
serverState({ phase = 'countdown', paceLap = true })
countdown(3); countdown(2); countdown(1)
reset()
countdown(0)
check(lastLight() and lastLight().moment == nil,
  'a pace-lap start has no GO moment: the formation lap is not racing')
check(lastSound() == 'event:UI_Countdown1', 'just a beep for the release')

reset()
serverState({ phase = 'racing', flag = 'yellow', paceLap = true, pacing = true })
check(lastLight() and lastLight().light == 'pace', 'the pace lap has its own light')

-- THE DERBY'S GO IS ALWAYS A GREEN, whatever the race's pace-lap rule says.
serverState({ phase = 'waiting', paceLap = true })
handlers['RM_DerbyCountdown']({ count = 1 })
check(lastLight() and lastLight().light == 'count1', 'the derby countdown lights the gantry')
reset()
handlers['RM_DerbyCountdown']({ count = 0 })
check(lastLight() and lastLight().moment == 'go', 'and its GO is green with a pace lap armed for races')
serverState({ phase = 'racing', flag = 'yellow', paceLap = true, pacing = true })

-- ---------------------------------------------------------------------------
-- GET READY, then the green
-- ---------------------------------------------------------------------------
reset()
serverState({ phase = 'racing', flag = 'yellow', paceLap = true, pacing = true, greenReady = true })
check(lastLight() and lastLight().light == 'ready', 'GET READY is its own light')
-- SILENT: it used to beep the countdown's beep, and drivers went on it.
check(#sounds == 0, 'and it makes no sound: the start tone belongs to the green')

reset()
serverState({ phase = 'racing', flag = 'green', paceLap = true })
check(lastLight() and lastLight().light == 'off', 'the green leaves nothing standing')
check(lastLight() and lastLight().moment == 'green', 'but flashes the green as a moment')
check(lastLight() and lastLight().hold == 4, 'for four seconds')
check(lastSound() == 'event:UI_CountdownGo', 'with the start tone')

-- ---------------------------------------------------------------------------
-- The caution and the restart
-- ---------------------------------------------------------------------------
reset()
serverState({ phase = 'racing', flag = 'yellow', cautionPending = true })
check(lastLight() and lastLight().light == 'cautionBack', 'a caution called: race back to the line')
serverState({ phase = 'racing', flag = 'yellow', caution = true })
check(lastLight() and lastLight().light == 'caution', 'then the frozen caution')
serverState({ phase = 'racing', flag = 'yellow', caution = true, restartPending = true })
check(lastLight() and lastLight().light == 'restart', 'then the restart this lap')
reset()
serverState({ phase = 'racing', flag = 'yellow', caution = true, restartPending = true,
  greenReady = true })
check(lastLight() and lastLight().light == 'readyRestart',
  'GET READY on the run in beats the caution, keeping the restart lamps')
check(#sounds == 0, 'and is silent here too')
reset()
serverState({ phase = 'racing', flag = 'green' })
check(lastLight() and lastLight().moment == 'green', 'and the restart is a green flag')

-- ---------------------------------------------------------------------------
-- The red flag beats everything, and lifting it is a green
-- ---------------------------------------------------------------------------
reset()
serverState({ phase = 'racing', flag = 'red', caution = true })
check(lastLight() and lastLight().light == 'red', 'a red flag is red, caution or not')
check(lastSound() == 'event:>UI>Main>Cancel', 'with a stop tone')
reset()
serverState({ phase = 'racing', flag = 'green' })
check(lastLight() and lastLight().moment == 'green', 'lifting the red is a green flag')

-- A session ending from under a held light is not a green.
serverState({ phase = 'racing', flag = 'yellow', pacing = true })
reset()
serverState({ phase = 'finished', flag = 'green' })
check(lastLight() and lastLight().light == 'off' and lastLight().moment == nil,
  'a session ended during the pace lap shows no green')
check(#sounds == 0, 'and plays nothing')

-- ---------------------------------------------------------------------------
-- This driver's own flags
-- ---------------------------------------------------------------------------
serverState({ phase = 'racing', flag = 'green', drivers = { { id = 1, name = 'Me' } } })
reset()
serverState({ phase = 'racing', flag = 'green', drivers = { { id = 1, name = 'Me', blue = true } } })
check(lastLight() and lastLight().moment == 'blue', 'the blue flag reaches the lights')
reset()
RM.lightsMoment('white')
check(lastLight() and lastLight().moment == 'white' and lastLight().hold == 4,
  'the white flag is a four second moment')
reset()
RM.lightsMoment('nonsense')
check(#lightPushes() == 0, 'an unknown moment pushes nothing')

-- ---------------------------------------------------------------------------
-- The drag tree
-- ---------------------------------------------------------------------------
serverState({ phase = 'waiting', drivers = {} })
reset()
RM.lightsTree({ stage = 'staged', lane = 2, dial = 9.8, prestaged = true, staged = false })
check(lastLight() and lastLight().light == 'tree', 'a lit tree takes the lights over')
check(lastLight() and lastLight().tree.lane == 2, 'and carries the lane')
check(#sounds == 0, 'staging is silent')
for _, st in ipairs({ 'amber1', 'amber2', 'amber3' }) do
  reset()
  RM.lightsTree({ stage = st, lane = 2, prestaged = true, staged = true })
  check(lastLight() and lastLight().tree.stage == st, st .. ' is pushed')
  check(lastSound() == 'event:UI_Countdown1', st .. ' beeps')
end
reset()
RM.lightsTree({ stage = 'green', lane = 2 })
check(lastSound() == 'event:UI_CountdownGo', 'the green bulb has the start tone')
reset()
RM.lightsTree({ stage = 'off' })
check(lastLight() and lastLight().light == 'off' and lastLight().tree == nil,
  'the tree going out gives the lights back')

-- ---------------------------------------------------------------------------
-- THE LIFT METER: a lift owed lights the meter, pushed as it moves
-- ---------------------------------------------------------------------------
local LIFT = { enabled = true, warnings = 0, type = 'lift', penaltySec = 5, liftSec = 3,
  liftWindow = 30, maxGates = 2 }
local function frames(secs, step)
  step = step or 0.05
  for _ = 1, math.floor(secs / step + 0.5) do RM.onUpdate(step) end
end
local function liftRow(t, extra)
  local me = { id = 1, name = 'Me', status = 'racing' }
  for k, v in pairs(t or {}) do me[k] = v end
  local st = { phase = 'racing', flag = 'green', cpSkip = LIFT, drivers = { me } }
  for k, v in pairs(extra or {}) do st[k] = v end
  serverState(st)
end
serverState({ phase = 'waiting', drivers = {} })
liftRow()
veh.speed, vm.throttle = 30, 1
reset()
liftRow({ liftOwed = 1, liftWindowLeft = 30 })
frames(0.2)
local L = lastLight()
check(L and L.light == 'lift', 'a lift owed lights the meter')
check(L and L.lift and L.lift.full == 3 and L.lift.left == 3, 'full and untouched while the throttle is on')
check(L and L.lift and L.lift.st == 'wait', 'waiting on the driver to lift')
check(L and L.lift and L.lift.win and L.lift.win > 29 and L.lift.win <= 30,
  'with the serve window, counted down between broadcasts')
reset()
frames(1.0)
check(#lightPushes() <= 1, 'nothing moving, nothing pushed (the window ticks in whole seconds)')

vm.throttle = 0
reset()
frames(1.0)
local pushes = lightPushes()
check(#pushes >= 5 and #pushes <= 11, 'lifting: the meter is pushed at most ten times a second ('
  .. #pushes .. ')')
L = lastLight()
check(L and L.lift and L.lift.st == 'lifting', 'the meter says the driver is lifting')
check(L and L.lift and L.lift.left > 1.8 and L.lift.left < 2.2, 'and how much is left (about 2s)')

-- The window pauses with the field, as the server's does.
liftRow({ liftOwed = 1, liftWindowLeft = 20 }, { caution = true, flag = 'yellow' })
check(lastLight() and lastLight().light == 'caution', 'a caution outranks the meter')
frames(2.0)
reset()
liftRow({ liftOwed = 1, liftWindowLeft = 20 })
L = lastLight()
check(L and L.light == 'lift' and L.lift.win == 20, 'back to the meter at the window the server holds')
-- THE GREEN IS NOT LOST TO A PENALTY: the caution ending is the green flag,
-- with its tone, for a driver who owes a lift as for everybody else.
check(L and L.moment == 'green' and L.hold == 4, 'the caution ending is still the green flag')
check(lastSound() == 'event:UI_CountdownGo', 'with the start tone')

-- A hazard yellow is about the whole field: it outranks the meter too.
liftRow({ liftOwed = 1, liftWindowLeft = 20 }, { flag = 'yellow' })
frames(0.2)
check(lastLight() and lastLight().light == 'yellow', 'a hazard yellow outranks the meter')
reset()
liftRow({ liftOwed = 1, liftWindowLeft = 20 })
frames(0.2)
check(lightPushes()[1] and lightPushes()[1].light == 'lift' and lightPushes()[1].moment == 'green',
  'and its end is a green, back to the meter')

-- Throttle on past the grace: the meter empties and says so.
vm.throttle = 1
reset()
frames(0.5)
L = lastLight()
check(L and L.lift and L.lift.st == 'restart' and L.lift.left == 3, 'throttle on: the lift restarts')

-- Two owed: the meter says one more.
liftRow({ liftOwed = 2, liftWindowLeft = 20 })
frames(0.2)
check(lastLight() and lastLight().lift and lastLight().lift.more == 1, 'one more owed after this')

-- Served: the moment, then the light goes out when the server catches up.
liftRow({ liftOwed = 1, liftWindowLeft = 20 })
vm.throttle = 0
reset()
frames(3.3)
local served = false
for _, p in ipairs(lightPushes()) do
  if p.moment == 'liftServed' and p.hold == 2 then served = true end
end
check(served, 'a served lift is a two second moment')
liftRow()
frames(0.2)
check(lastLight() and lastLight().light == 'off', 'and nothing is left standing')
reset()
frames(1.0)
check(#lightPushes() == 0, 'nothing owed: the meter costs nothing')
vm.throttle = 1

-- ---------------------------------------------------------------------------
-- THE BLACK FLAG: this driver's own standing light, under the field's
-- ---------------------------------------------------------------------------
reset()
liftRow({ blackFlag = 10, blackBy = 4 })
L = lastLight()
check(L and L.light == 'black' and L.black and L.black.sec == 10 and L.black.by == 4,
  'a black flag is a standing light, with its seconds and lap')
reset()
liftRow({ blackFlag = 10, blackBy = 4 })
check(#lightPushes() == 0, 'the same flag again pushes nothing')
liftRow({ blackFlag = 15, blackBy = 6 })
check(lastLight() and lastLight().black and lastLight().black.by == 6,
  'one added to it moves the lap without a new light')
liftRow({ blackFlag = 10, blackBy = 4 }, { caution = true, flag = 'yellow' })
check(lastLight() and lastLight().light == 'caution', 'a caution outranks it')
reset()
liftRow({ blackFlag = 10, blackBy = 4 })
check(lastLight() and lastLight().light == 'black' and lastLight().moment == 'green',
  'and its end is the green flag, back to the black flag')
check(lastSound() == 'event:UI_CountdownGo', 'with the start tone')
liftRow({ blackFlag = 10, blackBy = 4, liftOwed = 1, liftWindowLeft = 20 })
frames(0.2)
check(lastLight() and lastLight().light == 'lift', 'a lift being served shows over it')
liftRow()
frames(0.2)
check(lastLight() and lastLight().light == 'off', 'served or withdrawn, the light goes out')
reset()
RM.lightsMoment('dsq')
check(lastLight() and lastLight().moment == 'dsq' and lastLight().hold == 6,
  'a disqualification is a six second moment')

-- ---------------------------------------------------------------------------
-- Sound off, and a resend
-- ---------------------------------------------------------------------------
RM.lightsSetSound(false)
reset()
serverState({ phase = 'countdown' })
countdown(3); countdown(0)
check(#sounds == 0, 'with sound off nothing plays')
check(lastLight() and lastLight().moment == 'go', 'and the lights still work')
RM.lightsSetSound(true)

reset()
RM.lightsResend()
check(#lightPushes() == 1 and lastLight().moment == nil,
  'a resend sends the standing light without replaying a moment')

if fails == 0 then
  print(string.format('lights_test: %d checks, 0 failures', checks))
else
  print(string.format('lights_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
