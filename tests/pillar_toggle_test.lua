-- Headless test for the GATE SWITCHES: each player can hide, for themselves,
-- the checkpoint poles, the pit lane and the joker gate, each on its own (one
-- menu on the driver bar and the menu bar, remembered by the app).
--
-- Two properties matter. It is drawing only: a hidden gate still arms, scores,
-- opens the lane and counts the joker, or a driver who hides one loses laps.
-- And each switch hides its own group alone; direction markers have none.
--
-- Run from the repo root: lua5.3 tests/pillar_toggle_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- Stubs: the drawer is recorded, as in draw_test.
-- ---------------------------------------------------------------------------
local vec3mt = {}
vec3mt.__index = vec3mt
vec3mt.__add = function (a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
vec3mt.__sub = function (a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
vec3mt.__mul = function (a, s) return vec3(a.x * s, a.y * s, a.z * s) end
vec3 = function (x, y, z) return setmetatable({ x = x, y = y, z = z }, vec3mt) end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
color = function (r, g, b, a)
  local function chan(v) return math.max(0, math.min(255, math.floor(v or 0))) end
  return chan(r) * 16777216 + chan(g) * 65536 + chan(b) * 256 + chan(a or 255)
end
ColorF = function (r, g, b, a) return { r, g, b, a } end
ColorI = function (r, g, b, a) return { r, g, b, a } end
String = function (s) return s end

local cylinders, quads, tris, texts = {}, {}, {}, {}
debugDrawer = {
  drawCylinder = function (_, a, b, radius, col)
    cylinders[#cylinders + 1] = { a = a, b = b, radius = radius, color = col }
  end,
  drawTextAdvanced = function (_, at, text) texts[#texts + 1] = { at = at, text = text } end,
  drawQuadSolid = function (_, a, b, c, d, col)
    quads[#quads + 1] = { a = a, b = b, c = c, d = d, color = col }
  end,
  drawTriSolid = function (_, a, b, c, packed)
    if type(packed) ~= 'number' then error('drawTriSolid wants a packed color', 2) end
    tris[#tris + 1] = { a = a, b = b, c = c }
  end,
}

local veh = { id = 7, x = 0, y = 0, z = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation(x, y, z) self.x, self.y, self.z = x, y, z end
function veh:queueLuaCommand() end
function veh:setMeshAlpha() end

getPlayerVehicle = function (_) return veh end
be = { getPlayerVehicle = function () return veh end }
getAllVehicles = function () return { veh } end
beamng_version = '0.39.0.0'
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
log = function () end
local hooks = {}
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }
MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
local sent = {}
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
local handlers = {}
AddEventHandler = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
local function serverState(t) t.rmProtocol = 2; handlers['RM_Update'](t) end
local function frame()
  cylinders, quads, tris, texts = {}, {}, {}, {}
  RM.onUpdate(0.05)
end
-- Crossing is the segment between two frames, as in marker_test.
local function moveTo(y, x)
  veh.x, veh.y, veh.z = x or 0, y, 0
  frame()
end
local function route()
  for i = #hooks, 1, -1 do
    if hooks[i].event == 'RaceManagerRoute' then return hooks[i].payload end
  end
  return {}
end

-- Poles standing on a checkpoint line (x within the 20 m gate at y = 100/200).
local function checkpointPoles()
  local n = 0
  for _, c in ipairs(cylinders) do
    if (c.a.y == 100 or c.a.y == 200) and math.abs(c.a.x) <= 10 then n = n + 1 end
  end
  return n
end
-- Poles on the joker gate, which sits off to the side at x = 50. Upright only:
-- its glyph strokes are cylinders too.
local function jokerPoles()
  local n = 0
  for _, c in ipairs(cylinders) do
    if math.abs(c.a.x - 50) < 1 and c.a.x == c.b.x and c.a.y == c.b.y then n = n + 1 end
  end
  return n
end
-- Anything drawn on the joker gate's face: poles, fill, glyph.
local function jokerDraws()
  local n = 0
  for _, c in ipairs(cylinders) do if math.abs(c.a.x - 50) < 1 then n = n + 1 end end
  for _, q in ipairs(quads) do if math.abs(q.a.x - 50) < 1 then n = n + 1 end end
  return n
end
-- Anything drawn in the pit lane, which runs up x = -60: stalls, entry, exit.
local function pitDraws()
  local n = 0
  for _, c in ipairs(cylinders) do if math.abs(c.a.x + 60) < 12 then n = n + 1 end end
  for _, q in ipairs(quads) do if math.abs(q.a.x + 60) < 12 then n = n + 1 end end
  return n
end
local function noticeSince(from, kind)
  for i = from + 1, #hooks do
    if hooks[i].event == 'RaceManagerNotice' and hooks[i].payload.kind == kind then return true end
  end
  return false
end

-- Two checkpoints, a joker gate, a pit stall and a marker, all apart.
handlers['RM_ApplyLayout']({
  name = 'pillars', width = 20, height = 10,
  checkpoints = {
    { x = 0, y = 100, z = 0, hx = 0, hy = 1 },
    { x = 0, y = 200, z = 0, hx = 0, hy = 1 },
  },
  joker   = { { x = 50, y = 150, z = 0, hx = 1, hy = 0 } },
  pits    = { { x = -60, y = 150, z = 0, hx = 1, hy = 0 } },
  markers = { { x = 0, y = 150, z = 0, hx = 0, hy = 1, kind = 'right' } },
})
handlers['RM_ReleaseSpectate']({ source = 'race' })
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {},
  jokerEnabled = true })
moveTo(10)

-- ---------------------------------------------------------------------------
-- Shown by default
-- ---------------------------------------------------------------------------
check(checkpointPoles() == 4, 'on by default: the armed and next gate, two poles each (got '
  .. checkpointPoles() .. ')')
check(jokerPoles() == 2, 'and the joker gate')

-- ---------------------------------------------------------------------------
-- Hidden: the checkpoint poles go, nothing else does
-- ---------------------------------------------------------------------------
RM.setShowPoles(false)
frame()
check(checkpointPoles() == 0, 'off hides the checkpoint poles (got ' .. checkpointPoles() .. ')')
check(jokerPoles() == 2, 'the joker gate stays: it has its own switch')
check(pitDraws() > 0, 'the pit stall stays: so does the lane')
check(#tris > 0, 'the direction marker stays')

-- ---------------------------------------------------------------------------
-- Drawing only: a hidden gate still arms and scores
-- ---------------------------------------------------------------------------
check(route().nextWp == 1, 'checkpoint 1 is armed before the run')
moveTo(95); moveTo(105)
check(route().nextWp == 2, 'driving a hidden gate still clears it')
check(checkpointPoles() == 0, 'and the next one stays hidden too')

-- ---------------------------------------------------------------------------
-- Back on, and what the app may send
-- ---------------------------------------------------------------------------
RM.setShowPoles(true)
frame()
check(checkpointPoles() == 4, 'on again brings both gates back')

RM.setShowPoles('false')
frame()
check(checkpointPoles() == 0, 'the string "false" is off')
RM.setShowPoles(nil)
frame()
check(checkpointPoles() == 4, 'nil is on: a missing preference never hides a gate')

-- ---------------------------------------------------------------------------
-- The editor's Hide/Show Gates is a different switch
-- ---------------------------------------------------------------------------
-- Hiding pillars to race must not blank an admin's authoring view, and the
-- editor's toggle must not decide what a driver sees.
RM.setShowPoles(false)
serverState({ phase = 'waiting', totalLaps = 3, maxResets = -1, drivers = {},
  youAreAdmin = true })
RM.setEditorOpen(true)
frame()
check(#texts >= 2, 'an admin editing still sees every gate, labeled, with pillars off')
RM.setEditorOpen(false)
RM.editorToggleVisualize()        -- hide in the editor
RM.editorToggleVisualize()        -- and back
RM.setShowPoles(true)
frame()
check(checkpointPoles() == 4, 'the editor toggle leaves the pillar switch alone')

-- ---------------------------------------------------------------------------
-- The pit lane and the joker: a switch each
-- ---------------------------------------------------------------------------
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {},
  jokerEnabled = true })
frame()
check(pitDraws() > 0, 'the pit stall is on by default (got ' .. pitDraws() .. ')')
check(jokerDraws() > 0, 'and the joker gate')

RM.setShowPitGates(false)
frame()
check(pitDraws() == 0, 'pit off hides the stall (got ' .. pitDraws() .. ')')
check(checkpointPoles() == 4 and jokerPoles() == 2, 'and nothing else')

RM.setShowPitGates(true)
RM.setShowJokerGates(false)
frame()
check(jokerDraws() == 0, 'joker off hides its poles, fill and glyph (got ' .. jokerDraws() .. ')')
check(pitDraws() > 0 and checkpointPoles() == 4, 'and nothing else')

RM.setShowPoles(false)
RM.setShowPitGates(false)
frame()
check(checkpointPoles() + pitDraws() + jokerDraws() == 0, 'all three off hide all three')
check(#tris > 0, 'and the direction marker still stands: it has no switch')

-- Drawing only. On lap 1 the joker is shut, so crossing it draws a refusal:
-- proof the hidden gate was still seen.
local before = #hooks
moveTo(150, 40); moveTo(150, 60)
check(noticeSince(before, 'joker'), 'driving the hidden joker gate is still detected')

RM.setShowJokerGates('false')
frame()
check(jokerDraws() == 0, 'the string "false" is off for the joker')
RM.setShowJokerGates(nil)
RM.setShowPitGates(nil)
RM.setShowPoles(nil)
frame()
check(jokerDraws() > 0 and pitDraws() > 0 and checkpointPoles() == 4,
  'nil is on for all three: a missing preference never hides a gate')

-- An admin editing sees the lane and the joker with both switches off.
RM.setShowPitGates(false)
RM.setShowJokerGates(false)
serverState({ phase = 'waiting', totalLaps = 3, maxResets = -1, drivers = {},
  youAreAdmin = true, jokerEnabled = true })
RM.setEditorOpen(true)
frame()
check(pitDraws() > 0, 'the editor still draws the pit stall with pit off')
check(jokerPoles() == 2, 'and the joker gate with joker off')
RM.setEditorOpen(false)

-- A gated lane, with the switch off: crossing the hidden entry gate still puts
-- the driver in the lane, and nothing of it is drawn.
handlers['RM_ApplyLayout']({
  name = 'gated', width = 20, height = 10,
  checkpoints = {
    { x = 0, y = 100, z = 0, hx = 0, hy = 1 },
    { x = 0, y = 200, z = 0, hx = 0, hy = 1 },
  },
  pits     = { { x = -60, y = 150, z = 0, hx = 0, hy = 1 } },
  pitEntry = { { x = -60, y = 100, z = 0, hx = 0, hy = 1 } },
  pitExit  = { { x = -60, y = 200, z = 0, hx = 0, hy = 1 } },
})
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {} })
RM.setShowPitGates(true)
moveTo(90, -60)
check(pitDraws() > 0, 'a gated lane shows its entry gate')
check(route().pitInLane == false, 'and the driver is not in it yet')
-- Pit off hides the Pit In gate, but past it a driver needs the stalls.
local function stallDraws()
  local n = 0
  for _, q in ipairs(quads) do
    if math.abs(q.a.x + 60) < 12 and math.abs(q.a.y - 150) < 8 then n = n + 1 end
  end
  return n
end
RM.setShowPitGates(false)
frame()
check(pitDraws() == 0, 'pit off hides the Pit In gate (got ' .. pitDraws() .. ')')
-- One frame more after each crossing: a frame draws before its pit check.
moveTo(96, -60); moveTo(104, -60); frame()
check(route().pitInLane == true, 'crossing the hidden Pit In still enters the lane')
check(stallDraws() > 0, 'and in the lane the stalls show, pit off or not')
moveTo(196, -60); moveTo(204, -60); frame()
check(route().pitInLane == false, 'the exit gate takes them out')
check(pitDraws() == 0, 'and out of the lane it is hidden again')
RM.setShowPitGates(true)
frame()
check(pitDraws() > 0, 'back on, the Pit In gate shows')

-- This client's view only: no switch sends anything.
local sentBefore = #sent
for _, fn in ipairs({ 'setShowPoles', 'setShowPitGates', 'setShowJokerGates' }) do
  RM[fn](false); RM[fn](true)
end
check(#sent == sentBefore, 'no switch tells the server')

-- ---------------------------------------------------------------------------
-- The app wires it
-- ---------------------------------------------------------------------------
do
  local function read(p)
    local f = assert(io.open(p, 'r'))
    local s = f:read('*a')
    f:close()
    return s
  end
  local js, html = read('ui/modules/apps/RaceManager/app.js'), read('ui/modules/apps/RaceManager/app.html')
  for _, fn in ipairs({ 'setShowPoles', 'setShowPitGates', 'setShowJokerGates' }) do
    check(js:find('raceManager.' .. fn .. '(', 1, true) ~= nil, 'the app calls ' .. fn)
    check(type(RM[fn]) == 'function', 'and the bridge has ' .. fn)
  end
  -- 'poles' is the old key: a player who hid pillars before keeps that.
  for _, pref in ipairs({ "'poles'", "'pitGates'", "'jokerGates'" }) do
    check(js:find('pref: ' .. pref, 1, true) ~= nil, 'the choice is remembered under ' .. pref)
  end
  check(js:find('loadPref(k.pref, true) !== false', 1, true) ~= nil,
    'and an unset choice loads as shown')
  check(js:find('pushSound(); pushGates();', 1, true) ~= nil,
    'and resends them once a server is talking, in case Lua loaded after the panel')
  local _, bar  = html:gsub([[ng%-click="menuToggleGroup%('gates'%)"]], '')
  local _, drv  = html:gsub([[ng%-click="menuToggleGroup%('gatesBar'%)"]], '')
  local _, rows = html:gsub('ng%-click="toggleGate%(k%)"', '')
  check(bar == 1 and drv == 1, 'one menu on the menu bar and one on the driver bar')
  check(rows == 2, 'each with a checkbox row per kind (got ' .. rows .. ')')
end

print(string.format('pillar_toggle_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
