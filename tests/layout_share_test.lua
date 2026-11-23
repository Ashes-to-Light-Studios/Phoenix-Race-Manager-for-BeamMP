-- Headless test for SHARED LAYOUTS on the server (RM_onExportLayouts,
-- RM_onImportLayout in server/RaceManager/main.lua).
--
--   * Export sends the admin full copies, props included, one event each.
--   * Import ADDS and never replaces: identical is skipped, a different layout
--     under a taken name is saved as "Name (2)", within the name limit.
--   * Only for the map the server is on, never open for practice, admins only.
--   * One summary after the last, and the list goes out once.
--
-- Run from the repo root: lua5.3 tests/layout_share_test.lua

local DIR    = 'Resources/Server/PhoenixRM Server'
local FOLDER = DIR .. '/Data/Race Layout'

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function removeTree(path)
  if package.config:sub(1, 1) == '\\' then
    os.execute('rmdir /s /q "' .. path:gsub('/', '\\') .. '" 2>nul')
  else
    os.execute('rm -rf "' .. path .. '"')
  end
end
removeTree(DIR)
os.execute(package.config:sub(1, 1) == '\\'
  and ('mkdir "' .. DIR:gsub('/', '\\') .. '" 2>nul')
  or  ('mkdir -p "' .. DIR .. '"'))

