-- Headless test for THE BROADCAST FEED (lua/ge/extensions/raceManager/feed.lua):
-- the race served on the streamer's own PC for overlay software.
--
--   * Off as shipped: nothing is opened until it is turned on.
--   * The listener: this PC only unless LAN is on, never reuseaddr on Windows,
--     a port in use retried and then explained.
--   * HTTP: whole and split requests, the routes, CORS, HEAD, the limits, and
--     a Host from outside this PC and the local network turned away.
--   * The schema: every key always present, the app's formatting, and NOTHING
--     admin-only ever forwarded.
--   * Server-Sent Events: the latest frame wins for a slow reader, keepalives,
--     a reader that hangs up is dropped.
--   * Events, found by comparing snapshots: none on the first, each kind on its
--     own edge, a capped ring.
--   * The docs name every key (docs/REFERENCE.md, "Broadcast feed").
--
-- A fake LuaSocket stands in for the network; nothing is opened for real.
--
-- Run from the repo root: lua5.3 tests/feed_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ===========================================================================
-- A JSON reader that keeps what the feed promises: null, and [] apart from {}
-- ===========================================================================
local NULL = setmetatable({}, { __tostring = function () return 'null' end })
local ARRAY = {}
local function isArray(t) return getmetatable(t) == ARRAY end

