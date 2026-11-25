-- Phoenix Race Manager: THE OVERLAY'S LOOK, for the broadcast feed (feed.lua).
--
-- One spec (D.SPEC) is the style: every key, its check and its default, in the
-- order it is written out. The style page in the browser posts changes, this
-- checks them and keeps what passes in the BeamNG user folder, and the overlay
-- applies it. Nothing that fails a check is kept: a style can only ever hold a
-- color, a bounded number, one of a list, short text, or a link to an image.
--
-- THE OVERLAY FOLDER (settings/raceManager/overlay/) holds the style file and
-- the streamer's own files: logos, fonts, a custom stylesheet. Names are plain
-- (lower-case letters, digits, dot, dash, underscore), the type comes from the
-- extension and the first bytes have to agree with it, and an SVG may hold no
-- script. Nothing outside the folder is ever read or written.

local D = {}

D.DIR = 'settings/raceManager/overlay'
D.STYLE_FILE = D.DIR .. '/style.json'
D.MAX_FILE = 4 * 1024 * 1024
D.MAX_FILES = 64
D.MAX_TOTAL = 32 * 1024 * 1024
D.MAX_STYLE_BODY = 64 * 1024

-- ---------------------------------------------------------------------------
-- Checks: each returns the clean value, or nil.
-- ---------------------------------------------------------------------------
local function utf8ok(s)
  if utf8 and utf8.len then return utf8.len(s) ~= nil end
  -- LuaJIT: no utf8 library. Walk the bytes.
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = c < 0x80 and 1 or (c >= 0xC2 and c < 0xE0 and 2) or (c >= 0xE0 and c < 0xF0 and 3)
      or (c >= 0xF0 and c < 0xF5 and 4) or nil
    if not len or i + len - 1 > n then return false end
    for j = i + 1, i + len - 1 do
      local cc = s:byte(j)
      if cc < 0x80 or cc > 0xBF then return false end
    end
    i = i + len
  end
  return true
end

local C = {}

function C.color(v)
  if type(v) ~= 'string' then return nil end
  if v:match('^#%x%x%x%x%x%x$') then return v:lower() end
  return nil
end

function C.num(lo, hi)
  return function (v)
    v = tonumber(v)
    if not v or v ~= v or v < lo or v > hi then return nil end
    return math.floor(v * 1000 + 0.5) / 1000
  end
end

function C.bool(v)
  if type(v) == 'boolean' then return v end
  return nil
end

function C.enum(...)
  local set = {}
  for _, x in ipairs({ ... }) do set[x] = true end
  return function (v) if set[v] then return v end return nil end
end

