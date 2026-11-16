-- Headless test for what a DRIVER is told about a caution, in
-- lua/ge/extensions/raceManager.lua.
--
-- Three kinds of yellow reach a driver, and they ask for different things:
--   * a caution being raced back to: race back to the line;
--   * a caution frozen at the call, official in the same update as the
--     yellow: hold your place (racing back is exactly wrong);
--   * the advisory yellow, which freezes nothing: a hazard, take care.
-- The yellow's notice used to say "race back to the line" for all three.
--
-- And a driver who passed under caution reads it off their own row
-- (`ucPassed`, the cars they owe a place): told on the edge, told again for a
-- new car, and held on the HUD's sticky line until the place is given back.
--
-- Run from the repo root: lua5.3 tests/caution_client_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local notices  = {}
local handlers = {}
local veh = { id = 7, x = 0, y = 0, z = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation() end
function veh:queueLuaCommand() end
function veh:setMeshAlpha() end

be               = { getPlayerVehicle = function () return veh end }
getPlayerVehicle = function (_) return veh end
getAllVehicles   = function () return { veh } end
beamng_version   = '0.39.0.0'
vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function (e, p)
  if e == 'RaceManagerNotice' then notices[#notices + 1] = p end
end }
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
RM.onExtensionLoaded()

local function update(t)
  t.rmProtocol = 2
  t.phase = t.phase or 'racing'
  t.drivers = t.drivers or { { id = 1, name = 'Me', status = 'racing' } }
  handlers['RM_Update'](t)
end
local function noticed(msg)
  for _, n in ipairs(notices) do
    if n.msg == msg then return n end
  end
end

update({ flag = 'green' })

-- ---------------------------------------------------------------------------
-- The three yellows
-- ---------------------------------------------------------------------------
notices = {}
update({ flag = 'yellow' })
local n = noticed('YELLOW FLAG')
check(n and n.sub == 'Hazard on track, take care',
  'a plain yellow is a hazard (got ' .. tostring(n and n.sub) .. ')')
update({ flag = 'green' })

notices = {}
update({ flag = 'yellow', cautionPending = true })
n = noticed('YELLOW FLAG')
check(n and n.sub == 'Caution: race back to the line', 'a caution being raced back to says so')
update({ flag = 'green' })

notices = {}
update({ flag = 'yellow', caution = true })
n = noticed('YELLOW FLAG')
check(n and n.sub == 'Caution: positions frozen, hold your place',
  'a caution frozen at the call says hold your place, not race back (got '
    .. tostring(n and n.sub) .. ')')

-- ---------------------------------------------------------------------------
-- A pass under caution, off our own row
-- ---------------------------------------------------------------------------
local function owe(names)
  update({ flag = 'yellow', caution = true,
           drivers = { { id = 1, name = 'Me', status = 'racing', ucPassed = names },
                       { id = 2, name = 'Bob', status = 'racing' } } })
end
notices = {}
owe('Bob')
n = noticed('GIVE THE PLACE BACK')
check(n and n.sub == 'You passed Bob under caution', 'the driver is told whom to let by')
notices = {}
owe('Bob')
check(noticed('GIVE THE PLACE BACK') == nil, 'once, not on every update')
owe('Bob, Cara')
check(noticed('GIVE THE PLACE BACK') ~= nil, 'and again when another car is owed')
notices = {}
owe(nil)
owe('Bob')
check(noticed('GIVE THE PLACE BACK') ~= nil, 'a new pass after giving one back is told afresh')

-- Someone else's row is not ours.
notices = {}
owe(nil)
update({ flag = 'yellow', caution = true,
         drivers = { { id = 1, name = 'Me', status = 'racing' },
                     { id = 2, name = 'Bob', status = 'racing', ucPassed = 'Me' } } })
check(noticed('GIVE THE PLACE BACK') == nil, 'another driver\'s pass is not ours to give back')

print(string.format('caution_client_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
