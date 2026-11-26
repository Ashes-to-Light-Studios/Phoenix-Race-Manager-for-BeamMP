-- Phoenix Race Manager: STOCK TRACKS, client side.
--
-- BeamNG's own time trials, AI races and rally stages for the level this PC has
-- loaded, read from the game's files and opened in the admin's editor only.
-- Nothing of BeamNG's ships in the mod: a game update moves the tracks with
-- it, and a mod map that ships races in the same format is listed too.
--
-- A race file is pathnodes (a sphere, usually with a facing normal) joined by
-- segments from one node to the next. How it becomes a layout:
--   * startNode is the start/finish. A segment back to it makes a circuit, and
--     PRM wants that line LAST. Otherwise it is a sprint, start gate first.
--   * Width is radius * 2, heading the normal. A node with no normal faces
--     along the route.
--   * Where a node has two ways on, the first is the route. Another way that
--     rejoins it after the same number of nodes becomes branch gates on those
--     checkpoints; one that does not is left out, and said so.
--   * defaultStartPosition is pole. Its pos is the car's front edge, on or
--     just behind the line, so the slot moves back: a sprint arms its start
--     gate first, and a car parked on top of it never crosses it. A sprint
--     whose start is past that gate (AI races start rolling), or a race with
--     no start at all, gets pole behind the first gate armed instead.

local D = {}

D.KINDS = {
  { dir = 'timeTrial',  label = 'Time Trial' },
  { dir = 'aiRace',     label = 'AI Race' },
  { dir = 'rallyStage', label = 'Rally Stage' },
}
D.WIDTH = 20        -- the layout's default for gates placed after the import
D.MIN_WIDTH = 4
D.MAX_WIDTH = 120
D.HEIGHT = 8
D.DEPTH = 2
D.SLOT_BACK = 3     -- meters from the stock start (front edge) back to the slot
D.SLOT_LIFT = 0     -- a slot's z is the ground, as the stock start's is
D.MAX_NODES = 2000  -- a malformed graph walks no further than this
D.MAX_NAME = 40     -- the server's MAX_LAYOUT_NAME

-- Game calls, swapped out by the tests.
D.io = {
  level = function ()
    if type(getCurrentLevelIdentifier) ~= 'function' then return nil end
    local ok, level = pcall(getCurrentLevelIdentifier)
    return ok and level or nil
  end,
  -- The arguments the game's own mission loader searches with.
  find = function (dir)
    if not (FS and FS.findFiles) then return {} end
    local ok, files = pcall(function () return FS:findFiles(dir, 'race.race.json', -1, false, true) end)
    return ok and type(files) == 'table' and files or {}
  end,
  read = function (path)
    if type(jsonReadFile) ~= 'function' then return nil end
    local ok, data = pcall(jsonReadFile, path)
    return ok and type(data) == 'table' and data or nil
  end,
  -- nil when the key has no translation.
  translate = function (key)
    local tr = rawget(_G, '_tr')
    if type(tr) ~= 'function' then return nil end
    local ok, s = pcall(tr, key)
    if ok and type(s) == 'string' and s ~= '' and s ~= key then return s end
    return nil
  end,
}

-- id -> { path, name }, from the last list(). open() takes nothing else, so the
-- UI can only name a race file this module found.
D.last = {}

local atan2 = math.atan2 or math.atan

local function round(v)
  return math.floor(v * 1000 + 0.5) / 1000
end

local function vec(t)
  if type(t) ~= 'table' then return nil end
  local x, y, z = tonumber(t[1] or t.x), tonumber(t[2] or t.y), tonumber(t[3] or t.z)
  if x and y and z then return x, y, z end
  return nil
end

-- A flat unit heading, or nil for a normal that is missing or points mostly up.
local function flat(t)
  local x, y = vec(t)
  if not x then return nil end
  local d = math.sqrt(x * x + y * y)
  if d < 0.3 then return nil end
  return x / d, y / d
end

-- 'Street1' -> 'Street 1', 'east_coast' -> 'East coast'.
function D.pretty(s)
  s = tostring(s or ''):gsub('_', ' '):gsub('(%l)(%u)', '%1 %2'):gsub('(%a)(%d)', '%1 %2')
  return (s:gsub('^%l', string.upper))
end

