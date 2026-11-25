-- Race Manager: TEAMS AND CAR NUMBERS, league-wide.
--
-- An admin names the teams (name, a short code, a color and a logo link) and
-- gives drivers a team and a car number, once, on the server. Every client gets
-- them: each driver row carries its `team` id and `number`, and the list of
-- teams rides RM_Update on the sends that need it. The broadcast feed turns
-- them into team colors, number chips and team logos on stream.
--
-- NOTHING GLOBAL AT FILE SCOPE. "teams" sorts after "main", so BeamMP runs this
-- file on its own after main.lua has loaded it, and a file-scope handler would
-- replace the initialised one. RM_onTeamsSet comes from init().
--
-- MATCHED BY NAME, display name first. A driver is found by the name an admin
-- gave them (their alias, the roster's spelling), then by their BeamMP name,
-- case-insensitively. Resolved per driver row in main.lua's driverForWire and
-- memoized on the record, so a rename is seen at the next broadcast and a
-- settled one costs a comparison.
--
-- THE LIST IS NOT ON EVERY BROADCAST. The 3 Hz race pushes carry only each
-- row's team id and number; the teams themselves go on targeted sends (a
-- client asking for the state, a login) and on the one broadcast after an
-- edit. No new server-to-client event: clients bind those once per session.
--
-- PIT STALLS. A team and a driver can each have a stall number; the driver's
-- own wins over the team's. Resolved with the team and number (rec.pitStall)
-- and sent on each driver row: clients guide a driver to it, label it, and
-- hold a car stopped in another driver's stall longer (main.lua's
-- pitWrongStallSeconds), and Start in pits can place each car in its own.
-- A number past the loaded layout's stalls is the same as none.
--
-- Data/teams.json, cached: it is read on every broadcast. A file that does not
-- parse is never written over, and edits are refused until it is fixed.

local M = {}
local host

M.MAX_TEAMS   = 32
M.MAX_ENTRIES = 200
M.MAX_NAME    = 32
M.MAX_LOGO    = 256
M.MAX_STALL   = 99

M.rev = 0            -- bumped on every change: the per-record memo's key
M.broken = nil       -- why Data/teams.json could not be read, or nil
local doc = { version = 1, nextId = 1, teams = {}, entries = {} }
local byName = {}    -- [lower name] = entry
local byId = {}      -- [id] = team
local wireList = {}  -- the list as clients get it
local adminList = {} -- { teams, entries } for the admin panel
local dirty = false

local function teamsFile() return host.DATA_DIR .. '/teams.json' end

local function trim(s)
  return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- ---------------------------------------------------------------------------
-- Checking what comes in (from the file and from the panel alike)
-- ---------------------------------------------------------------------------
function M.cleanName(v)
  if type(v) ~= 'string' then return nil end
  v = trim(v:gsub('%c', ''))
  if v == '' or #v > M.MAX_NAME then return nil end
  if utf8 and utf8.len and not utf8.len(v) then return nil end
  return v
end

function M.cleanShort(v)
  if type(v) ~= 'string' then return nil end
  v = trim(v):upper()
  if v:match('^[A-Z0-9][A-Z0-9][A-Z0-9]?[A-Z0-9]?$') then return v end
  return nil
end

function M.cleanColor(v)
  if type(v) ~= 'string' then return nil end
  v = trim(v)
  if v:match('^#%x%x%x%x%x%x$') then return v:lower() end
  return nil
end

-- '' (no logo), a web link, or nil and why. Discord's attachment links expire
-- within a day (the ex= parameter), which would blank every logo by race night.
function M.cleanLogo(v)
  if v == nil or v == '' then return '' end
  if type(v) ~= 'string' then return nil, 'The logo must be a web link.' end
  v = trim(v)
  if v == '' then return '' end
  if #v > M.MAX_LOGO then return nil, 'The logo link is too long (' .. M.MAX_LOGO .. ' characters at most).' end
  if not v:match('^https?://[^%s"\'<>\\`]+$') then
    return nil, 'The logo must be a web link starting https://, with no spaces or quotes.'
  end
  local hostPart = v:match('^https?://([^/?#]+)') or ''
  hostPart = hostPart:lower()
  if (hostPart == 'cdn.discordapp.com' or hostPart == 'media.discordapp.net') and v:find('[?&]ex=') then
    return nil, 'Discord attachment links stop working within a day. Use a permanent link '
      .. '(your league site, Imgur), or a logo in the streamer\'s overlay folder.'
  end
  return v
