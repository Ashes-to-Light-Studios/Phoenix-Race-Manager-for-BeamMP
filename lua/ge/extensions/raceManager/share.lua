-- Phoenix Race Manager: SHARED LAYOUT FILES, client side.
--
-- Layouts written to files in the BeamNG user folder to pass around (a
-- Discord post), and read back on another PC. ONE FILE PER MAP,
-- '<map>.prm.json', holding any number of layouts.
--
-- NOTHING IS EVER OVERWRITTEN, in a file or on a server. A layout identical
-- to one already there is skipped; a different one under a taken name goes in
-- as "Name (2)". An export merges into the map's file by that rule, and an
-- import is sent to the server's RM_ImportLayout, which keeps it too.
--
-- Export asks the server for full copies (the layout list leaves props out);
-- they arrive one event each on RM_LayoutExport. Import is paced, one layout
-- per INTERVAL, the way an upload is.
--
-- A file is somebody else's text: size-capped, parsed under pcall, and only
-- the layout's own fields are taken. The server checks every one again.

local D = {}

D.DIR = 'settings/raceManager/layouts'
D.FORMAT = 1
D.SUFFIX = '.prm.json'
D.MAX_BYTES = 4 * 1024 * 1024
D.MAX_NAME = 40      -- the server's MAX_LAYOUT_NAME
D.INTERVAL = 0.2     -- seconds between imported layouts

-- What a layout may carry: the save payload's own fields.
D.KEYS = {
  'width', 'height', 'depth', 'checkpoints', 'joker', 'startPositions', 'branches',
  'gridOffLine', 'firstCheckpoint', 'pitFirstCheckpoint', 'sectors', 'pits', 'pitEntry', 'pitExit',
  'markers', 'props', 'pointToPoint', 'drag',
}

-- Game calls, swapped out by the tests.
D.io = {
  level = function ()
    if type(getCurrentLevelIdentifier) ~= 'function' then return nil end
    local ok, level = pcall(getCurrentLevelIdentifier)
    return ok and level or nil
  end,
  mkdir = function ()
    if FS and FS.directoryCreate then pcall(function () FS:directoryCreate(D.DIR, true) end) end
  end,
  find = function ()
    if not (FS and FS.findFiles) then return {} end
    local ok, files = pcall(function () return FS:findFiles(D.DIR, '*.json', 0, false, false) end)
    return ok and type(files) == 'table' and files or {}
  end,
  read = function (path)
    if type(readFile) ~= 'function' then return nil end
    local ok, text = pcall(readFile, path)
    return ok and type(text) == 'string' and text or nil
  end,
  decode = function (text)
    if type(jsonDecode) ~= 'function' then return nil end
    local ok, data = pcall(jsonDecode, text)
    return ok and data or nil
  end,
  write = function (path, data)
    if type(jsonWriteFile) ~= 'function' then return false end
    local ok, res = pcall(jsonWriteFile, path, data, true)
    return ok and res ~= false
  end,
  send = function (event, data)
    if type(TriggerServerEvent) == 'function' and type(jsonEncode) == 'function' then
      TriggerServerEvent(event, jsonEncode(data))
    end
  end,
  explore = function ()
    if Engine and Engine.Platform and Engine.Platform.exploreFolder then
      pcall(Engine.Platform.exploreFolder, '/' .. D.DIR .. '/')
    end
  end,
  -- The folder on disk, or nil.
  realPath = function ()
    if not (FS and FS.getFileRealPath) then return nil end
    local ok, p = pcall(function () return FS:getFileRealPath(D.DIR) end)
    return ok and type(p) == 'string' and p ~= '' and p or nil
  end,
  copy = function (text)
    if type(setClipboard) ~= 'function' then return false end
    return (pcall(setClipboard, text))
  end,
}

-- id -> { path, index }, from the last list(). open() and import take nothing else.
D.last = {}
-- The export being received: { map, total, got = { [index] = layout } }.
D.incoming = nil
-- The import being sent: { map, list = { layouts }, sent, wait }.
D.outgoing = nil

local function trim(s)
  return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- '<map>.prm.json', with nothing Windows refuses in a file name.
function D.fileName(map)
  local base = trim(map):gsub('[%c<>:"/\\|%?%*]', '_'):gsub('[%. ]+$', '')
  if base == '' then base = 'unknown' end
  return base:sub(1, 120) .. D.SUFFIX
