-- Headless test for SAVED OVERLAY LOOKS (server/RaceManager/looks.lua), run
-- against the real server plugin in Lua 5.3, the same as BeamMP.
--
--   * Loading the file alone defines nothing; the handler comes from init().
--   * Anyone lists and loads; saving takes a login, either tier; deleting is
--     admin only. Every refusal is answered, so the editor never waits it out.
--   * Saved looks are in Data/looks.json and back after a restart.
--   * Names checked, a cap, a size cap, and a broken file never written over.
--
-- Run from the repo root: lua5.3 tests/looks_test.lua

local connected = { [0] = 'Admin', [1] = 'Mod', [2] = 'Bob' }
local sent = {}          -- RM_Looks, { target, payload }

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function () end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Looks' then sent[#sent + 1] = { target = target, payload = payload } end
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
  dofile('server/RaceManager/looks.lua')
  local added = {}
  for k in pairs(_G) do if not before[k] then added[#added + 1] = k end end
  check(#added == 0, 'looks.lua alone defines no globals (got ' .. table.concat(added, ', ') .. ')')
end

local FILE = 'Resources/Server/PhoenixRM Server/Data/looks.json'
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
-- The last RM_Looks to `target` (-1 for everyone).
local function last(target)
  for i = #sent, 1, -1 do
    if sent[i].target == target then return sent[i].payload end
  end
end
local STYLE = '{"colors":{"accent":"#e10600","bg":"#16181c"},"opacity":0.92,"banner":"logo,flag,lap|order"}'
local function looks(pid, op, name, ticket, style)
  RM_onLooks(pid, string.format('{"op":%q,"name":%q,"ticket":%d%s}', op, name or '', ticket or 0,
    style and (',"style":' .. style) or ''))
  return last(pid)
end

local function reboot()
  dofile('server/RaceManager/main.lua')
  onInit()
  for pid in pairs(connected) do RM_onPlayerJoin(pid) end
  RM_onLogin(0, '{"password":"phoenix"}')
  RM_onLogin(1, '{"password":"tuesday"}')
end

reboot()
check(type(RM_onLooks) == 'function', 'RM_onLooks is installed by init')
RM_onChangePassword(0, '{"password":"tuesday","role":"moderator"}')
RM_onLogin(1, '{"password":"tuesday"}')

-- 2. Anyone may list: none yet.
local r = looks(2, 'list')
check(r and r.op == 'list' and #r.looks == 0, 'a fresh server lists no looks')

-- 3. Saving takes a login, and the refusal is an answer.
r = looks(2, 'save', 'Formula', 7, STYLE)
check(r and r.op == 'error' and r.ticket == 7 and r.msg:find('login', 1, true),
  'a driver who is not logged in cannot save, and is told so on the ticket')
check(read(FILE) == nil, 'and nothing is written')

r = looks(0, 'save', 'Formula', 8, STYLE)
check(r and r.op == 'saved' and r.ticket == 8 and r.name == 'Formula' and r.kept == true,
  'an admin saves a look')
local all = last(-1)
check(all and all.op == 'list' and #all.looks == 1 and all.looks[1].name == 'Formula'
  and all.looks[1].by == 'Admin', 'and everyone is sent the new list, with who saved it')
check(read(FILE) and read(FILE):find('#e10600', 1, true), 'Data/looks.json has the look')

r = looks(1, 'save', '  Rally   Cross ', 9, STYLE)
check(r and r.op == 'saved' and r.name == 'Rally Cross', 'a moderator saves one too, its name tidied')

-- 4. Anyone may load.
r = looks(2, 'get', 'formula', 10)
check(r and r.op == 'get' and r.ticket == 10 and r.name == 'Formula'
  and r.style.colors.accent == '#e10600' and r.style.opacity == 0.92,
  'a driver loads a look by name, in any case, style and all')
r = looks(2, 'get', 'Drift', 11)
check(r and r.op == 'error' and r.ticket == 11, 'a look nobody saved is an error on the ticket')

-- 5. Saving a name again replaces it.
r = looks(0, 'save', 'FORMULA', 12, '{"opacity":0.5}')
check(r and r.op == 'saved' and r.replaced == true, 'saving a name again replaces it')
check(#last(-1).looks == 2, 'still two looks')
check(looks(2, 'get', 'Formula', 13).style.opacity == 0.5, 'with the new look')

-- 6. Deleting is admin only.
r = looks(1, 'delete', 'Formula', 14)
check(r and r.op == 'error' and r.ticket == 14 and r.msg:find('admin', 1, true),
  'a moderator cannot delete a look')
r = looks(0, 'delete', 'Rally Cross', 15)
check(r and r.op == 'deleted' and r.name == 'Rally Cross', 'an admin deletes one')
check(#last(-1).looks == 1, 'and everyone is sent the shorter list')

-- 7. Names, a cap, a size cap.
r = looks(0, 'save', string.rep('x', 33), 16, STYLE)
check(r and r.op == 'error' and r.ticket == 16, 'a name over 32 characters is refused')
r = looks(0, 'save', 'Empty', 17)
check(r and r.op == 'error' and r.ticket == 17, 'a save with no style is refused')
for i = 1, 29 do looks(0, 'save', 'Look ' .. i, 100 + i, '{"opacity":0.7}') end
check(#last(-1).looks == 30, 'thirty looks kept')
r = looks(0, 'save', 'One too many', 18, STYLE)
check(r and r.op == 'error' and r.msg:find('30', 1, true), 'the thirty-first is refused')
RM_onLooks(0, '{"op":"save","name":"Huge","style":{"title":"' .. string.rep('a', 17000) .. '"}}')
check(last(0).op == 'error' and last(0).msg:find('too big', 1, true), 'a look over 16 KB is refused')

-- 8. Back after a restart.
reboot()
r = looks(2, 'list')
check(r and #r.looks == 30, 'every look is back after a restart')
check(looks(2, 'get', 'Formula', 19).style.opacity == 0.5, 'with its style')

-- 9. A broken looks.json is never written over.
write(FILE, '{"looks": [ oops')
reboot()
r = looks(0, 'save', 'Anything', 20, STYLE)
check(r and r.op == 'error' and r.msg:find('does not parse', 1, true),
  'a save over a broken looks.json is refused, and says why')
check(read(FILE) == '{"looks": [ oops', 'and the file is left as it is')
check(looks(2, 'list').broken ~= nil, 'the list says why too')

removeTree('Resources')
print(string.format('looks_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
