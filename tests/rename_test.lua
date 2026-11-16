-- Headless test for THE RENAME in server/RaceManager/main.lua
-- (race.adoptOldInstall).
--
-- 0.24.0 moved the plugin from Resources/Server/RaceManager to
-- "Resources/Server/PhoenixRM Server", and the client mod from
-- Resources/Client/RaceManager.zip to "PhoenixRM Client.zip", so an owner can
-- see what is installed. A release unzipped by hand over Resources/ leaves the
-- old pair beside the new one, and BeamMP loads EVERY plugin folder and sends
-- EVERY client zip. So the new plugin, at boot, takes the old install over:
--
--   * the old Data folder (tracks, cup, garage, settings, results) is moved in,
--     so nothing an owner built is left behind in a folder nothing reads;
--   * the old plugin's .lua files and the old client zip go to _attic/, so the
--     next start runs one Race Manager -- and since this one ran two, the admin
--     is told to restart;
--   * nothing that is not Race Manager's is touched.
--
-- Run from the repo root: lua5.3 tests/rename_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; io.write('FAIL: ', msg, '\n') end
end

local IS_WINDOWS = package.config:sub(1, 1) == '\\'
local function sh(unix, win) os.execute(IS_WINDOWS and win or unix) end
local function rmTree(p) sh('rm -rf "' .. p .. '"', 'rmdir /s /q "' .. p:gsub('/', '\\') .. '" 2>nul') end
local function mkdir(p) sh('mkdir -p "' .. p .. '"', 'mkdir "' .. p:gsub('/', '\\') .. '" 2>nul') end
local function write(p, s) local f = assert(io.open(p, 'wb')); f:write(s); f:close() end
local function read(p)
  local f = io.open(p, 'rb')
  if not f then return nil end
  local ok, s = pcall(f.read, f, '*a')
  f:close()
  return ok and s or nil