local function parseJson(text)
  local pos = 1
  local function ws() pos = text:find('[^ \t\r\n]', pos) or (#text + 1) end
  local function str()
    assert(text:sub(pos, pos) == '"', 'string expected at ' .. pos)
    pos = pos + 1
    local out = {}
    while true do
      local c = text:sub(pos, pos)
      if c == '"' then pos = pos + 1; break end
      if c == '' then error('unterminated string') end
      if c == '\\' then
        local n = text:sub(pos + 1, pos + 1)
        if n == 'u' then
          out[#out + 1] = utf8.char(tonumber(text:sub(pos + 2, pos + 5), 16))
          pos = pos + 6
        else
          out[#out + 1] = ({ b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' })[n] or n
          pos = pos + 2
        end
      else
        assert(c:byte() >= 32, 'raw control character in a string at ' .. pos)
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(out)
  end
  local value
  function value()
    ws()
    local c = text:sub(pos, pos)
    if c == '{' then
      local t = {}
      pos = pos + 1; ws()
      if text:sub(pos, pos) == '}' then pos = pos + 1; return t end
      while true do
        ws()
        local k = str()
        ws(); assert(text:sub(pos, pos) == ':', ': expected at ' .. pos); pos = pos + 1
        t[k] = value(); ws()
        local d = text:sub(pos, pos); pos = pos + 1
        if d == '}' then return t end
        assert(d == ',', ', expected at ' .. pos)
      end
    elseif c == '[' then
      local t = setmetatable({}, ARRAY)
      pos = pos + 1; ws()
      if text:sub(pos, pos) == ']' then pos = pos + 1; return t end
      while true do
        t[#t + 1] = value(); ws()
        local d = text:sub(pos, pos); pos = pos + 1
        if d == ']' then return t end
        assert(d == ',', ', expected at ' .. pos)
      end
    elseif c == '"' then return str()
    elseif text:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true
    elseif text:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false
    elseif text:sub(pos, pos + 3) == 'null' then pos = pos + 4; return NULL
    end
    local s, e = text:find('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
    assert(s, 'bad value at ' .. pos .. ': ' .. text:sub(pos, pos + 20))
    pos = e + 1
    return tonumber(text:sub(s, e))
  end
  local v = value()
  ws()
  assert(pos > #text, 'trailing data at ' .. pos)
  return v
end

-- ===========================================================================
-- A fake LuaSocket
-- ===========================================================================
local fake = {
  created = 0, servers = {}, pending = {},
  bindError = nil,        -- every bind fails with this while set
}

local function newClient(chunks, sendCap)
  local c = { inq = chunks or {}, out = {}, closed = false, peerClosed = false,
              sendCap = sendCap, opts = {} }
  function c:settimeout() end
  function c:setoption(k, v) self.opts[k] = v; return 1 end
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
    local avail = #data - i + 1
    local n = self.sendCap and math.min(self.sendCap, avail) or avail
    if n > 0 then self.out[#self.out + 1] = data:sub(i, i + n - 1) end
    if n < avail then return nil, 'timeout', i + n - 1 end
    return #data
  end
  function c:close() self.closed = true end
  function c:output() return table.concat(self.out) end
  return c
end

local function newServer()
  local s = { opts = {}, closed = false }
  function s:setoption(k, v) self.opts[k] = v; return 1 end
  function s:bind(host, port)
    if fake.bindError then return nil, fake.bindError end
    self.host, self.port = host, port
    return 1
  end
  function s:listen(n) self.backlog = n; return 1 end
  function s:settimeout() end
  function s:accept()
    if self.closed then return nil, 'closed' end
    local c = table.remove(fake.pending, 1)
    if c then return c end
    return nil, 'timeout'
  end
  function s:close() self.closed = true end
  return s
end

local socketModule = {
  tcp = function ()
    fake.created = fake.created + 1
    local s = newServer()
    fake.servers[#fake.servers + 1] = s
    return s
  end,
  udp = function ()
    return {
      setpeername = function () return 1 end,
      getsockname = function () return '192.168.1.50', 50000 end,
      close = function () end,
    }
  end,
}
package.preload.socket = function () return socketModule end

-- ===========================================================================
-- BeamNG stubs
-- ===========================================================================
jit = { os = 'Windows' }
local files = {}
jsonReadFile = function (path) return files[path] end
jsonWriteFile = function (path, data) files[path] = data; return true end
local statusPushes = {}
local copyPushes = {}
guihooks = { trigger = function (name, data)
  if name == 'RaceManagerFeed' then statusPushes[#statusPushes + 1] = data end
  if name == 'RaceManagerFeedCopy' then copyPushes[#copyPushes + 1] = data end
end }
log = function () end
local overlayOnDisk = true
FS = { fileExists = function (_, path) return overlayOnDisk and path:find('overlay.html', 1, true) ~= nil end }
readFile = function (path)
  if path:find('overlay.html', 1, true) then return '<!doctype html><title>PRM overlay</title>' end
end

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local function loadFeed()
  local f = dofile('lua/ge/extensions/raceManager/feed.lua')
  f.init({ build = '9.9.9' })
  return f
end

local feed = loadFeed()
local S = feed.feedDebug()
local function lastStatus() return statusPushes[#statusPushes] end
local function pump(n)
  for _ = 1, n or 1 do feed.feedUpdate(0.05) end
end
local function currentServer() return fake.servers[#fake.servers] end

-- An HTTP exchange: the request goes in, the reader hangs up after the answer.
local function parseResponse(raw)
  local headEnd = raw:find('\r\n\r\n', 1, true)
  if not headEnd then return { raw = raw } end
  local head = raw:sub(1, headEnd - 1)
  local r = { raw = raw, body = raw:sub(headEnd + 4), headers = {} }
  r.code = tonumber(head:match('^HTTP/1%.1 (%d+)'))
  for k, v in head:gmatch('\r\n([^:\r\n]+):%s*([^\r\n]*)') do r.headers[k:lower()] = v end
  return r
end
local function exchange(raw, chunks)
  local c = newClient(chunks or { raw })
  fake.pending[#fake.pending + 1] = c
  pump(6)
  c.peerClosed = true
  pump(2)
  return parseResponse(c:output()), c
end
local function get(path, hostHeader, method)
  return exchange(string.format('%s %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: test\r\n\r\n',
    method or 'GET', path, hostHeader or '127.0.0.1:8128'))
end
local function live()
  local r = get('/live.json')
  return parseJson(r.body), r
end

-- ===========================================================================
-- A race, as RM_Update brings it (admin-only fields included, as an admin's
-- targeted send carries them)
-- ===========================================================================
local function race(over)
  local d = {
    rmProtocol = 2, serverBuild = '0.27.0', phase = 'racing', sessionKind = 'race',
    sessionLaps = 5, totalLaps = 5, raceMode = 'laps', flag = 'green',
    jokerEnabled = true, entrants = 6, raceClock = 125.4, raceTime = 140,
    layoutName = 'Club Circuit', pointToPoint = false, paceLap = false, pacing = false,
    caution = false, cautionPending = false, restartPending = false, finalLap = false,
    qualiOutLap = false, heatCount = 0,
    bestLapPid = 1, bestLapTime = 83.456,
    -- Never to be forwarded:
    youAreAdmin = true, youRole = 'admin', resultsPath = 'C:/Users/secret/results',
    resultsSave = { server = true, admins = true }, onlineFeatures = { on = true },
    prmUpdate = { latest = '1.0.0' }, prmDiscord = { webhookTail = '1234' },
    cautionPasses = { { passer = 'Bob', passed = 'Cara' } },
    drivers = {
      { id = 1, name = 'Alice', alias = 'Ace', status = 'racing', position = 1, gridPos = 3,
        currentLap = 3, lastLap = 83.456, lastLapOn = 2, raceBest = 83.456, lapsLed = 2,
        jokerTaken = 1, jokerLap = 2, resets = 1 },
      { id = 2, name = 'Bob', status = 'racing', position = 2, gridPos = 1, currentLap = 3,
        gap = 1.234, intv = 1.234, lastLap = 84.0, lastLapOn = 2, raceBest = 84.0,
        jokerTaken = 2, jokerLap = 3, pitStops = 1, down = 0, idown = 0 },
      { id = 3, name = 'Cara', status = 'racing', position = 3, gridPos = 2, currentLap = 3,
        gap = 62.345, intv = 61.11, lastLapOn = 2, down = 0, idown = 0, penaltySeconds = 5 },
      { id = 4, name = 'Dan', status = 'racing', position = 4, gridPos = 4, currentLap = 2,
        gap = 90, intv = 20, down = 1, idown = 1, lastLapOn = 1 },
      { id = 5, name = 'Eve', status = 'racing', position = 5, gridPos = 5, currentLap = 1,
        gap = 150, intv = 30, down = 2, idown = 1 },
      { id = 6, name = 'Fay', status = 'dnf', outReason = 'retired', position = 6, gridPos = 6,
        currentLap = 1 },
      { id = 0, name = 'Admin', status = 'waiting', spectating = true },
    },
  }
  for k, v in pairs(over or {}) do d[k] = v end
  return d
end
local function rowOf(state, id)
  for _, r in ipairs(state.drivers) do if r.id == id then return r end end
end
local function driver(doc, id)
  for _, r in ipairs(doc.drivers) do if r.id == id then return r end end
end
local function copy(t)
  if type(t) ~= 'table' then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end

-- ===========================================================================
-- 1. Off as shipped
-- ===========================================================================
feed.feedBoot()
pump(5)
check(fake.created == 0, 'off as shipped: no socket is opened at boot')
feed.feedState(race())
check(fake.created == 0, 'and a race arriving opens none either')
feed.feedStatus()
check(lastStatus() and lastStatus().on == false and lastStatus().running == false,
  'the panel hears it is off')
check(lastStatus().port == 8128, 'on the default port 8128')

-- ===========================================================================
-- 2. On: this PC only, no reuseaddr on Windows, saved
-- ===========================================================================
feed.feedSet(true)
local srv = currentServer()
check(fake.created == 1 and srv.host == '127.0.0.1' and srv.port == 8128,
  'turned on, it listens on 127.0.0.1:8128 (got ' .. tostring(srv and srv.host) .. ')')
check(srv.opts.reuseaddr == nil, 'never reuseaddr on Windows (it lets a second program share the port)')
check(files['settings/raceManager/feed.json'] and files['settings/raceManager/feed.json'].on == true,
  'the setting is saved in the user folder')
local st = lastStatus()
check(st.running == true and st.error == nil, 'the panel hears it is running')
check(st.urls.json == 'http://127.0.0.1:8128/live.json'
  and st.urls.tower == 'http://127.0.0.1:8128/overlay?view=tower'
  and st.urls.stream == 'http://127.0.0.1:8128/stream', 'and is given the URLs to copy')
check(st.urls.bannerTicker == 'http://127.0.0.1:8128/overlay?view=banner'
  .. '&show=logo,flag,session,lap,time|leader,margin,fastest|order',
  'including the banner as a ticker, ready to paste')
check(st.urls.lan == nil, 'with no LAN address while LAN is off')

-- ===========================================================================
-- 3. The race, held while it was off, is there at once
-- ===========================================================================
local doc, resp = live()
check(resp.code == 200, '/live.json answers 200')
check(resp.headers['content-type'] == 'application/json; charset=utf-8', 'as JSON')
check(tonumber(resp.headers['content-length']) == #resp.body, 'with a true Content-Length')
check(resp.headers['access-control-allow-origin'] == '*', 'readable from any overlay page (CORS)')
check(resp.headers['cache-control'] == 'no-store', 'never cached')
check(doc.feed == 1 and doc.source == 'Phoenix Race Manager', 'schema 1, named')
check(doc.build == '9.9.9' and doc.serverBuild == '0.27.0', 'both builds stamped')
check(doc.connected == true, 'connected: the race held while off was used')
check(type(doc.seq) == 'number' and doc.seq >= 1 and type(doc.epoch) == 'number', 'seq and epoch')

-- NOTHING ADMIN-ONLY, anywhere in the body.
for _, secret in ipairs({ 'youAreAdmin', 'youRole', 'resultsPath', 'C:/Users/secret',
    'resultsSave', 'onlineFeatures', 'prmUpdate', 'prmDiscord', 'webhookTail',
    'cautionPasses', 'rmProtocol' }) do
  check(not resp.body:find(secret, 1, true), 'the feed never forwards ' .. secret)
end

-- Every key, always present.
local schema = feed.SCHEMA_KEYS
for _, k in ipairs(schema.session) do
  check(doc.session[k] ~= nil, 'session.' .. k .. ' is always present')
end
check(#doc.drivers == 6, 'six drivers: the spectator is counted, not listed (got ' .. #doc.drivers .. ')')
check(doc.session.spectators == 1, 'one spectator')
for _, row in ipairs(doc.drivers) do
  for _, k in ipairs(schema.drivers) do
    check(row[k] ~= nil, 'drivers[' .. tostring(row.id) .. '].' .. k .. ' is always present')
  end
end
check(isArray(doc.drivers) and isArray(doc.grid) and isArray(doc.events), 'lists are lists')
check(#doc.events == 0, 'no events from the first snapshot (no replaying the race as news)')

-- The session.
local s = doc.session
check(s.phase == 'racing' and s.phaseText == 'Racing' and s.kind == 'race' and s.mode == 'laps',
  'phase, its words, kind and mode')
check(s.lap == 3 and s.lapTarget == 5 and s.lapText == '3/5' and s.lapsToGo == 3,
  'the leader\'s lap: 3/5, three to go counting this one')
check(s.flag == 'green' and s.flagText == 'GREEN FLAG', 'green flag')
check(s.clock == 125.4 and s.clockText == '02:05', 'the race clock, mm:ss')
check(s.layout == 'Club Circuit', 'the layout')
check(s.jokerEnabled == true and s.heat == NULL, 'joker on, no heats')
check(s.fastestLap ~= NULL and s.fastestLap.id == 1 and s.fastestLap.name == 'Ace'
  and s.fastestLap.text == '1:23.456', 'the fastest lap, by display name')
check(s.gridSource == 'locked', 'the grid is the real one')

-- The drivers, formatted as the app formats them.
local a, b, c, dn, e, f = driver(doc, 1), driver(doc, 2), driver(doc, 3), driver(doc, 4),
  driver(doc, 5), driver(doc, 6)
check(a.name == 'Ace' and a.account == 'Alice', 'the display name first, the account beside it')
check(a.posText == 'P1' and a.gapText == '' and a.intervalText == '', 'the leader has no gap')
check(a.gained == 2 and a.gainedText == '+2', 'P3 on the grid to P1: +2')
check(b.gained == -1 and b.gainedText == '-1', 'P1 to P2: -1')
check(a.lastLap == 83.456 and a.lastLapText == '1:23.456', 'last lap m:ss.sss')
check(a.bestLapText == '1:23.456' and a.fastest == true and b.fastest == false, 'best lap, fastest marked')
check(a.jokerText == 'L2' and b.jokerText == '×2!' and c.jokerText == '', 'joker: L2, ×2!, none')
check(b.pitStops == 1 and a.pitStops == 0, 'pit stops, zero not null')
check(doc.session.pitStopsRequired == 0 and b.pitStopsCounted == 0 and b.pitStopsText == '1'
  and a.pitStopsText == '', 'no stops required: the stops made, as text')
-- Mandatory stops: the number in force, each car's counted stops, "1/2".
do
  local m = race({ pitStopRule = { required = 2, missed = 'time', seconds = 30, active = 2 } })
  rowOf(m, 2).pitCounted = 1
  feed.feedState(m)
  local d2 = live()
  local mb, ma = driver(d2, 2), driver(d2, 1)
  check(d2.session.pitStopsRequired == 2, 'stops required: the number in force')
  check(mb.pitStopsCounted == 1 and mb.pitStopsText == '1/2' and ma.pitStopsText == '0/2',
    'each car: the stops that count, and 1/2 as the timing table says it')
  local q = race({ sessionKind = 'quali', pitStopRule = { required = 2, active = 0 } })
  feed.feedState(q)
  check(live().session.pitStopsRequired == 0, 'none in qualifying')
  feed.feedState(race())
end
check(b.gapText == '+1.2' and b.intervalText == '+1.2', 'a gap under a minute: +s.s')
check(c.gapText == '+1:02.3', 'over a minute: +m:ss.s')
check(dn.gapText == '+1 LAP' and dn.lapsDown == 1, 'a lap down: +1 LAP')
check(e.gapText == '+2 LAPS' and e.intervalText == '+1 LAP', 'two down to the leader, one to the car ahead')
check(c.penalty == 5 and a.resets == 1, 'penalty seconds and resets')
check(f.out == true and f.posText == '-' and f.gapText == '' and f.statusText == 'DNF'
  and f.outReason == 'retired', 'a DNF: out, no place, no gap, the reason')
check(a.lapText == '3/5' and dn.lapText == '2/5', 'each driver\'s lap')

-- The grid, sorted by slot.
check(#doc.grid == 6 and doc.grid[1].slot == 1 and doc.grid[1].id == 2
  and doc.grid[2].id == 3 and doc.grid[3].id == 1, 'the grid, slot order')

-- The parts.
local r = get('/drivers.json')
local drivers = parseJson(r.body)
check(r.code == 200 and isArray(drivers) and #drivers == 6, '/drivers.json is the list at the root')
r = get('/grid.json')
check(isArray(parseJson(r.body)), '/grid.json too')
r = get('/session.json')
check(parseJson(r.body).phase == 'racing', '/session.json is the session')
r = get('/events.json')
check(isArray(parseJson(r.body)), '/events.json is the event list')

-- ===========================================================================
-- 4. HTTP: routes, methods, limits, Host
-- ===========================================================================
r = get('/nope')
check(r.code == 404, 'an unknown path is 404')
r = get('/live.json', nil, 'POST')
check(r.code == 405 and r.headers.allow == 'GET, HEAD, OPTIONS', 'POST is 405: read only')
r = get('/live.json', nil, 'OPTIONS')
check(r.code == 204 and r.headers['access-control-allow-private-network'] == 'true'
  and r.headers['access-control-allow-methods'] == 'GET, HEAD, OPTIONS', 'OPTIONS answers the preflight')
r = get('/live.json', nil, 'HEAD')
check(r.code == 200 and r.body == '' and tonumber(r.headers['content-length']) > 0,
  'HEAD: the headers, no body')
r = get('/live.json?cb=123')
check(r.code == 200 and parseJson(r.body).feed == 1, 'a query string is ignored')
r = get('/')
check(r.code == 200 and r.body:find('/overlay?view=tower', 1, true), 'the index links the overlays')
r = get('/overlay?view=tower')
check(r.code == 200 and r.headers['content-type'] == 'text/html; charset=utf-8'
  and r.body:find('PRM overlay', 1, true), 'the overlay page is served from the game\'s files')
r = get('/favicon.ico')
check(r.code == 204, 'no favicon, no error')

for _, h in ipairs({ 'localhost:8128', '127.0.0.1', '192.168.1.5:8128', 'streampc',
    'streampc.local', '[::1]:8128', 'box.home.arpa' }) do
  check(get('/live.json', h).code == 200, 'Host ' .. h .. ' is this PC or the local network')
end
for _, h in ipairs({ 'evil.example', 'evil.example:8128', 'attacker.com' }) do
  check(get('/live.json', h).code == 403, 'Host ' .. h .. ' is turned away (DNS rebinding)')
end
r = exchange('GET /live.json HTTP/1.0\r\n\r\n')
check(r.code == 200, 'no Host at all (HTTP/1.0) is answered')

-- A request in three pieces.
r = exchange(nil, { 'GET /live.j', 'son HTTP/1.1\r\nHo', 'st: 127.0.0.1\r\n\r\n' })
check(r.code == 200 and parseJson(r.body).feed == 1, 'a request split over three reads')

-- Too big a head.
r = exchange('GET /live.json HTTP/1.1\r\nX-Pad: ' .. string.rep('a', 9000) .. '\r\n\r\n')
check(r.code == 431, 'a head over 8 KB is 431')

-- A reader that never finishes its request is dropped.
do
  local slow = newClient({ 'GET /live.json HTTP/1.1\r\n' })
  fake.pending[#fake.pending + 1] = slow
  pump(4)
  check(not slow.closed, 'a request still coming is waited for')
  pump(120)
  check(slow.closed and slow:output() == '', 'and dropped after 5 s with nothing sent')
end

-- A served reader that does not hang up is closed for it.
do
  local c2 = newClient({ 'GET /live.json HTTP/1.1\r\n\r\n' })
  fake.pending[#fake.pending + 1] = c2
  pump(4)
  check(parseResponse(c2:output()).code == 200 and not c2.closed,
    'served: the reader is given the chance to hang up first')
  pump(50)
  check(c2.closed, 'and closed for it after 2 s')
end

-- ===========================================================================
-- 5. Server-Sent Events
-- ===========================================================================
local sse = newClient({ 'GET /stream HTTP/1.1\r\nHost: localhost:8128\r\n\r\n' })
fake.pending[#fake.pending + 1] = sse
pump(2)
local out = sse:output()
check(out:find('HTTP/1.1 200 OK\r\n', 1, true) == 1, 'the stream answers 200')
check(out:find('Content-Type: text/event-stream; charset=utf-8', 1, true), 'as an event stream')
check(out:find('retry: 2000\n\n', 1, true), 'with a reconnect delay')
local function frames(text)
  local list = {}
  for id, data in text:gmatch('id: (%d+)\nevent: state\ndata: ([^\n]*)\n\n') do
    list[#list + 1] = { id = tonumber(id), doc = parseJson(data) }
  end
  return list
end
local fr = frames(out)
check(#fr == 1 and fr[1].doc.feed == 1, 'and the current snapshot at once')
check(not sse.closed, 'the stream stays open')

-- A new state goes out as a frame.
local st2 = race({ raceClock = 126.0 })
feed.feedState(st2)
pump(1)
fr = frames(sse:output())
check(#fr == 2 and fr[2].id > fr[1].id and fr[2].doc.session.clock == 126,
  'each change is a frame, ids rising')

-- Unchanged state: no frame.
feed.feedState(copy(st2))
pump(1)
check(#frames(sse:output()) == 2, 'the same state again sends nothing')

-- A slow reader: blocked, then two states; only the latest goes when it drains.
sse.sendCap = 0
feed.feedState(race({ raceClock = 127.0 }))
pump(1)
feed.feedState(race({ raceClock = 128.0 }))
pump(1)
sse.sendCap = nil
pump(1)
fr = frames(sse:output())
check(#fr == 3 and fr[3].doc.session.clock == 128,
  'a slow reader skips to the latest frame (got ' .. #fr .. ' frames)')

-- A frame half sent when a newer one arrives: finished first, then the newer.
sse.sendCap = 40
feed.feedState(race({ raceClock = 129.0 }))
pump(1)
sse.sendCap = 0
feed.feedState(race({ raceClock = 130.0 }))
pump(1)
sse.sendCap = nil
pump(2)
fr = frames(sse:output())
check(#fr == 5 and fr[4].doc.session.clock == 129 and fr[5].doc.session.clock == 130,
  'a half-sent frame is finished, then the newest follows')

-- Quiet: a keepalive.
pump(320)
check(sse:output():find('\n: ka\n\n', 1, true), 'a keepalive after 15 s of quiet')

-- More than 16 readers: the next is told to wait.
local extra = {}
for i = 1, 15 do
  extra[i] = newClient({ 'GET /stream HTTP/1.1\r\n\r\n' })
  fake.pending[#fake.pending + 1] = extra[i]
end
pump(5)
check(#S.clients == 16, 'sixteen readers (got ' .. #S.clients .. ')')
local over = newClient({ 'GET /stream HTTP/1.1\r\n\r\n' })
fake.pending[#fake.pending + 1] = over
pump(1)
check(over:output():find('503', 1, true) and over.closed, 'the seventeenth gets a 503')
for i = 1, 15 do extra[i].peerClosed = true end
feed.feedState(race({ raceClock = 131.0 }))
pump(2)
check(#S.clients == 1, 'readers that hung up are dropped on the next send')
pump(60)
check(lastStatus().clients == 1 and lastStatus().streams == 1, 'and the panel hears the count')

-- ===========================================================================
-- 6. Events
-- ===========================================================================
local function lastEvents(doc0) return doc0.events end
local function findEvent(doc0, kind, id)
  for i = #doc0.events, 1, -1 do
    local ev = doc0.events[i]
    if ev.type == kind and (id == nil or ev.id == id) then return ev end
  end
end
local base = race({ raceClock = 200 })
feed.feedState(base)
local before = live()
local seq0 = before.seq

local nxt = copy(base)
nxt.raceClock = 201
local ra = rowOf(nxt, 1)
ra.lastLapOn, ra.lastLap, ra.raceBest, ra.currentLap = 3, 82.9, 82.9, 4
nxt.bestLapTime = 82.9
local rb = rowOf(nxt, 2)
rb.jokerTaken, rb.jokerLap = 3, 4
rb.pitStops = 2
local rc = rowOf(nxt, 3)
rc.penaltySeconds = 10
local rd = rowOf(nxt, 4)
rd.status, rd.outReason = 'dsq', 'contact'
feed.feedState(nxt)
doc = live()
check(doc.seq > seq0, 'seq rises')
local ev = findEvent(doc, 'lap', 1)
check(ev and ev.lap == 3 and ev.time == 82.9 and ev.timeText == '1:22.900' and ev.pb == true
  and ev.name == 'Ace' and ev.text == 'Ace: lap 3 1:22.900', 'a lap: number, time, personal best')
ev = findEvent(doc, 'fastest')
check(ev and ev.id == 1 and ev.timeText == '1:22.900', 'a new fastest lap')
ev = findEvent(doc, 'joker', 2)
check(ev and ev.lap == 4 and ev.count == 3 and ev.text == 'Bob takes the joker on lap 4', 'the joker')
ev = findEvent(doc, 'pit', 2)
check(ev and ev.stops == 2, 'a pit stop')
ev = findEvent(doc, 'penalty', 3)
check(ev and ev.seconds == 5 and ev.total == 10, 'a penalty: what was added and the total')
ev = findEvent(doc, 'out', 4)
check(ev and ev.status == 'dsq' and ev.reason == 'contact', 'out: disqualified, and why')
for i = 2, #doc.events do
  check(doc.events[i].seq > doc.events[i - 1].seq, 'event seq rises')
end
for _, e0 in ipairs(doc.events) do
  for _, k in ipairs(schema.events[e0.type]) do
    check(e0[k] ~= nil, 'event ' .. e0.type .. '.' .. k .. ' is always present')
  end
end

-- A missed mandatory pit stop at the flag ADDS to the checkpoint penalty: one
-- figure, as in the classification, and the event says what was added.
do
  local np = copy(nxt)
  rowOf(np, 3).pitStopPenalty = 30
  feed.feedState(np)
  local d = live()
  local carl
  for _, row in ipairs(d.drivers) do if row.id == 3 then carl = row end end
  check(carl and carl.penalty == 40, 'the pit stop penalty adds to the checkpoint seconds (got '
    .. tostring(carl and carl.penalty) .. ')')
  local pe = findEvent(d, 'penalty', 3)
  check(pe and pe.seconds == 30 and pe.total == 40, 'and the event adds 30 to a total of 40')
  feed.feedState(nxt)
end

-- The caution, the flag, the leader, the finish, the session.
local n2 = copy(nxt)
n2.flag, n2.cautionPending = 'yellow', true
feed.feedState(n2)
doc = live()
ev = findEvent(doc, 'caution')
check(ev and ev.state == 'called', 'a caution called')
ev = findEvent(doc, 'flag')
check(ev and ev.flag == 'yellow' and ev.from == 'green' and ev.text == 'CAUTION', 'the flag goes yellow')
local n3 = copy(n2)
n3.cautionPending, n3.caution, n3.cautionLaps = false, true, 1
feed.feedState(n3)
ev = findEvent(live(), 'caution')
check(ev and ev.state == 'out', 'the caution made official')
local n4 = copy(n3)
n4.caution, n4.flag = false, 'green'
-- Bob takes the lead.
rowOf(n4, 1).position, rowOf(n4, 2).position = 2, 1
table.sort(n4.drivers, function (x, y) return (x.position or 99) < (y.position or 99) end)
feed.feedState(n4)
doc = live()
ev = findEvent(doc, 'caution')
check(ev and ev.state == 'ended', 'the caution over')
ev = findEvent(doc, 'leader')
check(ev and ev.id == 2 and ev.prevId == 1 and ev.text == 'Bob leads, from Ace', 'a new leader')
local n5 = copy(n4)
rowOf(n5, 2).status, rowOf(n5, 2).finishTime = 'finished', 425.5
n5.flagOut = true
feed.feedState(n5)
doc = live()
ev = findEvent(doc, 'finish', 2)
check(ev and ev.position == 1 and ev.timeText == '7:05.500' and ev.text == 'Bob finishes P1', 'a finish')
check(doc.session.flag == 'checkered' and findEvent(doc, 'flag').flag == 'checkered', 'the checkered flag')
local n6 = copy(n5)
n6.phase = 'finished'
feed.feedState(n6)
ev = findEvent(live(), 'session')
check(ev and ev.from == 'racing' and ev.to == 'finished' and ev.text == 'Race Over', 'the session ends')

-- The countdown.
local grid = race({ phase = 'countdown' })
feed.feedState(grid)
feed.feedCountdown(3)
doc = live()
check(doc.session.countdown == 3, 'the countdown number rides the session')
ev = findEvent(doc, 'countdown')
check(ev and ev.count == 3, 'and each number is an event')
feed.feedCountdown(0)
check(findEvent(live(), 'go') ~= nil, 'GO')
feed.feedState(race({ phase = 'racing' }))
check(live().session.countdown == NULL, 'the number goes with the countdown')

-- The ring holds 30.
for i = 1, 40 do
  local t = race({ raceClock = 300 + i })
  rowOf(t, 2).pitStops = 10 + i
  feed.feedState(t)
end
doc = live()
check(#doc.events == 30, 'the ring holds the last 30 events (got ' .. #doc.events .. ')')

-- ===========================================================================
-- 7. Formatting cases
-- ===========================================================================
-- Behind the pace car.
local paced = race({ paceLap = true, pacing = true, flag = 'yellow' })
for _, row in ipairs(paced.drivers) do row.outLap = true; row.currentLap = 1 end
feed.feedState(paced)
doc = live()
check(driver(doc, 1).lapText == 'PACE' and doc.session.lapText == 'PACE', 'the formation lap reads PACE')
check(doc.session.flag == 'yellow' and doc.session.flagText == 'PACE LAP', 'under the pace car')
local pacedOn = race({ paceLap = true })
rowOf(pacedOn, 1).currentLap = 4
feed.feedState(pacedOn)
check(driver(live(), 1).lapText == '3/5', 'and a racing lap is crossings minus the formation')

-- A timed race: no target until the last lap is known.
local timed = race({ raceMode = 'timed', raceTimeLimit = 600, raceLeft = 61.2 })
feed.feedState(timed)
doc = live()
check(doc.session.lapTarget == NULL and doc.session.lapText == '3' and doc.session.mode == 'timed',
  'a timed race has no lap target')
check(doc.session.timeLeft == 61.2 and doc.session.timeLeftText == '01:02', 'time left, rounded up')
timed.lastLapNum = 7
feed.feedState(timed)
check(live().session.lapTarget == 7, 'until the last lap is set')

-- White flag on the last lap.
local white = race()
rowOf(white, 1).currentLap = 5
feed.feedState(white)
check(live().session.flag == 'white', 'the leader on the last lap: white')
feed.feedState(race({ flag = 'red' }))
check(live().session.flag == 'red' and live().session.flagText == 'RED FLAG', 'red outranks it')

-- Qualifying: gaps between best laps.
local q = race({ sessionKind = 'quali', phase = 'qualifying', qualiOutLap = true, sessionLaps = 3,
  qualiTime = 75, qualiTimeLimit = 600, qualiLeft = 525 })
q.drivers = {
  { id = 1, name = 'Alice', status = 'qualifying', position = 1, currentLap = 3, qualiBest = 60.0 },
  { id = 2, name = 'Bob', status = 'qualifying', position = 2, currentLap = 2, qualiBest = 61.25 },
  { id = 3, name = 'Cara', status = 'qualifying', position = 3, currentLap = 1, outLap = true },
}
feed.feedState(q)
doc = live()
check(driver(doc, 2).gapText == '+1.3' and driver(doc, 2).intervalText == '+1.3',
  'qualifying gap: best lap to best lap')
check(driver(doc, 1).gapText == '' and driver(doc, 3).gapText == '', 'none for pole or no time')
check(driver(doc, 1).lapText == '2/3' and driver(doc, 3).lapText == 'OUT', 'qualifying laps: 2/3, OUT')
check(driver(doc, 1).bestLapText == '1:00.000' and driver(doc, 1).gained == NULL,
  'best lap is the qualifying lap; no places gained in qualifying')
check(doc.session.phaseText == 'Qualifying' and doc.session.lapText == '', 'no shared lap in qualifying')
check(doc.session.timeLeftText == '08:45', 'qualifying time left')

-- The provisional grid from qualifying, before one is called.
local waiting = race({ phase = 'waiting' })
waiting.drivers = {
  { id = 1, name = 'Alice', status = 'waiting', qualiBest = 60.0 },
  { id = 2, name = 'Bob', status = 'waiting', qualiBest = 61.0 },
  { id = 3, name = 'Cara', status = 'waiting' },
}
feed.feedState(waiting)
doc = live()
check(doc.session.gridSource == 'quali' and #doc.grid == 2 and doc.grid[1].id == 1
  and doc.grid[2].qualiBestText == '1:01.000', 'a provisional grid in qualifying order')

-- Encoder edges.
local weird = race()
rowOf(weird, 1).alias = 'A "quoted"\n\tname\1'
rowOf(weird, 2).gap = 0 / 0
rowOf(weird, 3).gap = 1 / 3
feed.feedState(weird)
local raw = get('/live.json').body
doc = parseJson(raw)
check(driver(doc, 1).name == 'A "quoted"\n\tname\1', 'quotes, newlines and control characters survive')
check(driver(doc, 2).gap == NULL, 'NaN is null, not invalid JSON')
check(raw:find('"gap":0.333', 1, true) ~= nil, 'three decimals at most')

-- No car, no grid: a row the server marks unlisted (left off for want of a car
-- and never joined) is on no board, the overlay included: not listed, and not
-- counted as a spectator either.
local leftOff = race()
leftOff.drivers[#leftOff.drivers + 1] = { id = 9, name = 'Gus', status = 'waiting',
  unlisted = true, noCar = true }
feed.feedState(leftOff)
doc = live()
check(driver(doc, 9) == nil, 'an unlisted row is not on the overlay')
check(#doc.drivers == 6 and doc.session.spectators == 1,
  'and is neither listed nor counted (got ' .. #doc.drivers .. ' listed, '
    .. tostring(doc.session.spectators) .. ' spectating)')

-- ===========================================================================
-- 8. LAN, Linux, ports
-- ===========================================================================
feed.feedSet(nil, nil, true)
srv = currentServer()
check(srv.host == '0.0.0.0' and srv.port == 8128, 'LAN on: listens on every interface')
st = lastStatus()
check(st.lan == true and st.lanIp == '192.168.1.50' and st.urls.lan == 'http://192.168.1.50:8128'
  and st.urls.lanOverlay == 'http://192.168.1.50:8128/overlay', 'and says the address other PCs use')
check(fake.servers[#fake.servers - 1].closed, 'the old listener was closed first')
feed.feedSet(nil, nil, false)
check(currentServer().host == '127.0.0.1', 'LAN off: this PC only again')

jit.os = 'Linux'
feed.feedSet(true, 8200)
check(currentServer().opts.reuseaddr == true and currentServer().port == 8200,
  'elsewhere reuseaddr is set (TIME_WAIT after a reload), on the new port')
jit.os = 'Windows'

local pushes = #statusPushes
feed.feedSet(nil, 80)
check(lastStatus().error and lastStatus().error:find('1024', 1, true) and #statusPushes > pushes,
  'a port under 1024 is refused and said why')
check(files['settings/raceManager/feed.json'].port == 8200, 'and not saved')
feed.feedSet(nil, 'abc')
check(lastStatus().error ~= nil, 'nor a port that is not a number')

fake.bindError = 'address already in use'
feed.feedSet(true, 9000)
check(lastStatus().starting == true and not lastStatus().running, 'a port in use: retried')
pump(120)
check(lastStatus().starting == false and lastStatus().running == false
  and lastStatus().error == 'Port 9000 is in use by another program. Pick another port.',
  'then explained (got ' .. tostring(lastStatus().error) .. ')')
fake.bindError = 'permission denied'
feed.feedSet(true, 9001)
pump(10)
check(lastStatus().error and lastStatus().error:find('reserved', 1, true),
  'a port Windows keeps for itself is explained as such')
fake.bindError = nil
feed.feedSet(true, 8128)
check(lastStatus().running == true and lastStatus().error == nil, 'a free port: running, error cleared')

-- ===========================================================================
-- 9. Leaving, stopping, reloading
-- ===========================================================================
feed.feedOffline()
doc = live()
check(doc.connected == false and doc.session.phase == 'offline' and #doc.drivers == 0
  and #doc.grid == 0, 'left the server: not connected, nothing listed')
check(findEvent(doc, 'session').to == 'offline', 'and said as an event')

local reader = newClient({ 'GET /stream HTTP/1.1\r\n\r\n' })
fake.pending[#fake.pending + 1] = reader
pump(2)
local listener = currentServer()
feed.feedStop('unload')
check(listener.closed and reader.closed and #S.clients == 0, 'unload closes the listener and every reader')
check(files['settings/raceManager/feed.json'].on == true, 'and leaves the setting on')
local created = fake.created
pump(10)
check(fake.created == created, 'and opens nothing more')
feed.feedBoot()
check(fake.created == created + 1 and lastStatus().running, 'the next load brings it back')

-- A reloaded copy closes the old listener before taking the port.
local oldListener = currentServer()
local feed2 = loadFeed()
check(oldListener.closed, 'a reloaded module closes the listener the old copy left')
feed2.feedBoot()
check(currentServer() ~= oldListener and not currentServer().closed, 'and listens itself')
feed2.feedStop('unload')

-- The overlay missing from the install: a page that points at the data.
overlayOnDisk = false
feed = feed2
S = feed.feedDebug()
feed.feedBoot()
r = get('/overlay')
check(r.code == 200 and r.body:find('/live.json', 1, true), 'no overlay file: a page that points at the data')
feed.feedStop('unload')

-- ===========================================================================
-- 9b. The look: teams, the style key, writes, the overlay folder, `style`
-- ===========================================================================
-- The game's JSON reader, as the feed uses it for a POSTed style.
local function plain(v)
  if v == NULL then return nil end
  if type(v) ~= 'table' then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = plain(x) end
  return o
end
jsonDecode = function (text) return plain(parseJson(text)) end

-- The overlay folder, in memory.
local Style = feed.style
local mem = {}
Style.files = {
  list = function ()
    local out = {}
    for n, b in pairs(mem) do out[#out + 1] = { name = n, size = #b } end
    table.sort(out, function (a, b) return a.name < b.name end)
    return out
  end,
  read = function (n) return mem[n] end,
  write = function (n, b) mem[n] = b; return true end,
  remove = function (n) mem[n] = nil; return true end,
}
-- The style page, bundled.
FS.fileExists = function (_, path)
  return path:find('style.html', 1, true) ~= nil or (overlayOnDisk and path:find('overlay.html', 1, true) ~= nil)
end
local realReadFile = readFile
readFile = function (path)
  if path:find('style.html', 1, true) then return '<!doctype html><title>PRM style</title>' end
  return realReadFile(path)
end

feed.feedBoot()
check(lastStatus().running, 'the feed is back up')
local KEY = files['settings/raceManager/feed.json'].styleKey
check(type(KEY) == 'string' and KEY:match('^[a-z0-9]+$') and #KEY == 20, 'a 20-character style key is kept with the settings')
check(lastStatus().urls.style == 'http://127.0.0.1:8128/style#key=' .. KEY
  and lastStatus().urls.styleBase == 'http://127.0.0.1:8128/style',
  'the panel gets the editor link, the key in its fragment (never sent in a request)')

-- A request with a body, as a browser or curl sends it.
local function request(method, path, body, headers, opts)
  opts = opts or {}
  local h = { string.format('%s %s HTTP/1.1', method, path), 'Host: ' .. (opts.host or '127.0.0.1:8128') }
  for _, kv in ipairs(headers or {}) do h[#h + 1] = kv end
  if body and not opts.noLength then h[#h + 1] = 'Content-Length: ' .. (opts.length or #body) end
  local raw = table.concat(h, '\r\n') .. '\r\n\r\n' .. (body or '')
  local chunks = { raw }
  if opts.pieces then
    chunks = {}
    local size = math.ceil(#raw / opts.pieces)
    for i = 1, #raw, size do chunks[#chunks + 1] = raw:sub(i, i + size - 1) end
  end
  local c = newClient(chunks)
  fake.pending[#fake.pending + 1] = c
  pump(opts.pumps or 8)
  c.peerClosed = true
  pump(2)
  return parseResponse(c:output()), c
end
local function postStyle(t, headers, opts)
  local r = request('POST', '/style.json' .. ((opts and opts.query) or ''), t, headers or { 'X-PRM-Key: ' .. KEY }, opts)
  return r, (r.body and r.body:sub(1, 1) == '{') and parseJson(r.body) or nil
end
local function styleNow() return parseJson(get('/style.json').body) end

-- The editor page: served, and never inside another site's frame (it saves
-- with the key it holds). The overlay stays frameable, for the editor's own
-- previews and pages that embed it.
do
  local page = get('/style')
  check(page.code == 200 and page.body:find('PRM style', 1, true), '/style serves the editor page')
  check(page.headers['content-security-policy'] == "frame-ancestors 'none'"
    and page.headers['x-frame-options'] == 'DENY', 'which no other site may frame')
  check(get('/overlay').headers['x-frame-options'] == nil, 'the overlay may still be framed')
end

-- The style as shipped: the overlay's own look.
local st0 = styleNow()
check(st0.v == 1 and st0.colors.accent == '#ff7a1a' and st0.opacity == 0.86 and st0.bar == 'team'
  and st0.labels.leader == 'LEADER' and isArray(st0.classColors) == false, '/style.json: the defaults')
local seq0 = live().styleSeq

-- The key.
local r = postStyle('{"title":"x"}', {})
check(r.code == 403, 'no key: 403')
r = postStyle('{"title":"x"}', { 'X-PRM-Key: wrongwrongwrongwrong' })
check(r.code == 403, 'a wrong key: 403')
r = postStyle('{"title":"By query"}', {}, { query = '?key=' .. KEY })
check(r.code == 200 and styleNow().title == 'By query', 'the key in the query works')
r = postStyle('{"title":"x"}', { 'X-PRM-Key: ' .. KEY, 'Origin: http://evil.example' })
check(r.code == 403, 'another site\'s Origin is refused even with the key')
r = postStyle('{"title":"Same origin"}', { 'X-PRM-Key: ' .. KEY, 'Origin: http://127.0.0.1:8128' })
check(r.code == 200, 'this feed\'s own page is allowed')
r = request('POST', '/live.json', '{}', { 'X-PRM-Key: ' .. KEY })
check(r.code == 405 and r.headers.allow == 'GET, HEAD, OPTIONS', 'the race itself stays read only')

-- Checking what comes in.
local res
r, res = postStyle('{"colors":{"accent":"#00FF00","bg":"red"},"opacity":5,"bar":"class",'
  .. '"bogus":1,"title":"<b>Hi</b>","logo":"javascript:alert(1)","classColors":{"GT3":"#e53935","bad class!":"#000000"}}')
local got = styleNow()
check(r.code == 200 and res.ok == true, 'a style with some bad values is taken, the bad ones left out')
local rej = {}
for _, k in ipairs(res.rejected) do rej[k] = true end
check(rej['colors.bg'] and rej.opacity and rej.bogus and rej.logo and rej['classColors.bad class!'],
  'and the response names what was left out')
check(got.colors.accent == '#00ff00' and got.colors.bg == '#0c0e14' and got.opacity == 0.86
  and got.bar == 'class' and got.title == '<b>Hi</b>' and got.logo == '' and got.classColors.GT3 == '#e53935',
  'what passed is kept, lower-cased; the rest stays as it was')
check(files['settings/raceManager/overlay/style.json'] and files['settings/raceManager/overlay/style.json'].colors.accent == '#00ff00',
  'saved in the overlay folder')
check(live().styleSeq > seq0, 'live.json says the look changed (styleSeq), for overlays that poll')
postStyle('{"subtitle":"Round 3"}')
got = styleNow()
check(got.colors.accent == '#00ff00' and got.subtitle == 'Round 3', 'a post changes only the keys it has')
-- The banner: items by name, `|` between pages, checked like everything else.
check(got.banner == 'logo,flag,session,lap,time,countdown,fastest,sponsor' and got.bannerCycle == 8,
  'the banner shows what it always has until told otherwise, turning every 8 s')
r, res = postStyle('{"banner":" Logo, flag,session,lap|leader,margin,,fastest|order| ","bannerCycle":6}')
got = styleNow()
check(res.ok and #res.rejected == 0 and got.banner == 'logo,flag,session,lap|leader,margin,fastest|order'
  and got.bannerCycle == 6, 'pages of items, kept tidy: case, spaces and empty items and pages dropped')
r, res = postStyle('{"banner":"session,lapz|order"}')
check(res.rejected[1] == 'banner' and styleNow().banner == got.banner,
  'a name it does not know refuses the banner, which keeps what it had')
postStyle('{"banner":"lap|lap|lap|lap|lap|lap|lap|lap|lap"}')
check(styleNow().banner == got.banner, 'and so do nine pages: eight at most')
postStyle('{"banner":"|,|"}')
check(styleNow().banner == got.banner, 'and a banner with nothing on it')
postStyle('{"bannerCycle":1}')
check(styleNow().bannerCycle == 6, 'a page turns every 2 to 60 seconds')
local items = {}
for _, k in ipairs(feed.style.BANNER_ITEMS) do items[#items + 1] = k end
postStyle('{"banner":"' .. table.concat(items, ',') .. '"}')
check(styleNow().banner == table.concat(items, ','), 'every item there is, on one page')
do
  -- The overlay and the editor know the same items, and the docs name each one.
  local function slurp(p)
    local fh = io.open(p, 'r')
    local t = fh and fh:read('*a') or ''
    if fh then fh:close() end
    return t
  end
  local overlay = slurp('ui/modules/apps/RaceManager/overlay.html')
  local editor = slurp('ui/modules/apps/RaceManager/style.html')
  local docs = slurp('docs/REFERENCE.md')
  local from = docs:find('\n#### The banner', 1, true)
  docs = from and docs:sub(from, (docs:find('\n###', from + 5, true) or #docs)) or ''
  check(docs ~= '', 'docs/REFERENCE.md has a "The banner" section')
  local listed = overlay:match('var BANNER_ITEMS = (%b[])') or ''
  for _, k in ipairs(feed.style.BANNER_ITEMS) do
    check(listed:find("'" .. k .. "'", 1, true) ~= nil, 'the overlay draws the banner item ' .. k)
    check(editor:find("['" .. k .. "', '", 1, true) ~= nil, 'the style editor offers the banner item ' .. k)
    check(docs:find('| `' .. k .. '` |', 1, true) ~= nil, 'the docs describe the banner item ' .. k)
  end
end
-- The tower's columns: names, each once, no pages.
check(styleNow().towerColumns == 'gap,badges', 'the tower shows the gap and the badges until told otherwise')
r, res = postStyle('{"towerColumns":" Gap, last,best,,last,pits,badges "}')
check(res.ok and #res.rejected == 0 and styleNow().towerColumns == 'gap,last,best,pits,badges',
  'columns kept tidy: case and spaces dropped, a repeat kept once')
postStyle('{"towerColumns":"gap,lastlap"}')
check(styleNow().towerColumns == 'gap,last,best,pits,badges', 'a name it does not know refuses the columns')
postStyle('{"towerColumns":"gap|last"}')
check(styleNow().towerColumns == 'gap,last,best,pits,badges', 'and so does a page: the tower has none')
postStyle('{"towerColumns":","}')
check(styleNow().towerColumns == 'gap,last,best,pits,badges', 'and no column at all')
local allCols = table.concat(feed.style.TOWER_COLUMNS, ',')
postStyle('{"towerColumns":"' .. allCols .. '"}')
check(styleNow().towerColumns == allCols, 'every column there is')
do
  local function slurp(p)
    local fh = io.open(p, 'r')
    local t = fh and fh:read('*a') or ''
    if fh then fh:close() end
    return t
  end
  local overlay = slurp('ui/modules/apps/RaceManager/overlay.html')
  local editor = slurp('ui/modules/apps/RaceManager/style.html')
  local docs = slurp('docs/REFERENCE.md')
  local from = docs:find('\n#### Tower columns', 1, true)
  docs = from and docs:sub(from, (docs:find('\n###', from + 5, true) or #docs)) or ''
  check(docs ~= '', 'docs/REFERENCE.md has a "Tower columns" section')
  local listed = overlay:match('var TOWER_COLUMNS = (%b[])') or ''
  local offered = editor:match('var TOWER_COLUMNS = (%b[])') or ''
  for _, k in ipairs(feed.style.TOWER_COLUMNS) do
    check(listed:find("'" .. k .. "'", 1, true) ~= nil, 'the overlay draws the tower column ' .. k)
    check(offered:find("['" .. k .. "', '", 1, true) ~= nil, 'the style editor offers the tower column ' .. k)
    check(docs:find('| `' .. k .. '` |', 1, true) ~= nil, 'the docs describe the tower column ' .. k)
  end
end
postStyle('{"reset":true,"title":"Fresh"}')
got = styleNow()
check(got.colors.accent == '#ff7a1a' and got.title == 'Fresh' and got.subtitle == '', 'reset starts from the defaults')

-- Lengths and pieces.
r = request('POST', '/style.json', '{"title":"x"}', { 'X-PRM-Key: ' .. KEY }, { noLength = true })
check(r.code == 411, 'no Content-Length: 411')
r = request('POST', '/style.json', '{"title":"x"}', { 'X-PRM-Key: ' .. KEY, 'Transfer-Encoding: chunked' })
check(r.code == 411, 'chunked: 411')
r = request('POST', '/style.json', '{}', { 'X-PRM-Key: ' .. KEY }, { length = 70000 })
check(r.code == 413, 'a style over 64 KB: 413, before a byte of it is read')
r = request('POST', '/style.json', '{"title":"In four pieces","subtitle":"' .. string.rep('a', 40) .. '"}',
  { 'X-PRM-Key: ' .. KEY }, { pieces = 4 })
check(r.code == 200 and styleNow().title == 'In four pieces', 'a request split over several reads')
do
  local c = newClient({ 'POST /style.json HTTP/1.1\r\nHost: 127.0.0.1\r\nX-PRM-Key: ' .. KEY
    .. '\r\nExpect: 100-continue\r\nContent-Length: 17\r\n\r\n', '{"title":"Later"}' })
  fake.pending[#fake.pending + 1] = c
  pump(6)
  c.peerClosed = true
  pump(2)
  local out = c:output()
  check(out:find('HTTP/1.1 100 Continue\r\n\r\n', 1, true) == 1 and out:find('HTTP/1.1 200 OK', 1, true),
    'Expect: 100-continue is answered, then the result')
end

-- The overlay folder.
local PNG = '\137PNG\r\n\26\n' .. 'IHDR\0\0\0\1\0\0\0\1' .. '\r\n\0binary\0bytes'
r, res = (function ()
  local rr = request('POST', '/assets/logo.png', PNG, { 'X-PRM-Key: ' .. KEY })
  return rr, parseJson(rr.body)
end)()
check(r.code == 201 and res.name == 'logo.png' and res.kind == 'image', 'a PNG goes into the overlay folder')
check(mem['logo.png'] == PNG, 'byte for byte, NUL and CR/LF included')
local a = get('/assets/logo.png')
check(a.code == 200 and a.body == PNG and a.headers['content-type'] == 'image/png'
  and a.headers['content-security-policy']:find('sandbox', 1, true) and a.headers['cache-control'] == 'no-cache',
  'served back exactly, as image/png, sandboxed')
check(get('/assets/logo.png?v=3').headers['cache-control']:find('immutable', 1, true),
  'asked for by revision: cached for good')
local listed = parseJson(get('/assets.json').body)
check(#listed.files == 1 and listed.files[1].name == 'logo.png' and listed.files[1].kind == 'image'
  and listed.maxBytes == Style.MAX_FILE, '/assets.json lists it, with the limits')

local function refusedUpload(path, body, code, what)
  local rr = request('POST', path, body, { 'X-PRM-Key: ' .. KEY })
  check(rr.code == code, what .. ' (' .. tostring(rr.code) .. ' ' .. tostring(rr.body) .. ')')
end
refusedUpload('/assets/..%2Fescape.png', PNG, 400, 'a name with a path in it is refused')
refusedUpload('/assets/.hidden.png', PNG, 400, 'a dot-file is refused')
refusedUpload('/assets/sub/x.png', PNG, 400, 'a subfolder is refused')
refusedUpload('/assets/tool.exe', 'MZ', 400, 'a type the folder does not hold is refused')
refusedUpload('/assets/fake.png', 'not a png at all', 415, 'a PNG that is not one is refused')
refusedUpload('/assets/bad.svg', '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>', 415,
  'an SVG with script is refused')
refusedUpload('/assets/handler.svg', '<svg onload="alert(1)"></svg>', 415, 'an SVG with an event handler is refused')
r = request('POST', '/assets/mark.svg', '<svg xmlns="http://www.w3.org/2000/svg"><rect width="4" height="4"/></svg>',
  { 'X-PRM-Key: ' .. KEY })
check(r.code == 201 and get('/assets/mark.svg').headers['content-type'] == 'image/svg+xml', 'a plain SVG is fine')
check(get('/assets/../feed.json').code == 404, 'nothing outside the folder is served')
r = request('POST', '/assets/logo.png', PNG, {})
check(r.code == 403, 'no key, no upload')

-- A large file over several polls, and one that stalls.
do
  local big = '\137PNG\r\n\26\n' .. string.rep('x', 600 * 1024)
  local head = 'POST /assets/big.png HTTP/1.1\r\nHost: 127.0.0.1\r\nX-PRM-Key: ' .. KEY
    .. '\r\nContent-Length: ' .. #big .. '\r\n\r\n'
  local c = newClient({ head .. big })
  fake.pending[#fake.pending + 1] = c
  pump(2)
  local midway = false
  for _, cl in ipairs(S.clients) do if cl.sock == c and cl.state == 'body' then midway = true end end
  check(midway, '600 KB is read over several polls, not one')
  -- Meanwhile, another writer waits its turn.
  local other = request('POST', '/style.json', '{"title":"x"}', { 'X-PRM-Key: ' .. KEY }, { pumps = 1 })
  check(other.code == 503, 'a second upload at the same time: 503')
  pump(8)
  c.peerClosed = true
  pump(2)
  check(parseResponse(c:output()).code == 201 and mem['big.png'] == big, 'and it lands whole')
  local stall = newClient({ head .. big:sub(1, 1000) })
  fake.pending[#fake.pending + 1] = stall
  pump(4)
  check(S.writing ~= nil, 'a body that stops arriving holds the writer')
  pump(220)
  check(stall.closed and S.writing == nil, 'and is dropped after 10 s')
end

-- The folder's limits.
do
  local saveMax = Style.MAX_FILES
  Style.MAX_FILES = 3
  refusedUpload('/assets/one-more.png', PNG, 413, 'a full folder is refused')
  Style.MAX_FILES = saveMax
end
r = request('DELETE', '/assets/big.png', nil, { 'X-PRM-Key: ' .. KEY }, { length = 0 })
check(r.code == 200 and mem['big.png'] == nil and get('/assets/big.png').code == 404, 'DELETE removes a file')
r = request('DELETE', '/assets/big.png', nil, { 'X-PRM-Key: ' .. KEY }, { length = 0 })
check(r.code == 404, 'and a file not there is 404')

-- `event: style`: first on connect, and never lost behind state frames.
do
  local sse2 = newClient({ 'GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n' })
  fake.pending[#fake.pending + 1] = sse2
  pump(3)
  local out = sse2:output()
  local s1, s2 = out:find('event: style\ndata: ', 1, true), out:find('event: state\n', 1, true)
  check(s1 and s2 and s1 < s2, 'a new reader gets the look before the first state frame')
  sse2.sendCap = 0
  local mark = #sse2:output()
  postStyle('{"title":"While blocked"}')
  feed.feedState(race({ raceClock = 400 }))
  pump(1)
  feed.feedState(race({ raceClock = 401 }))
  pump(1)
  sse2.sendCap = nil
  pump(3)
  local after = sse2:output():sub(mark + 1)
  local ns = after:find('event: style\ndata: ', 1, true)
  check(ns and after:find('While blocked', ns, true), 'a style change survives two state frames for a slow reader')
  local stateFrames = 0
  for _ in after:gmatch('event: state\n') do stateFrames = stateFrames + 1 end
  check(stateFrames == 1, 'and only the latest state frame follows (' .. stateFrames .. ')')
  sse2.peerClosed = true
  pump(2)
end

-- Wrong keys: ten in a minute shut writes for a minute.
do
  for _ = 1, 10 do postStyle('{"title":"x"}', { 'X-PRM-Key: nopenopenopenopenope' }) end
  r = postStyle('{"title":"right key"}')
  check(r.code == 429, 'after ten wrong keys even the right one waits (429)')
  pump(1220)
  r = postStyle('{"title":"right key"}')
  check(r.code == 200, 'a minute later it works again')
end

-- New key: the old link stops working.
do
  local old = KEY
  feed.feedNewKey()
  KEY = files['settings/raceManager/feed.json'].styleKey
  check(KEY ~= old and lastStatus().urls.style:find(KEY, 1, true), 'New key makes another, and the panel shows it')
  r = postStyle('{"title":"x"}', { 'X-PRM-Key: ' .. old })
  check(r.code == 403, 'the old key is refused')
end

-- The league's teams on the rows.
do
  local t = race()
  t.teams = {
    { id = 1, name = 'Phoenix Racing', short = 'PHX', color = '#FF7A1A', logo = 'https://example.org/phx.png' },
    { id = 2, name = 'Blue Comet', short = 'BLU', color = 'blue', logo = 'javascript:alert(1)' },
  }
  rowOf(t, 1).team, rowOf(t, 1).number = 1, '07'
  rowOf(t, 2).team, rowOf(t, 2).number = 2, '12'
  rowOf(t, 3).number = '1234'
  feed.feedState(t)
  doc = live()
  local a1, b1 = driver(doc, 1), driver(doc, 2)
  check(a1.number == '07' and a1.team == 1 and a1.teamShort == 'PHX' and a1.teamName == 'Phoenix Racing'
    and a1.teamColor == '#ff7a1a' and a1.teamLogo == 'https://example.org/phx.png', 'a driver\'s team and number')
  check(b1.teamShort == 'BLU' and b1.teamColor == NULL and b1.teamLogo == NULL,
    'a bad color or logo from the server becomes null')
  check(driver(doc, 3).number == NULL, 'a number that is not 1 to 3 digits is dropped')
  check(isArray(doc.teams) and #doc.teams == 2 and doc.teams[1].short == 'PHX', 'the teams list, top level')
  local g1
  for _, g in ipairs(doc.grid) do if g.id == 1 then g1 = g end end
  check(g1 and g1.teamShort == 'PHX' and g1.number == '07', 'grid rows carry them too')
  check(#parseJson(get('/teams.json').body) == 2, '/teams.json')
  -- The next update without a list keeps the one held.
  local t2 = race({ raceClock = 500 })
  rowOf(t2, 1).team, rowOf(t2, 1).number = 1, '07'
  feed.feedState(t2)
  check(driver(live(), 1).teamShort == 'PHX', 'teams are kept until the next list')
  feed.feedOffline()
  check(#live().teams == 0, 'leaving the server forgets them')
end

-- Who this PC's camera is on: the attached car's BeamMP owner.
do
  local attached, free = nil, false
  local owners = {
    [101] = { ownerID = 2 },    -- Bob's car
    [102] = { ownerID = 0 },    -- the spectating admin's
    [103] = {},                 -- not acknowledged by the server yet
    [-1] = { ownerID = 1 },     -- ids at or under 0 are not vehicles
  }
  local function car(id) return { getID = function () return id end } end
  getPlayerVehicle = function () return attached end
  commands = { isFreeCamera = function () return free end }
  MPVehicleGE = { getVehicleByGameID = function (id) return owners[id] end }
  local function onCamera(d)
    local ids = {}
    for _, row in ipairs(d.drivers) do if row.onCamera then ids[#ids + 1] = row.id end end
    return ids
  end

  feed.feedState(race())
  pump(5)
  doc = live()
  check(doc.camera == NULL and #onCamera(doc) == 0, 'no car attached: nobody on camera')

  -- Tabbing onto Bob, with no RM_Update in between.
  attached = car(101)
  pump(5)
  doc = live()
  check(doc.camera ~= NULL and doc.camera.id == 2 and doc.camera.name == 'Bob'
    and doc.camera.posText == 'P2', 'tabbed onto Bob: he is on camera, without waiting for the server')
  local ids = onCamera(doc)
  check(#ids == 1 and ids[1] == 2, 'and his row alone says onCamera')
  for _, k in ipairs(schema.camera) do
    check(doc.camera[k] ~= nil, 'camera.' .. k .. ' is always present')
  end
  local cam = parseJson(get('/camera.json').body)
  check(type(cam) == 'table' and cam.id == 2, '/camera.json is the camera object')

  -- An RM_Update keeps it, with the new place.
  local moved = race()
  rowOf(moved, 2).position, rowOf(moved, 1).position = 1, 2
  feed.feedState(moved)
  doc = live()
  check(doc.camera.id == 2 and doc.camera.posText == 'P1', 'the next race update carries the camera on')

  free = true
  pump(5)
  doc = live()
  check(doc.camera == NULL and #onCamera(doc) == 0, 'free camera: nobody')
  check(get('/camera.json').body == 'null', '/camera.json is null then')
  free = false

  attached = car(102)
  pump(5)
  check(live().camera == NULL, 'a spectator\'s car: nobody (spectators have no row)')
  attached = car(103)
  pump(5)
  check(live().camera == NULL, 'a car with no owner yet: nobody')
  attached = car(-1)
  pump(5)
  check(live().camera == NULL, 'an id at or under 0: nobody')

  -- The engine accessor where the GE one is missing.
  getPlayerVehicle = nil
  be = { getPlayerVehicle = function () return car(101) end }
  pump(5)
  check(live().camera.id == 2, 'be:getPlayerVehicle works as well')

  -- A lookup that throws: nobody, and the feed carries on.
  MPVehicleGE = { getVehicleByGameID = function () error('boom') end }
  pump(5)
  doc, resp = live()
  check(resp.code == 200 and doc.camera == NULL and S.running == true,
    'a failing lookup is nobody, and the feed keeps serving')

  MPVehicleGE = { getVehicleByGameID = function (id) return owners[id] end }
  pump(5)
  check(live().camera.id == 2, 'and recovers when it works again')
  feed.feedOffline()
  check(live().camera == NULL, 'not connected: nobody')

  getPlayerVehicle, be, commands, MPVehicleGE = nil, nil, nil, nil
end

-- Copy editor link: 0.40's openWebBrowser refuses 127.0.0.1 (domain filter).
do
  local clip, opened = nil, nil
  setClipboard = function (s) clip = s end
  openWebBrowser = function (u) opened = u end
  local key = S.settings.styleKey
  feed.feedOpenStyle()
  check(type(key) == 'string' and clip ~= nil
    and clip:match('^http://127%.0%.0%.1:%d+/style#key=(.+)$') == key,
    'the editor link, key and all, goes to the clipboard (got ' .. tostring(clip) .. ')')
  check(opened == nil, 'and no browser is tried once it is copied')
  check(copyPushes[#copyPushes] and copyPushes[#copyPushes].copied == true,
    'the panel hears it was copied')
  setClipboard = function () error('no clipboard') end
  feed.feedOpenStyle()
  check(copyPushes[#copyPushes].copied == false, 'a copy that fails says so, and the panel shows the link')
  check(opened ~= nil, 'with the browser tried as a fallback')
  setClipboard = nil
  opened = nil
  feed.feedOpenStyle()
  check(copyPushes[#copyPushes].copied == false and opened ~= nil, 'no clipboard call at all: the same')
  setClipboard, openWebBrowser = nil, nil
end

-- The banner keys: a press is a new seq in the document, and the bindings
-- file calls only what the extension has.
do
  local before = live()
  check(before.banner == NULL, 'no banner key pressed yet: banner is null')
  feed.feedBanner('next')
  local d1 = live()
  check(d1.banner ~= NULL and d1.banner.go == 'next' and d1.banner.seq == 1 and d1.seq > before.seq,
    'a banner key is in the document at once, with a new seq')
  feed.feedBanner(3)
  check(live().banner.go == 3 and live().banner.seq == 2, 'a page number too')
  feed.feedBanner(9); feed.feedBanner('sideways'); feed.feedBanner(2.5); feed.feedBanner(nil)
  check(live().banner.seq == 2, 'anything else is ignored')

  local fh = io.open('lua/ge/extensions/core/input/actions/raceManager.json', 'r')
  local text = fh and fh:read('*a') or ''
  if fh then fh:close() end
  local ok, actions = pcall(parseJson, text)
  check(ok and type(actions) == 'table', 'the bindings file is plain JSON')
  local n, pages = 0, {}
  for name, a in pairs(ok and actions or {}) do
    n = n + 1
    local arg = type(a.onDown) == 'string' and a.onDown:match('raceManager%.feedBanner%((.-)%) end$')
    check(name:match('^raceManager_banner') and a.cat == 'gameplay' and a.ctx == 'tlua'
      and type(a.title) == 'string' and arg ~= nil, 'binding ' .. name .. ' is a gameplay key calling feedBanner')
    if arg then pages[#pages + 1] = arg end
  end
  check(n == 10, 'ten banner bindings: next, previous and pages 1 to 8 (got ' .. n .. ')')
  table.sort(pages)
  check(table.concat(pages, ',') == "'next','prev',1,2,3,4,5,6,7,8", 'each calls its own page')
  local ext = io.open('lua/ge/extensions/raceManager.lua', 'r')
  local src = ext and ext:read('*a') or ''
  if ext then ext:close() end
  check(src:find("'feedBanner'", 1, true) ~= nil, 'and the extension exposes feedBanner')
end

-- Saved looks on the race server: asked over RM_Looks, answered by ticket,
-- checked both ways.
do
  local toServer = {}
  TriggerServerEvent = function (e, p) toServer[#toServer + 1] = { e = e, p = p } end
  local function lastAsk() return parseJson(toServer[#toServer].p) end
  local admin, role = false, nil
  feed.init({ build = '9.9.9', isAdmin = function () return admin end, role = function () return role end })
  local function looksNow(q) return parseJson(get('/looks.json' .. (q or '')).body) end
  local function post(t, key)
    local r = request('POST', '/looks', t, { 'X-PRM-Key: ' .. (key or KEY) })
    return r, (r.body and r.body:sub(1, 1) == '{') and parseJson(r.body) or nil
  end

  feed.feedOffline()
  local j = looksNow()
  check(j.connected == false and j.looks == NULL and #toServer == 0, 'not connected: no list, and nothing asked')
  check(post('{"op":"get","name":"Formula"}').code == 503, 'and nothing can be asked')
  feed.feedState(race())
  j = looksNow()
  check(j.looks == NULL and #toServer == 1 and toServer[1].e == 'RM_Looks' and lastAsk().op == 'list',
    'connected: the list is asked for')
  looksNow()
  check(#toServer == 1, 'once, not on every read')
  feed.feedLooks('{"op":"list","looks":[{"name":"Formula","by":"Admin","at":1700000000}]}')
  j = looksNow()
  check(#j.looks == 1 and j.looks[1].name == 'Formula' and j.looks[1].by == 'Admin' and j.looks[1].at == 1700000000,
    'the server\'s list is served')
  check(j.canSave == false and j.canDelete == false, 'a game with no login may not save or delete')

  check(post('{"op":"get","name":"Formula"}', 'wrongwrongwrongwrong').code == 403, 'asking takes the style key')
  check(post('{"op":"rename","name":"Formula"}').code == 400, 'an unknown op is refused')
  check(post('{"op":"get","name":"   "}').code == 400, 'so is a blank name')
  local r, res = post('{"op":"get","name":"Formula"}')
  check(r.code == 200 and res.ok == true and type(res.ticket) == 'number', 'a load is asked, and given a ticket')
  local ask = lastAsk()
  check(ask.op == 'get' and ask.name == 'Formula' and ask.ticket == res.ticket,
    'the server is asked for that look on that ticket')
  check(looksNow('?ticket=' .. res.ticket).reply == NULL, 'no answer yet: reply is null')
  feed.feedLooks('{"op":"get","ticket":' .. res.ticket .. ',"name":"Formula",'
    .. '"style":{"colors":{"accent":"#e10600"},"opacity":7,"evil":"<script>"}}')
  local rep = looksNow('?ticket=' .. res.ticket).reply
  check(rep ~= NULL and rep.ok == true and rep.op == 'get' and rep.name == 'Formula',
    'the answer is served on its ticket')
  check(rep.style.colors.accent == '#e10600' and rep.style.opacity == 0.86 and rep.style.evil == nil,
    'its style is checked: a good value kept, a bad one at the default, an unknown key gone')
  check(table.concat(rep.rejected, ',') == 'evil,opacity', 'and what was left out is named')

  check(post('{"op":"save","name":"Rally","style":{"opacity":0.5}}').code == 403,
    'saving needs an admin or moderator login in the game')
  admin, role = true, 'moderator'
  j = looksNow()
  check(j.canSave == true and j.canDelete == false, 'a moderator may save, not delete')
  r, res = post('{"op":"save","name":"  Rally  ","style":{"opacity":0.5,"colors":{"accent":"#zzzzzz"}}}')
  ask = lastAsk()
  check(r.code == 200 and ask.op == 'save' and ask.name == 'Rally' and ask.style.opacity == 0.5
    and ask.style.colors.accent == '#ff7a1a', 'a save sends the look checked, its name trimmed')
  check(table.concat(res.rejected, ',') == 'colors.accent', 'and says what it left out')
  feed.feedLooks('{"op":"saved","ticket":' .. res.ticket .. ',"name":"Rally","kept":false}')
  rep = looksNow('?ticket=' .. res.ticket).reply
  check(rep.ok == true and type(rep.warn) == 'string', 'a save the server could not write says so')
  check(post('{"op":"delete","name":"Rally"}').code == 403, 'a moderator cannot delete')
  role = 'admin'
  r, res = post('{"op":"delete","name":"Rally"}')
  check(r.code == 200 and lastAsk().op == 'delete', 'an admin can')
  feed.feedLooks('{"op":"error","ticket":' .. res.ticket .. ',"msg":"No look is saved as \\"Rally\\"."}')
  rep = looksNow('?ticket=' .. res.ticket).reply
  check(rep.ok == false and rep.error == 'No look is saved as "Rally".', 'a refusal is served on its ticket')

  feed.feedOffline()
  check(looksNow().looks == NULL, 'leaving the server forgets its list')
  TriggerServerEvent = nil
  feed.init({ build = '9.9.9' })
end
feed.feedStop('unload')

-- ===========================================================================
-- 10. The docs name every key
-- ===========================================================================
do
  local fh = io.open('docs/REFERENCE.md', 'r')
  local docs = fh and fh:read('*a') or ''
  if fh then fh:close() end
  local from = docs:find('\n## Broadcast feed', 1, true) or docs:find('\n### Broadcast feed', 1, true)
  check(from ~= nil, 'docs/REFERENCE.md has a "Broadcast feed" section')
  local section = from and docs:sub(from) or ''
  local stop = section:find('\n## ', 3, true)
  if stop then section = section:sub(1, stop) end
  local function documented(key)
    return section:find('`' .. key .. '`', 1, true) ~= nil
  end
  for group, keys in pairs(schema) do
    if group == 'events' then
      for kind, list in pairs(keys) do
        check(documented(kind), 'the docs name the ' .. kind .. ' event')
        for _, k in ipairs(list) do
          check(documented(k), 'the docs name event key ' .. k .. ' (' .. kind .. ')')
        end
      end
    else
      for _, k in ipairs(keys) do
        check(documented(k), 'the docs name ' .. group .. '.' .. k)
      end
    end
  end
  for _, route in ipairs({ '/live.json', '/drivers.json', '/grid.json', '/session.json',
      '/events.json', '/stream', '/overlay', '/teams.json', '/camera.json', '/style', '/style.json',
      '/assets.json', '/assets/', 'styleSeq', 'event: style', '/looks.json', '/looks', 'banner' }) do
    check(documented(route), 'the docs name ' .. route)
  end
  -- Every style key, by its path (colors.accent, labels.leader, opacity...).
  for _, path in ipairs(feed.style.paths()) do
    check(documented(path), 'the docs name the style key ' .. path)
  end
end

-- ===========================================================================
-- 11. The editor and the overlay know every style key
-- ===========================================================================
do
  local function slurp(p)
    local fh = io.open(p, 'r')
    local t = fh and fh:read('*a') or ''
    if fh then fh:close() end
    return t
  end
  local editor = slurp('ui/modules/apps/RaceManager/style.html')
  for _, path in ipairs(feed.style.paths()) do
    check(editor:find('data-key="' .. path .. '"', 1, true) ~= nil, 'the style editor has a field for ' .. path)
  end
  local overlay = slurp('ui/modules/apps/RaceManager/overlay.html')
  -- Both pages keep a copy of the defaults (the overlay draws with them until
  -- the style arrives; the editor's Start over and Import fill gaps from them):
  -- every one must be the spec's, written `name: value`.
  local function literal(v)
    if type(v) == 'string' then return "'" .. v .. "'" end
    return tostring(v)
  end
  local function same(page, what, name, v)
    check(page:find(name .. ': ' .. literal(v), 1, true) ~= nil,
      what .. ' starts from the default ' .. name .. ' ' .. literal(v))
  end
  for _, e in ipairs(feed.style.SPEC) do
    if e.group then
      for _, s in ipairs(e.group) do
        same(overlay, 'the overlay', s[1], s[3])
        same(editor, 'the style editor', s[1], s[3])
      end
    elseif not e.map then
      same(overlay, 'the overlay', e[1], e[3])
      same(editor, 'the style editor', e[1], e[3])
    end
  end
end

print(string.format('feed_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
