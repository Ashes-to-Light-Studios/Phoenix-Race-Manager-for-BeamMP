-- Headless test for SECTORS (track.sectors in lua/ge/extensions/raceManager.lua).
--
-- A sector used to be a checkpoint: every gate closed one, so a thirty-gate
-- circuit showed S1 to S30. A layout can now name its sectors by the two gates
-- each one runs between -- S1 from the line to CP 2, S2 from CP 2 to CP 5 --
-- and only those are timed. With none named, every gate still closes one, so a
-- layout saved before this behaves exactly as it did.
--
-- A sector END is a checkpoint number, or 0 for the start/finish line. Not the
-- line's number: the line is whichever gate is LAST, so placing another gate
-- moves it, and a sector "to the line" has to move with it.
--
-- Run from the repo root: lua5.3 tests/sector_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function near(a, b, tol)
  return a ~= nil and b ~= nil and math.abs(a - b) <= (tol or 0.12)
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs (as tests/delta_test.lua)
-- ---------------------------------------------------------------------------
local sent     = {}
local hooks    = {}
local handlers = {}
local route    = nil   -- the last RaceManagerRoute push
local editMsg  = nil   -- the last RaceManagerEditorMsg

local veh = { id = 7, x = 0, y = 0, z = 0, hx = 0, hy = 1 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = self.hx, y = self.hy, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation(x, y, z) self.x, self.y, self.z = x, y, z end
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
  hooks[#hooks + 1] = { event = e, payload = p }
  if e == 'RaceManagerRoute' then route = p end
  if e == 'RaceManagerEditorMsg' then editMsg = p and p.msg end
end }

MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
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

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
local function serverState(t) t.rmProtocol = 2; handlers['RM_Update'](t) end
local function frame(n)
  for _ = 1, (n or 1) do RM.onUpdate(0.05) end
end
local function moveTo(y, x)
  veh.x, veh.y, veh.z = x or 0, y, 0
  frame()
end
local function burn(seconds) frame(math.floor(seconds / 0.05 + 0.5)) end

-- Six gates up the y axis: CP 1 to CP 5 at y = 100..500, the line at 600.
local GATE_Y = { 100, 200, 300, 400, 500, 600 }
local function gates()
  local cps = {}
  for i, y in ipairs(GATE_Y) do cps[i] = { x = 0, y = y, z = 0, hx = 0, hy = 1 } end
  return cps
end
local function load(sectors, name)
  handlers['RM_ApplyLayout']({
    name = name or 'six', width = 40, height = 10, depth = 2,
    checkpoints = gates(), sectors = sectors,
  })
end

local function startRace()
  handlers['RM_ReleaseSpectate']({ source = 'race' })
  serverState({ phase = 'waiting', drivers = {} })
  serverState({ phase = 'racing', totalLaps = 20, maxResets = -1, drivers = {} })
  moveTo(10)
end

-- One lap, spending t[k] seconds before gate k. Each gate is cleared over two
-- frames (0.1 s) on top of that. The return leg swings out to x=300, clear of
-- every gate: straight back would clear CP 1 backwards (see delta_test).
local function lap(t)
  moveTo(50)
  for k = 1, #GATE_Y do
    burn(t[k] or 0.5)
    moveTo(GATE_Y[k] - 5); moveTo(GATE_Y[k] + 5)
  end
  moveTo(605, 300); moveTo(10, 300); moveTo(10, 0)
end

local function sectorHooks()
  local out = {}
  for _, h in ipairs(hooks) do
    if h.event == 'RaceManagerSector' then out[#out + 1] = h.payload end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- 1. THE LAYOUT'S SECTORS ARE THE ONES TIMED
-- ---------------------------------------------------------------------------
-- S1 line -> CP 2, S2 CP 2 -> CP 5, S3 CP 5 -> line: three sectors on six gates.
load({ { from = 0, to = 2 }, { from = 2, to = 5 }, { from = 5, to = 0 } })
check(route and #route.sectors == 3, 'the layout\'s three sectors reach the panel')
check(route.maxSectors == 20, 'and so does the cap the Add button honours')

startRace()
hooks = {}
lap({ 1.0, 1.0, 2.0, 2.0, 2.0, 1.0 })
local s = sectorHooks()
check(#s == 3, 'six gates, three sectors: three times, not six (got ' .. #s .. ')')
check(s[1] and s[1].sector == 1 and s[2] and s[2].sector == 2 and s[3] and s[3].sector == 3,
  'numbered as the layout numbers them, not by the gate that closed them')
check(s[1] and s[1].count == 3, 'and counted out of three')
-- S2 runs CP 2 -> CP 5: 2 + 2 + 2 s of burn and three gates at 0.1 s each.
check(s[2] and near(s[2].time, 6.3), 'S2 is timed from CP 2 to CP 5 (got '
  .. tostring(s[2] and s[2].time) .. ')')
check(s[2] and s[2].delta == nil, 'with no delta on its first visit')

-- A quicker middle sector is a negative delta and a best; S1 is untouched.
hooks = {}
lap({ 1.0, 1.0, 1.5, 1.5, 1.5, 1.0 })
s = sectorHooks()
check(#s == 3, 'lap 2 closes the same three sectors')
check(s[2] and s[2].delta and near(s[2].delta, -1.5),
  'a quicker S2 reads 1.5 s faster than its best (got ' .. tostring(s[2] and s[2].delta) .. ')')
check(s[2] and s[2].best == true, 'and is flagged as a personal best')
-- S1 on lap 2 starts at the line crossing that ended lap 1, so it carries the
-- return leg (four frames) the first one did not; it must not read as faster.
check(s[1] and s[1].delta and s[1].delta >= 0, 'S1 starts at the line, lap after lap')

-- ---------------------------------------------------------------------------
-- 2. OVERLAPPING SECTORS AND ONE ACROSS THE LINE
-- ---------------------------------------------------------------------------
-- Nothing says sectors must tile the lap. CP 1 -> CP 4 overlaps two of them,
-- and CP 5 -> CP 1 runs across the line into the next lap.
serverState({ phase = 'waiting', drivers = {} })
load({ { from = 0, to = 2 }, { from = 1, to = 4 }, { from = 5, to = 1 } })
startRace()
hooks = {}
lap({ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 })
s = sectorHooks()
check(#s == 2, 'lap 1 closes S1 and S2; the one across the line has not ended yet (got '
  .. #s .. ')')
check(s[2] and s[2].sector == 2 and near(s[2].time, 3.3),
  'the overlapping CP 1 -> CP 4 is timed in full (got ' .. tostring(s[2] and s[2].time) .. ')')
hooks = {}
lap({ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 })
s = sectorHooks()
local across = nil
for _, h in ipairs(s) do if h.sector == 3 then across = h end end
check(across ~= nil, 'CP 5 -> CP 1 closes on the next lap')
-- From CP 5: 1 s to the line, 0.1 s through it, the return leg (3 frames),
-- moveTo(50), 1 s to CP 1 and 0.1 s through it.
check(across and near(across.time, 2.4, 0.2),
  'timed across the line (got ' .. tostring(across and across.time) .. ')')

-- ---------------------------------------------------------------------------
-- 3. NONE DEFINED: EVERY CHECKPOINT IS A SECTOR, AS BEFORE
-- ---------------------------------------------------------------------------
serverState({ phase = 'waiting', drivers = {} })
load(nil, 'plain')
check(route and #route.sectors == 0, 'a layout without sectors has none')
startRace()
hooks = {}
lap({})
s = sectorHooks()
check(#s == 6, 'and every gate closes one, numbered by the gate (got ' .. #s .. ')')
check(s[6] and s[6].sector == 6 and s[6].count == 6, 'S6 of 6 at the line')

-- Junk is dropped on load, not trusted: a gate past the route, a sector
-- that starts and ends at one gate, a non-table.
serverState({ phase = 'waiting', drivers = {} })
load({ { from = 0, to = 9 }, { from = 3, to = 3 }, 'S1', { from = 1, to = 3 } }, 'junk')
check(#route.sectors == 1 and route.sectors[1].from == 1,
  'only the one sector that fits the route survives the load')

-- ---------------------------------------------------------------------------
-- 4. EDITING
-- ---------------------------------------------------------------------------
load(nil, 'editing')
RM.addSector()
check(#route.sectors == 1 and route.sectors[1].from == 0 and route.sectors[1].to == 1,
  'the first sector starts at the line and runs to CP 1')
RM.addSector()
check(route.sectors[2].from == 1 and route.sectors[2].to == 2,
  'the next starts where the last one ends')
RM.setSector(1, nil, 3)
check(route.sectors[1].from == 0 and route.sectors[1].to == 3, 'the end can be moved alone')
RM.setSector(2, 3, 0)
check(route.sectors[2].from == 3 and route.sectors[2].to == 0, 'and both, to the line')
RM.setSector(2, nil, 99)
check(route.sectors[2].to == 0, 'a gate past the route is read as the line')
RM.addSector()
check(route.sectors[3].from == 0 and route.sectors[3].to == 1,
  'after one ending at the line, the next starts there')
RM.removeSector(1)
check(#route.sectors == 2 and route.sectors[1].from == 3,
  'removing S1 moves the rest up a number')
RM.removeSector(2)

-- Gates added, removed and reordered: a sector keeps the gates it named.
RM.setSector(1, 2, 4)                                    -- CP 2 -> CP 4
RM.insertCheckpoint(2, { x = 0, y = 150, z = 0, hx = 0, hy = 1 })
check(route.sectors[1].from == 3 and route.sectors[1].to == 5,
  'a gate inserted before it moves both ends along with their gates')
RM.removeCheckpoint(2)
check(route.sectors[1].from == 2 and route.sectors[1].to == 4, 'and removing it moves them back')
RM.reorderCheckpoint(2, 3)
check(route.sectors[1].from == 3 and route.sectors[1].to == 4,
  'reordering a gate takes its end along')
RM.removeCheckpoint(3)
check(route.sectors[1].from == 2 and route.sectors[1].to == 3,
  'an end on a removed gate moves to the gate before it')
RM.setSector(1, 1, 0)
RM.removeCheckpoint(1)
check(route.sectors[1].from == 0, 'and one on CP 1 moves to the line, the gate before CP 1')

-- THE LINE FOLLOWS THE LAST GATE. Placing another gate after it moves the
-- line there, and a sector ending at the line ends there too.
local before = #route.waypoints
veh.x, veh.y = 0, 900
RM.editorAdd()
check(#route.waypoints == before + 1, 'a gate was added after the line')
check(route.sectors[1].to == 0, 'and the sector still ends at the line, now the new gate')

-- Hard limit, as the server enforces it.
RM.editorClear()
load(nil, 'cap')
for _ = 1, 25 do RM.addSector() end
check(#route.sectors == 20, 'no more than 20 sectors (got ' .. #route.sectors .. ')')
check(editMsg and editMsg:find('at most 20', 1, true) ~= nil, 'and the editor says why')

-- ---------------------------------------------------------------------------
-- 5. SAVED WITH THE LAYOUT
-- ---------------------------------------------------------------------------
load({ { from = 0, to = 2 }, { from = 2, to = 0 } }, 'saving')
sent = {}
RM.saveLayout('saving')
local payload = sent[#sent] and sent[#sent].event == 'RM_SaveLayout' and sent[#sent].payload
check(payload and payload.sectors and #payload.sectors == 2, 'the save carries the sectors')
check(payload and payload.sectors[2].from == 2 and payload.sectors[2].to == 0,
  'with the line as 0, as the server expects')

load(nil, 'unsectored')
sent = {}
RM.saveLayout('unsectored')
payload = sent[#sent] and sent[#sent].payload
check(payload and payload.sectors == nil, 'a layout without sectors saves as it did')

-- One starting and ending at the same gate times nothing: refused by name.
load({ { from = 0, to = 2 } }, 'bad')
RM.setSector(1, 2, nil)
sent = {}
RM.saveLayout('bad')
check(#sent == 0, 'a sector that starts and ends at one gate stops the save')
check(editMsg and editMsg:find('sector 1', 1, true) ~= nil, 'and the editor names it')

-- An edit is a change to the layout like any other: the buffer guard sees it.
-- (The guard only holds while the panel is open.)
RM.setEditorOpen(true)
load({ { from = 0, to = 2 } }, 'guarded')
RM.setSector(1, nil, 3)
handlers['RM_ApplyLayout']({ name = 'other', width = 40, height = 10, depth = 2,
                             checkpoints = gates() })
check(#route.sectors == 1 and route.sectors[1].to == 3,
  'an unsaved sector edit is not overwritten by someone else\'s layout')
RM.setEditorOpen(false)

-- ---------------------------------------------------------------------------
-- 6. NOT MID-SESSION
-- ---------------------------------------------------------------------------
serverState({ phase = 'waiting', drivers = {} })
load({ { from = 0, to = 2 } }, 'locked')
startRace()
RM.addSector()
RM.setSector(1, nil, 4)
RM.removeSector(1)
check(#route.sectors == 1 and route.sectors[1].to == 2,
  'sectors cannot be added, moved or removed while a session runs')
serverState({ phase = 'waiting', drivers = {} })

-- ---------------------------------------------------------------------------
-- 7. ONE CAP, TWO PLACES
-- ---------------------------------------------------------------------------
local function readFile(path)
  local f = assert(io.open(path, 'r')); local t = f:read('*a'); f:close(); return t
end
local client = readFile('lua/ge/extensions/raceManager.lua')
local server = readFile('server/RaceManager/main.lua')
local clientMax = tonumber(client:match('MAX_SECTORS = (%d+)'))
local serverMax = tonumber(server:match('function race%.sanitizeSectors.-local MAX = (%d+)'))
check(clientMax ~= nil and clientMax == serverMax,
  'the client and server cap sectors at the same number ('
    .. tostring(clientMax) .. ' and ' .. tostring(serverMax) .. ')')

print(string.format('sector_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