end
local function listing(dir)
  local out = {}
  local p = io.popen(IS_WINDOWS and ('dir /b "' .. dir:gsub('/', '\\') .. '" 2>nul')
    or ('ls -1 "' .. dir .. '" 2>/dev/null'))
  for name in p:lines() do out[#out + 1] = name end
  p:close()
  return out
end

local OLD, NEW = 'Resources/Server/RaceManager', 'Resources/Server/PhoenixRM Server'
local OLD_CLIENT = 'Resources/Client/RaceManager.zip'
local OLD_MAIN = "local RM_BUILD = '0.23.4'\nprint('[RaceManager] loaded')\n"
-- The client zip's central directory names its files in the clear.
local OLD_ZIP = 'PK...lua/ge/extensions/raceManager.lua...'

local chat = {}
local loginOk = nil
MP = {
  GetPlayerName = function () return 'Admin' end,
  SendChatMessage = function (to, msg) chat[#chat + 1] = { to = to, msg = msg } end,
  GetPlayers = function () return { [0] = 'Admin' } end,
  TriggerClientEvent = function (_, event, payload)
    if event == 'RM_LoginResult' then loginOk = payload.success end
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
-- print is where the console line goes; keep it, and still show it.
local printed = {}
local realPrint = print
print = function (...)
  local parts = {}
  for i = 1, select('#', ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  printed[#printed + 1] = table.concat(parts, ' ')
end
local function printedHas(text)
  for _, line in ipairs(printed) do
    if line:find(text, 1, true) then return true end
  end
  return false
end
local function boot()
  printed, chat = {}, {}
  dofile('server/RaceManager/main.lua')
  onInit()
end

-- ---------------------------------------------------------------------------
-- 1. AN OLD INSTALL BESIDE THE NEW ONE
-- ---------------------------------------------------------------------------
rmTree('Resources'); rmTree('_attic')
mkdir(OLD .. '/Data/Race Layout'); mkdir(OLD .. '/Data/results'); mkdir('Resources/Client')
mkdir(NEW)
write(OLD .. '/main.lua', OLD_MAIN)
write(OLD .. '/maps.lua', '-- old maps\n')
write(OLD .. '/Data/config.json', '{"adminPassword": "theirs"}')
write(OLD .. '/Data/Race Layout/gridmap_v2.json', '{"layouts": []}')
write(OLD .. '/Data/results/race.txt', 'P1 somebody')
write(OLD_CLIENT, OLD_ZIP)
write('Resources/Client/othermod.zip', 'SOMEONE ELSE')

boot()
check(read(NEW .. '/Data/results/race.txt') == 'P1 somebody'
  and read(NEW .. '/Data/Race Layout/gridmap_v2.json') == '{"layouts": []}',
  'the old Data folder is now in "PhoenixRM Server", tracks and results with it')
check(read(OLD .. '/Data/results/race.txt') == nil, 'moved, not copied: one copy of the data')
loginOk = nil
RM_onLogin(0, '{"password":"theirs"}')
check(loginOk == true, 'the settings came across too: the old admin password logs in')
local note = nil
for _, m in ipairs(chat) do
  if m.to == 0 and m.msg:find('RESTART THE SERVER', 1, true) then note = m.msg end
end
check(note ~= nil, 'and the admin is told to restart: this start ran two Race Managers')
check(printedHas('RESTART THE SERVER'), 'so is the console')

check(read(OLD .. '/main.lua') == nil and read(OLD .. '/maps.lua') == nil,
  'the old plugin\'s code is out of the old folder, so BeamMP does not load it again')
check(read(OLD_CLIENT) == nil, 'and the old client mod is no longer sent to players')
local attics = listing('_attic')
local attic = attics[1] and ('_attic/' .. attics[1]) or ''
check(#attics == 1 and attics[1]:find('^PhoenixRM%-rename_'), 'they are in one folder in _attic')
check(read(attic .. '/Server/RaceManager/main.lua') == OLD_MAIN
  and read(attic .. '/Server/RaceManager/maps.lua') == '-- old maps\n'
  and read(attic .. '/Client/RaceManager.zip') == OLD_ZIP, 'whole, nothing lost')
check(read('Resources/Client/othermod.zip') == 'SOMEONE ELSE', 'another mod is left alone')

-- ---------------------------------------------------------------------------
-- 2. THE NEXT START: nothing left to take over
-- ---------------------------------------------------------------------------
boot()
RM_onLogin(0, '{"password":"theirs"}')
local again = false
for _, m in ipairs(chat) do
  if m.msg:find('older install', 1, true) then again = true end
end
check(not again and not printedHas('older install'), 'the restart is quiet: nothing to take over')
check(read(NEW .. '/Data/results/race.txt') == 'P1 somebody', 'and the data is where it was put')

-- ---------------------------------------------------------------------------
-- 3. NOT RACE MANAGER'S, NOT TOUCHED
-- ---------------------------------------------------------------------------
-- Somebody else's plugin that happens to be called RaceManager, and a
-- RaceManager.zip that is not this client.
rmTree('Resources'); rmTree('_attic')
mkdir(OLD); mkdir('Resources/Client'); mkdir(NEW)
write(OLD .. '/main.lua', "print('another plugin')\n")
write(OLD_CLIENT, 'PK...vehicles/racecar/racecar.jbeam...')
boot()
check(read(OLD .. '/main.lua') == "print('another plugin')\n", 'another plugin of the same name stays')
check(read(OLD_CLIENT) ~= nil, 'so does a zip of that name that is not the client')
check(#listing('_attic') == 0, 'and nothing went to _attic')

-- ---------------------------------------------------------------------------
-- 4. AN INSTALL FROM BEFORE THE DATA FOLDER
-- ---------------------------------------------------------------------------
-- Its files sat beside the old main.lua; they come across too.
rmTree('Resources'); rmTree('_attic')
mkdir(OLD); mkdir(NEW)
write(OLD .. '/main.lua', OLD_MAIN)
write(OLD .. '/config.json', '{"adminPassword": "older"}')
boot()
check(read(NEW .. '/Data/config.json') ~= nil and read(NEW .. '/Data/config.json'):find('older', 1, true),
  'a pre-Data install\'s settings are copied into the new Data folder')

rmTree('Resources'); rmTree('_attic')
print = realPrint
print(string.format('rename_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
