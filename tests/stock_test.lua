-- Headless test for STOCK TRACKS (lua/ge/extensions/raceManager/stock.lua):
-- BeamNG's own race files opened in the admin's editor.
--
--   * A circuit puts its start node LAST (PRM's line); a sprint puts it first.
--   * Width is radius * 2, clamped; heading is the normal, or along the route.
--   * Another way through that rejoins after as many nodes becomes branch
--     gates on those checkpoints; any other is left out and said so.
--   * Pole faces (sin, cos) of the start's yaw and sits back off the line; a
--     sprint's is always behind its start gate, the first one armed.
--   * The list is this level's races, its folder in any case. It names ids,
--     never paths, and open() takes only those.
--   * Through the client: opened privately, held as unsaved work, refused
--     over unsaved work and during a session.
--
-- Run from the repo root: lua5.3 tests/stock_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function near(a, b) return type(a) == 'number' and math.abs(a - b) < 1e-3 end

local S = dofile('lua/ge/extensions/raceManager/stock.lua')

local function node(id, x, y, r, nx, ny)
  return { oldId = id, pos = { x, y, 0 }, radius = r or 5, normal = nx and { nx, ny, 0 } or nil }
end
local function segs(pairs_)
  local out = {}
  for i, p in ipairs(pairs_) do out[i] = { from = p[1], to = p[2], oldId = 100 + i } end
  return out
end
-- A start position facing `yaw` radians: (sin, cos) on the ground.
local function startAt(id, x, y, z, yaw)
  return { oldId = id, pos = { x, y, z }, rot = { 0, 0, math.sin(yaw / 2), math.cos(yaw / 2) } }
end

-- ---------------------------------------------------------------------------
-- A circuit
-- ---------------------------------------------------------------------------
do
  local race = {
    startNode = 1, defaultStartPosition = 9,
    pathnodes = {
      node(1, 0, 0, 5, 0, 1), node(2, 0, 100, 1, 1, 0),
      node(3, 100, 100, 100, 0, -1), node(4, 100, 0, 5),
    },
    segments = segs({ { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 } }),
    startPositions = { startAt(9, 0, -1, 10, 0) },
  }
  local l, notes = S.convert(race)
  check(l and l.pointToPoint == false, 'a segment back to the start node makes a circuit')
  check(l and #l.checkpoints == 4, 'every node on the lap is a checkpoint')
  local cp = l and l.checkpoints or {}
  check(cp[4] and near(cp[4].x, 0) and near(cp[4].y, 0), 'the start node is the LAST gate: the line')
  check(cp[1] and near(cp[1].y, 100) and near(cp[3].x, 100) and near(cp[3].y, 0),
    'the rest follow in driving order')
  check(cp[4] and near(cp[4].hx, 0) and near(cp[4].hy, 1), 'a gate faces its normal')
  check(cp[1] and near(cp[1].hx, 1) and near(cp[1].hy, 0), 'every gate its own normal')
  check(cp[3] and near(cp[3].hx, -math.sqrt(0.5)) and near(cp[3].hy, -math.sqrt(0.5)),
    'no normal: faces from the node before to the one after, round the line')
  check(cp[4] and near(cp[4].width, 10), 'width is the radius times two')
  check(cp[1] and near(cp[1].width, S.MIN_WIDTH), 'a tiny radius is widened to the minimum')
  check(cp[2] and near(cp[2].width, S.MAX_WIDTH), 'a huge radius is capped')
  local found = false
  for _, s in ipairs(notes or {}) do if s:find('1 gate%(s%) face along the route') then found = true end end
  check(found, 'gates without a normal are said')
  local sp = l and l.startPositions and l.startPositions[1]
  check(sp and near(sp.hx, 0) and near(sp.hy, 1), 'pole faces the start\'s own heading')
  check(sp and near(sp.y, -1 - S.SLOT_BACK) and near(sp.z, 10 + S.SLOT_LIFT),
    'pole sits back off the line, and lifted off the ground')
  check(l and l.branches == nil, 'no branches, no branch list')
  check(l and l.height == S.HEIGHT and l.depth == S.DEPTH, 'the mod\'s own default gate size')
end

-- The yaw convention, as checked against the stock tracks: +z quarter turn is +x.
do
  local race = {
    startNode = 1, defaultStartPosition = 2,
    pathnodes = { node(1, 0, 0, 5, 1, 0), node(2, 100, 0, 5, 1, 0) },
    segments = segs({ { 1, 2 } }),
    startPositions = { startAt(2, 0, 0, 0, math.pi / 2), startAt(3, 0, 0, 0, 0) },
  }
  local l = S.convert(race)
  local sp = l and l.startPositions and l.startPositions[1]
  check(sp and near(sp.hx, 1) and near(sp.hy, 0), 'a quarter turn about +z faces +x')
  check(sp and near(sp.x, -S.SLOT_BACK) and near(sp.y, 0), 'and steps back along it')
  check(l and #l.startPositions == 1, 'only the default start is taken')
end

-- ---------------------------------------------------------------------------
-- A sprint
-- ---------------------------------------------------------------------------
do
  local race = {
    startNode = 1,
    pathnodes = { node(1, 0, 0, 5, 0, 1), node(2, 0, 100, 5, 0, 1), node(3, 0, 200, 5, 0, 1) },
    segments = segs({ { 1, 2 }, { 2, 3 } }),
  }
  local l, notes = S.convert(race)
  check(l and l.pointToPoint == true, 'no way back to the start: a sprint')
  check(l and #l.checkpoints == 3 and near(l.checkpoints[1].y, 0) and near(l.checkpoints[3].y, 200),
    'a sprint runs start gate first, finish last')
  local sp = l and l.startPositions and l.startPositions[1]
  check(sp and near(sp.x, 0) and near(sp.y, -S.SLOT_BACK) and near(sp.hy, 1),
    'no start in the file: pole behind the start gate, facing through it')
  local found = false
  for _, s in ipairs(notes or {}) do if s:find('pole set behind the start gate') then found = true end end
  check(found, 'and said')

  -- An AI race starts rolling, past the start node: the car would never cross gate 1.
  race.defaultStartPosition = 9
  race.startPositions = { startAt(9, 2, 10, 0, 0) }
  l = S.convert(race)
  sp = l and l.startPositions and l.startPositions[1]
  check(sp and near(sp.x, 0) and near(sp.y, -S.SLOT_BACK), 'a start past the start gate is moved behind it')
  race.startPositions = { startAt(9, 2, -20, 0, 0) }
  l = S.convert(race)
  sp = l and l.startPositions and l.startPositions[1]
  check(sp and near(sp.x, 2) and near(sp.y, -20 - S.SLOT_BACK), 'one behind it is kept where its author put it')
end

-- A circuit with no start: pole behind the line.
do
  local l = S.convert({
    startNode = 1,
    pathnodes = { node(1, 0, 0, 5, 1, 0), node(2, 100, 0), node(3, 100, 100) },
    segments = segs({ { 1, 2 }, { 2, 3 }, { 3, 1 } }),
  })
  local sp = l and l.startPositions and l.startPositions[1]
  check(sp and near(sp.x, -S.SLOT_BACK) and near(sp.y, 0) and near(sp.hx, 1), 'a circuit\'s pole goes behind the line')
end

-- ---------------------------------------------------------------------------
-- Other ways through
-- ---------------------------------------------------------------------------
do
  local race = {
    startNode = 1,
    pathnodes = {
      node(1, 0, 0), node(2, 0, 100), node(3, 100, 100), node(4, 100, 0),
      node(5, -10, 100, 5, 0, -1), node(6, 50, 150), node(7, 60, 150), node(8, 50, -10),
    },
    segments = segs({
      { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 },
      { 1, 5 }, { 5, 3 },             -- one node instead of node 2: a branch gate
      { 2, 6 }, { 6, 7 }, { 7, 4 },   -- two nodes instead of one: left out
      { 4, 8 }, { 8, 1 },             -- a node before the line, nothing to pair it with
    }),
  }
  local l, notes = S.convert(race)
  check(l and #l.checkpoints == 4, 'the first way on is the route')
  local b = l and l.branches or {}
  check(#b == 1 and b[1].slot == 1 and near(b[1].x, -10),
    'an alternative as long as the route it skips is a branch gate on that checkpoint')
  check(b[1] and near(b[1].hy, -1), 'a branch gate faces its own normal')
  local found = false
  for _, s in ipairs(notes or {}) do if s:find('^2 other way') then found = true end end
  check(found, 'the two that do not fit are left out, and said')
end

-- A lap's last node also leading off to a finish (italy's Port): still a circuit.
do
  local race = {
    startNode = 1,
    pathnodes = { node(1, 0, 0), node(2, 0, 100), node(3, 100, 100), node(9, 200, 100) },
    segments = segs({ { 1, 2 }, { 2, 3 }, { 3, 1 }, { 3, 9 } }),
  }
  local l = S.convert(race)
  check(l and l.pointToPoint == false and #l.checkpoints == 3, 'the way back to the start wins')
end

-- Malformed graphs stop rather than loop.
do
  local l = S.convert({
    startNode = 1,
    pathnodes = { node(1, 0, 0), node(2, 0, 100), node(3, 0, 200) },
    segments = segs({ { 1, 2 }, { 2, 3 }, { 3, 2 } }),
  })
  check(l and l.pointToPoint == true and #l.checkpoints == 3, 'a loop that misses the start ends the route')
  local none, why = S.convert({ startNode = 99, pathnodes = { node(1, 0, 0) }, segments = {} })
  check(none == nil and type(why) == 'string', 'no start node: refused with a reason')
  none = S.convert({ startNode = 1, pathnodes = { node(1, 0, 0) }, segments = {} })
  check(none == nil, 'one gate is not a track')
  check(S.convert('nope') == nil and S.convert({}) == nil, 'not a race file at all')
  local ok = pcall(S.convert, { startNode = 1, pathnodes = { { oldId = 1, pos = 'x' } }, segments = { 'x' } })
  check(ok, 'junk fields never throw')
end

-- ---------------------------------------------------------------------------
-- Titles
-- ---------------------------------------------------------------------------
check(S.pretty('Street1') == 'Street 1' and S.pretty('mixedrally') == 'Mixedrally'
  and S.pretty('PortTT') == 'Port TT', 'short names read as words')
S.io.translate = function (key) return key == 'k.ok' and 'Translated' or nil end
check(S.title({ name = 'k.ok' }, '001-x') == 'Translated', 'the game\'s own translation first')
check(S.title({ name = 'missions.lvl.timeTrial.Hill2.title' }, '001-x') == 'Hill 2',
  'an untranslated key gives its short name')
check(S.title({ name = 'My Mod Race' }, '001-x') == 'My Mod Race', 'a mod map\'s plain title is kept')
check(S.title(nil, '007-Street') == 'Street', 'no info.json: the folder, without its number')
check(#S.title({ name = string.rep('long ', 20) }, 'x') <= S.MAX_NAME, 'titles fit a layout name')

-- ---------------------------------------------------------------------------
-- The list, and opening from it
-- ---------------------------------------------------------------------------
local LEVEL = 'lvl'
local FILES = {}
local function put(kind, folder, race, info, levelDir)
  local dir = '/gameplay/missions/' .. (levelDir or LEVEL) .. '/' .. kind .. '/' .. folder .. '/'
  FILES[dir .. 'race.race.json'] = race
  FILES[dir .. 'info.json'] = info
end
local LAP = {
  startNode = 1, defaultStartPosition = 9,
  pathnodes = { node(1, 0, 0, 5, 0, 1), node(2, 0, 100, 5, 1, 0), node(3, 100, 100, 5, 0, -1) },
  segments = segs({ { 1, 2 }, { 2, 3 }, { 3, 1 } }),
  startPositions = { startAt(9, 0, -1, 0, 0) },
}
local SPRINT = {
  startNode = 1,
  pathnodes = { node(1, 0, 0), node(2, 0, 100) },
  segments = segs({ { 1, 2 } }),
}
put('timeTrial', '002-Bravo', LAP, { name = 'missions.lvl.timeTrial.Bravo1.title' })
put('timeTrial', '001-Zulu', LAP, { name = 'k.zulu' }, 'LVL')
put('aiRace', '001-Alpha', SPRINT, nil)
put('timeTrial', '001-Elsewhere', LAP, { name = 'Elsewhere' }, 'other_level')
put('drift', '001-Skid', LAP, { name = 'Skid' })
put('timeTrial', '003-Broken', nil, { name = 'Broken' })
local asked
S.io.level = function () return LEVEL end
S.io.find = function (dir)
  asked = dir
  local out = {}
  for path in pairs(FILES) do
    if path:find('race%.race%.json$') then out[#out + 1] = path end
  end
  table.sort(out)
  return out
end
S.io.read = function (path) return FILES[path] end
S.io.translate = function (key) return key == 'k.zulu' and 'Zulu Ring' or nil end

local list, level = S.list()
check(level == 'lvl' and asked == '/gameplay/missions/', 'searches the missions folder')
check(#list == 3, 'this level\'s races only, its folder in any case: no drift, nothing unreadable')
check(list[1] and list[1].name == 'Bravo 1' and list[2].name == 'Zulu Ring' and list[3].name == 'Alpha',
  'time trials first, then AI races, by name')
check(list[3] and list[3].kind == 'AI Race' and list[3].circuit == false and list[3].gates == 2,
  'each says what it is and how many gates')
check(list[1] and list[1].id == 'timeTrial/002-Bravo' and not list[1].path, 'ids, never paths')

local l, notes = S.open('timeTrial/002-Bravo')
check(l and l.name == 'Bravo 1' and #l.checkpoints == 3 and type(notes) == 'table',
  'open() gives the named layout')
check(S.open('../../settings/x') == nil, 'nothing that was not listed')
check(S.open(nil) == nil, 'nothing at all')
S.io.level = function () return nil end
local empty = S.list()
check(#empty == 0 and S.open('timeTrial/002-Bravo') == nil, 'no level: an empty list, and the old ids go')
S.io.level = function () return LEVEL end
S.list()

-- ---------------------------------------------------------------------------
-- Through the client
-- ---------------------------------------------------------------------------
local hooks, handlers = {}, {}
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
be = { getPlayerVehicle = function () return veh end }
getPlayerVehicle = function () return veh end
getAllVehicles   = function () return { veh } end
beamng_version   = '0.40.0.0'
vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quatFromDir = function (d, up) return { x = 0, y = up and up.z or 0, z = d.x, w = d.y } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
castRayStatic = function (o, dir, len) return (len or 100) + 1 end
log  = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }
MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function () end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt   = { getConfig = function () return { parts = {}, vars = {} } end }

package.path = 'lua/ge/extensions/?.lua;' .. package.path
-- The client requires the module by this name: give it the stubbed one.
package.loaded['raceManager/stock'] = S
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

local function lastHook(event)
  for i = #hooks, 1, -1 do
    if hooks[i].event == event then return hooks[i].payload end
  end
end
local function serverState(t) t.rmProtocol = 2; handlers['RM_Update'](t) end
serverState({ phase = 'waiting', drivers = {}, youAreAdmin = true })
RM.setEditorOpen(true)

RM.libraryList()
local got = lastHook('RaceManagerLibrary')
check(got and got.map == 'lvl' and #got.tracks == 3, 'the list reaches the UI with its level')

RM.libraryOpen('timeTrial/999-Nope')
local msg = lastHook('RaceManagerEditorMsg')
check(msg and msg.msg:find('Could not open', 1, true), 'an unknown id is refused, not thrown')

RM.libraryOpen('timeTrial/002-Bravo')
local route = lastHook('RaceManagerRoute')
check(route and #route.waypoints == 3, 'opening applies the gates')
msg = lastHook('RaceManagerEditorMsg')
check(msg and msg.msg:find('Opened "Bravo 1" in your editor only', 1, true), 'and says it is private')

-- Held as unsaved work: a layout from the server does not wipe it.
handlers['RM_ApplyLayout']({
  name = 'other', width = 20, height = 8, depth = 2,
  checkpoints = { { x = 5, y = 5, z = 0, hx = 0, hy = 1 } },
})
route = lastHook('RaceManagerRoute')
check(route and #route.waypoints == 3, 'a server load does not land on an unsaved import')

RM.libraryOpen('aiRace/001-Alpha')
msg = lastHook('RaceManagerEditorMsg')
check(msg and msg.msg:find('unsaved work', 1, true), 'a second track is refused over unsaved work')

-- Once the server's copy is back in the editor, another one opens.
RM.setEditorOpen(false)
handlers['RM_ApplyLayout']({
  name = 'other', width = 20, height = 8, depth = 2,
  checkpoints = { { x = 5, y = 5, z = 0, hx = 0, hy = 1 } },
})
RM.setEditorOpen(true)
RM.libraryOpen('aiRace/001-Alpha')
route = lastHook('RaceManagerRoute')
check(route and #route.waypoints == 2, 'after a load, another stock track opens')

serverState({ phase = 'racing', drivers = {}, youAreAdmin = true })
RM.libraryOpen('timeTrial/002-Bravo')
msg = lastHook('RaceManagerEditorMsg')
check(msg and msg.msg:find('Not while a session', 1, true), 'never during a session')

print(string.format('stock_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