local chats, events, listsSent = {}, {}, 0
local currentMap = 'italy'
MP = {
  GetPlayerName = function (pid) return pid == 0 and 'Admin' or 'Driver' end,
  SendChatMessage = function (pid, msg) chats[#chats + 1] = { pid = pid, msg = msg } end,
  GetPlayers = function () return { [0] = 'Admin', [1] = 'Driver' } end,
  TriggerClientEvent = function (target, event, payload)
    events[#events + 1] = { target = target, event = event, payload = payload }
    if event == 'RM_Layouts' then listsSent = listsSent + 1 end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
  RemoveVehicle = function () end,
  Settings = { Map = 0 },
  Get = function () return '/levels/' .. currentMap .. '/info.json' end,
}
Util = {
  JsonEncode = function (t) return t end,
  -- Tables pass straight through, so a test can hand a handler its payload.
  JsonDecode = function (s)
    if type(s) == 'table' then return s end
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    return load('return ' .. body)()
  end,
}

dofile('server/RaceManager/main.lua')
onInit()
RM_onLogin(0, '{"password":"phoenix"}')
RM_onPlayerJoin(0)
RM_onPlayerJoin(1)

local function gates(...)
  local out = {}
  for i, x in ipairs({ ... }) do out[i] = { x = x, y = 0, z = 0, hx = 0, hy = 1 } end
  return out
end
local function layout(name, ...)
  return { name = name, width = 20, height = 8, depth = 2, checkpoints = gates(...),
           props = { { kind = 'cone', x = 1, y = 2, z = 0, hx = 0, hy = 1 } } }
end
-- The store as the clients see it.
local function list()
  events = {}
  RM_onRequestLayouts(0)
  for _, e in ipairs(events) do
    if e.event == 'RM_Layouts' then return e.payload.layouts end
  end
  return {}
end
local function find(name)
  for _, l in ipairs(list()) do if l.name == name then return l end end
end
local function lastChat()
  return chats[#chats] and chats[#chats].msg or ''
end
-- An import of several, as the client paces them.
local function import(pid, map, layouts)
  for i, l in ipairs(layouts) do
    RM_onImportLayout(pid, { map = map, index = i, total = #layouts, layout = l })
  end
end

-- ---------------------------------------------------------------------------
-- Import into an empty map
-- ---------------------------------------------------------------------------
listsSent = 0
local club = layout('Club', 10, 20, 30)
club.practice = true
import(0, 'italy', { club, layout('Oval', 40, 50), layout('Sprint', 60, 70) })
check(listsSent == 2, 'the list goes out once to each player, after the last (sent ' .. listsSent .. ')')
check(#list() == 3, 'three layouts imported')
check(lastChat():find('3 layout(s) imported on italy by Admin', 1, true), 'one summary for the lot')
check(find('Club') and find('Club').practice == false, 'never open for practice on arrival')
check(find('Club') and find('Club').propCount == 1, 'props are kept')
local f = io.open(FOLDER .. '/italy.json', 'r')
check(f ~= nil, 'written to the map\'s own file')
if f then f:close() end

-- ---------------------------------------------------------------------------
-- Never overwrite
-- ---------------------------------------------------------------------------
import(0, 'italy', { layout('Club', 10, 20, 30), layout('Oval', 41, 51) })
local names = {}
for _, l in ipairs(list()) do names[#names + 1] = l.name end
check(#names == 4, 'an identical layout is skipped, a different one added: ' .. table.concat(names, ', '))
check(find('Oval') and find('Oval').checkpoints[1].x == 40, 'the Oval already here is untouched')
check(find('Oval (2)') and find('Oval (2)').checkpoints[1].x == 41, 'the new one is "Oval (2)"')
check(lastChat():find('"Oval" as "Oval (2)"', 1, true) and lastChat():find('1 already here', 1, true),
  'the summary says what was renamed and what was skipped')

import(0, 'italy', { layout('Oval', 41, 51) })
check(#list() == 4, 'importing it again finds it under its new name and skips it')
import(0, 'italy', { layout('OVAL', 42, 52) })
check(find('OVAL (3)'), 'names clash without case, and the next free number is taken')

local long = string.rep('L', 40)
import(0, 'italy', { layout(long, 1, 2) })
import(0, 'italy', { layout(long, 3, 4) })
local renamed
for _, l in ipairs(list()) do
  if l.name:sub(-4) == ' (2)' and l.name:sub(1, 1) == 'L' then renamed = l.name end
end
check(renamed and #renamed == 40, 'a renamed long name still fits the limit')

-- ---------------------------------------------------------------------------
-- Refused
-- ---------------------------------------------------------------------------
local before = #list()
import(0, 'utah', { layout('Elsewhere', 1, 2) })
check(#list() == before and lastChat():find('1 refused', 1, true), 'a layout for another map is refused')
import(0, 'italy', { { name = 'Empty', checkpoints = {} } })
check(#list() == before, 'one with no checkpoints is refused')
import(0, 'italy', { layout('', 1, 2) })
check(#list() == before, 'one with no name is refused')
import(1, 'italy', { layout('Sneaky', 1, 2) })
check(#list() == before and find('Sneaky') == nil, 'a driver who is not logged in cannot import')
check(pcall(RM_onImportLayout, 0, 'not json at all {'), 'garbage never throws')

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------
events = {}
RM_onExportLayouts(0, { names = { 'Club', 'oval (2)', 'Nope' } })
local sent = {}
for _, e in ipairs(events) do
  if e.event == 'RM_LayoutExport' then sent[#sent + 1] = e end
end
check(#sent == 2, 'the layouts asked for, found without case, one event each')
check(sent[1] and sent[1].target == 0 and sent[1].payload.map == 'italy'
  and sent[1].payload.index == 1 and sent[1].payload.total == 2, 'numbered, with the map, to the admin only')
check(sent[1] and sent[1].payload.layout.props and #sent[1].payload.layout.props == 1,
  'full copies: props included, which the list leaves out')
events = {}
RM_onExportLayouts(0, { names = { 'Nope' } })
check(#events == 0 and lastChat():find('None of those', 1, true), 'nothing found is said')
events = {}
RM_onExportLayouts(1, { names = { 'Club' } })
local leaked = false
for _, e in ipairs(events) do if e.event == 'RM_LayoutExport' then leaked = true end end
check(not leaked, 'a driver who is not logged in gets nothing')

removeTree(DIR)

print(string.format('layout_share_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
