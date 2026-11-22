-- Phoenix Race Manager: THE BROADCAST FEED, client side.
--
-- Live race data for a stream's overlay software (OBS, vMix, a page of your
-- own): the running order, the starting grid, laps and lap times, gaps, the
-- joker, pit stops, flags and what just happened, served over HTTP on the
-- streamer's own PC.
--
-- WHY THE CLIENT AND NOT THE SERVER. BeamMP's server has no HTTP client, and
-- the only way it reaches the network is curl in a process of its own, which
-- got a server cut off on a rented host (onlineFeatures, REFERENCE "Game
-- hosts"). A rented host gives no extra ports either. But every client already
-- receives the whole race state over BeamMP's own connection (RM_Update, about
-- three times a second while a session runs), so the streamer's game serves it
-- locally and the server does nothing new: it works on any host.
--
-- SHAPE. A non-blocking LuaSocket listener polled from onUpdate (one boolean
-- when off). RM_Update is rebuilt into a documented schema (`feed: 1`) from an
-- explicit list of fields, so nothing admin-only ever leaves the game, and
-- encoded once per change. Readers poll /live.json or hold /stream (Server-Sent
-- Events, the whole snapshot per frame, the latest frame winning for a slow
-- reader). Events (a lap, the joker, a pit stop, a flag) are found by comparing
-- consecutive snapshots and kept in a short ring with a sequence number.
--
-- Off as shipped. Settings live in the user folder, not the app: the listener
-- has to come up with the game whether or not the app is on screen.
--
-- THE LOOK (feedstyle.lua) is the streamer's: a style page at /style changes
-- the overlay's colors, logos, type and wording, and the overlay picks it up at
-- once (`event: style`). Writing takes the style key the Feed panel shows, and
-- an Origin, if a browser sends one, of this feed itself. Nothing a write can
-- reach is the race: only the style file and the overlay folder.
--
-- RACE CONTROL (/control) is the one exception, and it is off as shipped: an
-- admin's race-night buttons on a page for a second screen or a phone. It takes
-- its own key, and each action is a NAME on Ctl.ACTIONS calling the function
-- the panel's own button calls, so the server sees this game's login and
-- nothing new. A page never sends Lua.

local D = {}
local Style = require('raceManager/feedstyle')
D.style = Style

local SETTINGS_FILE = 'settings/raceManager/feed.json'
-- The optional overlay page, read through the game's virtual filesystem (the
-- mounted client zip), as splash.lua reads its logo.
local OVERLAY_FILE = '/ui/modules/apps/RaceManager/overlay.html'
local STYLE_PAGE_FILE = '/ui/modules/apps/RaceManager/style.html'
local CONTROL_PAGE_FILE = '/ui/modules/apps/RaceManager/control.html'
-- Race control: declared here, filled in after the write path it shares.
local Ctl = { MAX_BODY = 512 }
local DEFAULT_PORT = 8128
local PORT_MIN, PORT_MAX = 1024, 65535
local SCHEMA = 1

local POLL_EVERY = 0.05        -- seconds between socket polls
local CAMERA_EVERY = 0.2       -- seconds between looks at who the camera is on
local MAX_CLIENTS = 16         -- open connections; one more gets a 503
local ACCEPTS_PER_POLL = 4
local READ_CHUNK = 4096
local MAX_HEADER = 8192        -- request head; more gets a 431
local READ_TIMEOUT = 5         -- seconds to send a whole request head
local DRAIN_FOR = 2            -- seconds a served reader has to hang up first
local KEEPALIVE = 15           -- seconds of silence before an SSE comment
local WRITE_STALL = 30         -- seconds a reader may take no bytes
local BIND_TRIES = 5           -- port in use: retries, a second apart
local STATUS_EVERY = 2         -- reader-count pushes to the panel, at most
local EVENT_RING = 30

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
-- The extension's side: its build, its functions (race control calls them by
-- name) and whether this game is logged in as an admin, and at which tier.
local host = { build = '?', ext = nil, isAdmin = nil, role = nil }
local S = {
  settings = nil,        -- { on, port, lan }, read once
  running = false,       -- listening
  starting = false,      -- waiting to retry a port in use
  bindTries = 0,
  retryWait = 0,
  error = nil,
  srv = nil,
  clients = {},
  clock = 0,
  pollWait = 0,
  lanIp = nil,
  overlay = nil,         -- page text, false once it failed to load
  stylePage = nil,       -- the style editor's page, the same way
  -- The look (feedstyle.lua) and the writes that change it.
  style = nil,           -- the current style, checked
  styleSeq = 0,          -- bumped on every change, in live.json too
  assetsRev = 0,         -- bumped on every upload or removal (cache-busting)
  styleBody = nil,       -- /style.json
  styleFrame = nil,      -- the SSE `style` frame
  writing = nil,         -- the one client sending a body
  badKeys = {},          -- clock times of wrong keys, for the lockout
  lockUntil = 0,
  teams = nil,           -- { list, byId }: the league's teams, from RM_Update
  -- The race.
  last = nil,            -- the last RM_Update payload, kept while off too
  connected = false,
  countdown = nil,
  prev = nil,            -- the previous model, for events
  camera = nil,          -- the player id this PC's camera is on, as text; nil for nobody
  cameraAt = 0,          -- clock time of the next look
  cameraError = nil,     -- the last lookup error, logged once
  events = {},
  eventSeq = 0,
  seq = 0,
  epoch = os.time(),
  bodyKey = nil,
  body = nil,
  parts = nil,
  frame = nil,
  -- The panel.
  statusAt = -math.huge,
  pushedClients = 0,
  pushedStreams = 0,
  loggedError = nil,
}

-- The slot a reloaded copy of this module finds the old listener through.
local SLOT = 'raceManagerFeed'

local function say(level, msg)
  if type(log) == 'function' then pcall(log, level, 'raceManager', 'Feed: ' .. msg) end
end

local function isWindows()
  if type(jit) == 'table' and type(jit.os) == 'string' then return jit.os == 'Windows' end
  return package.config:sub(1, 1) == '\\'
end

-- ---------------------------------------------------------------------------
-- JSON: fixed key order, explicit null, [] for an empty list, three decimals.
-- An object is a table whose `_k` names its keys in order; anything else is a
-- list. BeamNG's jsonEncode cannot tell {} from [] and orders keys at random,
-- and a documented feed needs both pinned.
-- ---------------------------------------------------------------------------
local ESC = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}
local function jsonString(s)
  if s:find('[%c"\\]') then
    s = s:gsub('[%c"\\]', function (c)
      return ESC[c] or string.format('\\u%04x', c:byte())
    end)
  end
  return '"' .. s .. '"'
end

local function jsonNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then return 'null' end
  if n == math.floor(n) and math.abs(n) < 1e15 then
    return string.format('%d', math.floor(n))
  end
  local s = string.format('%.3f', n):gsub('0+$', ''):gsub('%.$', '')
  if s == '-0' then s = '0' end
  return s
end