end

-- One layout, its own fields only, or nil.
function D.clean(l)
  if type(l) ~= 'table' or type(l.checkpoints) ~= 'table' or #l.checkpoints == 0 then return nil end
  local out = {}
  for _, k in ipairs(D.KEYS) do out[k] = l[k] end
  local name = trim(type(l.name) == 'string' and l.name or '')
  out.name = (name ~= '' and name or 'Shared layout'):sub(1, D.MAX_NAME)
  return out
end

-- The same gates in the same places, the same kind of track. The server's
-- race.sameTrack, on this side.
function D.sameTrack(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  if (a.pointToPoint == true) ~= (b.pointToPoint == true) then return false end
  local ca, cb = a.checkpoints, b.checkpoints
  if type(ca) ~= 'table' or type(cb) ~= 'table' or #ca ~= #cb then return false end
  for i = 1, #ca do
    for _, k in ipairs({ 'x', 'y', 'z' }) do
      if type(ca[i]) ~= 'table' or type(cb[i]) ~= 'table' then return false end
      if math.abs((tonumber(ca[i][k]) or 0) - (tonumber(cb[i][k]) or 0)) > 0.05 then return false end
    end
  end
  return true
end

-- A file's map and layouts, or nil and why.
function D.read(path)
  local text = D.io.read(path)
  if not text then return nil, 'it could not be read' end
  if #text > D.MAX_BYTES then return nil, 'it is too big to be a layout file' end
  local data = D.io.decode(text)
  if type(data) ~= 'table' or data.prmLayouts == nil then return nil, 'it is not a PRM layout file' end
  if (tonumber(data.prmLayouts) or 0) > D.FORMAT then return nil, 'it was made by a newer PRM: update first' end
  if type(data.map) ~= 'string' or trim(data.map) == '' then return nil, 'it does not say which map it is for' end
  local layouts = {}
  for _, l in ipairs(type(data.layouts) == 'table' and data.layouts or {}) do
    layouts[#layouts + 1] = D.clean(l)
  end
  if #layouts == 0 then return nil, 'it has no layouts in it' end
  return { map = trim(data.map), layouts = layouts }
end

-- Add `incoming` to `existing` by the never-overwrite rule. Returns the merged
-- list and { added, renamed = { 'A as A (2)' }, same }.
function D.merge(existing, incoming)
  local out, taken = {}, {}
  for _, l in ipairs(existing or {}) do
    out[#out + 1] = l
    taken[l.name:lower()] = l
  end
  local res = { added = 0, renamed = {}, same = 0 }
  for _, l in ipairs(incoming or {}) do
    local base, name, n = l.name, l.name, 1
    while taken[name:lower()] and not D.sameTrack(taken[name:lower()], l) and n < 1000 do
      n = n + 1
      local tag = ' (' .. n .. ')'
      name = base:sub(1, D.MAX_NAME - #tag) .. tag
    end
    if taken[name:lower()] then
      res.same = res.same + 1
    else
      l.name = name
      out[#out + 1] = l
      taken[name:lower()] = l
      res.added = res.added + 1
      if name ~= base then res.renamed[#res.renamed + 1] = '"' .. base .. '" as "' .. name .. '"' end
    end
  end
  return out, res
end

-- The layouts in this level's files, for the picker, and how many layouts the
-- folder holds for other maps.
function D.list(level)
  D.last = {}
  local out, elsewhere = {}, 0
  if type(level) ~= 'string' or level == '' then return out, 0 end
  D.io.mkdir()
  for _, path in ipairs(D.io.find()) do
    path = tostring(path)
    local data = D.read(path)
    if data and data.map:lower() ~= level:lower() then
      elsewhere = elsewhere + #data.layouts
    elseif data then
      local file = path:match('([^/\\]+)$') or path
      for i, l in ipairs(data.layouts) do
        local id = 'file/' .. file .. '#' .. i
        D.last[id] = { path = path, index = i }
        out[#out + 1] = {
          id = id, name = l.name, kind = 'Shared file', file = file,
          gates = #l.checkpoints, circuit = l.pointToPoint ~= true,
        }
      end
    end
  end
  table.sort(out, function (a, b)
    if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
    return a.id < b.id
  end)
  return out, elsewhere
end

-- One layout from the last list, or nil and why. Also returns the file's map.
function D.layout(id)
  local at = D.last[tostring(id or '')]
  if not at then return nil, 'it is not in the list: open the list again' end
  local data, why = D.read(at.path)
  if not data then return nil, why end
  local l = data.layouts[at.index]
  if not l then return nil, 'the file has changed: open the list again' end
  return l, data.map
end

-- For the editor: the layout and its notes, or nil and why.
function D.open(id)
  local l, why = D.layout(id)
  if not l then return nil, why end
  return l, {}
end

-- ---------------------------------------------------------------------------
-- Export: the server's copies, merged into this map's file
-- ---------------------------------------------------------------------------

-- One RM_LayoutExport. Returns nil until the last has arrived, then the file
-- name and the merge result, or nil and why.
function D.receive(data, build)
  if type(data) ~= 'table' or type(data.layout) ~= 'table' then return nil end
  local index, total = tonumber(data.index) or 1, tonumber(data.total) or 1
  local map = trim(data.map)
  -- A piece already held, or another map or size: a new export has started.
  local inc = D.incoming
  if not inc or inc.map ~= map or inc.total ~= total or inc.got[index] ~= nil then
    inc = { map = map, total = total, got = {} }
    D.incoming = inc
  end
  inc.got[index] = D.clean(data.layout) or false
  for i = 1, total do
    if inc.got[i] == nil then return nil end
  end
  D.incoming = nil
  local layouts = {}
  for i = 1, total do
    if inc.got[i] then layouts[#layouts + 1] = inc.got[i] end
  end
  return D.write(map, layouts, build)
end

-- Merge `layouts` into '<map>.prm.json'. Returns the file name and the merge
-- result, or nil and why. A file there that is not ours is never replaced.
function D.write(map, layouts, build)
  if map == '' then return nil, 'the server did not say which map' end
  D.io.mkdir()
  local file = D.fileName(map)
  local path = D.DIR .. '/' .. file
  local existing = {}
  if D.io.read(path) then
    local data, why = D.read(path)
    if not data then return nil, file .. ' is there already and ' .. why .. ': move it first' end
    if data.map:lower() ~= map:lower() then
      return nil, file .. ' is there already, for ' .. data.map .. ': move it first'
    end
    existing = data.layouts
  end
  local merged, res = D.merge(existing, layouts)
  if res.added > 0 then
    local ok = D.io.write(path, { prmLayouts = D.FORMAT, map = map, build = build, layouts = merged })
    if not ok then return nil, 'the file could not be written' end
  end
  return file, res
end

-- Returns where the folder is. exploreFolder fails without raising, so the
-- window may never appear and the path is the only proof of anything.
function D.openFolder()
  D.io.mkdir()
  D.io.explore()
  return D.io.realPath() or D.DIR
end

-- ---------------------------------------------------------------------------
-- Import: listed layouts to the server, one per INTERVAL
-- ---------------------------------------------------------------------------

-- `ids`: listed ids, or 'all' for every listed layout. Returns the count
-- queued, or nil and why.
function D.importStart(ids, level)
  if D.outgoing then return nil, 'an import is still being sent' end
  if type(level) ~= 'string' or level == '' then return nil, 'no map is loaded' end
  local pick = {}
  if ids == 'all' then
    for id in pairs(D.last) do pick[#pick + 1] = id end
    table.sort(pick)
  elseif type(ids) == 'table' then
    pick = ids
  else
    pick = { ids }
  end
  local list = {}
  for _, id in ipairs(pick) do
    local l, map = D.layout(id)
    if l and map:lower() == level:lower() then list[#list + 1] = l end
  end
  if #list == 0 then return nil, 'there are no shared layouts for this map to import' end
  D.outgoing = { map = level, list = list, sent = 0, wait = 0 }
  return #list
end

-- Every frame: one layout per INTERVAL until the queue is empty.
function D.update(dt)
  local out = D.outgoing
  if not out then return end
  out.wait = out.wait - (dt or 0)
  if out.wait > 0 then return end
  out.sent = out.sent + 1
  local l = out.list[out.sent]
  if l then
    D.io.send('RM_ImportLayout', { map = out.map, index = out.sent, total = #out.list, layout = l })
  end
  out.wait = D.INTERVAL
  if out.sent >= #out.list then D.outgoing = nil end
end

function D.importCancel()
  D.outgoing = nil
end

return D
