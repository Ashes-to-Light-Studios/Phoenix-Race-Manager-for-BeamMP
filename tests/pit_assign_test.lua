-- Headless test for ASSIGNED PIT STALLS (server side).
-- Run from the repo root: lua5.3 tests/pit_assign_test.lua
--
-- Asked for: pit stalls given to drivers, mostly one each, with teams able to
-- share one. A stop in your own stall is the usual stop; one in another
-- driver's is held longer (pitWrongStallSeconds, 5 s as shipped). Start in
-- pits can put each car in its own stall ('assigned') or keep stall 1 = pole
-- ('grid order'), and the assignments still stand for the race either way.
--
-- The server's part: the assignments (teams.lua, Data/teams.json), each
-- driver row's pitStall, the rule's seconds on every update, and the start.
-- The hold itself is the client's (pit_assign_client_test.lua).

local connected = { [1] = 'Alice', [2] = 'Bob', [3] = 'Cara', [4] = 'Dan' }
local lastState = nil
local gridSent  = {}   -- [pid] = list of RM_GridAssign payloads, in order
local holdSent  = {}   -- [pid] = last RM_HoldCorrect payload
local chats     = {}   -- [pid] = list of chat lines (-1 = everyone)
local notices   = {}   -- [pid] = list of RM_Notice payloads

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg)
    chats[target] = chats[target] or {}
    table.insert(chats[target], msg)
  end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then lastState = payload end
    if event == 'RM_GridAssign' then
      gridSent[target] = gridSent[target] or {}
      table.insert(gridSent[target], payload)
    end
    if event == 'RM_HoldCorrect' then holdSent[target] = payload end
    if event == 'RM_Notice' then
      notices[target] = notices[target] or {}
      table.insert(notices[target], payload)
    end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
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

