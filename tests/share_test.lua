-- Headless test for SHARED LAYOUT FILES, client side
-- (lua/ge/extensions/raceManager/share.lua).
--
--   * One file per map, '<map>.prm.json', any number of layouts in it.
--   * Nothing is ever overwritten: an identical layout is skipped, a different
--     one under a taken name goes in as "Name (2)"; a file that is not ours, or
--     is for another map, is never written over.
--   * A file is somebody else's text: too big, not PRM, newer, mapless or
--     empty is refused, and only a layout's own fields are taken.
--   * Listed for this map only, in any case; ids, never paths.
--   * Export: the server's copies, any order, merged once the last arrives.
--   * Import: paced, one layout per INTERVAL, numbered, for this map.
--   * Through the client: ask, receive, write; list, open, import.
--
-- Run from the repo root: lua5.3 tests/share_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local Sh = dofile('lua/ge/extensions/raceManager/share.lua')

local function copy(t)
  if type(t) ~= 'table' then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end

-- An in-memory folder. A file's text is a token the decoder maps back to a
-- copy of what was written, so a read never shares tables with a write.
local FOLDER, TEXT = {}, {}
local explored, writes, sends = 0, 0, {}
local function store(path, data, text)
  text = text or ('json:' .. path .. ':' .. writes)
  FOLDER[path] = text
  TEXT[text] = data
