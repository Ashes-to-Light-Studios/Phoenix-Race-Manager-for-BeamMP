-- Headless test for RACE CONTROL (/control) in lua/ge/extensions/raceManager/feed.lua:
-- the admin's race-night buttons on a page for a second screen or a phone.
--
-- It can run the race, so what matters is what it refuses:
--
--   * Off as shipped, and 404 while off.
--   * Its own key, never the style key, and the style key never works here.
--   * Each action is a NAME on a fixed list, calling the extension function the
--     panel's own button calls. Anything else is refused and nothing is called.
--   * The admin actions need this game logged in as an admin; the camera does not.
--   * Writes only from the feed's own pages (Origin), the wrong-key lockout.
--
-- A fake LuaSocket stands in for the network, as in feed_test.
--
-- Run from the repo root: lua5.3 tests/race_control_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- A JSON object reader for the answers: simple objects only, null is nil.
local function readJson(text)
  if type(text) ~= 'string' or text:sub(1, 1) ~= '{' then return nil end
  local body = text:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
  local f = load('return ' .. body, 'json', 't', {})
  local ok, v = pcall(f or function () end)
  return ok and v or nil
end

-- ===========================================================================
-- A fake LuaSocket
-- ===========================================================================
local fake = { servers = {}, pending = {} }
local function newClient(chunks)
  local c = { inq = chunks or {}, out = {}, peerClosed = false }
  function c:settimeout() end
  function c:setoption() return 1 end
  function c:receive(n)
    if #self.inq > 0 then
      local chunk = table.remove(self.inq, 1)
      if #chunk > n then
        table.insert(self.inq, 1, chunk:sub(n + 1))
        return chunk:sub(1, n)
      end
      if #chunk == n then return chunk end
      return nil, 'timeout', chunk
    end
    if self.peerClosed then return nil, 'closed', '' end
    return nil, 'timeout', ''
  end
  function c:send(data, i)
    i = i or 1
    if self.peerClosed then return nil, 'closed', i - 1 end
    self.out[#self.out + 1] = data:sub(i)
    return #data
  end
  function c:close() end
  function c:output() return table.concat(self.out) end
  return c
end
local function newServer()
  local s = { closed = false }
  function s:setoption() return 1 end
  function s:bind(host, port) self.host, self.port = host, port; return 1 end
  function s:listen() return 1 end
  function s:settimeout() end
  function s:accept()
    local c = table.remove(fake.pending, 1)
    if c then return c end
    return nil, 'timeout'
  end
  function s:close() self.closed = true end
  return s
end
package.preload.socket = function ()
  return {
    tcp = function () local s = newServer(); fake.servers[#fake.servers + 1] = s; return s end,
    udp = function ()
      return { setpeername = function () return 1 end,
        getsockname = function () return '192.168.1.50', 50000 end, close = function () end }
    end,
  }
end

-- ===========================================================================
-- BeamNG stubs, and the extension's side
-- ===========================================================================
jit = { os = 'Windows' }
local files = {}
jsonReadFile = function (path) return files[path] end
jsonWriteFile = function (path, data) files[path] = data; return true end
local statusPushes, copyPushes = {}, {}
guihooks = { trigger = function (name, data)
  if name == 'RaceManagerFeed' then statusPushes[#statusPushes + 1] = data end
  if name == 'RaceManagerFeedCopy' then copyPushes[#copyPushes + 1] = data end
end }
log = function () end
local clipboard = nil
setClipboard = function (s) clipboard = s end
FS = { fileExists = function () return true end }
readFile = function (path)
  if path:find('control.html', 1, true) then return '<!doctype html><title>PRM race control</title>' end
  return '<!doctype html><title>page</title>'
end
jsonDecode = function (text)
  local v = readJson(text)
  if v == nil then error('not JSON') end
  return v
end

-- The extension's functions, recorded.
local calls = {}
local ext = {}
for _, name in ipairs({ 'startQualifying', 'generateGrid', 'startCountdown', 'startRace',
  'readyAll', 'setFlag', 'caution', 'restart', 'cancelRestart', 'endRace', 'restartFromGrid',
  'resetLeaderboard', 'spectateDriver' }) do
  ext[name] = function (arg) calls[#calls + 1] = { fn = name, arg = arg } end
end
local login = { admin = false, role = nil }

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local feed = dofile('lua/ge/extensions/raceManager/feed.lua')
feed.init({ build = '9.9.9', ext = ext,
  isAdmin = function () return login.admin end, role = function () return login.role end })
local S = feed.feedDebug()
local function lastStatus() return statusPushes[#statusPushes] end
local function pump(n) for _ = 1, n or 1 do feed.feedUpdate(0.05) end end

local function parseResponse(raw)
  local headEnd = raw:find('\r\n\r\n', 1, true)
  if not headEnd then return { raw = raw } end
  local head = raw:sub(1, headEnd - 1)
  local r = { raw = raw, body = raw:sub(headEnd + 4), headers = {} }
  r.code = tonumber(head:match('^HTTP/1%.1 (%d+)'))
  for k, v in head:gmatch('\r\n([^:\r\n]+):%s*([^\r\n]*)') do r.headers[k:lower()] = v end
  r.json = readJson(r.body)
  return r
end
local function request(method, path, body, headers, hostHeader)
  local h = { string.format('%s %s HTTP/1.1', method, path), 'Host: ' .. (hostHeader or '127.0.0.1:8128') }
  for _, kv in ipairs(headers or {}) do h[#h + 1] = kv end
  if body then h[#h + 1] = 'Content-Length: ' .. #body end
  local c = newClient({ table.concat(h, '\r\n') .. '\r\n\r\n' .. (body or '') })
  fake.pending[#fake.pending + 1] = c
  pump(8)
  c.peerClosed = true
  pump(2)
  return parseResponse(c:output())
end
local KEY = nil
local function act(body, key, extraHeaders)
  local h = { 'X-PRM-Key: ' .. (key or KEY or ''), 'Content-Type: application/json' }
  for _, x in ipairs(extraHeaders or {}) do h[#h + 1] = x end
  return request('POST', '/control', body, h)
end
local function state(key)
  return request('GET', '/control.json', nil, { 'X-PRM-Key: ' .. (key or KEY or '') })
end
local function callsTo(fn)
  local n, last = 0, nil
  for _, c in ipairs(calls) do if c.fn == fn then n, last = n + 1, c.arg end end
  return n, last
end

-- ===========================================================================
-- 1. Off as shipped
-- ===========================================================================
feed.feedSet(true, nil, nil)
check(lastStatus().running, 'the feed is on')
check(lastStatus().control == false, 'race control is off as shipped')
check(lastStatus().urls.control == nil, 'and the panel gets no link')
local r = request('GET', '/control')
check(r.code == 404, 'off: the page is not served')
r = act('{"action":"generateGrid"}', 'aaaaaaaaaaaaaaaaaaaa')
check(r.code == 404 and #calls == 0, 'off: an action is refused and nothing runs')

-- ===========================================================================
-- 2. On: its own key, a link, the page
-- ===========================================================================
feed.feedSetControl(true)
local saved = files['settings/raceManager/feed.json']
KEY = saved.controlKey
check(saved.control == true, 'the setting is kept')
check(type(KEY) == 'string' and #KEY == 20 and KEY:match('^[a-z0-9]+$') ~= nil,
  'a 20-character race control key is made')
check(KEY ~= saved.styleKey, 'and it is not the style key')
check(lastStatus().urls.control == 'http://127.0.0.1:8128/control#key=' .. KEY,
  'the panel gets the link, the key in its fragment')
check(lastStatus().urls.lanControl == nil, 'no network link while the feed is this PC only')

r = request('GET', '/control')
check(r.code == 200 and r.body:find('PRM race control', 1, true) ~= nil, 'the page is served')
check((r.headers['content-security-policy'] or ''):find("frame-ancestors 'none'", 1, true) ~= nil
  and r.headers['x-frame-options'] == 'DENY', 'and no other site may frame it')

-- ===========================================================================
-- 3. The key
-- ===========================================================================
r = request('GET', '/control.json')
check(r.code == 403, 'the state needs the key')
r = state('bbbbbbbbbbbbbbbbbbbb')
check(r.code == 403, 'a wrong key is refused')
r = state(saved.styleKey)
check(r.code == 403, 'the style key is not the race control key')
r = act('{"action":"generateGrid"}', saved.styleKey)
check(r.code == 403 and #calls == 0, 'and acts on nothing')
r = request('POST', '/style.json', '{}', { 'X-PRM-Key: ' .. KEY })
check(r.code == 403, 'the race control key does not write the style either')
r = state()
check(r.code == 200 and r.json and r.json.admin == false, 'the right key reads the state')

-- ===========================================================================
-- 4. Admin actions need the login
-- ===========================================================================
r = act('{"action":"generateGrid"}')
check(r.code == 403 and (r.json and r.json.error or ''):find('not logged in', 1, true) ~= nil,
  'not logged in: an admin action is refused, and says why')
check(#calls == 0, 'and nothing runs')
r = act('{"action":"watch","id":3}')
check(r.code == 200 and callsTo('spectateDriver') == 1, 'the camera needs no login')
check(select(2, callsTo('spectateDriver')) == 3, 'and goes to the driver asked for')

login.admin, login.role = true, 'moderator'
-- Every action on the list, by its name, calls the panel's own function.
local LIST = {
  { 'startQualifying', 'startQualifying' }, { 'generateGrid', 'generateGrid' },
  { 'startCountdown', 'startCountdown' }, { 'startRace', 'startRace' },
  { 'readyAll', 'readyAll' }, { 'caution', 'caution' }, { 'restart', 'restart' },
  { 'cancelRestart', 'cancelRestart' }, { 'endSession', 'endRace' },
  { 'restartFromGrid', 'restartFromGrid' }, { 'resetSession', 'resetLeaderboard' },
}
for _, pair in ipairs(LIST) do
  local before = callsTo(pair[2])
  r = act('{"action":"' .. pair[1] .. '"}')
  check(r.code == 200 and r.json and r.json.ok == true and callsTo(pair[2]) == before + 1,
    pair[1] .. ' calls ' .. pair[2])
end
r = act('{"action":"flag","flag":"red"}')
check(r.code == 200 and select(2, callsTo('setFlag')) == 'red', 'flag red calls setFlag("red")')

-- ===========================================================================
-- 5. What is refused
-- ===========================================================================
local n0 = #calls
r = act('{"action":"flag","flag":"purple"}')
check(r.code == 400, 'a flag that is not green, yellow or red is refused')
r = act('{"action":"flag"}')
check(r.code == 400, 'and a flag action with none')
r = act('{"action":"watch","id":"x"}')
check(r.code == 400, 'a camera action with no driver id is refused')
r = act('{"action":"watch","id":2.5}')
check(r.code == 400, 'and one with a fractional id')
r = act('{"action":"extensions.unload(\\"raceManager\\")"}')
check(r.code == 400, 'Lua for an action name is just an unknown name')
r = act('{"action":"setNametags"}')
check(r.code == 400, 'an extension function off the list is refused')
r = act('{"nothing":1}')
check(r.code == 400, 'a body with no action is refused')
r = act('not json')
check(r.code == 400, 'a body that is not JSON is refused')
check(#calls == n0, 'and none of them called anything')

r = act('{"action":"' .. string.rep('a', 600) .. '"}')
check(r.code == 413, 'a body over 512 bytes is refused before it is read')
r = act('{"action":"generateGrid"}', nil, { 'Origin: http://evil.example' })
check(r.code == 403 and #calls == n0, 'a write from another site\'s page is refused')
r = act('{"action":"generateGrid"}', nil, { 'Origin: http://127.0.0.1:8128' })
check(r.code == 200, 'and one from this feed\'s own page is taken')

-- An upload in progress does not hold an action up.
S.writing = { busy = true }
r = act('{"action":"readyAll"}')
check(r.code == 200, 'an action is not queued behind an upload')
S.writing = nil

-- ===========================================================================
-- 6. The state the page draws its buttons from
-- ===========================================================================
feed.feedState({ phase = 'grid', sessionKind = 'race', flag = 'green', paceLap = true,
  pointToPoint = false, readyCheck = true, pacing = false, caution = false,
  youAreAdmin = true, resultsPath = 'C:/secret',
  drivers = { { id = 1, status = 'gridded' }, { id = 2, status = 'called' },
    { id = 3, status = 'gridded' }, { id = 4, status = 'waiting' } } })
r = state()
local st = r.json or {}
check(st.admin == true and st.role == 'moderator', 'the state says who this game is logged in as')
check(st.phase == 'grid' and st.kind == 'race' and st.flag == 'green', 'and the phase, kind and flag')
check(st.paceLap == true and st.readyCheck == true, 'and what picks the start button')
check(st.ready == 2 and st.readyTotal == 3, 'and who is ready on the grid')
check(r.body:find('secret', 1, true) == nil and r.body:find('resultsPath', 1, true) == nil,
  'nothing else from the update is passed on')
check(st.connected == true, 'and that the game is on a server')

-- ===========================================================================
-- 7. A new key, off and on, the network link, the copy
-- ===========================================================================
local old = KEY
feed.feedNewControlKey()
KEY = files['settings/raceManager/feed.json'].controlKey
check(KEY ~= old and #KEY == 20, 'New key makes a new key')
check(state(old).code == 403 and state().code == 200, 'the old link stops working, the new one works')
check(files['settings/raceManager/feed.json'].styleKey == saved.styleKey, 'the style key is untouched')

feed.feedSetControl(false)
check(request('GET', '/control').code == 404 and lastStatus().urls.control == nil,
  'turned off, the page goes and the panel loses the link')
feed.feedSetControl(true)
check(files['settings/raceManager/feed.json'].controlKey == KEY, 'turned on again, the same key')

feed.feedSet(nil, nil, true)
check(lastStatus().urls.lanControl == 'http://192.168.1.50:8128/control#key=' .. KEY,
  'with the network allowed, the panel gets the network link')
feed.feedCopyControl(true)
check(clipboard == lastStatus().urls.lanControl, 'Copy network link copies it')
check(copyPushes[#copyPushes].copied == true and copyPushes[#copyPushes].what == 'control',
  'and the panel hears it was race control\'s link')
feed.feedCopyControl(false)
check(clipboard == lastStatus().urls.control, 'Copy link copies this PC\'s')

-- ===========================================================================
-- 8. The lockout
-- ===========================================================================
for _ = 1, 10 do state('cccccccccccccccccccc') end
check(state().code == 429, 'ten wrong keys shut race control for a minute')
check(act('{"action":"readyAll"}').code == 429, 'actions too')
for _ = 1, 61 * 20 do feed.feedUpdate(0.05) end
check(state().code == 200, 'and it opens again after the minute')

-- ===========================================================================
-- 9. Settings from disk: on without a key is off
-- ===========================================================================
feed.feedStop('unload')
files['settings/raceManager/feed.json'] = { on = true, port = 8128, control = true }
local feed2 = dofile('lua/ge/extensions/raceManager/feed.lua')
feed2.init({ build = '9.9.9', ext = ext, isAdmin = function () return true end })
feed2.feedStatus()
check(lastStatus().control == false, 'a saved "on" with no key reads as off')
feed2.feedStop('unload')

-- ===========================================================================
-- 10. The wiring: the extension, the page, the panel, the docs
-- ===========================================================================
local function slurp(p)
  local f = assert(io.open(p, 'r'))
  local s = f:read('*a')
  f:close()
  return s
end
local ext_src = slurp('lua/ge/extensions/raceManager.lua')
for _, pair in ipairs(LIST) do
  check(ext_src:find('function M%.' .. pair[2] .. '%(') ~= nil, 'the extension has M.' .. pair[2])
end
check(ext_src:find('function M%.setFlag%(') and ext_src:find('function M%.spectateDriver%('),
  'and M.setFlag and M.spectateDriver')
for _, name in ipairs({ 'feedSetControl', 'feedNewControlKey', 'feedCopyControl' }) do
  check(ext_src:find("'" .. name .. "'", 1, true) ~= nil, 'the extension exports ' .. name)
end
check(ext_src:find('ext = M,', 1, true) ~= nil, 'and hands the feed its functions')

local page = slurp('ui/modules/apps/RaceManager/control.html')
check(page:find('innerHTML', 1, true) == nil, 'the page never writes HTML from data')
check(page:find("'X-PRM-Key': KEY", 1, true) ~= nil, 'the page sends its key in the header')
check(page:find("fetch('/control'", 1, true) ~= nil, 'and posts to /control alone')
for _, name in ipairs({ 'startQualifying', 'generateGrid', 'startCountdown', 'startRace',
  'readyAll', 'caution', 'restart', 'cancelRestart', 'endSession', 'restartFromGrid',
  'resetSession', 'watch' }) do
  check(page:find("'" .. name .. "'", 1, true) ~= nil, 'the page has a button for ' .. name)
end
check(page:find("action: 'flag'", 1, true) ~= nil, 'and the flags')

local js = slurp('ui/modules/apps/RaceManager/app.js')
for _, call in ipairs({ 'raceManager.feedSetControl(', 'raceManager.feedCopyControl(',
  'raceManager.feedNewControlKey()' }) do
  check(js:find(call, 1, true) ~= nil, 'the panel calls ' .. call)
end
local doc = slurp('docs/REFERENCE.md')
check(doc:find('### Race control page', 1, true) ~= nil, 'REFERENCE documents the race control page')
local wf = slurp('.github/workflows/package.yml')
check(wf:find('ui/modules/apps/RaceManager/control.html', 1, true) ~= nil,
  'the release check requires the page in the package')

print(string.format('race_control_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