-- Rules and teams outlive a boot: start from config.json's rules and no teams.
local DATA = 'Resources/Server/PhoenixRM Server/Data/'
os.remove(DATA .. 'rules.json')
os.remove(DATA .. 'teams.json')
dofile('server/RaceManager/main.lua')

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local ADMIN = 1
local function lastSlot(pid)
  local list = gridSent[pid]
  return list and list[#list] or nil
end
local function chatTo(pid, text)
  for _, line in ipairs(chats[pid] or {}) do
    if line:find(text, 1, true) then return line end
  end
end
local function noticeTo(pid, text)
  for _, n in ipairs(notices[pid] or {}) do
    if tostring(n.sub):find(text, 1, true) then return n end
  end
end
local function clearSends() gridSent, holdSent, chats, notices = {}, {}, {}, {} end
local function row(pid)
  for _, d in ipairs(lastState.drivers) do
    if d.id == pid then return d end
  end
end
local function teams(json) RM_onTeamsSet(ADMIN, json) end
local function toRacing()
  RM_onStartCountdown(ADMIN)
  for _ = 1, 80 do
    if lastState.phase == 'racing' then break end
    RM_CountdownTick()
  end
end

-- A two-gate circuit facing +y, four start positions, and four pit stalls at
-- x=-30, stall 1 nearest the exit (highest y), 8 m apart.
local CPS = '"checkpoints":[{"x":0,"y":100,"z":0,"hx":0,"hy":1},{"x":0,"y":200,"z":0,"hx":0,"hy":1}]'
local STARTS = '"startPositions":[{"x":0,"y":0,"z":0,"hx":0,"hy":1},{"x":0,"y":-8,"z":0,"hx":0,"hy":1},'
  .. '{"x":0,"y":-16,"z":0,"hx":0,"hy":1},{"x":0,"y":-24,"z":0,"hx":0,"hy":1}]'
local PITS = '"pits":[{"x":-30,"y":50,"z":0,"hx":0,"hy":1},{"x":-30,"y":42,"z":0,"hx":0,"hy":1},'
  .. '{"x":-30,"y":34,"z":0,"hx":0,"hy":1},{"x":-30,"y":26,"z":0,"hx":0,"hy":1}]'
local STALL_Y = { 50, 42, 34, 26 }

onInit()
RM_onLogin(ADMIN, '{"password":"phoenix"}')
RM_onSetReadyCheck(ADMIN, '{"on":false}')
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onSaveLayout(ADMIN, '{"name":"Pits","width":20,"height":8,"depth":2,"confirmDrop":true,'
  .. CPS .. ',' .. STARTS .. ',' .. PITS .. '}')
RM_onLoadLayout(ADMIN, '{"name":"Pits"}')

-- ---------------------------------------------------------------------------
-- 1. Assignments: a driver's own, a team's, the driver's winning
-- ---------------------------------------------------------------------------
check(row(1).pitStall == nil and row(2).pitStall == nil, 'nobody has a stall as shipped')

teams('{"op":"team","name":"Phoenix Racing","short":"PHX","color":"#ff7a1a","stall":4}')
local phx = lastState.teams and lastState.teams[1]
check(phx and phx.short == 'PHX' and phx.stall == 4, 'a team takes a stall')
teams('{"op":"entry","name":"Bob","team":' .. phx.id .. ',"number":"12"}')
teams('{"op":"entry","name":"Cara","team":' .. phx.id .. ',"stall":""}')
teams('{"op":"entry","name":"Alice","stall":3}')
check(row(2).pitStall == 4 and row(3).pitStall == 4,
  'both PHX drivers have the team\'s stall: teammates share one')
check(row(1).pitStall == 3, 'a driver with a stall and no team or number is listed for the stall alone')
check(row(4).pitStall == nil, 'Dan has none')

teams('{"op":"entry","name":"Cara","team":' .. phx.id .. ',"stall":2}')
check(row(3).pitStall == 2 and row(2).pitStall == 4, 'a driver\'s own stall wins over the team\'s')
teams('{"op":"entry","name":"Cara","team":' .. phx.id .. ',"stall":""}')
check(row(3).pitStall == 4, 'and emptied, the team\'s comes back')

-- Checked like everything else on that panel.
clearSends()
teams('{"op":"entry","name":"Dan","stall":100}')
check(row(4).pitStall == nil and noticeTo(ADMIN, 'A pit stall is a number from 1 to 99'),
  'a stall past 99 is refused, and the admin is told why')
teams('{"op":"entry","name":"Dan","stall":"x"}')
check(row(4).pitStall == nil, 'and so is one that is not a number')
-- An older panel sends no stall: what was there stays.
teams('{"op":"entry","name":"Alice","number":"7"}')
check(row(1).pitStall == 3 and row(1).number == '7', 'an edit without a stall keeps the stall')
-- Kept on the server.
do
  local f = io.open(DATA .. 'teams.json', 'r')
  local text = f and f:read('*a') or ''
  if f then f:close() end
  check(text:find('"stall"', 1, true) ~= nil, 'the stalls are saved in Data/teams.json')
end
-- Removing the team: its drivers keep their own stalls, and lose the team's.
teams('{"op":"team","name":"Spare","short":"SPR","color":"#3b82f6"}')
local spr
for _, t in ipairs(lastState.teams) do if t.short == 'SPR' then spr = t end end
teams('{"op":"entry","name":"Dan","team":' .. spr.id .. '}')
teams('{"op":"removeTeam","id":' .. spr.id .. '}')
check(row(4).pitStall == nil and row(4).team == nil, 'a removed team takes nothing else with it')

-- ---------------------------------------------------------------------------
-- 2. The rule: seconds for another driver's stall, on every update
-- ---------------------------------------------------------------------------
check(lastState.pitStopRule.wrongStall == 5, 'a stop in another driver\'s stall adds 5 s as shipped')
RM_onSetPitStopRule(2, '{"wrongStall":20}')
check(lastState.pitStopRule.wrongStall == 5, 'a driver cannot change it')
RM_onSetPitStopRule(ADMIN, '{"wrongStall":2.4}')
check(lastState.pitStopRule.wrongStall == 2.5, 'half seconds, like the other pit times')
RM_onSetPitStopRule(ADMIN, '{"wrongStall":99}')
check(lastState.pitStopRule.wrongStall == 60, 'at most 60 s')
RM_onSetPitStopRule(ADMIN, '{"wrongStall":0}')
check(lastState.pitStopRule.wrongStall == 0, '0 turns it off')
check(lastState.pitStopRule.required == 0, 'and setting it leaves the mandatory stops alone')
RM_onSetPitStopRule(ADMIN, '{"wrongStall":5}')

-- ---------------------------------------------------------------------------
-- 3. Start in pits: assigned stalls
-- ---------------------------------------------------------------------------
check(lastState.racePitOrder == 'grid' and lastState.qualiPitOrder == 'grid',
  'a pit start is in grid order as shipped')
RM_onSetPitStart(ADMIN, '{"session":"race","enabled":true}')
RM_onSetPitStart(ADMIN, '{"session":"race","order":"assigned"}')
check(lastState.raceFromPits == true and lastState.racePitOrder == 'assigned',
  'the order is its own setting: choosing it leaves the switch on')
check(lastState.qualiPitOrder == 'grid', 'and qualifying keeps its own')
RM_onSetPitStart(2, '{"session":"race","order":"grid"}')
check(lastState.racePitOrder == 'assigned', 'a driver cannot change it')

clearSends()
RM_onGenerateGrid(ADMIN)
check(lastState.gridKind == 'pits', 'the race lines up in the stalls')
-- Alice has 3; Bob and Cara share PHX's 4, so the one ahead on the grid has it
-- and the other takes the first free stall; Dan has none and takes the next.
check(lastSlot(1) and lastSlot(1).slot == 3 and lastSlot(1).grid == 'pits',
  'Alice starts in her own stall, 3 (got ' .. tostring(lastSlot(1) and lastSlot(1).slot) .. ')')
local ahead, behind = 2, 3
if row(3).gridPos < row(2).gridPos then ahead, behind = 3, 2 end
check(lastSlot(ahead).slot == 4, connected[ahead] .. ', ahead of their teammate, takes the team\'s stall 4')
local rest = { behind, 4 }
table.sort(rest, function (a, b) return row(a).gridPos < row(b).gridPos end)
check(lastSlot(rest[1]).slot == 1 and lastSlot(rest[2]).slot == 2,
  'the teammate behind and Dan take the free stalls 1 and 2, in grid order (got '
    .. tostring(lastSlot(rest[1]).slot) .. ', ' .. tostring(lastSlot(rest[2]).slot) .. ')')
check(row(1).gridPos ~= nil and row(4).gridPos ~= nil, 'and the grid positions themselves are the grid\'s')

-- The hold is policed against the car's OWN stall.
RM_onHoldPos(1, '{"x":40,"y":40,"z":0}')
check(holdSent[1] and holdSent[1].x == -30 and holdSent[1].y == STALL_Y[3],
  'a car off its stall is pulled back to its assigned stall, not stall Pn')

-- At the green, each driver with a stall is told which.
clearSends()
toRacing()
check(lastState.phase == 'racing', 'the race is on')
check(chatTo(1, 'Your pit stall: PIT 3 (a stop in another driver\'s stall takes 5s longer)'),
  'Alice is told her stall and what another costs')
check(chatTo(2, 'Your pit stall: PIT 4') and chatTo(3, 'Your pit stall: PIT 4'),
  'both PHX drivers are told the team\'s stall, whichever started in it')
check(not chatTo(4, 'Your pit stall'), 'Dan, with none, is told nothing')

-- A stop in another driver's stall: logged as such; it counts like any other.
RM_onPitStop(4, '{"stall":3,"wrong":5}')
check(row(4).pitStops == 1, 'a stop in another driver\'s stall is still a pit stop')
RM_onEndRace(ADMIN)
if lastState.phase ~= 'finished' then RM_onEndRace(ADMIN) end

-- ---------------------------------------------------------------------------
-- 4. Grid order keeps stall 1 = pole, and the assignments still stand
-- ---------------------------------------------------------------------------
RM_onSetPitStart(ADMIN, '{"session":"race","order":"grid"}')
clearSends()
RM_onGenerateGrid(ADMIN)
for pid = 1, 4 do
  check(lastSlot(pid) and lastSlot(pid).slot == row(pid).gridPos,
    connected[pid] .. ' starts in stall ' .. tostring(row(pid).gridPos) .. ' in grid order')
end
check(row(1).pitStall == 3, 'and still has stall 3 for the race')
toRacing()
check(chatTo(1, 'Your pit stall: PIT 3'), 'and is told so at the green')
RM_onEndRace(ADMIN)
if lastState.phase ~= 'finished' then RM_onEndRace(ADMIN) end

-- ---------------------------------------------------------------------------
-- 5. With the ready check: each car placed in its own stall as it readies
-- ---------------------------------------------------------------------------
RM_onSetPitStart(ADMIN, '{"session":"race","order":"assigned"}')
RM_onSetReadyCheck(ADMIN, '{"on":true}')
clearSends()
RM_onGenerateGrid(ADMIN)
check(lastSlot(1) and lastSlot(1).slot == nil, 'called, not placed yet')
RM_onSetReady(1, '{"ready":true}')
check(lastSlot(1) and lastSlot(1).slot == 3, 'Ready puts Alice in her own stall')
RM_onReadyAll(ADMIN)
local seen = {}
for pid = 1, 4 do
  local s = lastSlot(pid) and lastSlot(pid).slot
  check(s and not seen[s], connected[pid] .. ' has a stall of their own on the grid (' .. tostring(s) .. ')')
  if s then seen[s] = true end
end
RM_onSetReadyCheck(ADMIN, '{"on":false}')
RM_onEndRace(ADMIN)

-- ---------------------------------------------------------------------------
-- 6. A stall past the layout's is none
-- ---------------------------------------------------------------------------
teams('{"op":"entry","name":"Alice","number":"7","stall":9}')
clearSends()
RM_onGenerateGrid(ADMIN)
check(lastSlot(1) and lastSlot(1).slot >= 1 and lastSlot(1).slot <= 4,
  'stall 9 on a four-stall layout: Alice takes a free stall instead')
toRacing()
check(not chatTo(1, 'Your pit stall'), 'and is not told a stall the layout does not have')
RM_onEndRace(ADMIN)

-- Leave no teams for the next test.
os.remove(DATA .. 'teams.json')

if fails == 0 then
  print('pit_assign_test: ' .. checks .. ' checks, 0 failures')
else
  print('pit_assign_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