-- The title the game shows, from info.json's translation key.
function D.title(info, folder)
  local key = type(info) == 'table' and info.name
  local name
  if type(key) == 'string' and key ~= '' then
    name = D.io.translate(key)
    -- A mod map's plain title, or the key's own short name.
    if not name and not key:find('^missions%.') then name = key end
    if not name then
      local short = key:match('%.([^%.]+)%.title$')
      if short then name = D.pretty(short) end
    end
  end
  name = name or D.pretty((tostring(folder or ''):gsub('^%d+%-', '')))
  name = name:gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' then name = 'Stock track' end
  return name:sub(1, D.MAX_NAME)
end

-- A race file -> a layout (unnamed) and notes for the admin, or nil and why.
function D.convert(race)
  if type(race) ~= 'table' then return nil, 'not a race file' end
  local nodes = {}
  for _, p in ipairs(type(race.pathnodes) == 'table' and race.pathnodes or {}) do
    if type(p) == 'table' and p.oldId ~= nil then
      local x, y, z = vec(p.pos)
      if x then nodes[p.oldId] = { x = x, y = y, z = z, r = tonumber(p.radius) or 5, n = p.normal } end
    end
  end
  local succ = {}
  for _, s in ipairs(type(race.segments) == 'table' and race.segments or {}) do
    if type(s) == 'table' and s.from ~= nil and nodes[s.from] and nodes[s.to] then
      local list = succ[s.from]
      if not list then list = {}; succ[s.from] = list end
      list[#list + 1] = s.to
    end
  end
  local start = race.startNode
  if start == nil or not nodes[start] then return nil, 'it has no start node' end

  -- The route in driving order, start node first.
  local route, at, closed = { start }, { [start] = 1 }, false
  local cur = start
  while #route < D.MAX_NODES do
    local nx = succ[cur]
    if not nx then break end
    for _, id in ipairs(nx) do
      if id == start then closed = true end
    end
    if closed or at[nx[1]] then break end
    cur = nx[1]
    route[#route + 1] = cur
    at[cur] = #route
  end
  local n = #route
  if n < 2 then return nil, 'it has fewer than two checkpoints' end

  -- Checkpoint number of route index r: a circuit's start node is the line, last.
  local function slotOf(r)
    if not closed then return r end
    return r == 1 and n or r - 1
  end
  local function along(r)
    local p = nodes[route[r > 1 and r - 1 or (closed and n or r)]]
    local q = nodes[route[r < n and r + 1 or (closed and 1 or r)]]
    local dx, dy = q.x - p.x, q.y - p.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 1e-6 then return 0, 1 end
    return dx / d, dy / d
  end
  local function gate(node, hx, hy)
    local w = node.r * 2
    if w < D.MIN_WIDTH then w = D.MIN_WIDTH end
    if w > D.MAX_WIDTH then w = D.MAX_WIDTH end
    return { x = round(node.x), y = round(node.y), z = round(node.z),
             hx = round(hx), hy = round(hy), width = round(w) }
  end

  local notes, faced = {}, 0
  local cps, heads = {}, {}
  for r = 1, n do
    local node = nodes[route[r]]
    local hx, hy = flat(node.n)
    if not hx then hx, hy = along(r); faced = faced + 1 end
    heads[r] = { hx, hy }
    cps[slotOf(r)] = gate(node, hx, hy)
  end

  -- Other ways on from a route node.
  local branches, leftOut = {}, 0
  for r = 1, n do
    local nx = succ[route[r]] or {}
    local onRoute = (closed and r == n) and start or route[r + 1]
    for _, alt in ipairs(nx) do
      if alt ~= onRoute then
        local path, seen, j = {}, {}, nil
        local c = alt
        while c ~= nil and not seen[c] and #path < D.MAX_NODES do
          if at[c] then j = at[c]; break end
          seen[c] = true
          path[#path + 1] = c
          c = succ[c] and succ[c][1]
        end
        if j == 1 and closed then j = n + 1 end
        if j and j > r and #path > 0 and #path == j - r - 1 then
          for k, id in ipairs(path) do
            local node = nodes[id]
            local hx, hy = flat(node.n)
            if not hx then hx, hy = heads[r + k][1], heads[r + k][2] end
            local g = gate(node, hx, hy)
            g.slot = slotOf(r + k)
            branches[#branches + 1] = g
          end
        else
          leftOut = leftOut + 1
        end
      end
    end
  end

  -- Pole, from the stock start. The heading is (sin, cos) of the quaternion's
  -- yaw: checked against the start line's normal on all 222 stock races of 0.40.
  local starts
  local sp
  for _, s in ipairs(type(race.startPositions) == 'table' and race.startPositions or {}) do
    if type(s) == 'table' and s.oldId ~= nil and s.oldId == race.defaultStartPosition then sp = s end
  end
  if sp then
    local x, y, z = vec(sp.pos)
    local q = type(sp.rot) == 'table' and sp.rot or {}
    local qx, qy, qz, qw = tonumber(q[1] or q.x), tonumber(q[2] or q.y), tonumber(q[3] or q.z), tonumber(q[4] or q.w)
    if x and qx and qy and qz and qw then
      local yaw = atan2(2 * (qw * qz + qx * qy), 1 - 2 * (qy * qy + qz * qz))
      local hx, hy = math.sin(yaw), math.cos(yaw)
      starts = { {
        x = round(x - hx * D.SLOT_BACK), y = round(y - hy * D.SLOT_BACK), z = round(z + D.SLOT_LIFT),
        hx = round(hx), hy = round(hy),
      } }
    end
  end

  -- The first gate armed at the green: a sprint's start gate, a circuit's line.
  local first = closed and cps[n] or cps[1]
  local moved = not starts
  if starts and not closed then
    local s = starts[1]
    moved = (s.x - first.x) * first.hx + (s.y - first.y) * first.hy > -D.SLOT_BACK
  end
  if moved then
    starts = { {
      x = round(first.x - first.hx * D.SLOT_BACK), y = round(first.y - first.hy * D.SLOT_BACK),
      z = round(first.z + D.SLOT_LIFT), hx = first.hx, hy = first.hy,
    } }
  end

  if leftOut > 0 then notes[#notes + 1] = leftOut .. ' other way(s) through left out' end
  if faced > 0 then notes[#notes + 1] = faced .. ' gate(s) face along the route' end
  if moved then notes[#notes + 1] = 'pole set behind the ' .. (closed and 'line' or 'start gate') end

  return {
    width = D.WIDTH, height = D.HEIGHT, depth = D.DEPTH,
    checkpoints = cps,
    branches = #branches > 0 and branches or nil,
    startPositions = starts,
    pointToPoint = not closed,
  }, notes
end

-- The stock races on the loaded level, for the picker. Returns the list (ids,
-- not paths) and the level.
function D.list()
  D.last = {}
  local out = {}
  local level = D.io.level()
  if type(level) ~= 'string' or level == '' then return out, nil end
  local rank = {}
  for i, k in ipairs(D.KINDS) do rank[k.dir] = i end
  -- Every level's, matched without case: the game's own mission loader
  -- compares the folder to the level that way, and a mod map's may differ.
  for _, path in ipairs(D.io.find('/gameplay/missions/')) do
    path = tostring(path)
    local lvl, kind, folder = path:match('/gameplay/missions/([^/]+)/([^/]+)/([^/]+)/race%.race%.json$')
    if lvl and lvl:lower() == level:lower() and rank[kind] then
      local race = D.io.read(path)
      local layout = race and D.convert(race)
      if layout then
        local id = kind .. '/' .. folder
        local name = D.title(D.io.read((path:gsub('race%.race%.json$', 'info.json'))), folder)
        D.last[id] = { path = path, name = name }
        out[#out + 1] = {
          id = id, name = name, kind = D.KINDS[rank[kind]].label, rank = rank[kind],
          gates = #layout.checkpoints, circuit = not layout.pointToPoint,
        }
      end
    end
  end
  table.sort(out, function (a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
    return a.id < b.id
  end)
  return out, level
end

-- One race from the last list, as a named layout and its notes, or nil and why.
function D.open(id)
  local entry = D.last[tostring(id or '')]
  if not entry then return nil, 'it is not in the list: open the list again' end
  local race = D.io.read(entry.path)
  if not race then return nil, 'its race file could not be read' end
  local layout, notes = D.convert(race)
  if not layout then return nil, notes end
  layout.name = entry.name
  return layout, notes
end

return D
