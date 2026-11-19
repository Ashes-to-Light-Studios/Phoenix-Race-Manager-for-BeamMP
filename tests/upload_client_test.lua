-- Headless test for INSTALL FROM THIS PC, the sending side
-- (lua/ge/extensions/raceManager/upload.lua).
--
--   * Base64 the server can read back byte for byte (its own decoder).
--   * A file is read and checked before a byte goes: not a zip, too small, too
--     big, cut short or read back changed (CR/LF) is refused here.
--   * Only files from the listing, and never a path.
--   * Paced: a piece every INTERVAL, at most WINDOW ahead of what the server
--     says it has, given up when the server goes quiet, stopped on a refusal.
--   * The pieces put back together are the file.
--
-- Run from the repo root: lua5.3 tests/upload_client_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- A scratch user folder and the game's file API over it
-- ---------------------------------------------------------------------------
local IS_WINDOWS = package.config:sub(1, 1) == '\\'
local base = (os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp'):gsub('\\', '/')
local root = base .. '/rm_upload_client_test_' .. os.time()
local DIR = 'settings/raceManager/update'
if IS_WINDOWS then os.execute('mkdir "' .. (root .. '/' .. DIR):gsub('/', '\\') .. '" 2>nul')
else os.execute('mkdir -p "' .. root .. '/' .. DIR .. '"') end

local function write(name, bytes)
  local f = assert(io.open(root .. '/' .. DIR .. '/' .. name, 'wb'))
  f:write(bytes)
  f:close()
end

-- A stored zip, as a release is laid out.
local function zipOf(entries)
  local body, cd, offset = {}, {}, 0
  for _, e in ipairs(entries) do
    local name, data = e[1], e[2]
    local lh = string.pack('<I4I2I2I2I2I2I4I4I4I2I2', 0x04034b50, 20, 0, 0, 0, 0, 0, #data, #data,
      #name, 0) .. name .. data
    cd[#cd + 1] = string.pack('<I4I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4',
      0x02014b50, 20, 20, 0, 0, 0, 0, 0, #data, #data, #name, 0, 0, 0, 0, 0, offset) .. name
    body[#body + 1] = lh
    offset = offset + #lh
  end
  local cdData = table.concat(cd)
  return table.concat(body) .. cdData
    .. string.pack('<I4I2I2I2I2I4I4I2', 0x06054b50, 0, 0, #entries, #entries, #cdData, offset, 0)
end

local filler = {}
for i = 1, 3000 do filler[#filler + 1] = string.format('line %d\n', i) end
filler = table.concat(filler)   -- with newlines in it, for the CR/LF case
local GOOD = zipOf({
  { 'Client/PhoenixRM Client.zip', 'client bytes ' .. filler },
  { 'Server/PhoenixRM Server/main.lua', "local RM_BUILD = '10.0.0'\n" .. filler },
})
write('RaceManager-v10.0.0.zip', GOOD)
write('notazip.zip', string.rep('hello ', 300))
write('tiny.zip', 'PK\3\4tiny')
write('big.zip', GOOD .. string.rep('x', 70 * 1024))
write('cut.zip', GOOD:sub(1, #GOOD - 40))
write('crlf.zip', (GOOD:gsub('\n', '\r\n')))

FS = {
  directoryCreate = function () end,
  findFiles = function (_, dir, pattern)
    local out = {}
    for _, n in ipairs({ 'RaceManager-v10.0.0.zip', 'notazip.zip', 'tiny.zip', 'big.zip',
        'cut.zip', 'crlf.zip' }) do
      out[#out + 1] = '/' .. dir .. '/' .. n
    end
    return out
  end,
  getFileRealPath = function (_, vpath) return root .. '/' .. vpath:gsub('^/', '') end,
}
local pushes = {}
guihooks = { trigger = function (name, data)
  if name == 'RaceManagerUpload' then pushes[#pushes + 1] = data end
end }
local events = {}
TriggerServerEvent = function (name, payload) events[#events + 1] = { name = name, payload = payload } end
log = function () end
local inMP = false

local U = dofile('lua/ge/extensions/raceManager/upload.lua')
U.init({ inMultiplayer = function () return inMP end })
U.MAX = 64 * 1024          -- so "too big" needs no 8 MB file
local S = U.uploadDebug()
local server = dofile('server/RaceManager/update.lua')
local function lastPush() return pushes[#pushes] end
local function uploads()
  local out = {}
  for _, e in ipairs(events) do
    if e.name == 'RM_UpdateUpload' then out[#out + 1] = e end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- 1. Base64 the server reads back exactly
-- ---------------------------------------------------------------------------
do
  local all = {}
  for i = 0, 255 do all[#all + 1] = string.char(i) end
  all = table.concat(all)
  local whole = true
  for cut = 0, 3 do
    local piece = all:sub(1, #all - cut)
    if server.b64decode(U.b64encode(piece)) ~= piece then whole = false end
  end
  check(whole, 'every byte value round-trips through the server decoder, every length remainder')
  check(U.b64encode('foobar') == 'Zm9vYmFy' and U.b64encode('fo') == 'Zm8=' and U.b64encode('') == '',
    'RFC 4648 vectors')
end

-- ---------------------------------------------------------------------------
-- 2. The listing, and what is refused before a byte goes
-- ---------------------------------------------------------------------------
U.uploadList()
local p = lastPush()
check(p and #p.files == 6 and p.dir == DIR, 'the folder is listed (' .. tostring(p and #p.files) .. ' zips)')
local sizeOk = false
for _, f in ipairs(p.files) do
  if f.name == 'RaceManager-v10.0.0.zip' then sizeOk = f.size == #GOOD end
end
check(sizeOk, 'with each file\'s size')

U.uploadStart('RaceManager-v10.0.0.zip')
check(S.phase == 'error' and S.error:find('Join the server', 1, true) and #events == 0,
  'not on a server: nothing is sent')
inMP = true

local function refused(name, want)
  events = {}
  U.uploadStart(name)
  check(S.phase == 'error' and S.error:find(want, 1, true) and #events == 0,
    name .. ' is refused before anything is sent (' .. tostring(S.error) .. ')')
  U.uploadList()
end
refused('notazip.zip', 'not a zip')
refused('tiny.zip', 'too small')
refused('big.zip', 'bigger than 8 MB')
refused('cut.zip', 'cut short')
refused('crlf.zip', 'read back changed')
refused('missing.zip', 'press Refresh')
events = {}
U.uploadStart('../RaceManager-v10.0.0.zip')
check(S.phase == 'idle' and #events == 0, 'a path is never read')

-- ---------------------------------------------------------------------------
-- 3. Sending: paced, windowed, put back together
-- ---------------------------------------------------------------------------
events = {}
U.uploadStart('RaceManager-v10.0.0.zip')
local total = math.ceil(#GOOD / U.CHUNK)
check(S.phase == 'sending' and total >= 3, 'the release goes in ' .. total .. ' pieces')
check(#events == 0, 'nothing before the first frame')
U.uploadUpdate(1 / 60)
check(#uploads() == 1, 'the first piece goes on the first frame')
U.uploadUpdate(0.1)
check(#uploads() == 1, 'and the next waits its turn')
U.uploadUpdate(0.15)
check(#uploads() == 2, 'one every quarter second')
local first = uploads()[1].payload
local id = first:match('"id":"([^"]+)"')
check(first:find('"name":"RaceManager-v10.0.0.zip"', 1, true) and first:find('"seq":1,', 1, true)
  and first:find('"total":' .. total, 1, true) and first:find('"size":' .. #GOOD, 1, true),
  'the first piece says what is coming')

-- With the server saying nothing, it stops WINDOW pieces ahead.
local saveWindow = U.WINDOW
U.WINDOW = 2
for _ = 1, 40 do U.uploadUpdate(0.25) end
check(#uploads() == 2, 'the window: no more than ' .. U.WINDOW .. ' pieces ahead of the server')
U.uploadAck({ upload = { id = id, got = 2, state = 'receiving' } })
U.WINDOW = saveWindow
for _ = 1, 200 do
  if S.phase ~= 'sending' then break end
  U.uploadUpdate(0.25)
end
local sent = uploads()
check(#sent == total and S.phase == 'waiting', 'heard back: the rest goes, then it waits on the check')
local parts, inOrder = {}, true
for i, e in ipairs(sent) do
  local seq = tonumber(e.payload:match('"seq":(%d+)'))
  if seq ~= i then inOrder = false end
  parts[#parts + 1] = server.b64decode(e.payload:match('"data":"([^"]*)"'))
end
check(inOrder, 'pieces go in order, 1 to ' .. total)
check(table.concat(parts) == GOOD, 'and put back together they are the file')
U.uploadAck({ upload = { id = 'someone else', got = 99, state = 'ready' } })
check(S.phase == 'waiting', "another upload's state is not ours")
U.uploadAck({ upload = { id = id, got = total, state = 'ready' } })
check(S.phase == 'done', 'the server has it and checked it: done')

-- The server refuses it: stop at once.
events = {}
U.uploadStart('RaceManager-v10.0.0.zip')
U.uploadUpdate(0)
id = uploads()[1].payload:match('"id":"([^"]+)"')
U.uploadAck({ upload = { id = id, got = 0, state = 'refused', error = 'An update is already under way.' } })
check(S.phase == 'error' and S.error == 'An update is already under way.', 'a refusal is shown as the server said it')
local n = #uploads()
for _ = 1, 20 do U.uploadUpdate(0.25) end
check(#uploads() == n, 'and nothing more is sent')

-- The server goes quiet.
events = {}
U.uploadStart('RaceManager-v10.0.0.zip')
for _ = 1, 4 * (U.ACK_TIMEOUT + 1) do U.uploadUpdate(0.25) end
check(S.phase == 'error' and S.error:find('stopped answering', 1, true), 'no word from the server: given up')

-- Leaving the server mid-send.
events = {}
U.uploadStart('RaceManager-v10.0.0.zip')
U.uploadUpdate(0)
inMP = false
U.uploadUpdate(0.25)
check(S.phase == 'error' and S.error:find('Left the server', 1, true), 'leaving the server stops it')
inMP = true

-- Cancel: tells the server, unless leaving.
U.uploadList()
events = {}
U.uploadStart('RaceManager-v10.0.0.zip')
U.uploadUpdate(0)
U.uploadCancel()
check(S.phase == 'idle' and events[#events].name == 'RM_UpdateCancel', 'Stop tells the server to drop it')
events = {}
U.uploadStart('RaceManager-v10.0.0.zip')
U.uploadCancel(true)
check(S.phase == 'idle' and #events == 0, 'stopped on leaving: nobody to tell')

-- Install.
events = {}
U.uploadInstall('10.0.0', true)
check(#events == 1 and events[1].name == 'RM_UpdateStart'
  and events[1].payload == '{"upload":true,"version":"10.0.0","allowOlder":true}',
  'Install asks the server to put the checked upload in')

-- Nothing to do: one comparison a frame.
check(pcall(U.uploadUpdate, 0.016), 'idle frames cost nothing and never throw')

if IS_WINDOWS then os.execute('rmdir /s /q "' .. root:gsub('/', '\\') .. '"')
else os.execute('rm -rf "' .. root .. '"') end

print(string.format('upload_client_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