end
Sh.io.level = function () return 'lvl' end
Sh.io.mkdir = function () end
Sh.io.find = function ()
  local out = {}
  for path in pairs(FOLDER) do out[#out + 1] = path end
  table.sort(out)
  return out
end
Sh.io.read = function (path) return FOLDER[path] end
Sh.io.decode = function (text) return copy(TEXT[text]) end
Sh.io.write = function (path, data) writes = writes + 1; store(path, copy(data)); return true end
Sh.io.send = function (event, data) sends[#sends + 1] = { event = event, data = copy(data) } end
Sh.io.explore = function () explored = explored + 1 end

local DIR = Sh.DIR .. '/'
local function gates(...)
  local out = {}
  for i, x in ipairs({ ... }) do out[i] = { x = x, y = 0, z = 0, hx = 0, hy = 1 } end
  return out
end
local function layout(name, ...) return { name = name, checkpoints = gates(...) } end
local function fileOf(map) return TEXT[FOLDER[DIR .. Sh.fileName(map)]] end
local function namesIn(data)
  local out = {}
  for _, l in ipairs(data and data.layouts or {}) do out[#out + 1] = l.name end
  return table.concat(out, ', ')
end

-- ---------------------------------------------------------------------------
-- Pieces
-- ---------------------------------------------------------------------------
check(Sh.fileName('west_coast_usa') == 'west_coast_usa.prm.json', 'one file per map, named after it')
check(Sh.fileName('A/B:C*') == 'A_B_C_.prm.json', 'nothing Windows refuses in a file name')

local c = Sh.clean({ name = '  Club  ', checkpoints = gates(1), practice = true, map = 'x', evil = 1,
                     props = { 1 }, sectors = { 2 } })
check(c and c.name == 'Club' and c.props and c.sectors and c.practice == nil and c.map == nil
  and c.evil == nil, 'a layout keeps its own fields only')
check(Sh.clean({ name = string.rep('n', 80), checkpoints = gates(1) }).name == string.rep('n', 40),
  'a name is cut to what the server keeps')
check(Sh.clean({ checkpoints = gates(1) }).name == 'Shared layout', 'no name gets one')
check(Sh.clean({ name = 'x', checkpoints = {} }) == nil and Sh.clean('x') == nil, 'no checkpoints, no layout')

check(Sh.sameTrack(layout('a', 1, 2), layout('b', 1, 2)), 'the same gates are the same track, whatever the name')
check(Sh.sameTrack(layout('a', 1, 2), layout('a', 1.01, 2)), 'a centimeter of drift is still the same track')
check(not Sh.sameTrack(layout('a', 1, 2), layout('a', 1, 3)), 'a moved gate is not')
check(not Sh.sameTrack(layout('a', 1, 2), layout('a', 1, 2, 3)), 'nor another gate count')
local p2p = layout('a', 1, 2); p2p.pointToPoint = true
check(not Sh.sameTrack(layout('a', 1, 2), p2p), 'nor a sprint of a circuit')

-- ---------------------------------------------------------------------------
-- Merging: nothing is ever overwritten
-- ---------------------------------------------------------------------------
do
  local mine = { layout('Oval', 1, 2), layout('Club', 3, 4) }
  local merged, res = Sh.merge(mine, { layout('Oval', 1, 2), layout('Club', 5, 6), layout('New', 7, 8) })
  check(#merged == 4 and res.added == 2 and res.same == 1, 'identical skipped, the rest added')
  check(merged[1].name == 'Oval' and merged[2].name == 'Club' and merged[2].checkpoints[1].x == 3,
    'what was there is untouched, and first')
  check(merged[3].name == 'Club (2)' and merged[3].checkpoints[1].x == 5, 'a different "Club" is "Club (2)"')
  check(res.renamed[1] == '"Club" as "Club (2)"', 'and the rename is reported')
  local again, res2 = Sh.merge(merged, { layout('Oval', 1, 2), layout('Club', 5, 6), layout('New', 7, 8) })
  check(#again == 4 and res2.added == 0 and res2.same == 3, 'merging the same again adds nothing')
  local third = select(1, Sh.merge(again, { layout('club', 9, 9) }))
  check(third[5] and third[5].name == 'club (3)', 'names clash without case; the next free number')
  local long = string.rep('L', 40)
  local l2 = select(1, Sh.merge({ layout(long, 1) }, { layout(long, 2) }))
  check(l2[2] and #l2[2].name == 40 and l2[2].name:sub(-4) == ' (2)', 'a renamed long name still fits')
end

-- ---------------------------------------------------------------------------
-- Writing a map's file
-- ---------------------------------------------------------------------------
do
  local file, res = Sh.write('lvl', { layout('Oval', 1, 2) }, '9.9.9')
  local data = fileOf('lvl')
  check(file == 'lvl.prm.json' and res.added == 1, 'a new file for the map')
  check(data and data.prmLayouts == Sh.FORMAT and data.map == 'lvl' and data.build == '9.9.9'
    and namesIn(data) == 'Oval', 'stamped with the format, the map and the build')
  local w = writes
  file, res = Sh.write('lvl', { layout('Oval', 1, 2) }, '9.9.9')
  check(res.same == 1 and writes == w, 'nothing new: the file is not even rewritten')
  Sh.write('lvl', { layout('Oval', 5, 6), layout('Club', 3, 4) }, '9.9.9')
  check(namesIn(fileOf('lvl')) == 'Oval, Oval (2), Club', 'merged in, never over: ' .. namesIn(fileOf('lvl')))

  store(DIR .. 'foreign.prm.json', { something = 'else' })
  local was = FOLDER[DIR .. 'foreign.prm.json']
  local nope, why = Sh.write('foreign', { layout('X', 1) })
  check(nope == nil and why:find('move it first', 1, true) and FOLDER[DIR .. 'foreign.prm.json'] == was,
    'a file there that is not ours is never written over')
  store(DIR .. 'mapb.prm.json', { prmLayouts = 1, map = 'other', layouts = { layout('Y', 1) } })
  nope = Sh.write('mapb', { layout('X', 1) })
  check(nope == nil, 'nor one that says it is for another map')
  FOLDER[DIR .. 'foreign.prm.json'], FOLDER[DIR .. 'mapb.prm.json'] = nil, nil
end

-- ---------------------------------------------------------------------------
-- Reading somebody else's file
-- ---------------------------------------------------------------------------
store(DIR .. 'big.json', nil, string.rep('x', Sh.MAX_BYTES + 1))
store(DIR .. 'notprm.json', { map = 'lvl', layouts = { layout('A', 1) } })
store(DIR .. 'newer.json', { prmLayouts = Sh.FORMAT + 1, map = 'lvl', layouts = { layout('A', 1) } })
store(DIR .. 'nomap.json', { prmLayouts = 1, layouts = { layout('A', 1) } })
store(DIR .. 'empty.json', { prmLayouts = 1, map = 'lvl', layouts = { { name = 'E', checkpoints = {} } } })
store(DIR .. 'garbage.json', 'not a table')
local function reason(file)
  local d, why = Sh.read(DIR .. file)
  return d == nil and type(why) == 'string' and why or nil
end
check(reason('big.json') and reason('big.json'):find('too big'), 'too big is refused before parsing')
check(reason('notprm.json'), 'a JSON file that is not PRM\'s is refused')
check(reason('newer.json') and reason('newer.json'):find('newer'), 'a newer format says update first')
check(reason('nomap.json'), 'a file that does not say its map is refused')
check(reason('empty.json'), 'a file with no usable layout is refused')
check(reason('garbage.json') and reason('missing.json'), 'garbage, or a file that is gone, is refused')
for _, f in ipairs({ 'big.json', 'notprm.json', 'newer.json', 'nomap.json', 'empty.json', 'garbage.json' }) do
  FOLDER[DIR .. f] = nil
end

-- ---------------------------------------------------------------------------
-- The list, and opening from it
-- ---------------------------------------------------------------------------
-- lvl.prm.json holds Oval, Oval (2), Club. A downloaded copy for the same map
-- under another name, and one for another map:
store(DIR .. 'lvl (1).prm.json', { prmLayouts = 1, map = 'LVL', layouts = { layout('Downloaded', 9, 9) } })
store(DIR .. 'other.prm.json', { prmLayouts = 1, map = 'other_map', layouts = { layout('A', 1), layout('B', 2) } })
local list, elsewhere = Sh.list('lvl')
local names = {}
for _, e in ipairs(list) do names[#names + 1] = e.name end
check(#list == 4 and elsewhere == 2,
  'every layout in this map\'s files, in any case; the count for other maps: ' .. table.concat(names, ', '))
check(names[1] == 'Club' and names[2] == 'Downloaded', 'by name')
check(list[1] and list[1].id == 'file/lvl.prm.json#3' and list[1].kind == 'Shared file' and list[1].gates == 2,
  'each with an id, never a path')
local l = Sh.open('file/lvl.prm.json#3')
check(l and l.name == 'Club' and #l.checkpoints == 2, 'open() gives the layout')
check(Sh.open('file/../x.json#1') == nil and Sh.open(nil) == nil, 'nothing that was not listed')

-- ---------------------------------------------------------------------------
-- Export: the server's copies arrive one at a time, in any order
-- ---------------------------------------------------------------------------
do
  local full = layout('Props', 20, 21)
  full.props = { { kind = 'cone', x = 1, y = 1, z = 0 } }
  full.practice, full.map = true, 'lvl'
  check(Sh.receive({ map = 'lvl', index = 2, total = 3, layout = layout('Two', 30) }, 'b') == nil,
    'nothing written before the last arrives')
  check(Sh.receive({ map = 'lvl', index = 3, total = 3, layout = full }, 'b') == nil, 'still not')
  local file, res = Sh.receive({ map = 'lvl', index = 1, total = 3, layout = layout('One', 40) }, 'b')
  check(file == 'lvl.prm.json' and res and res.added == 3, 'the last one, whatever its number, writes them all')
  local data = fileOf('lvl')
  local got = data.layouts[#data.layouts]
  check(namesIn(data) == 'Oval, Oval (2), Club, One, Two, Props', 'in order, after what was there')
  check(got and got.props and got.practice == nil and got.map == nil, 'props kept, the server\'s own fields not')
  -- A repeated number is a new export.
  Sh.receive({ map = 'lvl', index = 1, total = 2, layout = layout('Half', 50) }, 'b')
  local f2 = Sh.receive({ map = 'lvl', index = 1, total = 1, layout = layout('Whole', 60) }, 'b')
  check(f2 == 'lvl.prm.json' and namesIn(fileOf('lvl')):find('Whole') and not namesIn(fileOf('lvl')):find('Half'),
    'an export cut short is dropped when the next one starts')
end

-- ---------------------------------------------------------------------------
-- Import: paced, numbered, this map only
-- ---------------------------------------------------------------------------
do
  Sh.list('lvl')
  local n = Sh.importStart('all', 'lvl')
  local listed = #Sh.list('lvl')
  check(n == listed, 'all: every layout listed for this map (' .. tostring(n) .. ')')
  local again, why = Sh.importStart('all', 'lvl')
  check(again == nil and why:find('still being sent', 1, true), 'one import at a time')
  Sh.update(0)
  check(#sends == 1 and sends[1].event == 'RM_ImportLayout' and sends[1].data.index == 1
    and sends[1].data.total == n and sends[1].data.map == 'lvl', 'the first goes at once, numbered')
  Sh.update(Sh.INTERVAL / 2)
  check(#sends == 1, 'the next waits its turn')
  for _ = 1, n * 2 do Sh.update(Sh.INTERVAL) end
  check(#sends == n and sends[n].data.index == n and Sh.outgoing == nil, 'then one per interval, and done')
  check(sends[1].data.layout.name and sends[1].data.layout.checkpoints, 'each carries its layout')

  sends = {}
  Sh.list('lvl')
  check(Sh.importStart('file/lvl.prm.json#3', 'lvl') == 1, 'one picked layout')
  Sh.update(0)
  check(#sends == 1 and sends[1].data.layout.name == 'Club' and sends[1].data.total == 1, 'sent alone')
  check(Sh.importStart('all', 'other_map') == nil, 'nothing for a map that is not loaded')
  Sh.importStart('all', 'lvl')
  Sh.importCancel()
  check(Sh.outgoing == nil, 'an import can be stopped')
end

-- ---------------------------------------------------------------------------
-- Through the client
-- ---------------------------------------------------------------------------
for k in pairs(FOLDER) do FOLDER[k] = nil end
sends = {}

local registry, nextId = {}, 1000
local function newObject(class)
  local o = { class = class, fields = {}, children = {} }
  function o:setField(k, _, v) self.fields[k] = v end
  function o:registerObject(name)
    nextId = nextId + 1
    self.id, self.name = nextId, name
    registry[self.id] = self
  end
  function o:getId() return self.id end
  function o:getName() return self.name end
  function o:setPosRot() end
  function o:addObject(child) self.children[#self.children + 1] = child end
  function o:delete() registry[self.id] = nil end
  function o:deleteAllObjects()
    for _, ch in ipairs(self.children) do if registry[ch.id] then ch:delete() end end
  end
  return o
end
createObject = newObject
scenetree = {
  MissionGroup = newObject('SimGroup'),
  findObjectById = function (id) return registry[id] end,
  findObject = function (name)
    for _, o in pairs(registry) do if o.name == name then return o end end
  end,
}
castRayStatic = function (o, dir, len)
  if dir.z < 0 and o.z >= 0 then return o.z end
  return (len or 100) + 1
end

local sent, hooks, handlers = {}, {}, {}
local veh = { id = 7, x = 0, y = -200, z = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation() end
function veh:queueLuaCommand() end
function veh:setMeshAlpha() end
be = { getPlayerVehicle = function () return veh end, reloadCollision = function () end }
getPlayerVehicle = function () return veh end
getAllVehicles   = function () return { veh } end
beamng_version   = '0.40.0.0'
vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quatFromDir = function (dd, up) return { x = 0, y = up and up.z or 0, z = dd.x, w = dd.y } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }
MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt   = { getConfig = function () return { parts = {}, vars = {} } end }

package.path = 'lua/ge/extensions/?.lua;' .. package.path
package.loaded['raceManager/share'] = Sh
-- Sent the way the game sends it, now that the globals are stubbed.
Sh.io.send = function (event, data) TriggerServerEvent(event, jsonEncode(data)) end
local St = require('raceManager/stock')
St.io.level = function () return 'lvl' end
St.io.find = function () return {} end

local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()
local function lastHook(event)
  for i = #hooks, 1, -1 do
    if hooks[i].event == event then return hooks[i].payload end
  end
end
local function lastSent(event)
  for i = #sent, 1, -1 do
    if sent[i].event == event then return sent[i].payload end
  end
end
handlers['RM_Update']({ rmProtocol = 2, phase = 'waiting', drivers = {}, youAreAdmin = true })

-- Export: ask, and the server's answers merge into the map's file.
RM.layoutExport({ 'Club', 'Sprint', 5, '' })
local ask = lastSent('RM_ExportLayouts')
check(ask and #ask.names == 2 and ask.names[1] == 'Club' and ask.names[2] == 'Sprint',
  'Export asks the server for the ticked names, and only names')
local CLUB = {
  name = 'Club', map = 'lvl', practice = true, width = 20, height = 8, depth = 2,
  checkpoints = { { x = 0, y = 100, z = 0, hx = 0, hy = 1, width = 14 }, { x = 0, y = 0, z = 0, hx = 0, hy = 1 } },
  startPositions = { { x = 0, y = -8, z = 0.5, hx = 0, hy = 1 } },
  branches = { { slot = 1, x = 9, y = 100, z = 0, hx = 0, hy = 1, oneWay = true } },
  pits = { { x = -20, y = 40, z = 0, hx = 0, hy = 1, length = 6, width = 3 } },
  markers = { { x = 10, y = 50, z = 0, hx = 0, hy = 1, kind = 'left' } },
  props = { { kind = 'cone', x = 5, y = 60, z = 0, hx = 0, hy = 1 } },
  sectors = { { from = 0, to = 1 } },
}
handlers['RM_LayoutExport']({ map = 'lvl', index = 1, total = 2, layout = copy(CLUB) })
check(fileOf('lvl') == nil, 'nothing written until the last one')
handlers['RM_LayoutExport']({ map = 'lvl', index = 2, total = 2, layout = layout('Sprint', 1, 2, 3) })
local file = fileOf('lvl')
check(file and namesIn(file) == 'Club, Sprint', 'both in lvl.prm.json')
check(file and file.layouts[1].props and #file.layouts[1].pits == 1 and file.layouts[1].branches[1].oneWay,
  'with everything the server sent')
check(explored > 0 and lastHook('RaceManagerEditorMsg').msg:find('Exported to lvl.prm.json: 2 added', 1, true),
  'the folder opens, and the message says what went in')
handlers['RM_LayoutExport']({ map = 'lvl', index = 1, total = 1, layout = copy(CLUB) })
check(lastHook('RaceManagerEditorMsg').msg:find('0 added; 1 already in it', 1, true),
  'exporting it again adds nothing, and says so')

-- Folder: says where and copies it, window or not.
local clip
Sh.io.realPath = function () return 'C:/BeamNG/current/' .. Sh.DIR end
Sh.io.copy = function (text) clip = text; return true end
explored = 0
RM.layoutFolder()
check(explored == 1 and clip == 'C:/BeamNG/current/' .. Sh.DIR
  and lastHook('RaceManagerEditorMsg').msg:find(clip .. '. Path copied', 1, true),
  'Folder opens it, copies the path and shows it')
Sh.io.realPath = function () return nil end
Sh.io.copy = function () return false end
RM.layoutFolder()
local folderMsg = lastHook('RaceManagerEditorMsg').msg
check(folderMsg:find(Sh.DIR, 1, true) and not folderMsg:find('copied', 1, true),
  'no real path and no clipboard: the game path, and no claim it was copied')

-- Somebody else's PC: the file in their folder, nothing loaded.
RM.setEditorOpen(true)
RM.libraryList()
local lib = lastHook('RaceManagerLibrary')
check(lib and #lib.tracks == 2 and lib.tracks[1].name == 'Club' and lib.tracks[1].kind == 'Shared file',
  'the file\'s layouts are listed')
RM.libraryOpen(lib.tracks[1].id)
check(#lastHook('RaceManagerRoute').waypoints == 2, 'Open puts one in the editor')

-- Import all: paced through the frame.
sent = {}
RM.libraryImport('all')
check(lastHook('RaceManagerEditorMsg').msg:find('Importing 2 layout(s)', 1, true), 'Import All says how many')
for _ = 1, 20 do RM.onUpdate(0.1) end
local imports = {}
for _, s in ipairs(sent) do if s.event == 'RM_ImportLayout' then imports[#imports + 1] = s.payload end end
check(#imports == 2 and imports[1].index == 1 and imports[2].index == 2 and imports[2].total == 2,
  'every layout goes, one at a time, numbered')
check(imports[1].map == 'lvl' and imports[1].layout.name == 'Club' and imports[1].layout.practice == nil
  and #imports[1].layout.props == 1, 'for this map, the layout\'s own fields, props included')

-- Not connected: nothing is sent.
MPGameNetwork = nil
sent = {}
RM.libraryImport('all')
RM.layoutExport({ 'Club' })
for _ = 1, 5 do RM.onUpdate(0.1) end
check(#sent == 0, 'off a server, import and export send nothing')
MPGameNetwork = {}

print(string.format('share_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