end

function M.cleanNumber(v)
  if v == nil or v == '' then return '' end
  if type(v) == 'number' then
    if v ~= math.floor(v) or v < 0 or v > 999 then return nil end
    return string.format('%d', v)
  end
  if type(v) ~= 'string' then return nil end
  v = trim(v)
  if v == '' then return '' end
  if v:match('^%d%d?%d?$') then return v end
  return nil
end

-- A pit stall: '' (none), or a whole number 1 to MAX_STALL. nil when neither.
function M.cleanStall(v)
  if v == nil or v == '' or v == false then return '' end
  if type(v) == 'string' then
    v = trim(v)
    if v == '' then return '' end
    if not v:match('^%d%d?$') then return nil end
    v = tonumber(v)
  end
  if type(v) ~= 'number' or v ~= math.floor(v) then return nil end
  if v == 0 then return '' end
  if v < 1 or v > M.MAX_STALL then return nil end
  return math.floor(v)
end

-- ---------------------------------------------------------------------------
-- The cache
-- ---------------------------------------------------------------------------
local function rebuild()
  byName, byId, wireList = {}, {}, {}
  for _, t in ipairs(doc.teams) do
    byId[t.id] = t
    wireList[#wireList + 1] = { id = t.id, name = t.name, short = t.short, color = t.color,
      logo = t.logo ~= '' and t.logo or nil, stall = t.stall ~= '' and t.stall or nil }
  end
  local entries = {}
  for _, e in ipairs(doc.entries) do
    byName[e.name:lower()] = e
    entries[#entries + 1] = { name = e.name, team = e.team, number = e.number ~= '' and e.number or nil,
      stall = e.stall ~= '' and e.stall or nil }
  end
  table.sort(entries, function (a, b) return a.name:lower() < b.name:lower() end)
  adminList = { teams = wireList, entries = entries }
  M.rev = M.rev + 1
end