local function encodeInto(v, out)
  local tv = type(v)
  if v == nil then
    out[#out + 1] = 'null'
  elseif tv == 'boolean' then
    out[#out + 1] = v and 'true' or 'false'
  elseif tv == 'number' then
    out[#out + 1] = jsonNumber(v)
  elseif tv == 'string' then
    out[#out + 1] = jsonString(v)
  elseif tv == 'table' then
    local keys = v._k
    if keys then
      out[#out + 1] = '{'
      for i = 1, #keys do
        local k = keys[i]
        out[#out + 1] = (i > 1 and ',"' or '"') .. k .. '":'
        encodeInto(v[k], out)
      end
      out[#out + 1] = '}'
    else
      out[#out + 1] = '['
      for i = 1, #v do
        if i > 1 then out[#out + 1] = ',' end
        encodeInto(v[i], out)
      end
      out[#out + 1] = ']'
    end
  else
    out[#out + 1] = 'null'
  end
end

local function encode(v)
  local out = {}
  encodeInto(v, out)
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- The schema. These lists ARE the feed: what is not named here never leaves
-- the game, and docs/REFERENCE.md "Broadcast feed" documents each name
-- (tests/feed_test.lua checks that it does).
-- ---------------------------------------------------------------------------
local SESSION_KEYS = {
  'phase', 'phaseText', 'kind', 'mode', 'pointToPoint', 'layout',
  'lap', 'lapTarget', 'lapText', 'lapsToGo',
  'clock', 'clockText', 'timeLimit', 'timeLeft', 'timeLeftText', 'clockStopped',
  'flag', 'flagText', 'caution', 'cautionPending', 'cautionLaps', 'pacing',
  'restartPending', 'greenReady', 'finalLap', 'raceExpired', 'finishCloseIn',
  'countdown', 'jokerEnabled', 'heat', 'fastestLap', 'entrants', 'spectators',
  'gridSource',
}
local DRIVER_KEYS = {
  'id', 'name', 'account', 'position', 'posText', 'class', 'classPos',
  'status', 'statusText', 'out', 'outReason',
  'gridPos', 'gained', 'gainedText',
  'lap', 'lapText', 'lapsLed', 'lastLap', 'lastLapText',
  'bestLap', 'bestLapText', 'qualiBest', 'qualiBestText', 'fastest',
  'gap', 'gapText', 'interval', 'intervalText', 'lapsDown',
  'jokerTaken', 'jokerLap', 'jokerText', 'pitStops',
  'finishTime', 'finishText', 'penalty', 'resets',
  'number', 'team', 'teamName', 'teamShort', 'teamColor', 'teamLogo',
  'onCamera',
}
local GRID_KEYS = { 'slot', 'id', 'name', 'class', 'qualiBest', 'qualiBestText',
  'number', 'team', 'teamName', 'teamShort', 'teamColor', 'teamLogo' }
-- The driver this PC's camera is on (watchedPid), copied from their row.
local CAMERA_KEYS = { 'id', 'name', 'position', 'posText', 'class',
  'number', 'team', 'teamName', 'teamShort', 'teamColor', 'teamLogo' }
local TEAM_KEYS = { 'id', 'name', 'short', 'color', 'logo' }
local FASTEST_KEYS = { 'id', 'name', 'time', 'text' }
local HEAT_KEYS = { 'current', 'count' }
local EVENT_COMMON = { 'seq', 'type', 'ts', 'clock', 'id', 'name', 'text' }
local EVENT_EXTRA = {
  session   = { 'from', 'to', 'kind' },
  countdown = { 'count' },
  go        = {},
  abort     = {},
  flag      = { 'flag', 'from' },
  caution   = { 'state', 'laps' },
  lap       = { 'lap', 'time', 'timeText', 'pb' },
  fastest   = { 'time', 'timeText' },
  joker     = { 'lap', 'count' },
  pit       = { 'stops', 'lap' },
  leader    = { 'prevId', 'prevName' },
  finish    = { 'position', 'time', 'timeText' },
  out       = { 'status', 'reason' },
  penalty   = { 'seconds', 'total' },
}
local EVENT_KEYS = {}
for kind, extra in pairs(EVENT_EXTRA) do
  local keys = {}
  for i = 1, #EVENT_COMMON do keys[i] = EVENT_COMMON[i] end
  for i = 1, #extra do keys[#keys + 1] = extra[i] end
  EVENT_KEYS[kind] = keys
end

-- Exposed for the test and the docs check.
D.SCHEMA_KEYS = {
  session = SESSION_KEYS, drivers = DRIVER_KEYS, grid = GRID_KEYS,
  fastestLap = FASTEST_KEYS, heat = HEAT_KEYS, events = EVENT_KEYS,
  teams = TEAM_KEYS, camera = CAMERA_KEYS,
}

-- The app's words for the same things (app.js PHASE_LABELS, STATUS_LABELS), so
-- the stream says what the board says.
local PHASE_TEXT = {
  waiting = 'Waiting', qualifying = 'Qualifying', grid = 'Grid Locked',
  countdown = 'Countdown', racing = 'Racing', finished = 'Race Over',
  offline = 'Offline',
}
local QUALI_PHASE_TEXT = { grid = 'Quali Grid', countdown = 'Quali Countdown' }
local STATUS_TEXT = {
  waiting = 'Waiting', qualifying = 'On Track', gridded = 'On Grid',
  called = 'Not Ready', racing = 'Racing', finished = 'Finished',
  dsq = 'Disqualified', dnf = 'DNF',
}
local FLAG_TEXT = {
  none = '', green = 'GREEN FLAG', red = 'RED FLAG', white = 'FINAL LAP',
  checkered = 'CHECKERED FLAG',
}

-- ---------------------------------------------------------------------------
-- Formatting, as the app formats (app.js formatLap, formatBehind, gapLabel,
-- lapLabel, jokerLabel, gridDelta). Blank is "", never "-": an overlay binds
-- these straight onto a graphic.
-- ---------------------------------------------------------------------------
local function num(v)
  if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then return nil end
  return v
end

-- m:ss.sss, h:mm:ss.sss past the hour.
local function fmtLap(t)
  t = num(t)
  if not t or t < 0 then return '' end
  local ms = math.floor(t * 1000 + 0.5)
  local m = math.floor(ms / 60000)
  local rest = ms - m * 60000
  local s = math.floor(rest / 1000)
  local frac = rest - s * 1000
  if m >= 60 then
    local h = math.floor(m / 60)
    return string.format('%d:%02d:%02d.%03d', h, m - h * 60, s, frac)
  end
  return string.format('%d:%02d.%03d', m, s, frac)
end

-- +s.s under a minute, +m:ss.s above (tenths: the split carries a ping).
local function fmtBehind(t)
  t = num(t)
  if not t then return '' end
  if t < 0 then t = 0 end
  local tenths = math.floor(t * 10 + 0.5)
  if tenths < 600 then
    return string.format('+%d.%d', math.floor(tenths / 10), tenths % 10)
  end
  local m = math.floor(tenths / 600)
  local r = tenths - m * 600
  return string.format('+%d:%02d.%d', m, math.floor(r / 10), r % 10)
end

-- A count as text: "3", never "3.0" (Lua 5.3 keeps a float's point).
local function istr(n)
  if type(n) == 'number' and n == math.floor(n) and math.abs(n) < 1e15 then
    return string.format('%d', math.floor(n))
  end
  return tostring(n)
end

local function fmtLaps(n)
  return '+' .. istr(n) .. ' LAP' .. (n > 1 and 'S' or '')
end

-- mm:ss, h:mm:ss past the hour. `up` rounds up (a clock running down).
local function fmtClock(t, up)
  t = num(t)
  if not t then return '' end
  if t < 0 then t = 0 end
  local s = up and math.ceil(t) or math.floor(t)
  local h = math.floor(s / 3600)
  local m = math.floor((s - h * 3600) / 60)
  s = s - h * 3600 - m * 60
  if h > 0 then return string.format('%d:%02d:%02d', h, m, s) end
  return string.format('%02d:%02d', m, s)
end

local function keyedObject(keys)
  return { _k = keys }
end

-- ---------------------------------------------------------------------------
-- RM_Update -> the feed model. `data` is the payload as the client decoded it;
-- `src` is one of its driver rows (tests/ui_bindings_test.lua checks every
-- src.<field> read here against the server's DRIVER_WIRE_FIELDS).
-- ---------------------------------------------------------------------------
local function rowName(src)
  local alias = src.alias
  if type(alias) == 'string' and alias ~= '' then return alias end
  return type(src.name) == 'string' and src.name or ''
end

local function isOut(status) return status == 'dnf' or status == 'dsq' end

local function offlineSession()
  local s = keyedObject(SESSION_KEYS)
  s.phase, s.phaseText = 'offline', PHASE_TEXT.offline
  s.lapText, s.clockText, s.timeLeftText = '', '', ''
  s.flag, s.flagText = 'none', ''
  s.pointToPoint, s.caution, s.cautionPending, s.pacing = false, false, false, false
  s.restartPending, s.greenReady, s.finalLap, s.raceExpired = false, false, false, false
  s.clockStopped, s.jokerEnabled = false, false
  s.cautionLaps, s.entrants, s.spectators = 0, 0, 0
  return s
end

-- The league's teams as the server sent them, checked again: they are going
-- onto a stream page.
local function indexTeams(raw)
  local list, byId = {}, {}
  if type(raw) ~= 'table' then return { list = list, byId = byId } end
  for _, t in ipairs(raw) do
    if type(t) == 'table' then
      local id = num(t.id)
      local name = type(t.name) == 'string' and #t.name <= 32 and t.name or nil
      local short = type(t.short) == 'string' and t.short:match('^[A-Z0-9][A-Z0-9][A-Z0-9]?[A-Z0-9]?$') or nil
      local color = type(t.color) == 'string' and t.color:match('^#%x%x%x%x%x%x$') or nil
      local logo = type(t.logo) == 'string' and #t.logo <= 300
        and t.logo:match('^https?://[^%s"\'<>\\`()]+$') or nil
      if id and name and short then
        local o = keyedObject(TEAM_KEYS)
        o.id, o.name, o.short, o.color, o.logo = id, name, short, color and color:lower() or nil, logo
        list[#list + 1] = o
        byId[id] = o
      end
    end
  end
  return { list = list, byId = byId }
end

-- A row's team and number, onto `d` (a driver or a grid row).
local function teamFields(d, team, number)
  d.number = number
  d.team = team and team.id or nil
  d.teamName = team and team.name or nil
  d.teamShort = team and team.short or nil
  d.teamColor = team and team.color or nil
  d.teamLogo = team and team.logo or nil
end

-- `cameraPid` is watchedPid's answer: a player id as text, or nil.
local function buildModel(data, teams, cameraPid)
  local model = { connected = false, session = nil, drivers = {}, grid = {}, byId = {} }
  model.teams = teams and teams.list or {}
  if type(data) ~= 'table' then
    model.session = offlineSession()
    return model
  end
  model.connected = true
  model.serverBuild = type(data.serverBuild) == 'string' and data.serverBuild or nil

  local phase = type(data.phase) == 'string' and data.phase or 'waiting'
  local quali = data.sessionKind == 'quali'
  local p2p = data.pointToPoint == true
  local paced = data.paceLap == true and not quali and not p2p
  local outRule = data.qualiOutLap == true
  local racing = phase == 'racing' or phase == 'qualifying'
  local rows = type(data.drivers) == 'table' and data.drivers or {}

  -- The lap target (app.js raceLapTarget): the final lap a timed race set, the
  -- distance, or none. Qualifying's is its lap limit.
  local sessionLaps = num(data.sessionLaps) or 0
  local target
  if quali then
    target = sessionLaps > 0 and sessionLaps or nil
  elseif num(data.lastLapNum) then
    target = math.max(1, data.lastLapNum - (paced and 1 or 0))
  elseif data.raceMode ~= 'timed' and sessionLaps > 0 then
    target = sessionLaps
  end

  -- Each driver's lap (app.js lapLabel / raceLapNumber).
  local function lapOf(src)
    local cur = num(src.currentLap) or 0
    if cur <= 0 then return 0, '' end
    if quali then
      if src.outLap then return 0, 'OUT' end
      local q = math.max(1, cur - (outRule and 1 or 0))
      return q, target and (istr(q) .. '/' .. istr(target)) or istr(q)
    end
    if paced and src.outLap then return 0, 'PACE' end
    local n = cur - (paced and 1 or 0)
    if n < 1 then n = 1 end
    return n, target and (istr(n) .. '/' .. istr(target)) or istr(n)
  end

  -- The field: spectators are counted, not listed (app.js splitField).
  local spectators = 0
  local field = {}
  for _, src in ipairs(rows) do
    if type(src) == 'table' then
      if src.spectating then spectators = spectators + 1
      else field[#field + 1] = src end
    end
  end

  -- Qualifying gaps are between best laps, to the first car still out there
  -- with a time (app.js bcGapLabel).
  local qualiLeader
  if quali then
    for _, src in ipairs(field) do
      if not isOut(src.status) then qualiLeader = src; break end
    end
  end

  local bestPid, bestTime = data.bestLapPid, num(data.bestLapTime)
  local fastest
  local prevQuali  -- the car ahead's best, for a qualifying interval
  for _, src in ipairs(field) do
    local d = keyedObject(DRIVER_KEYS)
    local status = type(src.status) == 'string' and src.status or 'waiting'
    local out = isOut(status)
    d.id = src.id
    d.name = rowName(src)
    d.account = type(src.name) == 'string' and src.name or ''
    d.position = num(src.position)
    d.posText = (not out and d.position) and ('P' .. istr(d.position)) or '-'
    d.class = src.class
    d.classPos = num(src.classPos)
    d.status, d.statusText = status, STATUS_TEXT[status] or status
    d.out = out
    d.outReason = src.outReason
    d.gridPos = num(src.gridPos)
    if not quali and d.gridPos and d.position and not out then
      d.gained = d.gridPos - d.position
      d.gainedText = d.gained > 0 and ('+' .. istr(d.gained)) or (d.gained < 0 and istr(d.gained) or '')
    else
      d.gainedText = ''
    end
    d.lap, d.lapText = lapOf(src)
    d.lapsLed = num(src.lapsLed) or 0
    d.lastLap = num(src.lastLap)
    d.lastLapText = fmtLap(d.lastLap)
    d.qualiBest = num(src.qualiBest)
    d.qualiBestText = fmtLap(d.qualiBest)
    if quali then d.bestLap = d.qualiBest else d.bestLap = num(src.raceBest) end
    d.bestLapText = fmtLap(d.bestLap)
    d.fastest = bestPid ~= nil and src.id == bestPid and bestTime ~= nil
    d.lapsDown = 0
    if quali then
      local q = d.qualiBest
      if q and qualiLeader and qualiLeader ~= src and num(qualiLeader.qualiBest) then
        d.gap = q - qualiLeader.qualiBest
        d.gapText = fmtBehind(d.gap)
      else
        d.gapText = ''
      end
      if q and prevQuali and not out then
        d.interval = q - prevQuali
        d.intervalText = fmtBehind(d.interval)
      else
        d.intervalText = ''
      end
      if q and not out then prevQuali = q end
    else
      d.gap, d.interval = num(src.gap), num(src.intv)
      local down = (not out) and num(src.down) or 0
      local idown = (not out) and num(src.idown) or 0
      d.lapsDown = down or 0
      if out or d.position == 1 then
        d.gapText, d.intervalText = '', ''
      else
        d.gapText = (down and down > 0) and fmtLaps(down) or fmtBehind(d.gap)
        d.intervalText = (idown and idown > 0) and fmtLaps(idown) or fmtBehind(d.interval)
      end
    end
    d.jokerTaken = num(src.jokerTaken) or 0
    d.jokerLap = num(src.jokerLap)
    if data.jokerEnabled ~= true or d.jokerTaken <= 0 then d.jokerText = ''
    elseif d.jokerTaken > 1 then d.jokerText = '×' .. istr(d.jokerTaken) .. '!'
    else d.jokerText = 'L' .. (d.jokerLap and istr(d.jokerLap) or '?') end
    d.pitStops = num(src.pitStops) or 0
    d.finishTime = num(src.finishTime)
    d.finishText = fmtLap(d.finishTime)
    d.penalty = num(src.penaltySeconds) or 0
    d.resets = num(src.resets) or 0
    -- The league's team and car number (server teams.lua).
    local number = type(src.number) == 'string' and src.number:match('^%d%d?%d?$') or nil
    teamFields(d, teams and teams.byId[num(src.team) or -1] or nil, number)
    -- Row ids are numbers and BeamMP owner ids can be either: compared as text.
    d.onCamera = cameraPid ~= nil and d.id ~= nil and tostring(d.id) == cameraPid
    if d.onCamera then
      local c = keyedObject(CAMERA_KEYS)
      for _, k in ipairs(CAMERA_KEYS) do c[k] = d[k] end
      model.camera = c
    end
    -- Kept for the events, never encoded: not in DRIVER_KEYS.
    d.lastLapOn = num(src.lastLapOn)
    model.drivers[#model.drivers + 1] = d
    if d.id ~= nil then model.byId[d.id] = d end
    if d.fastest then fastest = d end
  end

  -- The grid: the slots as given, or the qualifying order while it is only a
  -- prospect.
  local gridSource
  for _, d in ipairs(model.drivers) do
    if d.gridPos then
      local g = keyedObject(GRID_KEYS)
      g.slot, g.id, g.name, g.class = d.gridPos, d.id, d.name, d.class
      g.qualiBest, g.qualiBestText = d.qualiBest, d.qualiBestText
      teamFields(g, teams and teams.byId[d.team or -1] or nil, d.number)
      model.grid[#model.grid + 1] = g
    end
  end
  if #model.grid > 0 then
    gridSource = 'locked'
    table.sort(model.grid, function (a, b) return a.slot < b.slot end)
  elseif phase == 'waiting' then
    for _, d in ipairs(model.drivers) do
      if d.qualiBest and not d.out then
        local g = keyedObject(GRID_KEYS)
        g.slot, g.id, g.name, g.class = #model.grid + 1, d.id, d.name, d.class
        g.qualiBest, g.qualiBestText = d.qualiBest, d.qualiBestText
        teamFields(g, teams and teams.byId[d.team or -1] or nil, d.number)
        model.grid[#model.grid + 1] = g
      end
    end
    if #model.grid > 0 then gridSource = 'quali' end
  end

  -- The session.
  local s = keyedObject(SESSION_KEYS)
  s.phase = phase
  s.phaseText = (quali and QUALI_PHASE_TEXT[phase]) or PHASE_TEXT[phase] or phase
  s.kind = quali and 'quali' or 'race'
  s.mode = (not quali and type(data.raceMode) == 'string') and data.raceMode or nil
  s.pointToPoint = p2p
  s.layout = (type(data.layoutName) == 'string' and data.layoutName ~= '') and data.layoutName or nil

  -- The race's lap is the leader's (app.js broadcastLap); none in qualifying.
  local leader
  for _, d in ipairs(model.drivers) do
    if not d.out then leader = d; break end
  end
  model.leaderId = leader and leader.id
  if not quali and leader and leader.lapText ~= '' then
    s.lapText = leader.lapText
    if leader.lap > 0 then
      s.lap = leader.lap
      if target then
        s.lapsToGo = leader.status == 'finished' and 0 or math.max(target - leader.lap + 1, 0)
      end
    end
  else
    s.lapText = ''
  end
  s.lapTarget = target

  if quali then
    s.clock = num(data.qualiTime)
    local limit = num(data.qualiTimeLimit)
    s.timeLimit = (limit and limit > 0) and limit or nil
    s.timeLeft = num(data.qualiLeft)
  else
    s.clock = num(data.raceClock)
    local limit = num(data.raceTimeLimit)
    s.timeLimit = (limit and limit > 0) and limit or nil
    s.timeLeft = num(data.raceLeft)
  end
  s.clockText = racing and fmtClock(s.clock) or ''
  s.timeLeftText = s.timeLeft and fmtClock(s.timeLeft, true) or ''
  s.clockStopped = data.clockStopped == true

  s.caution = data.caution == true
  s.cautionPending = data.cautionPending == true
  s.cautionLaps = num(data.cautionLaps) or 0
  s.pacing = data.pacing == true
  s.restartPending = data.restartPending == true
  s.greenReady = data.greenReady == true
  s.finalLap = data.finalLap == true
  s.raceExpired = data.raceExpired == true
  s.finishCloseIn = num(data.closeLeft)

  -- The flag the broadcast shows: the race's, not one driver's (the client's
  -- driverFlag decides white per car).
  local flag
  if data.flag == 'red' then flag = 'red'
  elseif data.flagOut or phase == 'finished' then flag = 'checkered'
  elseif data.flag == 'yellow' or s.caution or s.pacing then flag = 'yellow'
  elseif racing and not quali and (s.finalLap
      or (target and not p2p and s.lap and s.lap >= target)) then flag = 'white'
  elseif racing then flag = 'green'
  else flag = 'none' end
  s.flag = flag
  if flag == 'yellow' then
    s.flagText = s.pacing and 'PACE LAP' or ((s.caution or s.cautionPending) and 'CAUTION' or 'YELLOW FLAG')
  else
    s.flagText = FLAG_TEXT[flag]
  end

  s.countdown = (phase == 'countdown') and S.countdown or nil
  s.jokerEnabled = data.jokerEnabled == true
  local heats = num(data.heatCount) or 0
  if heats > 0 then
    s.heat = keyedObject(HEAT_KEYS)
    s.heat.current, s.heat.count = num(data.heatCurrent), heats
  end
  if fastest then
    s.fastestLap = keyedObject(FASTEST_KEYS)
    s.fastestLap.id, s.fastestLap.name = fastest.id, fastest.name
    s.fastestLap.time, s.fastestLap.text = bestTime, fmtLap(bestTime)
  elseif bestTime then
    s.fastestLap = keyedObject(FASTEST_KEYS)
    s.fastestLap.id, s.fastestLap.name = bestPid, ''
    s.fastestLap.time, s.fastestLap.text = bestTime, fmtLap(bestTime)
  end
  s.entrants = num(data.entrants) or 0
  s.spectators = spectators
  s.gridSource = gridSource
  model.session = s
  model.paced, model.quali, model.outRule = paced, quali, outRule
  return model
end

D.buildModel = buildModel

-- ---------------------------------------------------------------------------
-- Events: what changed between two snapshots. None on the first one after a
-- start or a reconnect, which would replay the whole race as news.
-- ---------------------------------------------------------------------------
local function addEvent(kind, fields, who)
  S.eventSeq = S.eventSeq + 1
  local e = keyedObject(EVENT_KEYS[kind])
  e.seq, e.type, e.ts = S.eventSeq, kind, os.time()
  e.clock = S.prev and S.prev.session and S.prev.session.clock or nil
  if who then e.id, e.name = who.id, who.name end
  for k, v in pairs(fields) do e[k] = v end
  if e.text == nil then e.text = '' end
  local ring = S.events
  ring[#ring + 1] = e
  while #ring > EVENT_RING do table.remove(ring, 1) end
  return e
end

local function diff(prev, cur)
  if not prev or not cur then return end
  local ps, cs = prev.session, cur.session
  local clock = cs.clock
  local function add(kind, fields, who)
    local e = addEvent(kind, fields, who)
    e.clock = clock
  end
  if ps.phase ~= cs.phase then
    add('session', { from = ps.phase, to = cs.phase, kind = cs.kind, text = cs.phaseText })
  end
  if ps.flag ~= cs.flag then
    add('flag', { flag = cs.flag, from = ps.flag,
      text = cs.flagText ~= '' and cs.flagText or ('Flag: ' .. cs.flag) })
  end
  if cs.cautionPending and not ps.cautionPending and not cs.caution then
    add('caution', { state = 'called', laps = cs.cautionLaps, text = 'Caution called' })
  end
  if cs.caution and not ps.caution then
    add('caution', { state = 'out', laps = cs.cautionLaps, text = 'Caution: positions frozen' })
  elseif ps.caution and not cs.caution then
    add('caution', { state = 'ended', laps = ps.cautionLaps, text = 'Caution over' })
  elseif ps.cautionPending and not cs.cautionPending and not cs.caution then
    add('caution', { state = 'withdrawn', laps = 0, text = 'Caution withdrawn' })
  end

  for _, d in ipairs(cur.drivers) do
    local p = d.id ~= nil and prev.byId[d.id] or nil
    if p then
      if d.lastLapOn and d.lastLapOn ~= p.lastLapOn then
        local n = d.lastLapOn - ((cur.quali and cur.outRule or cur.paced) and 1 or 0)
        if n >= 1 then
          local pb = d.lastLap ~= nil and d.bestLap ~= nil and d.lastLap <= d.bestLap
          add('lap', { lap = n, time = d.lastLap, timeText = d.lastLapText, pb = pb,
            text = d.name .. ': lap ' .. istr(n)
              .. (d.lastLap and (' ' .. d.lastLapText) or ' (no time)') }, d)
        end
      end
      if d.jokerTaken > p.jokerTaken then
        add('joker', { lap = d.jokerLap, count = d.jokerTaken,
          text = d.name .. ' takes the joker' .. (d.jokerLap and (' on lap ' .. istr(d.jokerLap)) or '') }, d)
      end
      if d.pitStops > p.pitStops then
        add('pit', { stops = d.pitStops, lap = d.lap,
          text = d.name .. ' pits (stop ' .. istr(d.pitStops) .. ')' }, d)
      end
      if d.status ~= p.status then
        if d.status == 'finished' then
          add('finish', { position = d.position, time = d.finishTime, timeText = d.finishText,
            text = d.name .. ' finishes ' .. d.posText }, d)
        elseif d.out then
          add('out', { status = d.status, reason = d.outReason,
            text = d.name .. ': ' .. d.statusText
              .. (type(d.outReason) == 'string' and d.outReason ~= '' and (' (' .. d.outReason .. ')') or '') }, d)
        end
      end
      if d.penalty > p.penalty then
        local add_s = d.penalty - p.penalty
        add('penalty', { seconds = add_s, total = d.penalty,
          text = d.name .. string.format(': +%.1fs penalty', add_s) }, d)
      end
    end
  end

  local pf, cf = ps.fastestLap, cs.fastestLap
  if cf and cf.time and (not pf or pf.time ~= cf.time or pf.id ~= cf.id) then
    local who = cur.byId[cf.id]
    add('fastest', { time = cf.time, timeText = cf.text,
      text = 'Fastest lap: ' .. ((who and who.name) or '') .. ' ' .. cf.text },
      { id = cf.id, name = who and who.name or cf.name })
  end

  local live = cs.phase == 'racing' or cs.phase == 'qualifying'
  if live and ps.phase == cs.phase and cur.leaderId ~= nil and prev.leaderId ~= nil
      and cur.leaderId ~= prev.leaderId then
    local who, was = cur.byId[cur.leaderId], prev.byId[prev.leaderId]
    if who then
      add('leader', { prevId = prev.leaderId, prevName = was and was.name or '',
        text = who.name .. (cur.quali and ' is on provisional pole' or ' leads')
          .. ((was and not cur.quali) and (', from ' .. was.name) or '') }, who)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Publishing: encode once per change, hand the frame to every stream.
-- ---------------------------------------------------------------------------
local function eventsList()
  local list = {}
  for i = 1, #S.events do list[i] = S.events[i] end
  return list
end

local function publish(model)
  local session = encode(model.session)
  local drivers = encode(model.drivers)
  local grid = encode(model.grid)
  local events = encode(eventsList())
  local teams = encode(model.teams or {})
  local camera = encode(model.camera)
  local serverBuild = model.serverBuild and jsonString(model.serverBuild) or 'null'
  local key = table.concat({ tostring(model.connected), serverBuild, session, drivers, grid, events,
    teams, camera, S.styleSeq }, '\1')
  if key == S.bodyKey then return false end
  S.bodyKey = key
  S.seq = S.seq + 1
  S.body = table.concat({
    '{"feed":', SCHEMA,
    ',"source":"Phoenix Race Manager"',
    ',"build":', jsonString(tostring(host.build or '?')),
    ',"serverBuild":', serverBuild,
    ',"epoch":', jsonNumber(S.epoch),
    ',"seq":', jsonNumber(S.seq),
    ',"ts":', jsonNumber(os.time()),
    ',"connected":', model.connected and 'true' or 'false',
    ',"styleSeq":', jsonNumber(S.styleSeq),
    ',"session":', session,
    ',"drivers":', drivers,
    ',"grid":', grid,
    ',"teams":', teams,
    ',"camera":', camera,
    ',"events":', events,
    '}',
  })
  S.parts = { session = session, drivers = drivers, grid = grid, events = events, teams = teams,
    camera = camera }
  S.frame = 'id: ' .. istr(S.seq) .. '\nevent: state\ndata: ' .. S.body .. '\n\n'
  for _, cl in ipairs(S.clients) do
    if cl.state == 'stream' then
      -- Not a byte of the waiting frame out yet: it is stale, replace it.
      if cl.cur and cl.off == 1 and cl.replaceable then cl.cur = S.frame
      else cl.next = S.frame end
    end
  end
  return true
end

-- Rebuild from what we hold, find the events, publish.
local function refresh()
  local model = buildModel(S.connected and S.last or nil, S.teams, S.camera)
  diff(S.prev, model)
  S.prev = model
  publish(model)
end

local function refreshSafely()
  local ok, err = pcall(refresh)
  if not ok then
    local msg = tostring(err)
    if S.loggedError ~= msg then
      S.loggedError = msg
      say('E', 'could not build the feed: ' .. msg)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Who the camera is on. THIS PC's camera: the feed has to run on the camera
-- operator's game. Tabbing onto a rival attaches their car, so the attached
-- car's BeamMP owner is the driver on screen. Free camera, singleplayer and a
-- car BeamMP has no owner for are nobody.
-- ---------------------------------------------------------------------------
local function watchedPid()
  if commands and commands.isFreeCamera and commands.isFreeCamera() == true then return nil end
  local veh
  if type(getPlayerVehicle) == 'function' then veh = getPlayerVehicle(0)
  elseif be then veh = be:getPlayerVehicle(0) end
  if not veh then return nil end
  -- Closure: a deleted vehicle's __index raises outside a bare pcall.
  local ok, id = pcall(function () return veh:getID() end)
  -- Ids at or under 0 find a non-vehicle object on 0.40.
  if not ok or type(id) ~= 'number' or id <= 0 then return nil end
  if not (MPVehicleGE and type(MPVehicleGE.getVehicleByGameID) == 'function') then return nil end
  local v = MPVehicleGE.getVehicleByGameID(id)
  local owner = type(v) == 'table' and v.ownerID or nil
  if owner == nil then return nil end
  return tostring(owner)
end

-- A camera move republishes at once, not on the next RM_Update.
local function cameraCheck()
  local ok, pid = pcall(watchedPid)
  if not ok then
    if S.cameraError ~= tostring(pid) then
      S.cameraError = tostring(pid)
      say('W', 'could not tell who the camera is on: ' .. S.cameraError)
    end
    pid = nil
  end
  if pid == S.camera then return end
  S.camera = pid
  refreshSafely()
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local function validPort(p)
  p = tonumber(p)
  if not p or p ~= p or p ~= math.floor(p) or p < PORT_MIN or p > PORT_MAX then return nil end
  return math.floor(p)
end

-- A stored key: 20 lower-case letters and digits, or nothing.
local function validKey(k)
  return type(k) == 'string' and #k == 20 and k:match('^[a-z0-9]+$') and k or nil
end

local function settings()
  if not S.settings then
    local s = { on = false, port = DEFAULT_PORT, lan = false, control = false }
    if type(jsonReadFile) == 'function' then
      local ok, data = pcall(jsonReadFile, SETTINGS_FILE)
      if ok and type(data) == 'table' then
        s.on = data.on == true
        s.port = validPort(data.port) or DEFAULT_PORT
        s.lan = data.lan == true
        s.styleKey = validKey(data.styleKey)
        -- Race control needs its key: on without one is off.
        s.controlKey = validKey(data.controlKey)
        s.control = data.control == true and s.controlKey ~= nil
      end
    end
    S.settings = s
  end
  return S.settings
end

local function saveSettings()
  local s = settings()
  if type(jsonWriteFile) ~= 'function'
      or not pcall(jsonWriteFile, SETTINGS_FILE,
        { on = s.on, port = s.port, lan = s.lan, styleKey = s.styleKey,
          control = s.control, controlKey = s.controlKey }, true) then
    say('W', 'could not save ' .. SETTINGS_FILE)
  end
end

-- ---------------------------------------------------------------------------
-- The panel's status
-- The style key: 20 letters and digits, kept with the settings. Only a write
-- (the style, the overlay folder) needs it; the overlay itself never does.
local function newKey()
  local seed = os.time() + math.floor((os.clock() % 1) * 1e6)
  local addr = tonumber((tostring({}):match('0x(%x+)') or tostring({}):match('(%x+)$') or '0'), 16) or 0
  seed = (seed * 69069 + addr) % 2147483647
  local okS, sock = pcall(require, 'socket')
  if okS and type(sock) == 'table' and sock.gettime then
    seed = (seed + math.floor((sock.gettime() % 1000) * 1e6)) % 2147483647
  end
  if math.random then seed = (seed + math.random(1, 2147483646)) % 2147483647 end
  if seed == 0 then seed = 1 end
  local chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
  local out = {}
  for i = 1, 20 do
    seed = (seed * 48271) % 2147483647
    local k = seed % 36 + 1
    out[i] = chars:sub(k, k)
  end
  return table.concat(out)
end

local function ensureKey()
  local s = settings()
  if not s.styleKey then
    s.styleKey = newKey()
    saveSettings()
  end
  return s.styleKey
end

-- ---------------------------------------------------------------------------
local function streamCount()
  local n = 0
  for _, cl in ipairs(S.clients) do
    if cl.state == 'stream' then n = n + 1 end
  end
  return n
end

local function status()
  local s = settings()
  local base = 'http://127.0.0.1:' .. istr(s.port)
  local lanBase = (s.lan and S.lanIp) and ('http://' .. S.lanIp .. ':' .. istr(s.port)) or nil
  local ok, sock = pcall(require, 'socket')
  return {
    available = ok and type(sock) == 'table',
    on = s.on, running = S.running, starting = S.starting,
    port = s.port, lan = s.lan, error = S.error,
    clients = #S.clients, streams = streamCount(), lanIp = S.lanIp,
    urls = {
      base = base,
      overlay = base .. '/overlay',
      tower = base .. '/overlay?view=tower',
      grid = base .. '/overlay?view=grid',
      banner = base .. '/overlay?view=banner',
      json = base .. '/live.json',
      drivers = base .. '/drivers.json',
      stream = base .. '/stream',
      lan = lanBase,
      lanOverlay = lanBase and (lanBase .. '/overlay') or nil,
      lanJson = lanBase and (lanBase .. '/live.json') or nil,
      -- The style editor: the key rides the fragment, which no request carries.
      styleBase = base .. '/style',
      style = s.styleKey and (base .. '/style#key=' .. s.styleKey) or nil,
      -- Race control, the same way: this PC's link, and the network's.
      control = (s.control and s.controlKey) and (base .. '/control#key=' .. s.controlKey) or nil,
      lanControl = (s.control and s.controlKey and lanBase)
        and (lanBase .. '/control#key=' .. s.controlKey) or nil,
    },
    canOpen = type(openWebBrowser) == 'function',
    styleSeq = S.styleSeq,
    control = s.control,
    admin = Ctl.isAdmin(),
  }
end

-- To the panel. Settings, state and errors go at once (force); a change in the
-- reader count alone waits its turn (readerCountChanged, from the poll).
local function pushStatus()
  local st = status()
  S.statusAt, S.pushedClients, S.pushedStreams = S.clock, st.clients, st.streams
  if type(guihooks) == 'table' and type(guihooks.trigger) == 'function' then
    pcall(guihooks.trigger, 'RaceManagerFeed', st)
  end
end

local function readerCountChanged()
  return #S.clients ~= S.pushedClients or streamCount() ~= S.pushedStreams
end

-- ---------------------------------------------------------------------------
-- The listener
-- ---------------------------------------------------------------------------
local function closeSock(sock)
  if sock then pcall(sock.close, sock) end
end

local function closeAll()
  for _, cl in ipairs(S.clients) do closeSock(cl.sock) end
  S.clients = {}
  S.writing = nil
  closeSock(S.srv)
  S.srv = nil
  S.running, S.starting = false, false
  if rawget(_G, SLOT) == S.slot then rawset(_G, SLOT, nil) end
end

-- What a reloaded copy of this module finds: the way to shut this one.
S.slot = { close = closeAll }

-- A copy of this module from before a reload (package.loaded dropped it, the
-- listener did not die with it) holds the port: close it first.
local function closeStale()
  local stale = rawget(_G, SLOT)
  if type(stale) == 'table' and stale ~= S.slot and type(stale.close) == 'function' then
    pcall(stale.close)
  end
  if rawget(_G, SLOT) ~= S.slot then rawset(_G, SLOT, nil) end
end

-- The address other PCs reach this one on. A UDP "connect" sends nothing; it
-- only picks the interface the route would use.
local function lanAddress(socket)
  local ok, ip = pcall(function ()
    local u = socket.udp()
    u:setpeername('192.0.2.1', 9)
    local addr = u:getsockname()
    u:close()
    return addr
  end)
  if ok and type(ip) == 'string' and ip ~= '0.0.0.0' and not ip:find('^127%.') then return ip end
  return nil
end

-- One try at the port. Returns the listener, or nil and LuaSocket's reason.
local function bindOnce(socket)
  local s = settings()
  local make = socket.tcp4 or socket.tcp
  local srv, err = make()
  if not srv then return nil, err end
  -- NOT socket.bind(): it sets reuseaddr, which on Windows lets a second
  -- program share the port. Elsewhere it only skips TIME_WAIT after a reload.
  if not isWindows() then pcall(srv.setoption, srv, 'reuseaddr', true) end
  local ok, berr = srv:bind(s.lan and '0.0.0.0' or '127.0.0.1', s.port)
  if not ok then closeSock(srv); return nil, berr end
  ok, berr = srv:listen(32)
  if not ok then closeSock(srv); return nil, berr end
  srv:settimeout(0)
  return srv
end

local function bindFailed(err)
  local s = settings()
  err = tostring(err)
  if err:find('in use', 1, true) then
    return 'Port ' .. s.port .. ' is in use by another program. Pick another port.'
  elseif err:find('permission', 1, true) or err:find('denied', 1, true) then
    return 'Port ' .. s.port .. ' is reserved on this PC (Windows keeps some for Hyper-V '
      .. 'and WSL). Pick another port.'
  end
  return 'Could not open port ' .. s.port .. ': ' .. err
end

local function tryStart()
  local okReq, socket = pcall(require, 'socket')
  if not okReq or type(socket) ~= 'table' then
    S.starting, S.running = false, false
    S.error = 'The socket library is not available in this version of the game.'
    return
  end
  local srv, err = bindOnce(socket)
  if srv then
    S.srv, S.running, S.starting, S.error = srv, true, false, nil
    S.lanIp = settings().lan and lanAddress(socket) or nil
    rawset(_G, SLOT, S.slot)
    say('I', 'serving on ' .. (settings().lan and '0.0.0.0' or '127.0.0.1') .. ':' .. settings().port)
    -- Readers get what we already hold, at once.
    S.prev, S.bodyKey = nil, nil
    refreshSafely()
    return
  end
  S.bindTries = S.bindTries + 1
  if tostring(err):find('in use', 1, true) and S.bindTries < BIND_TRIES then
    -- A reload's old socket may still be letting go: try again shortly.
    S.starting, S.retryWait = true, 1
    return
  end
  S.starting, S.running = false, false
  S.error = bindFailed(err)
  say('W', S.error)
end

-- The style as it is now, encoded once for /style.json and the SSE frame.
local function styleEncode()
  S.styleBody = encode(Style.toWire(S.style, S.styleSeq, S.assetsRev))
  S.styleFrame = 'event: style\ndata: ' .. S.styleBody .. '\n\n'
end

local function start()
  closeAll()
  closeStale()
  S.error, S.bindTries, S.overlay, S.stylePage = nil, 0, nil, nil
  S.pollWait = 0
  ensureKey()
  S.style = Style.load()
  S.styleSeq = S.styleSeq + 1
  styleEncode()
  tryStart()
  pushStatus()
end

local function stop()
  closeAll()
end

-- Start from the extension's own hooks: whatever goes wrong, the extension
-- loads and the panel says why.
local function startSafely()
  local ok, err = pcall(start)
  if not ok then
    pcall(closeAll)
    S.error = 'The feed could not start: ' .. tostring(err)
    say('E', S.error)
    pushStatus()
  end
end

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------
local REASON = {
  [200] = 'OK', [201] = 'Created', [204] = 'No Content', [400] = 'Bad Request',
  [403] = 'Forbidden', [404] = 'Not Found', [405] = 'Method Not Allowed',
  [411] = 'Length Required', [413] = 'Payload Too Large', [415] = 'Unsupported Media Type',
  [429] = 'Too Many Requests', [431] = 'Request Header Fields Too Large',
  [500] = 'Internal Server Error', [503] = 'Service Unavailable',
}

local function response(code, ctype, body, extra, headOnly, cache)
  local h = { 'HTTP/1.1 ' .. code .. ' ' .. (REASON[code] or 'OK') }
  if code ~= 204 then
    body = body or ''
    h[#h + 1] = 'Content-Type: ' .. (ctype or 'text/plain; charset=utf-8')
    h[#h + 1] = 'Content-Length: ' .. #body
  end
  h[#h + 1] = 'Cache-Control: ' .. (cache or 'no-store')
  h[#h + 1] = 'Access-Control-Allow-Origin: *'
  h[#h + 1] = 'X-Content-Type-Options: nosniff'
  h[#h + 1] = 'Connection: close'
  if extra then for i = 1, #extra do h[#h + 1] = extra[i] end end
  return table.concat(h, '\r\n') .. '\r\n\r\n' .. ((headOnly or code == 204) and '' or body)
end

local BUSY = response(503, nil, 'Too many readers. Close one and try again.\n')

-- The Host a request names must be this PC or the local network: a web page
-- that points its own name at 127.0.0.1 (DNS rebinding) is turned away.
local function hostAllowed(h)
  if h == nil or h == '' then return true end
  h = h:lower():gsub('%s+$', '')
  if h:sub(1, 1) == '[' then return true end                   -- an IPv6 literal
  local name = h:match('^([^:]+)') or h
  if name:match('^%d+%.%d+%.%d+%.%d+$') then return true end
  if name == 'localhost' or not name:find('.', 1, true) then return true end
  for _, tail in ipairs({ '.localhost', '.local', '.lan', '.home.arpa' }) do
    if name:sub(-#tail) == tail then return true end
  end
  return false
end

local function indexPage()
  local s = settings()
  local links = {
    { '/overlay?view=tower', 'Overlay: running order (tower)' },
    { '/overlay?view=grid', 'Overlay: starting grid' },
    { '/overlay?view=banner', 'Overlay: session banner (lap, flag, clock)' },
    { '/overlay?view=results', 'Overlay: results' },
    { '/overlay?view=ticker', 'Overlay: event ticker' },
    { '/live.json', 'live.json: everything' },
    { '/drivers.json', 'drivers.json: the running order' },
    { '/grid.json', 'grid.json: the starting grid' },
    { '/session.json', 'session.json: lap, clock, flags' },
    { '/events.json', 'events.json: the last 30 events' },
    { '/stream', 'stream: live updates (Server-Sent Events)' },
    { '/teams.json', 'teams.json: the league\'s teams' },
    { '/camera.json', 'camera.json: the driver this PC\'s camera is on' },
    { '/style', 'Style editor (open it from the Feed panel: it needs the key)' },
    { '/style.json', 'style.json: the overlay\'s look' },
    { '/assets.json', 'assets.json: the overlay folder' },
  }
  local items = {}
  for _, l in ipairs(links) do
    items[#items + 1] = '<li><a href="' .. l[1] .. '">' .. l[2] .. '</a></li>'
  end
  return '<!doctype html><html><head><meta charset="utf-8"><title>PRM Broadcast feed</title>'
    .. '<style>body{font:15px/1.5 system-ui,sans-serif;margin:2em;max-width:44em}'
    .. 'code{background:#8882;padding:0 .3em}</style></head><body>'
    .. '<h1>Phoenix Race Manager: Broadcast feed</h1>'
    .. '<p>Serving on port <code>' .. s.port .. '</code>, build <code>' .. tostring(host.build)
    .. '</code>. Feed schema <code>' .. SCHEMA .. '</code>.</p><ul>' .. table.concat(items)
    .. '</ul><p>Add an overlay link as an OBS Browser Source, or point your own graphics '
    .. 'at the JSON. The schema is in docs/REFERENCE.md, "Broadcast feed".</p></body></html>'
end

local FALLBACK_OVERLAY = '<!doctype html><html><head><meta charset="utf-8"><title>PRM overlay</title>'
  .. '</head><body style="font:16px system-ui;color:#fff;background:transparent">'
  .. 'The overlay page is missing from this install. The data is at '
  .. '<a href="/live.json" style="color:#fc6">/live.json</a>.</body></html>'

local FALLBACK_STYLE = '<!doctype html><html><head><meta charset="utf-8"><title>PRM style</title>'
  .. '</head><body style="font:16px system-ui">The style editor page is missing from this '
  .. 'install. The style is at <a href="/style.json">/style.json</a>.</body></html>'

-- A page from the game's own files (the mounted client zip), read once a start.
local function bundled(file, slot, fallback)
  if S[slot] == nil then
    S[slot] = false
    pcall(function ()
      if type(FS) == 'table' and FS.fileExists and not FS:fileExists(file) then return end
      if type(readFile) ~= 'function' then return end
      local text = readFile(file)
      if type(text) == 'string' and #text > 0 then S[slot] = text end
    end)
  end
  return S[slot] or fallback
end

local function overlayPage() return bundled(OVERLAY_FILE, 'overlay', FALLBACK_OVERLAY) end
local function stylePage() return bundled(STYLE_PAGE_FILE, 'stylePage', FALLBACK_STYLE) end
function Ctl.page()
  return bundled(CONTROL_PAGE_FILE, 'controlPage', '<!doctype html><html><head><meta charset="utf-8">'
    .. '<title>PRM race control</title></head><body style="font:16px system-ui">The race control '
    .. 'page is missing from this install.</body></html>')
end

local JSON = 'application/json; charset=utf-8'
local HTML = 'text/html; charset=utf-8'

local function sendOnce(cl, text)
  cl.state, cl.cur, cl.off, cl.next = 'send', text, 1, nil
end

-- ---------------------------------------------------------------------------
-- Writes: the style and the overlay folder. Key, Origin, one at a time.
-- ---------------------------------------------------------------------------
local BODY_PER_POLL = 256 * 1024   -- bytes read a poll, at most
local BODY_CHUNK = 65536
local BODY_IDLE = 10               -- seconds a body may stall
local BAD_KEYS = 10                -- wrong keys a minute before the lockout
local LOCKOUT = 60

local function jsonReply(code, fields)
  local out = {}
  for _, kv in ipairs(fields) do out[#out + 1] = jsonString(kv[1]) .. ':' .. kv[2] end
  return response(code, JSON, '{' .. table.concat(out, ',') .. '}')
end

local function jsonList(list)
  local out = {}
  for i, v in ipairs(list) do out[i] = jsonString(tostring(v)) end
  return '[' .. table.concat(out, ',') .. ']'
end

local function refuse(code, msg)
  return jsonReply(code, { { 'ok', 'false' }, { 'error', jsonString(msg) } })
end

-- The overlay folder as /assets.json.
local function assetsBody()
  local files, total = {}, 0
  for _, f in ipairs(Style.files.list()) do
    local _, t = Style.validName(f.name)
    total = total + f.size
    files[#files + 1] = '{"name":' .. jsonString(f.name) .. ',"size":' .. jsonNumber(f.size)
      .. ',"kind":' .. jsonString(t.kind) .. '}'
  end
  return '{"files":[' .. table.concat(files, ',') .. '],"total":' .. jsonNumber(total)
    .. ',"maxBytes":' .. jsonNumber(Style.MAX_FILE) .. ',"maxFiles":' .. jsonNumber(Style.MAX_FILES)
    .. ',"maxTotal":' .. jsonNumber(Style.MAX_TOTAL) .. ',"rev":' .. jsonNumber(S.assetsRev) .. '}'
end

-- Every open overlay gets the new look; pollers see styleSeq move.
local function publishStyle()
  S.styleSeq = S.styleSeq + 1
  styleEncode()
  for _, cl in ipairs(S.clients) do
    if cl.state == 'stream' then cl.styleNext = S.styleFrame end
  end
  S.bodyKey = nil
  refreshSafely()
end

-- The routes that write, and the most each may send.
local function writeRoute(method, path)
  if method == 'POST' and path == '/style.json' then
    return { kind = 'style', max = Style.MAX_STYLE_BODY }
  end
  if method == 'POST' and path == '/control' then
    return { kind = 'control', max = Ctl.MAX_BODY }
  end
  local name = path:match('^/assets/(.+)$')
  if name and (method == 'POST' or method == 'DELETE') then
    return { kind = method == 'POST' and 'upload' or 'delete', name = name,
      max = method == 'POST' and Style.MAX_FILE or 0 }
  end
  return nil
end

local function finishWrite(cl)
  local route, body = cl.route, table.concat(cl.parts)
  cl.parts = nil
  if S.writing == cl then S.writing = nil end
  local ok, res = pcall(function ()
    if route.kind == 'control' then
      if type(jsonDecode) ~= 'function' then return refuse(500, 'No JSON reader in this game build') end
      local okJ, input = pcall(jsonDecode, body)
      if not okJ or type(input) ~= 'table' then return refuse(400, 'The action is not a JSON object') end
      local code, why = Ctl.run(input)
      if code then return refuse(code, why) end
      return jsonReply(200, { { 'ok', 'true' }, { 'action', jsonString(input.action) } })
    end
    if route.kind == 'style' then
      if type(jsonDecode) ~= 'function' then return refuse(500, 'No JSON reader in this game build') end
      local okJ, input = pcall(jsonDecode, body)
      if not okJ or type(input) ~= 'table' then return refuse(400, 'The style is not a JSON object') end
      local style, rejected = Style.clean(input, S.style)
      S.style = style
      if not Style.save(style) then say('W', 'could not save ' .. Style.STYLE_FILE) end
      publishStyle()
      return jsonReply(200, { { 'ok', 'true' }, { 'rejected', jsonList(rejected) },
        { 'style', S.styleBody } })
    end
    local name, t, ext = Style.validName(route.name)
    if not name then return refuse(400, 'A file name is lower-case letters, digits, dot, dash and '
      .. 'underscore, ending in a known type (png, jpg, gif, webp, svg, woff2, woff, ttf, otf, css)') end
    if route.kind == 'delete' then
      if not Style.files.read(name) then return refuse(404, 'No file called ' .. name) end
      Style.files.remove(name)
      S.assetsRev = S.assetsRev + 1
      publishStyle()
      return jsonReply(200, { { 'ok', 'true' }, { 'name', jsonString(name) } })
    end
    local why = Style.checkBytes(ext, body)
    if why then return refuse(415, name .. ': ' .. why) end
    local full, code = Style.room(name, #body)
    if full then return refuse(code or 413, name .. ': ' .. full) end
    if not Style.files.write(name, body) then return refuse(500, 'Could not write ' .. name) end
    S.assetsRev = S.assetsRev + 1
    publishStyle()
    return jsonReply(201, { { 'ok', 'true' }, { 'name', jsonString(name) },
      { 'size', jsonNumber(#body) }, { 'kind', jsonString(t.kind) } })
  end)
  sendOnce(cl, ok and res or refuse(500, 'The write failed: ' .. tostring(res)))
end

-- A wrong key counts; ten in a minute shuts writes for a minute.
local function badKey()
  local now, kept = S.clock, {}
  for _, t in ipairs(S.badKeys) do if now - t < 60 then kept[#kept + 1] = t end end
  kept[#kept + 1] = now
  S.badKeys = kept
  if #kept >= BAD_KEYS then S.lockUntil = now + LOCKOUT end
end

-- ---------------------------------------------------------------------------
-- Race control: the page, its state, and the actions it may ask for
-- ---------------------------------------------------------------------------
local CONTROL_OFF = 'Race control is off. Turn it on in the Feed panel.'
local CONTROL_BADKEY = 'The race control key is missing or wrong: copy the link from the Feed panel again'

-- name = { fn = the extension function, admin = needs the login, arg = what it takes }
Ctl.ACTIONS = {
  startQualifying = { fn = 'startQualifying', admin = true },
  generateGrid    = { fn = 'generateGrid', admin = true },
  startCountdown  = { fn = 'startCountdown', admin = true },
  startRace       = { fn = 'startRace', admin = true },
  readyAll        = { fn = 'readyAll', admin = true },
  flag            = { fn = 'setFlag', admin = true, arg = 'flag' },
  caution         = { fn = 'caution', admin = true },
  restart         = { fn = 'restart', admin = true },
  cancelRestart   = { fn = 'cancelRestart', admin = true },
  endSession      = { fn = 'endRace', admin = true },
  restartFromGrid = { fn = 'restartFromGrid', admin = true },
  resetSession    = { fn = 'resetLeaderboard', admin = true },
  -- This PC's camera, as the broadcast board's names do: no login needed.
  watch           = { fn = 'spectateDriver', arg = 'id' },
}

-- The key a request carries: the header, or ?key= for a client that cannot set one.
function Ctl.keyOf(lower, query)
  return lower:match('\nx%-prm%-key:[ \t]*([%w]+)') or ('&' .. (query or '')):match('&key=(%w+)')
end

function Ctl.isAdmin()
  if type(host.isAdmin) ~= 'function' then return false end
  local ok, v = pcall(host.isAdmin)
  return ok and v == true
end

-- One action. Returns nothing, or the HTTP code and why not.
function Ctl.run(input)
  local name = type(input.action) == 'string' and input.action or ''
  local a = Ctl.ACTIONS[name]
  if not a then return 400, 'Unknown action: ' .. name:sub(1, 40) end
  if a.admin and not Ctl.isAdmin() then return 403, 'This game is not logged in as an admin' end
  local fn = type(host.ext) == 'table' and host.ext[a.fn] or nil
  if type(fn) ~= 'function' then return 500, 'Not available in this build' end
  local arg = nil
  if a.arg == 'flag' then
    arg = input.flag
    if arg ~= 'green' and arg ~= 'yellow' and arg ~= 'red' then
      return 400, 'The flag is green, yellow or red'
    end
  elseif a.arg == 'id' then
    arg = tonumber(input.id)
    if not arg or arg ~= arg or arg < 0 or arg ~= math.floor(arg) then return 400, 'No driver id' end
  end
  local ok, err = pcall(fn, arg)
  if not ok then return 500, 'The action failed: ' .. tostring(err) end
  say('I', 'race control: ' .. name .. (arg ~= nil and (' ' .. tostring(arg)) or ''))
end

-- What the page needs beyond the public feed: whether this game can run the
-- race, and what decides which buttons a phase gets (as the panel's).
function Ctl.state()
  local d = S.last or {}
  local ready, total = 0, 0
  for _, r in ipairs(type(d.drivers) == 'table' and d.drivers or {}) do
    if type(r) == 'table' then
      if r.status == 'gridded' then ready, total = ready + 1, total + 1
      elseif r.status == 'called' then total = total + 1 end
    end
  end
  local role = nil
  if type(host.role) == 'function' then
    local ok, r = pcall(host.role)
    if ok and type(r) == 'string' then role = r end
  end
  local admin = Ctl.isAdmin()
  return encode({
    _k = { 'admin', 'role', 'build', 'connected', 'phase', 'kind', 'flag', 'pacing',
      'caution', 'cautionPending', 'restartPending', 'paceLap', 'pointToPoint',
      'readyCheck', 'ready', 'readyTotal' },
    admin = admin, role = admin and role or nil, build = tostring(host.build),
    connected = S.connected == true,
    phase = type(d.phase) == 'string' and d.phase or 'waiting',
    kind = d.sessionKind == 'quali' and 'quali' or 'race',
    flag = (d.flag == 'yellow' or d.flag == 'red') and d.flag or 'green',
    pacing = d.pacing == true, caution = d.caution == true,
    cautionPending = d.cautionPending == true, restartPending = d.restartPending == true,
    paceLap = d.paceLap == true, pointToPoint = d.pointToPoint == true,
    readyCheck = d.readyCheck ~= false, ready = ready, readyTotal = total,
  })
end

-- GET /control (the page) and /control.json (its state, with the key).
function Ctl.get(cl, path, query, lower, headOnly)
  local s = settings()
  if not s.control then return sendOnce(cl, response(404, nil, CONTROL_OFF .. '\n')) end
  if path ~= '/control.json' then
    -- It acts with the key it holds: no other site may frame it.
    return sendOnce(cl, response(200, HTML, Ctl.page(),
      { "Content-Security-Policy: frame-ancestors 'none'", 'X-Frame-Options: DENY' }, headOnly))
  end
  if S.clock < S.lockUntil then
    return sendOnce(cl, refuse(429, 'Too many wrong keys: try again in a minute'))
  end
  if not s.controlKey or Ctl.keyOf(lower, query) ~= s.controlKey then
    badKey()
    return sendOnce(cl, refuse(403, CONTROL_BADKEY))
  end
  sendOnce(cl, response(200, JSON, Ctl.state(), nil, headOnly))
end

local function beginWrite(cl, method, path, query, lower, hostHeader, rest)
  local route = writeRoute(method, path)
  if not route then
    return sendOnce(cl, response(405, nil, 'Read only\n', { 'Allow: GET, HEAD, OPTIONS' }))
  end
  local control = route.kind == 'control'
  if control and not settings().control then return sendOnce(cl, refuse(404, CONTROL_OFF)) end
  -- From a browser, only from this feed's own pages.
  local origin = lower:match('\norigin:[ \t]*([^\r\n]*)')
  if origin and origin ~= '' and origin:gsub('%s+$', '') ~= 'http://' .. tostring(hostHeader or ''):gsub('%s+$', '') then
    return sendOnce(cl, refuse(403, 'Writes are only taken from this feed\'s own pages'))
  end
  if S.clock < S.lockUntil then
    return sendOnce(cl, refuse(429, 'Too many wrong keys: writes are shut for a minute'))
  end
  local key = Ctl.keyOf(lower, query)
  local want = control and settings().controlKey or settings().styleKey
  if not want or key ~= want then
    badKey()
    return sendOnce(cl, refuse(403, control and CONTROL_BADKEY
      or 'The style key is missing or wrong: open the style editor from the Feed panel'))
  end
  if lower:find('\ntransfer%-encoding:') then
    return sendOnce(cl, refuse(411, 'Send a Content-Length, not chunks'))
  end
  local len = tonumber(lower:match('\ncontent%-length:[ \t]*(%d+)'))
  if route.kind == 'delete' then len = len or 0 end
  if not len then return sendOnce(cl, refuse(411, 'A Content-Length is needed')) end
  if len > route.max then
    return sendOnce(cl, refuse(413, 'Too large: at most ' .. route.max .. ' bytes'))
  end
  -- One upload at a time. A race control action is a few bytes and never waits
  -- behind a logo.
  if not control and S.writing and S.writing ~= cl then
    return sendOnce(cl, refuse(503, 'Another upload is running: try again in a moment'))
  end
  if lower:find('\nexpect:[ \t]*100%-continue') then
    pcall(cl.sock.send, cl.sock, 'HTTP/1.1 100 Continue\r\n\r\n')
  end
  rest = rest or ''
  cl.state, cl.route, cl.want = 'body', route, len
  cl.parts, cl.got, cl.bodyAt = { rest:sub(1, len) }, math.min(#rest, len), S.clock
  if not control then S.writing = cl end
  if cl.got >= cl.want then return finishWrite(cl) end
end

local function readBody(cl)
  local budget = BODY_PER_POLL
  while cl.got < cl.want and budget > 0 do
    local data, err, part = cl.sock:receive(math.min(BODY_CHUNK, cl.want - cl.got, budget))
    local chunk = data or part
    if chunk and #chunk > 0 then
      cl.parts[#cl.parts + 1] = chunk
      cl.got, budget, cl.bodyAt = cl.got + #chunk, budget - #chunk, S.clock
    end
    if err == 'closed' then return 'drop' end
    if err then break end
  end
  if cl.got >= cl.want then return finishWrite(cl) end
  if S.clock - cl.bodyAt > BODY_IDLE then return 'drop' end
end

local function handle(cl, head, rest)
  local method, target = head:match('^(%u+)%s+(%S+)%s+HTTP/1%.[01]')
  if not method then return sendOnce(cl, response(400, nil, 'Bad request\n')) end
  local lower = head:lower()
  local hostHeader = lower:match('\nhost:[ \t]*([^\r\n]*)')
  if not hostAllowed(hostHeader) then
    return sendOnce(cl, response(403, nil, 'This feed only answers on this PC and the local network.\n'))
  end
  if method == 'OPTIONS' then
    return sendOnce(cl, response(204, nil, nil, {
      'Access-Control-Allow-Methods: GET, HEAD, OPTIONS',
      'Access-Control-Allow-Headers: *',
      'Access-Control-Allow-Private-Network: true',
      'Access-Control-Max-Age: 600',
    }))
  end
  local rawPath = target:gsub('^%a+://[^/]*', ''):gsub('#.*$', '')
  local path, query = rawPath:match('^([^?]*)%??(.*)$')
  if path == '' then path = '/' end
  if path ~= '/' then path = path:gsub('/+$', '') end
  if method == 'POST' or method == 'DELETE' then
    return beginWrite(cl, method, path, query, lower, hostHeader, rest)
  end
  if method ~= 'GET' and method ~= 'HEAD' then
    return sendOnce(cl, response(405, nil, 'Read only\n', { 'Allow: GET, HEAD, OPTIONS' }))
  end
  local headOnly = method == 'HEAD'
  if path == '/control' or path == '/control.html' or path == '/control.json' then
    return Ctl.get(cl, path, query, lower, headOnly)
  end

  if path == '/stream' and not headOnly then
    cl.state = 'stream'
    cl.cur = 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\n'
      .. 'Cache-Control: no-store\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n'
      .. 'X-Accel-Buffering: no\r\n\r\nretry: 2000\n\n'
    cl.off = 1
    cl.replaceable = false
    cl.styleNext = S.styleFrame
    cl.next = S.frame
    return
  end
  -- A file from the overlay folder: exact type, sandboxed, cached for good when
  -- asked for by revision (?v=).
  local assetName = path:match('^/assets/(.+)$')
  if assetName then
    local name, t = Style.validName(assetName)
    local bytes = name and Style.files.read(name)
    if not bytes then return sendOnce(cl, response(404, nil, 'No such file\n')) end
    local cache = query:find('v=', 1, true) and 'public, max-age=31536000, immutable' or 'no-cache'
    return sendOnce(cl, response(200, t.ctype, bytes, {
      "Content-Security-Policy: sandbox; default-src 'none'; style-src 'unsafe-inline'",
    }, headOnly, cache))
  end
  local parts = S.parts or {}
  local body, ctype
  if path == '/live.json' then body, ctype = S.body, JSON
  elseif path == '/session.json' then body, ctype = parts.session, JSON
  elseif path == '/drivers.json' then body, ctype = parts.drivers, JSON
  elseif path == '/grid.json' then body, ctype = parts.grid, JSON
  elseif path == '/events.json' then body, ctype = parts.events, JSON
  elseif path == '/teams.json' then body, ctype = parts.teams or '[]', JSON
  elseif path == '/camera.json' then body, ctype = parts.camera or 'null', JSON
  elseif path == '/style.json' then body, ctype = S.styleBody or '{}', JSON
  elseif path == '/assets.json' then body, ctype = assetsBody(), JSON
  elseif path == '/style' or path == '/style.html' then body, ctype = stylePage(), HTML
  elseif path == '/overlay' or path == '/overlay.html' then body, ctype = overlayPage(), HTML
  elseif path == '/' or path == '/index.html' then body, ctype = indexPage(), HTML
  elseif path == '/stream' then body, ctype = '', 'text/event-stream; charset=utf-8'
  elseif path == '/favicon.ico' then return sendOnce(cl, response(204))
  else return sendOnce(cl, response(404, nil, 'Not found. Try /live.json\n')) end
  if body == nil then body = (path == '/live.json') and '{}' or 'null' end
  -- The style page saves with the key it holds: no other site may frame it
  -- and trick a click on Save. (The overlay stays frameable: the editor's
  -- previews and pages of your own embed it.)
  local extra = ctype == HTML and path:sub(1, 6) == '/style'
    and { "Content-Security-Policy: frame-ancestors 'none'", 'X-Frame-Options: DENY' } or nil
  sendOnce(cl, response(200, ctype, body, extra, headOnly))
end

-- Reading a request head, byte counts only (a line pattern buffers inside
-- LuaSocket and blocks on a half line).
local function readHead(cl)
  local data, err, part = cl.sock:receive(READ_CHUNK)
  local chunk = data or part
  if chunk and #chunk > 0 then cl.inbuf = cl.inbuf .. chunk end
  if err == 'closed' then return 'drop' end
  local stop = cl.inbuf:find('\r\n\r\n', 1, true) or cl.inbuf:find('\n\n', 1, true)
  if not stop then
    if #cl.inbuf > MAX_HEADER then
      sendOnce(cl, response(431, nil, 'Request too large\n'))
    elseif S.clock - cl.born > READ_TIMEOUT then
      return 'drop'
    end
    return
  end
  if stop > MAX_HEADER then return sendOnce(cl, response(431, nil, 'Request too large\n')) end
  -- The head ends at whichever blank line comes first; what follows is the
  -- start of a body (a write), kept.
  local crlf = cl.inbuf:find('\r\n\r\n', 1, true)
  local lf = cl.inbuf:find('\n\n', 1, true)
  local dl = 4
  if lf and (not crlf or lf < crlf) then stop, dl = lf, 2 else stop = crlf end
  local head = cl.inbuf:sub(1, stop - 1)
  local rest = cl.inbuf:sub(stop + dl)
  cl.inbuf = ''
  handle(cl, head .. '\n', rest)
end

-- Writing: resume where the last send stopped; the latest frame replaces any
-- unsent one, so a slow reader skips frames instead of falling behind. A few
-- whole items a poll (a style frame, then a state frame) when the socket takes
-- them.
local function flush(cl)
  for _ = 1, 3 do
    if not cl.cur then
      -- A new look goes before the next state frame, and is never replaced by one.
      if cl.styleNext then
        cl.cur, cl.styleNext, cl.off, cl.replaceable = cl.styleNext, nil, 1, false
      elseif cl.next then
        cl.cur, cl.next, cl.off = cl.next, nil, 1
        cl.replaceable = cl.state == 'stream'
      elseif cl.state == 'send' then
        return 'drop'
      elseif S.clock - cl.lastSend >= KEEPALIVE then
        cl.cur, cl.off, cl.replaceable = ': ka\n\n', 1, true
      else
        return
      end
    end
    local last, err, partial = cl.sock:send(cl.cur, cl.off)
    local sent = last or partial
    if sent and sent >= cl.off then
      cl.off = sent + 1
      cl.lastSend = S.clock
    end
    if err and err ~= 'timeout' then return 'drop' end
    if cl.off <= #cl.cur then
      if S.clock - cl.lastSend > WRITE_STALL then return 'drop' end
      return
    end
    cl.cur = nil
    -- Served. The reader hangs up first (Connection: close), which leaves the
    -- closed connection's TIME_WAIT on its side, not on this port.
    if cl.state == 'send' and not cl.next then
      cl.state, cl.drainUntil = 'drain', S.clock + DRAIN_FOR
      return
    end
  end
end

local function drain(cl)
  local _, err = cl.sock:receive(READ_CHUNK)
  if err == 'closed' or S.clock >= cl.drainUntil then return 'drop' end
  if err and err ~= 'timeout' then return 'drop' end
end

local function service(cl)
  if cl.state == 'drain' then return drain(cl) end
  if cl.state == 'body' then
    if readBody(cl) == 'drop' then return 'drop' end
    if cl.state == 'body' then return end
  end
  if cl.state == 'read' then
    if readHead(cl) == 'drop' then return 'drop' end
    if cl.state == 'read' then return end
  end
  return flush(cl)
end

local function poll()
  if S.starting then
    S.retryWait = S.retryWait - POLL_EVERY
    if S.retryWait <= 0 then
      tryStart()
      pushStatus()
    end
    return
  end
  if not S.srv then return end
  for _ = 1, ACCEPTS_PER_POLL do
    local sock = S.srv:accept()
    if not sock then break end
    sock:settimeout(0)
    pcall(sock.setoption, sock, 'tcp-nodelay', true)
    if #S.clients >= MAX_CLIENTS then
      pcall(sock.send, sock, BUSY)
      closeSock(sock)
    else
      S.clients[#S.clients + 1] = {
        sock = sock, state = 'read', inbuf = '', born = S.clock, lastSend = S.clock,
      }
    end
  end
  for i = #S.clients, 1, -1 do
    local cl = S.clients[i]
    if service(cl) == 'drop' then
      if S.writing == cl then S.writing = nil end
      closeSock(cl.sock)
      table.remove(S.clients, i)
    end
  end
  if S.clock - S.statusAt >= STATUS_EVERY and readerCountChanged() then pushStatus() end
end

-- ---------------------------------------------------------------------------
-- Entry points, merged onto the extension (raceManager.lua)
-- ---------------------------------------------------------------------------
function D.init(hostApi)
  if type(hostApi) ~= 'table' then return end
  if hostApi.build then host.build = hostApi.build end
  host.ext, host.isAdmin, host.role = hostApi.ext, hostApi.isAdmin, hostApi.role
end

-- Extension load: up again if it was left on. Idempotent.
function D.feedBoot()
  if settings().on and not (S.running or S.starting) then startSafely() end
end

-- The panel: on, port, LAN, each nil for unchanged.
function D.feedSet(on, port, lan)
  local s = settings()
  if port ~= nil then
    local p = validPort(port)
    if not p then
      S.error = 'The port must be a whole number from ' .. PORT_MIN .. ' to ' .. PORT_MAX .. '.'
      pushStatus()
      return
    end
    s.port = p
  end
  if on ~= nil then s.on = on == true end
  if lan ~= nil then s.lan = lan == true end
  saveSettings()
  if s.on then startSafely() else stop(); S.error = nil; pushStatus() end
end

function D.feedStatus()
  pushStatus()
end

-- Every RM_Update. Held while off, so turning the feed on mid-race has data.
function D.feedState(data)
  if type(data) ~= 'table' then return end
  S.last, S.connected = data, true
  -- The teams come on the sends that carry them; kept until the next list.
  if data.teams ~= nil then S.teams = indexTeams(data.teams) end
  if data.phase ~= 'countdown' then S.countdown = nil end
  if S.running then refreshSafely() end
end

-- RM_Countdown: 3, 2, 1, then 0 for GO or -1 for an abort.
function D.feedCountdown(n)
  n = tonumber(n)
  if not n then return end
  S.countdown = n > 0 and n or nil
  if not S.running then return end
  pcall(function ()
    local who = nil
    if n > 0 then addEvent('countdown', { count = n, text = tostring(n) }, who)
    elseif n == 0 then addEvent('go', { text = 'GO' }, who)
    else addEvent('abort', { text = 'Start aborted' }, who) end
  end)
  refreshSafely()
end

-- Left the server: readers see "not connected" rather than a frozen race.
function D.feedOffline()
  S.last, S.connected, S.countdown, S.teams = nil, false, nil, nil
  if S.running then refreshSafely() end
end

-- Extension unload (and leaving a server unmounts the mod): close everything.
-- The setting stays; the next load brings it back.
function D.feedStop(why)
  stop()
  if why ~= 'unload' then pushStatus() end
end

function D.feedUpdate(dt)
  if not (S.running or S.starting) then return end
  dt = tonumber(dt) or 0
  S.clock = S.clock + dt
  S.pollWait = S.pollWait - dt
  if S.pollWait > 0 then return end
  S.pollWait = POLL_EVERY
  local ok, err = pcall(poll)
  if not ok then
    say('E', 'stopped: ' .. tostring(err))
    closeAll()
    S.error = 'The feed stopped after an error: ' .. tostring(err)
    pushStatus()
  end
  if S.running and S.clock >= S.cameraAt then
    S.cameraAt = S.clock + CAMERA_EVERY
    cameraCheck()
  end
end

-- The panel's New key: the old link stops working.
function D.feedNewKey()
  local s = settings()
  s.styleKey = newKey()
  saveSettings()
  pushStatus()
end

-- The style editor's link, onto the clipboard. The game will not open a page on
-- this PC: 0.40's openWebBrowser logs "unable to open webpage due to domain
-- filter" for 127.0.0.1 and does nothing. The panel hears whether it copied.
function D.feedOpenStyle()
  local url = status().urls.style
  local copied = false
  if url and type(setClipboard) == 'function' then
    copied = pcall(setClipboard, url)
  end
  -- INERT on 0.40 (the domain filter). Kept for a game with no setClipboard.
  if url and not copied and type(openWebBrowser) == 'function' then pcall(openWebBrowser, url) end
  if type(guihooks) == 'table' and type(guihooks.trigger) == 'function' then
    pcall(guihooks.trigger, 'RaceManagerFeedCopy', { copied = copied })
  end
end

-- The panel's Race control switch. Its key is made the first time it goes on,
-- and kept, so a link given out works again after off and on.
function D.feedSetControl(on)
  local s = settings()
  s.control = on == true
  if s.control and not s.controlKey then s.controlKey = newKey() end
  saveSettings()
  pushStatus()
end

-- New key: race control links given out stop working.
function D.feedNewControlKey()
  local s = settings()
  s.controlKey = newKey()
  saveSettings()
  pushStatus()
end

-- The race control link onto the clipboard: this PC's, or with `lan` the
-- network's, for a phone or a second PC. As the style editor's, for the same reason.
function D.feedCopyControl(lan)
  local u = status().urls
  local url = (lan == true and u.lanControl) or u.control
  local copied = false
  if url and type(setClipboard) == 'function' then copied = pcall(setClipboard, url) end
  if type(guihooks) == 'table' and type(guihooks.trigger) == 'function' then
    pcall(guihooks.trigger, 'RaceManagerFeedCopy', { copied = copied, what = 'control' })
  end
end

-- The overlay folder, for logos and fonts by hand.
function D.feedOpenFolder()
  if FS and FS.directoryCreate then pcall(function () FS:directoryCreate(Style.DIR, true) end) end
  if Engine and Engine.Platform and Engine.Platform.exploreFolder then
    pcall(Engine.Platform.exploreFolder, '/' .. Style.DIR .. '/')
  end
end

-- For the test: the internals, read only.
function D.feedDebug()
  return S
end

-- A copy of this module loaded over an older one: the older listener goes.
closeStale()

return D
