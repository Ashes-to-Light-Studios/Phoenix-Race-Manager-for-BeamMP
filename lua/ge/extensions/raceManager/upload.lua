-- Phoenix Race Manager: INSTALL FROM THIS PC, client side.
--
-- On a rented game server the server cannot download an update (online
-- features are off there, for good reason) and the owner has no shell. So the
-- admin downloads the release zip on their own PC, drops it in a folder of
-- their BeamNG user folder, and this sends it to the server over BeamMP's own
-- connection: numbered pieces of base64 on RM_UpdateUpload. The server checks
-- it the way it checks a download (server/RaceManager/update.lua), shows its
-- SHA-256, and installs it when the admin presses Install.
--
-- PACED, NOT FLOODED: a piece every INTERVAL, at most WINDOW pieces ahead of
-- what the server says it has (snapshot.upload.got on the admin's own
-- RM_Update, every few pieces). A 1 MB release is about 16 seconds; vehicle
-- sync shares the same connection.
--
-- CHECKED BEFORE A BYTE GOES: read in binary, and the zip's own end record has
-- to agree with its length, which a text-mode read (CR/LF) or a cut-short file
-- breaks.

local D = {}

D.DIR = 'settings/raceManager/update'
D.CHUNK = 16384          -- raw bytes a piece: about 22 KB of base64 per event
D.INTERVAL = 0.25        -- seconds between pieces
D.WINDOW = 12            -- pieces in flight before waiting for the server
D.ACK_TIMEOUT = 15       -- seconds of silence from the server: give up
D.MAX = 8 * 1024 * 1024
D.MIN = 1024

local host = { inMultiplayer = function () return false end }

-- idle | sending | waiting (all sent, the server is checking) | done | error
local U = { phase = 'idle', files = {}, send = nil, error = nil, name = nil }

