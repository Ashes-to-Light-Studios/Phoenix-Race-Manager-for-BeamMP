-- Headless test for TEAMS AND CAR NUMBERS (server/RaceManager/teams.lua), run
-- against the real server plugin in Lua 5.3, the same as BeamMP.
--
--   * Loading the file alone defines nothing; the handler comes from init().
--   * Either admin tier edits; anyone else is turned away.
--   * Every value is checked: names, short codes, colors, logo links (Discord
--     attachment links that expire are refused), car numbers (unique).
--   * Driver rows carry `team` and `number`, matched by display name first,
--     then BeamMP name, re-resolved after a rename or a team going.
--   * The list rides RM_Update on targeted sends and the broadcast after a
--     change, never the ticks after it; admins also get every entry.
--   * Data/teams.json survives a restart, and a broken one is never written over.
--
-- Run from the repo root: lua5.3 tests/teams_test.lua

local connected = { [0] = 'Admin', [1] = 'speedy_k', [2] = 'Bob', [3] = 'Guest_77' }
local updates = {}       -- RM_Update payloads, { target, payload }
local notices = {}       -- RM_Notice, { target, payload }

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function () end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then updates[#updates + 1] = { target = target, payload = payload } end
    if event == 'RM_Notice' then notices[#notices + 1] = { target = target, payload = payload } end
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

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- 1. Loading the file alone defines nothing.
do
  local before = {}
  for k in pairs(_G) do before[k] = true end
  dofile('server/RaceManager/teams.lua')
  local added = {}
  for k in pairs(_G) do if not before[k] then added[#added + 1] = k end end
  check(#added == 0, 'teams.lua alone defines no globals (got ' .. table.concat(added, ', ') .. ')')
end

local FILE = 'Resources/Server/PhoenixRM Server/Data/teams.json'
os.remove(FILE)
dofile('server/RaceManager/main.lua')
local teams = require('teams')
check(type(RM_onTeamsSet) == 'function', 'RM_onTeamsSet is installed by init')
onInit()

local function read(p)
  local f = io.open(p, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end
local function lastUpdate(target)
  for i = #updates, 1, -1 do
    if updates[i].target == target then return updates[i].payload end
  end
end
local function lastNotice(target)
  for i = #notices, 1, -1 do
    if notices[i].target == target then return notices[i].payload.sub end
  end
end
local function set(pid, t)
  local parts = {}
  for k, v in pairs(t) do
    local val = type(v) == 'string' and string.format('%q', v) or tostring(v)
    parts[#parts + 1] = string.format('"%s":%s', k, val)
  end
  RM_onTeamsSet(pid, '{' .. table.concat(parts, ',') .. '}')
end
local function stateFor(pid)
  RM_onRequestState(pid, '')
  return lastUpdate(pid)
end
local function row(state, pid)
  for _, d in ipairs(state.drivers) do if d.id == pid then return d end end
end

for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onLogin(0, '{"password":"phoenix"}')

-- 2. Who may edit.
set(2, { op = 'team', name = 'Phoenix', short = 'PHX', color = '#ff7a1a' })
check(#teams.entries().teams == 0, 'a driver cannot add a team')

-- 3. Teams.
notices = {}
set(0, { op = 'team', name = 'Phoenix Racing', short = 'phx', color = '#FF7A1A',
  logo = 'https://example.org/phx.png' })
local list = teams.entries().teams
check(#list == 1 and list[1].short == 'PHX' and list[1].color == '#ff7a1a'
  and list[1].logo == 'https://example.org/phx.png', 'a team: short code upper-cased, color lower-cased')
local PHX = list[1].id
set(0, { op = 'team', name = 'Blue Comet', short = 'BLU', color = '#3b82f6' })
local BLU = teams.entries().teams[2].id

local function refused(t, want, what)
  local n = #teams.entries().teams
  local before = read(FILE)
  set(0, t)
  local msg = lastNotice(0) or ''
  check(#teams.entries().teams == n and read(FILE) == before and msg:find(want, 1, true),
    what .. ' (' .. msg .. ')')
end
refused({ op = 'team', name = 'X', short = 'P', color = '#ff0000' }, '2 to 4', 'a one-letter short code is refused')
refused({ op = 'team', name = 'X', short = 'PHX', color = '#ff0000' }, 'already another team', 'a short code taken is refused')
refused({ op = 'team', name = 'X', short = 'XX', color = 'red' }, 'hex', 'a color that is not #rrggbb is refused')
refused({ op = 'team', name = 'X', short = 'XX', color = '#ff0000', logo = 'javascript:alert(1)' },
  'https://', 'a logo that is not a web link is refused')
refused({ op = 'team', name = 'X', short = 'XX', color = '#ff0000', logo = 'https://x.org/a b.png' },
  'no spaces', 'a logo link with a space is refused')
refused({ op = 'team', name = 'X', short = 'XX', color = '#ff0000',
  logo = 'https://cdn.discordapp.com/attachments/1/2/logo.png?ex=6612&is=55&hm=ab' },
  'stop working within a day', 'a Discord attachment link that expires is refused')
refused({ op = 'team', name = string.rep('n', 33), short = 'XX', color = '#ff0000' },
  '1 to 32', 'a name over 32 characters is refused')
check(lastNotice(2) == nil, 'refusals go to the admin who asked, nobody else')

-- 4. Drivers: team and number on the wire.
set(0, { op = 'entry', name = 'Speedy_K', team = PHX, number = '07' })
set(0, { op = 'entry', name = 'Bob', team = BLU, number = '7' })
local st = stateFor(0)
check(row(st, 1).team == PHX and row(st, 1).number == '07', 'a driver matched by BeamMP name, either case')
check(row(st, 2).team == BLU and row(st, 2).number == '7', '07 and 7 are different numbers')
check(row(st, 3).team == nil and row(st, 3).number == nil, 'a driver with neither sends neither')
refused({ op = 'entry', name = 'Guest_77', number = '07' }, 'already Speedy_K', 'a number taken is refused')
refused({ op = 'entry', name = 'Guest_77', number = '1234' }, '1 to 3 digits', 'a four-digit number is refused')
refused({ op = 'entry', name = 'Guest_77', team = 99 }, 'gone', 'a team that does not exist is refused')

-- Display name first: an alias the admin gave wins over the BeamMP name.
set(0, { op = 'entry', name = 'Comet Kid', team = BLU, number = '12' })
RM_onSetAlias(0, '{"target":3,"alias":"Comet Kid"}')
st = stateFor(0)
check(row(st, 3).team == BLU and row(st, 3).number == '12', 'matched by the alias the admin gave')
RM_onSetAlias(0, '{"target":3,"alias":""}')
st = stateFor(0)
check(row(st, 3).team == nil and row(st, 3).number == nil, 'and the alias taken away is seen at once')

-- A team going clears its drivers' team; their numbers stay.
set(0, { op = 'removeTeam', id = BLU })
st = stateFor(0)
check(row(st, 2).team == nil and row(st, 2).number == '7', 'a removed team leaves its drivers their numbers')
check(#teams.entries().teams == 1, 'one team left')
set(0, { op = 'entry', name = 'Bob', number = '' })
check(#teams.entries().entries == 2, 'an entry left with no team and no number goes')

-- 5. When the list goes out.
updates = {}
set(0, { op = 'team', name = 'Grey Ghosts', short = 'GG', color = '#888888' })
local broadcast
for _, u in ipairs(updates) do if u.target == -1 then broadcast = u.payload end end
check(broadcast and type(broadcast.teams) == 'table' and #broadcast.teams == 2,
  'the broadcast after a change carries the teams')
updates = {}
RM_onRequestState(2, '')
for _, u in ipairs(updates) do
  check(u.payload.teams ~= nil, 'a targeted send always carries them')
end
check(lastUpdate(2).teamEntries == nil, 'a driver does not get the entries')
check(stateFor(0).teamEntries and #stateFor(0).teamEntries.entries == 2, 'an admin does')
-- The next plain broadcast has nothing.
updates = {}
RM_onSetSpectating(2, '{"spectating":true}')
RM_onSetSpectating(2, '{"spectating":false}')
local plain = 0
for _, u in ipairs(updates) do
  if u.target == -1 then
    plain = plain + 1
    check(u.payload.teams == nil, 'later broadcasts leave the list out')
  end
end
check(plain > 0, 'broadcasts went out to check')

-- 6. The file.
local text = read(FILE) or ''
check(text:find('"Phoenix Racing"', 1, true) and text:find('"07"', 1, true), 'Data/teams.json holds it')
teams.warm()
st = stateFor(0)
check(#teams.entries().teams == 2 and row(st, 1).number == '07', 'read back at the next start')

local f = assert(io.open(FILE, 'w'))
f:write('{ this is not json')
f:close()
teams.warm()
notices = {}
set(0, { op = 'team', name = 'New', short = 'NEW', color = '#123456' })
check(read(FILE) == '{ this is not json' and (lastNotice(0) or ''):find('does not parse', 1, true),
  'a broken file is never written over, and edits say why')
os.remove(FILE)

print(string.format('teams_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
