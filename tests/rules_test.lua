-- Headless test for RACE RULES OVER A RESTART and saved rulesets
-- (server/RaceManager/rules.lua), run against the real server plugin in Lua 5.3,
-- the same as BeamMP.
--
--   * Loading the file alone defines nothing; the handler comes from init().
--   * Every rule set in the panel is in Data/rules.json and back after a
--     restart (the map switch that restarts the server), a hot reload included.
--   * A broadcast with no rule change writes nothing.
--   * A rule edited in config.json since wins over the file; the rest do not.
--   * Custom grid order, the heat draw and a joker lap on a track with no route
--     are not carried: what they need is gone.
--   * Rulesets: save, load, the server defaults, delete (admin only), refused
--     mid-session, names checked, a cap, the one in force marked.
--   * A broken rules.json is never written over.
--
-- Run from the repo root: lua5.3 tests/rules_test.lua

local connected = { [0] = 'Admin', [1] = 'Mod', [2] = 'Bob' }
local updates = {}       -- RM_Update payloads, { target, payload }
local notices = {}       -- RM_Notice, { target, payload }
local chat = {}

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (_, msg) chat[#chat + 1] = msg end,
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
  RemoveVehicle = function () end,
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

local function removeTree(path)
  if package.config:sub(1, 1) == '\\' then
    os.execute('rmdir /s /q "' .. path:gsub('/', '\\') .. '" 2>nul')
  else
    os.execute('rm -rf "' .. path .. '"')
  end
end
removeTree('Resources')

-- 1. Loading the file alone defines nothing.
do
  local before = {}
  for k in pairs(_G) do before[k] = true end
  dofile('server/RaceManager/rules.lua')
  local added = {}
  for k in pairs(_G) do if not before[k] then added[#added + 1] = k end end
  check(#added == 0, 'rules.lua alone defines no globals (got ' .. table.concat(added, ', ') .. ')')
end

local DATA = 'Resources/Server/PhoenixRM Server/Data'
local FILE = DATA .. '/rules.json'
local CONFIG = DATA .. '/config.json'

local function read(p)
  local f = io.open(p, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end
local function write(p, s)
  local f = assert(io.open(p, 'w'))
  f:write(s)
  f:close()
end
local function last(target)
  for i = #updates, 1, -1 do
    if target == nil or updates[i].target == target then return updates[i].payload end
  end
end
local function state()
  RM_onRequestState(0, '')
  return last(0)
end
local function lastNotice(target)
  for i = #notices, 1, -1 do
    if notices[i].target == target then return notices[i].payload.sub end
  end
  return ''
end
local function chatHas(text)
  for _, m in ipairs(chat) do if m:find(text, 1, true) then return true end end
  return false
end
local function rules(pid, op, name)
  RM_onRules(pid, string.format('{"op":%q,"name":%q}', op, name or ''))
end

-- A restart: the plugin read again from source, then booted. A hot reload is
-- the same in one Lua state, which is what this is.
local function reboot()
  dofile('server/RaceManager/main.lua')
  onInit()
  for pid in pairs(connected) do RM_onPlayerJoin(pid) end
  RM_onLogin(0, '{"password":"phoenix"}')
  -- Refused until the moderator password is set below.
  RM_onLogin(1, '{"password":"tuesday"}')
end

reboot()
check(type(RM_onRules) == 'function', 'RM_onRules is installed by init')
check(read(FILE) == nil, 'a fresh server writes no rules.json until a rule changes')

-- A moderator, for the tier checks.
RM_onChangePassword(0, '{"password":"tuesday","role":"moderator"}')
RM_onLogin(1, '{"password":"tuesday"}')

-- 2. Every rule the panel sets.
RM_onSetRaceLimits(0, '{"laps":12,"seconds":900,"mode":"endurance"}')
RM_onSetFinishRule(0, '{"after":2,"seconds":90}')
RM_onSetMaxResets(0, '{"maxResets":3}')
RM_onSetResetMode(0, '{"mode":"checkpoint"}')
RM_onSetCheckpointSkip(0, '{"enabled":true,"warnings":2,"type":"lift","penaltySec":7.5,'
  .. '"liftSec":4,"liftWindow":40,"pitServe":"optional","pitLaps":4,"liftUnserved":"black"}')
RM_onSetBlackFlag(0, '{"seconds":25,"laps":5}')
RM_onSetPitStopRule(0, '{"required":2,"missed":"time","seconds":45}')
RM_onSetJokerExtra(0, '{"mode":"dsq","seconds":12.5}')
RM_onSetPitStart(0, '{"session":"quali","enabled":true}')
RM_onSetPitStart(0, '{"session":"race","enabled":true}')
RM_onSetPaceLap(0, '{"enabled":true}')
RM_onSetLuckyDog(0, '{"enabled":true}')
RM_onSetLapsBack(0, '{"enabled":true}')
RM_onSetCautionMode(0, '{"mode":"call"}')
RM_onSetGhostQuali(0, '{"enabled":true}')
RM_onSetQualiLimits(0, '{"laps":3,"seconds":0}')
RM_onSetHeats(0, '{"count":3,"transfer":4,"laps":6}')
RM_onSetHeatDraw(0, '{"mode":"random"}')
RM_onSetGridMode(0, '{"mode":"reverse"}')
RM_onSetReadyCheck(0, '{"on":false}')
check(read(FILE) ~= nil, 'a rule change writes Data/rules.json')

local function sameRules(s, what)
  local cs = s.cpSkip or {}
  check(s.raceMode == 'endurance' and s.totalLaps == 12 and s.raceTimeLimit == 900,
    what .. ': race length (endurance, 12 laps, 15 min)')
  check(s.finishAfter == 2 and s.finishTimer == 90, what .. ': finish countdown')
  check(s.maxResets == 3 and s.resetMode == 'checkpoint', what .. ': resets')
  check(cs.enabled == true and cs.warnings == 2 and cs.type == 'lift' and cs.penaltySec == 7.5
    and cs.liftSec == 4 and cs.liftWindow == 40 and cs.pitServe == 'optional' and cs.pitLaps == 4,
    what .. ': checkpoint skips')
  check(cs.liftUnserved == 'black' and s.bf and s.bf.seconds == 25 and s.bf.laps == 5,
    what .. ': black flags')
  local pr = s.pitStopRule or {}
  check(pr.required == 2 and pr.missed == 'time' and pr.seconds == 45,
    what .. ': mandatory pit stops')
  check(s.qualiFromPits == true and s.raceFromPits == true, what .. ': starts from the pit stalls')
  check(s.paceLap == true and s.luckyDog == true and s.lapsBack == true and s.cautionMode == 'call',
    what .. ': pace lap and caution rules')
  check(s.ghostQuali == true and s.qualiLapLimit == 3 and s.qualiTimeLimit == 0,
    what .. ': qualifying')
  check(s.heatCount == 3 and s.heatTransfer == 4 and s.heatLaps == 6 and s.heatDraw == 'random',
    what .. ': heat program')
  check(s.gridMode == 'reverse' and s.readyCheck == false, what .. ': grid order and ready check')
  check(s.jokerExtra == 'dsq' and s.jokerExtraSeconds == 12.5, what .. ': what a second joker run costs')
end
sameRules(state(), 'set live')

-- 3. A broadcast with nothing changed writes nothing.
do
  local before = read(FILE)
  os.remove(FILE)
  RM_onRequestState(2, '')
  RM_Tick()
  check(read(FILE) == nil, 'a broadcast with no rule change does not write rules.json')
  write(FILE, before)
end

-- 4. THE BUG: a restart (a map switch to a map BeamMP does not have loaded)
-- used to put every rule back to config.json.
reboot()
sameRules(state(), 'after a restart')
check(state().heatsDrawn == false, 'the heat program is back, the draw is not (the drivers left)')

-- 5. Custom grid order is not carried: its pins belong to drivers connected now.
RM_onSetDriverGrid(0, '{"pid":2,"slot":1}')
check(state().gridMode == 'custom', 'pinning a driver sets custom order')
reboot()
check(state().gridMode == 'quali', 'custom order comes back as quali')
RM_onSetGridMode(0, '{"mode":"reverse"}')

-- 6. A rule edited in config.json since wins; the rest come from the file.
do
  local cfg = read(CONFIG)
  write(CONFIG, (cfg:gsub('"maxResets":%s*%-?%d+', '"maxResets": 7')))
  reboot()
  local s = state()
  check(s.maxResets == 7, 'maxResets edited in config.json wins over rules.json')
  check(s.totalLaps == 12 and s.resetMode == 'checkpoint',
    'and every rule config.json did not change still comes from rules.json')
  reboot()
  check(state().maxResets == 7, 'and stays: the file was rewritten against this config.json')
  RM_onSetMaxResets(0, '{"maxResets":3}')
  reboot()
  check(state().maxResets == 3, 'a panel change after the edit is kept again')
  -- Editing it back is an edit too.
  write(CONFIG, cfg)
  reboot()
  check(state().maxResets == -1, 'config.json edited back wins again')
  RM_onSetMaxResets(0, '{"maxResets":3}')
end

-- 7. Rulesets.
notices, chat = {}, {}
rules(0, 'save', 'Endurance')
check(lastNotice(0):find('Saved "Endurance"', 1, true), 'an admin saves a ruleset')
local s = state()
check(s.rulesets and s.rulesets.sets[1] == 'Endurance' and s.rulesets.active == 'Endurance',
  'it rides the admin\'s RM_Update, marked as the one in force')

rules(1, 'save', 'Sprint')   -- a moderator saves too, the rules unchanged
RM_onSetRaceLimits(0, '{"laps":4,"seconds":0,"mode":"laps"}')
RM_onSetPaceLap(0, '{"enabled":false}')
RM_onSetHeats(0, '{"count":0,"transfer":0,"laps":0}')
rules(1, 'save', 'sprint')   -- same name in other case: an update, not a second set
s = state()
check(#s.rulesets.sets == 2 and s.rulesets.active ~= nil and s.rulesets.active:lower() == 'sprint',
  'a name differing only in case replaces that set (' .. #s.rulesets.sets .. ' sets)')
check(lastNotice(1):find('Updated', 1, true), 'and says it was an update')

rules(2, 'save', 'Hijack')
check(#state().rulesets.sets == 2, 'a driver who is not logged in cannot save')
rules(0, 'save', string.rep('x', 33))
check(lastNotice(0):find('1 to 32', 1, true) and #state().rulesets.sets == 2,
  'a name over 32 characters is refused')

-- Load: every rule back, said in chat.
rules(0, 'load', 'Endurance')
s = state()
sameRules(s, 'loading a ruleset')
check(s.rulesets.active == 'Endurance', 'the loaded set is the one in force')
check(chatHas('Ruleset "Endurance" loaded by Admin'), 'a load is announced to everyone')

-- Changing one rule by hand: no set is in force.
RM_onSetMaxResets(0, '{"maxResets":5}')
check(state().rulesets.active == nil, 'a hand change leaves no set marked in force')

-- The broadcast after a change carries the list; the tick after it does not.
updates = {}
RM_onSetMaxResets(0, '{"maxResets":3}')
local bc = last(-1)
check(bc and bc.rulesets and bc.rulesets.active == 'Endurance',
  'the broadcast after a change carries the rulesets')
RM_onSetFinishRule(0, '{"after":2,"seconds":90}')   -- no rule moves
check(last(-1).rulesets == nil, 'a broadcast with nothing changed does not')
RM_onRequestState(2, '')
check(last(2).rulesets == nil, 'and a driver\'s own send does not')

-- Server defaults.
rules(0, 'defaults')
s = state()
check(s.totalLaps == 5 and s.raceMode == 'laps' and s.maxResets == -1 and s.paceLap == false
  and s.heatCount == 0 and s.gridMode == 'quali' and s.readyCheck == true and s.ghostQuali == false,
  'the server defaults are config.json\'s rules')
check(s.rulesets.atDefaults == true and s.rulesets.active == nil, 'and are marked in force')

-- Refused mid-session, as every rule's own switch is.
RM_onSetReadyCheck(0, '{"on":false}')
RM_onStartQualifying(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(state().phase == 'qualifying', 'qualifying is running')
rules(0, 'load', 'Endurance')
check(state().totalLaps == 5 and lastNotice(0):find('Finish the session', 1, true),
  'a load is refused while a session runs')
RM_onEndRace(0)
check(state().phase ~= 'qualifying', 'qualifying ended')

-- 8. Track rules follow the track.
do
  local pos = '[{"x":0,"y":0,"z":0,"hx":0,"hy":1},{"x":0,"y":8,"z":0,"hx":0,"hy":1}]'
  RM_onStartPositionCount(0, '{"count":2,"positions":' .. pos .. ',"jokerGates":3}')
  RM_onSetJokerEnabled(0, '{"enabled":true}')
  check(state().jokerEnabled == true, 'the joker lap arms on a track with a route')
  rules(0, 'save', 'Rallycross')
  RM_onStartPositionCount(0, '{"count":2,"positions":' .. pos .. ',"jokerGates":0}')
  check(state().jokerEnabled == false, 'and switches off when the route goes')
  notices = {}
  rules(0, 'load', 'Rallycross')
  check(state().jokerEnabled == false and lastNotice(0):find('no Joker Route', 1, true),
    'a ruleset with the joker on leaves it off on a track with no route, and says so')
  RM_onStartPositionCount(0, '{"count":2,"positions":' .. pos .. ',"jokerGates":3}')
  rules(0, 'load', 'Rallycross')
  check(state().jokerEnabled == true, 'and arms it on one that has a route')
  -- The heat draw goes when a load changes the heat count.
  rules(0, 'load', 'Endurance')
  RM_onDrawHeats(0)
  check(state().heatsDrawn == true, 'heats drawn')
  rules(0, 'load', 'Endurance')
  check(state().heatsDrawn == true, 'loading the same heat count keeps the draw')
  rules(0, 'load', 'Rallycross')
  check(state().heatsDrawn == false and state().heatCount == 0,
    'a different heat count drops the draw')
end

-- 9. Delete: admin only.
rules(1, 'delete', 'Sprint')
check(#state().rulesets.sets == 3, 'a moderator cannot delete a ruleset')
rules(0, 'delete', 'Sprint')
s = state()
check(#s.rulesets.sets == 2 and s.rulesets.sets[1] == 'Endurance' and s.rulesets.sets[2] == 'Rallycross',
  'an admin can, and the list stays in name order')

-- The sets survive a restart with the rules.
reboot()
check(#state().rulesets.sets == 2, 'saved rulesets survive a restart')

-- 10. The cap.
for i = 1, 40 do rules(0, 'save', 'Set ' .. i) end
check(#state().rulesets.sets == 30 and lastNotice(0):find('delete one first', 1, true),
  'at most 30 rulesets, refused out loud past that')

-- 11. A broken rules.json is never written over.
write(FILE, '{"live": {"totalLaps": 9,,, oops')
reboot()
RM_onSetMaxResets(0, '{"maxResets":8}')
check(read(FILE) == '{"live": {"totalLaps": 9,,, oops', 'a broken rules.json is left as it is')
check(state().maxResets == 8, 'and the rules still change in memory')
rules(0, 'save', 'Anything')
check(lastNotice(0):find('does not parse', 1, true), 'and a ruleset change says why it is refused')
rules(0, 'defaults')
check(state().maxResets == -1, 'the server defaults still load')

removeTree('Resources')
print(string.format('rules_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