-- The file's contents, checked. Anything malformed is dropped, not repaired.
local function fromFile(t)
  local out = { version = 1, nextId = 1, teams = {}, entries = {} }
  if type(t) ~= 'table' then return out end
  local shorts, maxId = {}, 0
  for _, raw in ipairs(type(t.teams) == 'table' and t.teams or {}) do
    if #out.teams >= M.MAX_TEAMS then break end
    local id = tonumber(type(raw) == 'table' and raw.id)
    local name = type(raw) == 'table' and M.cleanName(raw.name)
    local short = type(raw) == 'table' and M.cleanShort(raw.short)
    local color = type(raw) == 'table' and M.cleanColor(raw.color)
    local logo = type(raw) == 'table' and M.cleanLogo(raw.logo) or ''
    local stall = type(raw) == 'table' and M.cleanStall(raw.stall) or ''
    if id and id >= 1 and id == math.floor(id) and name and short and color and not shorts[short] then
      shorts[short] = true
      out.teams[#out.teams + 1] = { id = math.floor(id), name = name, short = short, color = color,
        logo = logo, stall = stall }
      if id > maxId then maxId = id end
    end
  end
  local teamIds = {}
  for _, tm in ipairs(out.teams) do teamIds[tm.id] = true end
  local names, numbers = {}, {}
  for _, raw in ipairs(type(t.entries) == 'table' and t.entries or {}) do
    if #out.entries >= M.MAX_ENTRIES then break end
    local name = type(raw) == 'table' and M.cleanName(raw.name)
    local team = type(raw) == 'table' and tonumber(raw.team) or nil
    local number = type(raw) == 'table' and M.cleanNumber(raw.number) or ''
    local stall = type(raw) == 'table' and M.cleanStall(raw.stall) or ''
    if team and not teamIds[team] then team = nil end
    if number and number ~= '' and numbers[number] then number = '' end
    if name and not names[name:lower()] and (team or (number and number ~= '') or stall ~= '') then
      names[name:lower()] = true
      if number ~= '' then numbers[number] = true end
      out.entries[#out.entries + 1] = { name = name, team = team, number = number or '', stall = stall }
    end
  end
  out.nextId = math.max(math.floor(tonumber(t.nextId) or 1), maxId + 1)
  return out
end

local function save()
  local text = host.jsonStringify({ version = 1, nextId = doc.nextId, teams = doc.teams,
    entries = doc.entries }, '  ')
  local ok, err = host.writeFile(teamsFile(), text)
  if not ok then
    print('[RaceManager] Teams: could not write ' .. teamsFile() .. ': ' .. tostring(err))
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- What main.lua asks
-- ---------------------------------------------------------------------------
-- A driver's team id, car number and pit stall, stamped on the record
-- (rec.team, rec.number, rec.pitStall) for driverForWire to copy. The stall is
-- the driver's own, else their team's. Memoized: a settled record is a
-- comparison per broadcast.
function M.lookup(rec)
  if rec.teamRev == M.rev and rec.teamAlias == rec.alias and rec.teamFor == rec.name then
    return rec.team, rec.number
  end
  local e = (type(rec.alias) == 'string' and byName[rec.alias:lower()])
    or (type(rec.name) == 'string' and byName[rec.name:lower()]) or nil
  rec.teamRev, rec.teamAlias, rec.teamFor = M.rev, rec.alias, rec.name
  rec.team = e and e.team or nil
  rec.number = (e and e.number ~= '') and e.number or nil
  local stall = e and e.stall ~= '' and e.stall or nil
  if not stall and rec.team and byId[rec.team] and byId[rec.team].stall ~= '' then
    stall = byId[rec.team].stall
  end
  rec.pitStall = stall
  return rec.team, rec.number
end

-- The teams for RM_Update: on every targeted send, and on the first broadcast
-- after a change; nil otherwise. An empty list is sent, not nil, so a client
-- that had teams clears them.
function M.wire(targetPid)
  if targetPid == nil then
    if not dirty then return nil end
    dirty = false
  end
  return wireList
end

-- For the admin panel: every team and every driver entry.
function M.entries() return adminList end

function M.team(id) return byId[id] end

-- ---------------------------------------------------------------------------
-- Edits from the panel
-- ---------------------------------------------------------------------------
local function notice(pid, msg)
  if pid then
    MP.TriggerClientEvent(pid, 'RM_Notice', Util.JsonEncode({ kind = 'session', msg = 'Teams', sub = msg }))
  end
end

local function changed(pid, what)
  rebuild()
  dirty = true
  local kept = save()
  print('[RaceManager] Teams: ' .. what .. ' (' .. tostring(MP.GetPlayerName(pid) or pid) .. ')')
  if not kept then notice(pid, 'Changed, but Data/teams.json could not be written: it reverts on restart.') end
  if host.broadcast then host.broadcast() end
  if host.pushAdmins then host.pushAdmins() end
end

local function findShort(short, except)
  for _, t in ipairs(doc.teams) do
    if t.short == short and t.id ~= except then return t end
  end
end

local function entryIndex(name)
  local low = name:lower()
  for i, e in ipairs(doc.entries) do
    if e.name:lower() == low then return i end
  end
end

local OPS = {}

function OPS.team(pid, d)
  local id = tonumber(d.id)
  local t = id and byId[id] or nil
  if id and not t then return notice(pid, 'That team is gone. Refresh the list.') end
  local name = M.cleanName(d.name)
  if not name then return notice(pid, 'A team needs a name of 1 to ' .. M.MAX_NAME .. ' characters.') end
  local short = M.cleanShort(d.short)
  if not short then return notice(pid, 'The short code is 2 to 4 letters or digits, like PHX.') end
  if findShort(short, id) then return notice(pid, short .. ' is already another team\'s code.') end
  local color = M.cleanColor(d.color)
  if not color then return notice(pid, 'The color is a hex value like #ff7a1a.') end
  local logo, why = M.cleanLogo(d.logo)
  if not logo then return notice(pid, why) end
  -- Left out (an older panel): the stall it had.
  local stall = t and t.stall or ''
  if d.stall ~= nil then
    stall = M.cleanStall(d.stall)
    if not stall then return notice(pid, 'A pit stall is a number from 1 to ' .. M.MAX_STALL .. '.') end
  end
  if t then
    t.name, t.short, t.color, t.logo, t.stall = name, short, color, logo, stall
    return changed(pid, 'team ' .. short .. ' edited')
  end
  if #doc.teams >= M.MAX_TEAMS then return notice(pid, 'There are already ' .. M.MAX_TEAMS .. ' teams.') end
  t = { id = doc.nextId, name = name, short = short, color = color, logo = logo, stall = stall }
  doc.nextId = doc.nextId + 1
  doc.teams[#doc.teams + 1] = t
  return changed(pid, 'team ' .. short .. ' added')
end

function OPS.removeTeam(pid, d)
  local id = tonumber(d.id)
  for i, t in ipairs(doc.teams) do
    if t.id == id then
      table.remove(doc.teams, i)
      -- Its drivers keep their numbers and stalls; entries left with nothing go.
      for j = #doc.entries, 1, -1 do
        local e = doc.entries[j]
        if e.team == id then
          e.team = nil
          if e.number == '' and e.stall == '' then table.remove(doc.entries, j) end
        end
      end
      return changed(pid, 'team ' .. t.short .. ' removed')
    end
  end
  notice(pid, 'That team is gone already.')
end

function OPS.entry(pid, d)
  local name = M.cleanName(d.name)
  if not name then return notice(pid, 'A driver name is 1 to ' .. M.MAX_NAME .. ' characters.') end
  local team = nil
  if d.team ~= nil and d.team ~= '' and d.team ~= false then
    team = tonumber(d.team)
    if not (team and byId[team]) then return notice(pid, 'That team is gone. Refresh the list.') end
  end
  local number = M.cleanNumber(d.number)
  if not number then return notice(pid, 'A car number is 1 to 3 digits, like 7 or 07.') end
  local i = entryIndex(name)
  -- Left out (an older panel): the stall it had.
  local stall = i and doc.entries[i].stall or ''
  if d.stall ~= nil then
    stall = M.cleanStall(d.stall)
    if not stall then return notice(pid, 'A pit stall is a number from 1 to ' .. M.MAX_STALL .. '.') end
  end
  if number ~= '' then
    for j, e in ipairs(doc.entries) do
      if j ~= i and e.number == number then
        return notice(pid, '#' .. number .. ' is already ' .. e.name .. '\'s number.')
      end
    end
  end
  if not team and number == '' and stall == '' then
    if not i then return end
    table.remove(doc.entries, i)
    return changed(pid, name .. ' has no team, number or stall now')
  end
  if i then
    local e = doc.entries[i]
    e.name, e.team, e.number, e.stall = name, team, number, stall
  else
    if #doc.entries >= M.MAX_ENTRIES then return notice(pid, 'There are already ' .. M.MAX_ENTRIES .. ' drivers listed.') end
    doc.entries[#doc.entries + 1] = { name = name, team = team, number = number, stall = stall }
  end
  return changed(pid, name .. ': ' .. (team and byId[team].short or 'no team')
    .. (number ~= '' and (', #' .. number) or '') .. (stall ~= '' and (', PIT ' .. stall) or ''))
end

function OPS.removeEntry(pid, d)
  local name = M.cleanName(d.name)
  local i = name and entryIndex(name)
  if not i then return end
  table.remove(doc.entries, i)
  return changed(pid, name .. ' taken off the list')
end

-- Either admin tier: every edit is undone by editing it back.
function M.set(pid, raw)
  if not host.requireAuth(pid) then return end
  if M.broken then return notice(pid, M.broken) end
  local ok, d = pcall(Util.JsonDecode, raw or '')
  if not ok or type(d) ~= 'table' then return end
  local op = OPS[d.op]
  if not op then return end
  op(pid, d)
end

-- At boot: read the file once. Kept in memory from then on.
function M.warm()
  M.broken = nil
  local f = io.open(teamsFile(), 'r')
  if not f then
    doc = { version = 1, nextId = 1, teams = {}, entries = {} }
  else
    local text = f:read('*a')
    f:close()
    local ok, t = pcall(host.jsonParse, text)
    if not ok or type(t) ~= 'table' then
      M.broken = 'Data/teams.json does not parse, so teams cannot be changed until it is fixed '
        .. 'or removed on the server.'
      print('[RaceManager] Teams: ' .. M.broken)
      doc = { version = 1, nextId = 1, teams = {}, entries = {} }
    else
      doc = fromFile(t)
    end
  end
  rebuild()
  dirty = true
  if #doc.teams > 0 or #doc.entries > 0 then
    print(string.format('[RaceManager] Teams: %d team(s), %d driver(s) with a team or number',
      #doc.teams, #doc.entries))
  end
end

-- The RM_onTeams* global, installed here and not at file scope: see the top.
function M.init(h)
  host = h
  M.host = h
  function RM_onTeamsSet(pid, raw) M.set(pid, raw) end
end

return M
