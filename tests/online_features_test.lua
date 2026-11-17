-- Headless test for ONLINE FEATURES on the Admin panel (server/RaceManager/main.lua,
-- RM_onSetOnlineFeatures): whether the server goes online by itself.
--
-- It used to be config.json only, and it is off as shipped for a real reason:
-- on one game host the startup update check cut the server off BeamMP's own
-- login, and every player was kicked with "Invalid key". The panel can set it
-- now, and this file pins the guard rails that make that safe enough:
--
--   * as shipped it is off, an admin's panel says so, and a driver is never
--     sent it
--   * only the ADMIN tier can change it: a moderator is refused, as for
--     installing an update
--   * switching it ON reaches nothing by itself: nothing is spawned and no
--     check is queued until an admin asks (Check now), a Discord post goes out,
--     or the server next starts
--   * every admin's panel follows, race control is told, and it is written to
--     config.json, so it survives a restart
--   * switching it OFF is refused while an update is under way, and otherwise
--     works at once
--
-- Run from the repo root: lua5.3 tests/online_features_test.lua

local connected = { [1] = 'Admin', [2] = 'Mod', [3] = 'Driver' }
local ADMIN, MOD, DRIVER = 1, 2, 3
local chat     = {}   -- { target, msg }
local events   = {}   -- every TriggerClientEvent: { target, event, payload }
local targeted = {}   -- the last RM_Update sent to each pid on its own

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) chat[#chat + 1] = { target = target, msg = msg } end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    events[#events + 1] = { target = target, event = event, payload = payload }
    if event == 'RM_Update' and target ~= -1 then targeted[target] = payload end
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

local IS_WINDOWS = package.config:sub(1, 1) == '\\'
local function removeTree(path)
  if IS_WINDOWS then
    os.execute('rmdir /s /q "' .. path:gsub('/', '\\') .. '" 2>nul')
  else
    os.execute('rm -rf "' .. path .. '"')
  end
end
-- A fresh data folder, and gone again at the end: a config.json left saying
-- onlineFeatures true would put every later suite online.
removeTree('Resources')

local CONFIG = 'Resources/Server/PhoenixRM Server/Data/config.json'

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function read(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local t = f:read('*a'); f:close()
  return t
end
local function savedOnline()
  return (read(CONFIG) or ''):match('"onlineFeatures"%s*:%s*(%a+)')
end
local function chatTo(pid, fragment)
  for _, c in ipairs(chat) do
    if c.target == pid and c.msg:find(fragment, 1, true) then return c.msg end
  end
  return nil
end
local function denied(pid)
  for _, e in ipairs(events) do
    if e.event == 'RM_Denied' and e.target == pid then return true end
  end
  return false
end
local function clearLogs() chat, events = {}, {} end
local function stateOf(pid)
  RM_onRequestState(pid)
  return targeted[pid]
end
local function onlineOf(pid)
  local s = stateOf(pid)
  return s and s.onlineFeatures and s.onlineFeatures.on
end
local function set(pid, on)
  RM_onSetOnlineFeatures(pid, on and '{"on":true}' or '{"on":false}')
end

-- Everything the updater would run goes through update.spawn (and the cwd
-- probe through update.sys.popen). Both stand in here, so a test that went
-- online by mistake is a count, not a request to GitHub.
local spawned = 0
local update
local function boot()
  dofile('server/RaceManager/main.lua')
  update = require('update')
  update.spawn = function () spawned = spawned + 1; return false end
  update.cwdCache = '/nowhere'
  onInit()
  for pid in pairs(connected) do RM_onPlayerJoin(pid) end
  RM_onLogin(ADMIN, '{"password":"phoenix"}')
end

boot()
RM_onChangePassword(ADMIN, '{"password":"marshal","role":"moderator"}')
RM_onLogin(MOD, '{"password":"marshal"}')
local discord = package.loaded.discord

-- ---------------------------------------------------------------------------
-- 1. As shipped: off, and only an admin's panel is told
-- ---------------------------------------------------------------------------
check(onlineOf(ADMIN) == false, 'off as shipped, and an admin\'s panel says so')
check(onlineOf(MOD) == false, 'a moderator\'s panel shows it too')
check(stateOf(DRIVER).onlineFeatures == nil, 'a driver is never sent it')
check(savedOnline() == 'false', 'config.json is written with it, off')

-- ---------------------------------------------------------------------------
-- 2. Only the admin tier can change it
-- ---------------------------------------------------------------------------
clearLogs()
set(DRIVER, true)
check(onlineOf(ADMIN) == false, 'a driver cannot turn it on')
set(MOD, true)
check(onlineOf(ADMIN) == false and savedOnline() == 'false', 'nor can a moderator')
check(denied(MOD), 'and the moderator is told it needs the admin password')
RM_onSetOnlineFeatures(ADMIN, '{"on":"yes"}')
check(onlineOf(ADMIN) == false, 'and nothing but true or false is taken')

-- ---------------------------------------------------------------------------
-- 3. An admin turns it on, and nothing goes online because of it
-- ---------------------------------------------------------------------------
clearLogs()
set(ADMIN, true)
check(onlineOf(ADMIN) == true, 'an admin turns it on')
check(targeted[MOD] and targeted[MOD].onlineFeatures.on == true,
  'and every admin\'s panel follows, without asking')
check(savedOnline() == 'true', 'written to config.json, so it survives a restart')
check(chatTo(ADMIN, 'Online features turned ON by Admin') and chatTo(MOD, 'Online features turned ON'),
  'race control is told who turned it on')
check(chatTo(ADMIN, 'Invalid key') ~= nil, 'and how to undo it if the host cuts the server off')
check(chatTo(DRIVER, 'Online features') == nil, 'the drivers are not told')
check(spawned == 0 and update.job == nil and not update.pendingCheck,
  'switching it on reaches nothing by itself: no check started, none queued')
check(discord == nil or discord.job == nil, 'and no Discord post started')
local u = stateOf(ADMIN).prmUpdate
check(u and u.online == true and u.enabled == true, 'the Updates row comes alive')

-- Now Check now does go to GitHub (the stand-in counts it).
RM_onUpdateCheck(ADMIN)
check(spawned == 1, 'an admin\'s Check now is what goes online')

-- ---------------------------------------------------------------------------
-- 4. It survives a restart
-- ---------------------------------------------------------------------------
boot()
check(onlineOf(ADMIN) == true, 'read back from config.json after a restart')

-- ---------------------------------------------------------------------------
-- 5. Off: refused while an update is under way, then at once
-- ---------------------------------------------------------------------------
clearLogs()
update.state.phase = 'downloading'
set(ADMIN, false)
check(onlineOf(ADMIN) == true and savedOnline() == 'true',
  'not while an update is under way: it is using the network')
check(chatTo(ADMIN, 'Not while an update is under way') ~= nil, 'and the admin is told why')
update.state.phase = 'idle'

clearLogs()
set(ADMIN, false)
check(onlineOf(ADMIN) == false and savedOnline() == 'false', 'an admin turns it off')
check(chatTo(ADMIN, 'Online features turned OFF by Admin') ~= nil, 'and race control is told')
u = stateOf(ADMIN).prmUpdate
check(u and u.online == false, 'the Updates row goes back to updating by hand')
local before = spawned
RM_onUpdateCheck(ADMIN)
check(spawned == before, 'and Check now no longer reaches GitHub')

-- Pressing it again changes nothing and says nothing.
clearLogs()
set(ADMIN, false)
check(chatTo(ADMIN, 'Online features') == nil, 'turning off what is off is no news')

removeTree('Resources')

if fails == 0 then
  print(string.format('online_features_test: %d checks, 0 failures', checks))
else
  print(string.format('online_features_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