local function say(level, msg)
  if type(log) == 'function' then pcall(log, level, 'raceManager', 'Upload: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- Base64, in arithmetic only: the same code on LuaJIT and in the Lua 5.3 tests.
-- ---------------------------------------------------------------------------
local ALPHA = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local CODE = {}
for i = 1, 64 do CODE[i - 1] = ALPHA:byte(i) end

function D.b64encode(s)
  local out, char, floor = {}, string.char, math.floor
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    out[#out + 1] = char(CODE[floor(v / 262144)], CODE[floor(v / 4096) % 64],
      b and CODE[floor(v / 64) % 64] or 61, c and CODE[v % 64] or 61)
  end
  return table.concat(out)
end

local function jsonText(s)
  s = tostring(s):gsub('[%c"\\]', function (ch)
    return ch == '"' and '\\"' or (ch == '\\' and '\\\\' or string.format('\\u%04x', ch:byte()))
  end)
  return '"' .. s .. '"'
end

-- ---------------------------------------------------------------------------
-- The file
-- ---------------------------------------------------------------------------
local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

-- Why these bytes are not a whole release zip, or nil.
function D.zipProblem(bytes)
  if #bytes < D.MIN then return 'it is too small to be a release' end
  if #bytes > D.MAX then return 'it is bigger than 8 MB, so it is not a release' end
  if bytes:sub(1, 4) ~= 'PK\3\4' then return 'it is not a zip' end
  local pos
  for i = #bytes - 21, math.max(1, #bytes - 65557), -1 do
    if bytes:byte(i) == 0x50 and bytes:sub(i, i + 3) == 'PK\5\6' then pos = i; break end
  end
  if not pos then return 'it is not a whole zip (cut short?)' end
  local cdSize, cdOffset = u32(bytes, pos + 12), u32(bytes, pos + 16)
  if cdOffset ~= 0xFFFFFFFF and cdOffset + cdSize ~= pos - 1 then
    return 'it read back changed or cut short, so it was not sent'
  end
  return nil
end

local function readAll(path, mode)
  local ok, data = pcall(function ()
    local f = io.open(path, mode)
    if not f then return nil end
    local d = f:read('*a')
    f:close()
    return d
  end)
  return ok and data or nil
end

local function realPath(vpath)
  if not (FS and FS.getFileRealPath) then return nil end
  local ok, real = pcall(function () return FS:getFileRealPath(vpath) end)
  if ok and type(real) == 'string' and real ~= '' then return real end
  return nil
end

-- The bytes, in binary, by the first way that gives a whole zip: the real path
-- (plain stdio), the game's path, then readFile.
local function readBytes(vpath)
  local tries = {}
  local real = realPath(vpath)
  if real then tries[#tries + 1] = function () return readAll(real, 'rb') end end
  tries[#tries + 1] = function () return readAll(vpath, 'rb') end
  if type(readFile) == 'function' then
    tries[#tries + 1] = function ()
      local ok, d = pcall(readFile, vpath)
      return ok and d or nil
    end
  end
  local problem
  for _, try in ipairs(tries) do
    local data = try()
    if type(data) == 'string' and #data > 0 then
      local why = D.zipProblem(data)
      if not why then return data end
      problem = problem or why
    end
  end
  return nil, problem or 'it could not be read'
end

local function fileSize(vpath)
  for _, p in ipairs({ realPath(vpath) or false, vpath }) do
    if p then
      local ok, size = pcall(function ()
        local f = io.open(p, 'rb')
        if not f then return nil end
        local n = f:seek('end')
        f:close()
        return n
      end)
      if ok and type(size) == 'number' then return size end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- To the panel
-- ---------------------------------------------------------------------------
local function push()
  local s = U.send
  local st = {
    dir = D.DIR, real = realPath(D.DIR), files = U.files, phase = U.phase, error = U.error,
    name = U.name, sent = s and s.seq or nil, total = s and s.total or nil,
    acked = s and s.acked or nil,
  }
  if type(guihooks) == 'table' and type(guihooks.trigger) == 'function' then
    pcall(guihooks.trigger, 'RaceManagerUpload', st)
  end
end

local function stop(phase, err)
  U.phase, U.error = phase, err
  U.send = nil
  if err then say('W', err) end
  push()
end

-- ---------------------------------------------------------------------------
-- Entry points, merged onto the extension (raceManager.lua)
-- ---------------------------------------------------------------------------
function D.init(h)
  if type(h) == 'table' and type(h.inMultiplayer) == 'function' then host.inMultiplayer = h.inMultiplayer end
end

-- The zips in the folder, and the folder itself made if it is not there.
function D.uploadList()
  if FS and FS.directoryCreate then pcall(function () FS:directoryCreate(D.DIR, true) end) end
  local files = {}
  if FS and FS.findFiles then
    local ok, found = pcall(function () return FS:findFiles(D.DIR, '*.zip', 0, false, false) end)
    if ok and type(found) == 'table' then
      for _, path in pairs(found) do
        local name = type(path) == 'string' and path:match('([^/\\]+)$')
        if name then files[#files + 1] = { name = name, path = path, size = fileSize(path) } end
      end
    end
  end
  table.sort(files, function (a, b) return a.name:lower() < b.name:lower() end)
  U.files = files
  if U.phase == 'error' or U.phase == 'done' then U.phase, U.error = 'idle', nil end
  push()
end

function D.uploadOpenFolder()
  if FS and FS.directoryCreate then pcall(function () FS:directoryCreate(D.DIR, true) end) end
  if Engine and Engine.Platform and Engine.Platform.exploreFolder then
    pcall(Engine.Platform.exploreFolder, '/' .. D.DIR .. '/')
  end
  D.uploadList()
end

function D.uploadStatus() push() end

-- Send one of the listed files. Read and checked here first: nothing goes to
-- the server unless it is a whole zip.
function D.uploadStart(name)
  if U.phase == 'sending' or U.phase == 'waiting' then return end
  if type(name) ~= 'string' or name:find('[/\\]') or name:find('..', 1, true) then return end
  local entry
  for _, f in ipairs(U.files) do
    if f.name == name then entry = f end
  end
  if not entry then return stop('error', name .. ' is not in the folder any more: press Refresh.') end
  if not host.inMultiplayer() then return stop('error', 'Join the server first.') end
  U.name = name
  local data, why = readBytes(entry.path)
  if not data then return stop('error', name .. ': ' .. why .. '.') end
  local total = math.ceil(#data / D.CHUNK)
  U.send = {
    id = tostring(os.time()) .. '-' .. tostring(math.random(1000, 9999)),
    data = data, size = #data, total = total, seq = 0, acked = 0, wait = 0, quiet = 0,
  }
  U.phase, U.error = 'sending', nil
  say('I', string.format('sending %s (%d bytes, %d pieces)', name, #data, total))
  push()
end

-- Stop sending. `localOnly` when leaving the server: there is nobody to tell.
function D.uploadCancel(localOnly)
  local busy = U.phase == 'sending' or U.phase == 'waiting'
  if busy and not localOnly and host.inMultiplayer() and TriggerServerEvent then
    TriggerServerEvent('RM_UpdateCancel', '')
  end
  if busy or U.phase == 'done' or U.phase == 'error' then
    U.send, U.phase, U.error = nil, 'idle', nil
    push()
  end
end

-- Install the checked upload: the server's countdown, kick, swap and restart.
function D.uploadInstall(version, allowOlder)
  if type(version) ~= 'string' or not host.inMultiplayer() or not TriggerServerEvent then return end
  TriggerServerEvent('RM_UpdateStart', '{"upload":true,"version":' .. jsonText(version)
    .. (allowOlder == true and ',"allowOlder":true' or '') .. '}')
end

-- The admin's own RM_Update: how far the server got with OUR upload.
function D.uploadAck(prm)
  local s = U.send
  if not s or type(prm) ~= 'table' or type(prm.upload) ~= 'table' then return end
  local up = prm.upload
  if tostring(up.id) ~= s.id then return end
  local got = tonumber(up.got)
  if got and got > s.acked then s.acked = got end
  s.quiet = 0
  local state = up.state
  if state == 'ready' then
    say('I', 'the server has ' .. tostring(U.name) .. ' and checked it')
    return stop('done', nil)
  elseif state == 'failed' or state == 'refused' or state == 'cancelled' or state == 'expired' then
    return stop('error', type(up.error) == 'string' and up.error or ('The server ' .. state .. ' it.'))
  end
end

-- Every frame: one comparison unless a file is going out.
function D.uploadUpdate(dt)
  if U.phase ~= 'sending' and U.phase ~= 'waiting' then return end
  local s = U.send
  if not s then return stop('idle', nil) end
  if not host.inMultiplayer() then return stop('error', 'Left the server, so the upload stopped.') end
  dt = tonumber(dt) or 0
  s.quiet = s.quiet + dt
  if s.quiet > D.ACK_TIMEOUT and (s.seq > s.acked or U.phase == 'waiting') then
    return stop('error', 'The server stopped answering, so the upload stopped. Nothing was changed.')
  end
  if U.phase == 'waiting' then return end
  s.wait = s.wait - dt
  if s.wait > 0 then return end
  s.wait = math.max(s.wait + D.INTERVAL, 0)
  if s.seq - s.acked >= D.WINDOW then return end
  local seq = s.seq + 1
  local piece = s.data:sub((seq - 1) * D.CHUNK + 1, seq * D.CHUNK)
  if TriggerServerEvent then
    TriggerServerEvent('RM_UpdateUpload', string.format(
      '{"id":"%s","seq":%d,"total":%d,"size":%d,%s"data":"%s"}', s.id, seq, s.total, s.size,
      seq == 1 and ('"name":' .. jsonText(U.name) .. ',') or '', D.b64encode(piece)))
  end
  if seq == 1 then s.quiet = 0 end
  s.seq = seq
  if seq >= s.total then
    U.phase = 'waiting'
    s.data = nil
  end
  push()
end

-- For the test.
function D.uploadDebug() return U end

return D