function C.text(max)
  return function (v)
    if type(v) ~= 'string' then return nil end
    v = v:gsub('%c', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if #v > max or not utf8ok(v) then return nil end
    return v
  end
end

-- File types the folder may hold, by extension.
D.TYPES = {
  png   = { kind = 'image', ctype = 'image/png' },
  jpg   = { kind = 'image', ctype = 'image/jpeg' },
  jpeg  = { kind = 'image', ctype = 'image/jpeg' },
  gif   = { kind = 'image', ctype = 'image/gif' },
  webp  = { kind = 'image', ctype = 'image/webp' },
  svg   = { kind = 'image', ctype = 'image/svg+xml' },
  woff2 = { kind = 'font',  ctype = 'font/woff2' },
  woff  = { kind = 'font',  ctype = 'font/woff' },
  ttf   = { kind = 'font',  ctype = 'font/ttf' },
  otf   = { kind = 'font',  ctype = 'font/otf' },
  css   = { kind = 'css',   ctype = 'text/css; charset=utf-8' },
}

-- A file name the folder may hold: plain, with a known extension. Returns the
-- name and its type, or nil.
function D.validName(name)
  if type(name) ~= 'string' or #name > 64 or name:find('..', 1, true) then return nil end
  if not name:match('^[a-z0-9][a-z0-9._%-]*$') then return nil end
  local ext = name:match('%.([a-z0-9]+)$')
  local t = ext and D.TYPES[ext]
  if not t or name == 'style.json' then return nil end
  return name, t, ext
end

local function assetOf(kind)
  return function (v)
    if type(v) ~= 'string' then return nil end
    local name = v:match('^asset:(.+)$')
    local ok, t = D.validName(name)
    if ok and t.kind == kind then return v end
    return nil
  end
end

-- '' (none), one of the folder's images, or a web link.
function C.image(v)
  if v == '' then return '' end
  if type(v) ~= 'string' then return nil end
  if v:match('^asset:') then return assetOf('image')(v) end
  if #v <= 300 and v:match('^https?://[^%s"\'<>\\`()]+$') then return v end
  return nil
end

local FONT_STACKS = C.enum('system', 'condensed', 'mono', 'serif', 'rounded')
function C.font(v)
  return FONT_STACKS(v) or assetOf('font')(v)
end

function C.css(v)
  if v == '' then return '' end
  return assetOf('css')(v)
end

-- THE BANNER (?view=banner): what it shows, in order. Items by name, a comma
-- between them; a `|` starts a new page, and the banner turns through the
-- pages every bannerCycle seconds. logo, flag and sponsor are its frame: shown
-- on every page wherever they are named. The overlay's BANNER_ITEMS is this
-- list, and docs/REFERENCE.md describes each one.
D.BANNER_ITEMS = {
  'logo', 'flag', 'session', 'title', 'track', 'lap', 'togo', 'time', 'clock', 'left',
  'countdown', 'fastest', 'leader', 'margin', 'order', 'onboard', 'heat', 'field',
  'joker', 'pits', 'latest', 'sponsor',
}
D.BANNER_PAGES = 8
local BANNER_SET = {}
for _, k in ipairs(D.BANNER_ITEMS) do BANNER_SET[k] = true end

-- "logo,flag,session,lap|order": known items only, spaces and empty pages
-- dropped, at most BANNER_PAGES pages. A name it does not know refuses the
-- whole value, so a typo is reported rather than quietly shown as nothing.
function C.banner(v)
  if type(v) ~= 'string' or #v > 200 then return nil end
  v = (v:lower():gsub('%s', ''))
  local pages = {}
  for page in (v .. '|'):gmatch('([^|]*)|') do
    local items = {}
    for item in (page .. ','):gmatch('([^,]*),') do
      if item ~= '' then
        if not BANNER_SET[item] then return nil end
        items[#items + 1] = item
      end
    end
    if #items > 0 then pages[#pages + 1] = table.concat(items, ',') end
  end
  if #pages == 0 or #pages > D.BANNER_PAGES then return nil end
  return table.concat(pages, '|')
end

local function shortCode(k)
  if type(k) == 'string' and k:match('^[A-Z0-9][A-Z0-9][A-Z0-9]?[A-Z0-9]?$') then return k end
  return nil
end

local function className(k)
  if type(k) ~= 'string' then return nil end
  k = k:gsub('^%s+', ''):gsub('%s+$', '')
  if k == '' or #k > 12 or not k:match('^[%w%-%. ]+$') then return nil end
  return k
end

-- ---------------------------------------------------------------------------
-- The spec. Order matters: it is the order the style is written out in.
-- Defaults are the overlay's own look (overlay.html :root).
-- ---------------------------------------------------------------------------
local text24 = C.text(24)
D.SPEC = {
  { 'colors', group = {
    { 'bg', C.color, '#0c0e14' }, { 'bgAlt', C.color, '#1a1d26' },
    { 'fg', C.color, '#f2f4f8' }, { 'muted', C.color, '#9aa3b2' },
    { 'accent', C.color, '#ff7a1a' }, { 'fastest', C.color, '#b06cff' },
    { 'gain', C.color, '#3ddc84' }, { 'loss', C.color, '#ff5c5c' },
    { 'pit', C.color, '#3b82f6' },
    { 'flagGreen', C.color, '#1db954' }, { 'flagYellow', C.color, '#ffd400' },
    { 'flagRed', C.color, '#e53935' }, { 'flagWhite', C.color, '#f5f5f5' },
  } },
  { 'opacity', C.num(0, 1), 0.86 },
  { 'scale', C.num(0.5, 3), 1 },
  { 'radius', C.num(0, 1), 0.3 },
  { 'rowHeight', C.num(1.4, 2.8), 1.85 },
  { 'nameWidth', C.num(6, 20), 11 },
  { 'font', C.font, 'system' },
  { 'weight', C.enum('regular', 'bold', 'black'), 'bold' },
  { 'uppercase', C.bool, false },
  { 'bar', C.enum('team', 'class', 'accent', 'none'), 'team' },
  { 'classColors', map = { className, C.color, 16 } },
  { 'nameFormat', C.enum('full', 'last', 'code', 'initialLast'), 'full' },
  { 'numbers', C.enum('chip', 'plain', 'off'), 'chip' },
  { 'teamLogos', C.bool, true },
  { 'teamLogoOverrides', map = { shortCode, C.image, 32 } },
  { 'badges', C.bool, true },
  { 'gained', C.bool, true },
  { 'flash', C.bool, true },
  { 'flagStripe', C.bool, true },
  { 'logo', C.image, '' },
  { 'sponsor', C.image, '' },
  { 'title', C.text(40), '' },
  { 'subtitle', C.text(60), '' },
  { 'banner', C.banner, 'logo,flag,session,lap,time,countdown,fastest,sponsor' },
  { 'bannerCycle', C.num(2, 60), 8 },
  { 'labels', group = {
    { 'leader', text24, 'LEADER' }, { 'lap', text24, 'LAP' }, { 'noTime', text24, 'NO TIME' },
    { 'race', text24, 'Race' }, { 'qualifying', text24, 'Qualifying' },
    { 'qualiResult', text24, 'Qualifying result' }, { 'result', text24, 'Result' },
    { 'standings', text24, 'Standings' }, { 'startingGrid', text24, 'Starting grid' },
    { 'provisionalGrid', text24, 'Provisional grid' }, { 'noGrid', text24, 'No grid yet' },
    { 'session', text24, 'Session' }, { 'timeLeft', text24, 'Time left' },
    { 'time', text24, 'Time' }, { 'start', text24, 'Start' },
    { 'fastestLap', text24, 'Fastest lap' },
    { 'track', text24, 'Track' }, { 'toGo', text24, 'To go' },
    { 'margin', text24, 'Margin' }, { 'order', text24, 'Running order' },
    { 'onBoard', text24, 'On board' }, { 'heat', text24, 'Heat' },
    { 'field', text24, 'Field' }, { 'latest', text24, 'Latest' },
    { 'jokers', text24, 'Jokers taken' }, { 'pits', text24, 'Pit stops' },
    { 'pitsDone', text24, 'All stops made' },
    { 'waiting', C.text(60), 'Waiting for Phoenix Race Manager…' },
    { 'pit', text24, 'PIT' }, { 'fl', text24, 'FL' }, { 'joker', text24, 'J' },
  } },
  { 'css', C.css, '' },
}

local function copy(t)
  if type(t) ~= 'table' then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end

-- Every key at its default.
function D.defaults()
  local out = {}
  for _, e in ipairs(D.SPEC) do
    if e.group then
      local g = {}
      for _, s in ipairs(e.group) do g[s[1]] = s[3] end
      out[e[1]] = g
    elseif e.map then
      out[e[1]] = {}
    else
      out[e[1]] = e[3]
    end
  end
  return out
end

-- `input` checked onto `base` (the current style, or the defaults). Top-level
-- keys given replace what is there: a group merges key by key, a map is
-- replaced whole. {"reset": true} starts from the defaults. Returns the style
-- and the list of what was refused, by path.
function D.clean(input, base)
  local out = copy(base or D.defaults())
  local rejected = {}
  if type(input) ~= 'table' then return out, { '(not an object)' } end
  if input.reset == true then out = D.defaults() end
  local known = { reset = true, v = true, seq = true, assetsRev = true }
  for _, e in ipairs(D.SPEC) do
    local key = e[1]
    known[key] = true
    local v = input[key]
    if v ~= nil then
      if e.group then
        if type(v) ~= 'table' then
          rejected[#rejected + 1] = key
        else
          local g = copy(out[key])
          local inGroup = {}
          for _, s in ipairs(e.group) do
            inGroup[s[1]] = true
            if v[s[1]] ~= nil then
              local c = s[2](v[s[1]])
              if c == nil then rejected[#rejected + 1] = key .. '.' .. s[1] else g[s[1]] = c end
            end
          end
          for k in pairs(v) do
            if not inGroup[k] then rejected[#rejected + 1] = key .. '.' .. tostring(k) end
          end
          out[key] = g
        end
      elseif e.map then
        if type(v) ~= 'table' then
          rejected[#rejected + 1] = key
        else
          local keyCheck, valCheck, max = e.map[1], e.map[2], e.map[3]
          local m, n = {}, 0
          local names = {}
          for k in pairs(v) do names[#names + 1] = k end
          table.sort(names, function (a, b) return tostring(a) < tostring(b) end)
          for _, k in ipairs(names) do
            local ck, cv = keyCheck(k), valCheck(v[k])
            if ck and cv ~= nil and n < max then
              m[ck] = cv
              n = n + 1
            else
              rejected[#rejected + 1] = key .. '.' .. tostring(k)
            end
          end
          out[key] = m
        end
      else
        local c = e[2](v)
        if c == nil then rejected[#rejected + 1] = key else out[key] = c end
      end
    end
  end
  for k in pairs(input) do
    if not known[k] then rejected[#rejected + 1] = tostring(k) end
  end
  table.sort(rejected)
  return out, rejected
end

-- The style as the feed writes it out: keyed objects (`_k`) for feed.lua's
-- encoder, in the spec's order, map keys sorted.
function D.toWire(style, seq, assetsRev)
  local keys = { 'v', 'seq', 'assetsRev' }
  local out = { v = 1, seq = seq or 0, assetsRev = assetsRev or 0 }
  for _, e in ipairs(D.SPEC) do
    local key = e[1]
    keys[#keys + 1] = key
    local v = style[key]
    if e.group then
      local g = { _k = {} }
      for _, s in ipairs(e.group) do
        g._k[#g._k + 1] = s[1]
        g[s[1]] = v and v[s[1]]
      end
      out[key] = g
    elseif e.map then
      local m = { _k = {} }
      for k in pairs(v or {}) do m._k[#m._k + 1] = k end
      table.sort(m._k)
      for _, k in ipairs(m._k) do m[k] = v[k] end
      out[key] = m
    else
      out[key] = v
    end
  end
  out._k = keys
  return out
end

-- Every path the spec has, 'colors.bg' style: for the tests and the docs.
function D.paths()
  local out = {}
  for _, e in ipairs(D.SPEC) do
    if e.group then
      for _, s in ipairs(e.group) do out[#out + 1] = e[1] .. '.' .. s[1] end
    else
      out[#out + 1] = e[1]
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- The style file
-- ---------------------------------------------------------------------------
function D.load()
  if type(jsonReadFile) ~= 'function' then return D.defaults() end
  local ok, data = pcall(jsonReadFile, D.STYLE_FILE)
  if not ok or type(data) ~= 'table' then return D.defaults() end
  local style = D.clean(data, D.defaults())
  return style
end

function D.save(style)
  if FS and FS.directoryCreate then pcall(function () FS:directoryCreate(D.DIR, true) end) end
  if type(jsonWriteFile) ~= 'function' then return false end
  local ok, res = pcall(jsonWriteFile, D.STYLE_FILE, style, true)
  return ok and res ~= false
end

-- ---------------------------------------------------------------------------
-- What a file's first bytes say it is
-- ---------------------------------------------------------------------------
-- nil when the bytes are what the extension says, else why not.
function D.checkBytes(ext, b)
  if type(b) ~= 'string' or #b == 0 then return 'the file is empty' end
  local function starts(s) return b:sub(1, #s) == s end
  local ok
  if ext == 'png' then ok = starts('\137PNG\r\n\26\n')
  elseif ext == 'jpg' or ext == 'jpeg' then ok = starts('\255\216\255')
  elseif ext == 'gif' then ok = starts('GIF87a') or starts('GIF89a')
  elseif ext == 'webp' then ok = starts('RIFF') and b:sub(9, 12) == 'WEBP'
  elseif ext == 'woff2' then ok = starts('wOF2')
  elseif ext == 'woff' then ok = starts('wOFF')
  elseif ext == 'ttf' then ok = starts('\0\1\0\0') or starts('true')
  elseif ext == 'otf' then ok = starts('OTTO')
  elseif ext == 'svg' then
    local low = b:lower()
    if not low:find('<svg', 1, true) then return 'it is not an SVG' end
    if low:find('<script', 1, true) or low:find('javascript:', 1, true)
        or low:find('<foreignobject', 1, true) or low:find('%son%a+%s*=') then
      return 'the SVG holds script, which is not allowed'
    end
    ok = true
  elseif ext == 'css' then
    ok = not b:find('\0', 1, true) and utf8ok(b)
    if not ok then return 'it is not a text stylesheet' end
  end
  if not ok then return 'its contents are not a ' .. ext:upper() .. ' file' end
  return nil
end

-- ---------------------------------------------------------------------------
-- The folder. A table so the tests can stand in for it.
-- ---------------------------------------------------------------------------
local function realPath(vpath)
  if not (FS and FS.getFileRealPath) then return nil end
  local ok, real = pcall(function () return FS:getFileRealPath(vpath) end)
  if ok and type(real) == 'string' and real ~= '' then return real end
  return nil
end

local function readAll(path)
  local ok, data = pcall(function ()
    local f = io.open(path, 'rb')
    if not f then return nil end
    local d = f:read('*a')
    f:close()
    return d
  end)
  return ok and data or nil
end

-- This session's writes and removals: the game's file index may not see a
-- file written through its real path until later.
local written, removed = {}, {}

D.files = {}

function D.files.list()
  if FS and FS.directoryCreate then pcall(function () FS:directoryCreate(D.DIR, true) end) end
  local seen, out = {}, {}
  if FS and FS.findFiles then
    local ok, found = pcall(function () return FS:findFiles(D.DIR, '*', 0, false, false) end)
    if ok and type(found) == 'table' then
      for _, p in pairs(found) do
        local name = type(p) == 'string' and p:match('([^/\\]+)$')
        if name and D.validName(name) and not removed[name] and not seen[name] then
          seen[name] = true
          local bytes = readAll(realPath(D.DIR .. '/' .. name) or (D.DIR .. '/' .. name))
          out[#out + 1] = { name = name, size = bytes and #bytes or 0 }
        end
      end
    end
  end
  for name, size in pairs(written) do
    if not seen[name] and not removed[name] then out[#out + 1] = { name = name, size = size } end
  end
  table.sort(out, function (a, b) return a.name < b.name end)
  return out
end

function D.files.read(name)
  if not D.validName(name) or removed[name] then return nil end
  local vpath = D.DIR .. '/' .. name
  local real = realPath(vpath)
  local data = (real and readAll(real)) or readAll(vpath)
  if not data and type(readFile) == 'function' then
    local ok, d = pcall(readFile, vpath)
    data = ok and d or nil
  end
  return data
end

function D.files.write(name, bytes)
  if not D.validName(name) then return false end
  if FS and FS.directoryCreate then pcall(function () FS:directoryCreate(D.DIR, true) end) end
  local dirReal = realPath(D.DIR)
  local targets = {}
  if dirReal then targets[#targets + 1] = dirReal .. '/' .. name end
  targets[#targets + 1] = D.DIR .. '/' .. name
  for _, p in ipairs(targets) do
    local ok = pcall(function ()
      local f = assert(io.open(p, 'wb'))
      f:write(bytes)
      f:close()
    end)
    if ok then
      local back = readAll(p)
      if back and #back == #bytes then
        written[name], removed[name] = #bytes, nil
        return true
      end
      pcall(os.remove, p)
    end
  end
  return false
end

function D.files.remove(name)
  if not D.validName(name) then return false end
  local vpath = D.DIR .. '/' .. name
  local real = realPath(vpath)
  local gone = false
  if real then gone = os.remove(real) and true or false end
  if not gone and FS and FS.removeFile then gone = pcall(function () FS:removeFile(vpath) end) end
  if not gone then gone = os.remove(vpath) and true or false end
  written[name] = nil
  removed[name] = true
  return gone
end

-- Room for `size` more bytes under `name` (replacing it if there)? nil, or why not.
function D.room(name, size)
  if size > D.MAX_FILE then
    return 'it is bigger than ' .. math.floor(D.MAX_FILE / 1048576) .. ' MB', 413
  end
  local list = D.files.list()
  local count, total, old = 0, 0, 0
  for _, f in ipairs(list) do
    count, total = count + 1, total + f.size
    if f.name == name then old = f.size end
  end
  if old == 0 and count >= D.MAX_FILES then
    return 'the overlay folder already holds ' .. D.MAX_FILES .. ' files', 413
  end
  if total - old + size > D.MAX_TOTAL then
    return 'the overlay folder would hold more than ' .. math.floor(D.MAX_TOTAL / 1048576) .. ' MB', 413
  end
  return nil
end

-- For the tests.
function D.resetIndex() written, removed = {}, {} end

return D
