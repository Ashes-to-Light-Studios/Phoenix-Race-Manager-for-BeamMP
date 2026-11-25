-- Race Manager: RACE RULES THAT SURVIVE A RESTART, and saved rulesets.
--
-- The rules in the Race, Quali and Grid tabs live in `race`. They used to live
-- nowhere else, so a map switch that restarts the server, a crash and a hot
-- reload all put them back to config.json. Data/rules.json now holds them,
-- written when they change and put back at boot, beside the rulesets an admin
-- saved by name.
--
-- NOTHING GLOBAL AT FILE SCOPE. "rules" sorts after "main", so BeamMP runs this
-- file on its own after main.lua has loaded it, and a file-scope handler would
-- replace the initialised one. RM_onRules comes from init().
--
-- A CHANGE IS FOUND, NOT REPORTED. Every setter ends in broadcastState, which
-- calls M.sync: the live rules against what was last written, a write on a
-- difference. The automatic switch-offs (joker on a track with no route, pace
-- lap on a sprint, Reset ending the heats) are caught the same way, and a
-- setter added later needs no call of its own. Comparisons only, so the 3 Hz
-- pushes stay cheap.
--
-- CONFIG.JSON STILL WINS WHERE IT WAS EDITED. The file keeps the defaults it
-- was written against (`base`). A rule whose config.json value has changed
-- since boots from config.json, the rest from the file.
--
-- TRACK RULES FOLLOW THE TRACK. A joker lap needs a joker route and a pace lap
-- a circuit, so both apply only where the loaded track allows them, as the
-- panel's switches do. Custom grid order is never kept: its pins belong to
-- drivers connected now.

local M = {}
local host, race, CFG

M.MAX_SETS = 30
M.MAX_NAME = 32
M.broken = nil       -- why Data/rules.json could not be read, or nil

local loaded = false  -- the file has been read: until then nothing is written
local sets = {}       -- { { name, rules } }, sorted by name
local written = {}    -- the live rules as last written
local active, atDefaults = nil, false  -- the set (or defaults) the live rules equal
local wireCache = nil
local dirty = false

-- Every rule a ruleset holds, with what a value may be. `lo`/`hi` naming a
-- string are CFG ceilings. `default` is for a rule config.json does not seed.
local SPEC = {
  { 'raceMode', { laps = true, timed = true, endurance = true }, default = 'laps' },
  { 'totalLaps', 'int', 1, 'maxTotalLaps' },
  { 'raceTimeLimit', 'int', 0, 'maxRaceTime' },
  { 'finishAfter', 'int', 1, 99 },
  { 'finishTimer', 'int', 0, 3600 },
  { 'maxResets', 'int', -1, 'maxResetLimit' },
  { 'resetMode', { inplace = true, checkpoint = true } },
  { 'enableCheckpointSkipPenalty', 'bool' },
  { 'checkpointSkipWarningsAllowed', 'int', 0, 99 },
  { 'checkpointSkipPenaltyType', { time = true, lift = true, liftAndTime = true } },
  { 'checkpointSkipPenaltySeconds', 'half', 0.5, 300 },
  { 'checkpointSkipLiftSeconds', 'half', 0.5, 30 },
  { 'checkpointSkipLiftWindow', 'int', 5, 300 },
  { 'checkpointSkipPitServe', { off = true, optional = true, required = true } },
  { 'checkpointSkipPitLaps', 'int', 1, 20 },
  { 'pitStopsRequired', 'int', 0, 10 },
  { 'pitStopMissed', { dsq = true, time = true } },
  { 'pitStopPenaltySeconds', 'half', 1, 600 },
  { 'paceLap', 'bool' },
  { 'luckyDog', 'bool' },
  { 'lapsBack', 'bool' },
  { 'cautionMode', { line = true, call = true } },
  { 'jokerEnabled', 'bool', default = false },
  { 'ghostQuali', 'bool', default = false },
  { 'qualiFromPits', 'bool', default = false },
  { 'raceFromPits', 'bool', default = false },
  { 'qualiLapLimit', 'int', 0, 'maxQualiLaps' },
  { 'qualiTimeLimit', 'int', 0, 'maxQualiTime' },
  { 'heatCount', 'int', 0, 'maxHeats', default = 0 },
  { 'heatTransfer', 'int', 0, 99, default = 0 },
  { 'heatLaps', 'int', 0, 'maxTotalLaps' },
  { 'heatDraw', { quali = true, random = true, points = true }, default = 'quali' },
  { 'gridMode', { quali = true, reverse = true, random = true, heats = true,
    points = true, pointsrev = true }, default = 'quali' },
  { 'readyCheck', 'bool' },
}
M.SPEC = SPEC

local function rulesFile() return host.DATA_DIR .. '/rules.json' end

local function bound(b) return type(b) == 'string' and CFG[b] or b end

-- One value as the rule may hold it, or nil.
local function clean(s, v)
  local kind = s[2]
  if kind == 'bool' then
    if type(v) == 'boolean' then return v end
    return nil
  end
  if type(kind) == 'table' then
    return (type(v) == 'string' and kind[v]) and v or nil
  end
  v = tonumber(v)
  if not v or v ~= v then return nil end
  local lo, hi = bound(s[3]), bound(s[4])
  if kind == 'half' then return race.halfStep(v, lo, hi) end
  v = math.floor(v)
  if v < lo then v = lo elseif v > hi then v = hi end
  return v
end

-- A live rule as a ruleset holds it.
local function live(key)
  local v = race[key]
  if key == 'gridMode' and v == 'custom' then return 'quali' end
  return v
end

function M.snapshot()
  local t = {}
  for _, s in ipairs(SPEC) do t[s[1]] = live(s[1]) end
  return t
end

-- Every rule, each one checked, with the invariants the setters keep. A missing
-- or bad value takes `fill`'s.
local function complete(t, fill)
  t = type(t) == 'table' and t or {}
  local out = {}
  for _, s in ipairs(SPEC) do
    local v = clean(s, t[s[1]])
    if v == nil then v = fill[s[1]] end
    out[s[1]] = v
  end
  -- A lap race carries no clock, and a clock mode with none is a lap race.
  if out.raceMode == 'laps' then
    out.raceTimeLimit = 0
  elseif out.raceTimeLimit <= 0 then
    out.raceMode = 'laps'
  end
  if out.gridMode == 'heats' and out.heatCount == 0 then out.gridMode = 'quali' end
  return out
end

-- What config.json starts a server on.
local function defaults()
  local t = {}
  for _, s in ipairs(SPEC) do
    local v = CFG[s[1]]
    if v == nil then v = s.default end
    t[s[1]] = v
  end
  return complete(t, t)
end
M.defaults = defaults

local function same(a, b)
  for _, s in ipairs(SPEC) do
    if a[s[1]] ~= b[s[1]] then return false end
  end
  return true
end

local function rebuildWire()
  local names = {}
  for i, s in ipairs(sets) do names[i] = s.name end
  wireCache = { sets = names, active = active, atDefaults = atDefaults }
  dirty = true
end

-- Which saved set the live rules equal, if any. Run on a change only.
local function refreshMatch()
  local now = M.snapshot()
  local name = nil
  for _, s in ipairs(sets) do
    if same(s.rules, now) then name = s.name break end
  end
  local def = same(defaults(), now)
  if name ~= active or def ~= atDefaults or not wireCache then
    active, atDefaults = name, def
    rebuildWire()
  end
end

local function save()
  if M.broken then return false end
  if host.ensureDir then host.ensureDir() end
  local list = {}
  for i, s in ipairs(sets) do list[i] = { name = s.name, rules = s.rules } end
  local ok, err = host.writeFile(rulesFile(), host.jsonStringify({
    version = 1, base = defaults(), live = written, sets = list,
  }))
  if not ok then
    print('[RaceManager] Rules: could not write ' .. rulesFile() .. ': ' .. tostring(err))
    return false
  end
  return true
end

-- Put a complete rules table in force. Returns what the loaded track refused.
local function apply(want)
  local t, notes = {}, {}
  for k, v in pairs(want) do t[k] = v end
  if t.jokerEnabled and (race.jokerGates or 0) == 0 then
    t.jokerEnabled = false
    notes[#notes + 1] = 'Joker lap left off: this track has no Joker Route.'
  end
  if t.paceLap and race.pointToPoint then
    t.paceLap = false
    notes[#notes + 1] = 'Pace lap left off: this track is a sprint stage.'
  end
  -- A different heat count is a different program: the old draw is dropped.
  if t.heatCount ~= race.heatCount and host.dropHeatDraw then host.dropHeatDraw() end
  for k, v in pairs(t) do race[k] = v end
  return notes
end

-- ---------------------------------------------------------------------------
-- What main.lua asks
-- ---------------------------------------------------------------------------
-- From broadcastState: write the live rules if one has moved.
function M.sync()
  if not loaded then return end
  for i = 1, #SPEC do
    local k = SPEC[i][1]
    if live(k) ~= written[k] then
      written = M.snapshot()
      save()
      refreshMatch()
      return
    end
  end
end

-- For RM_Update: admins' targeted sends, and the first broadcast after a
-- change. nil otherwise.
function M.wire(targetPid, isAdmin)
  if targetPid == nil then
    if not dirty then return nil end
    dirty = false
  elseif not isAdmin then
    return nil
  end
  return wireCache
end

-- ---------------------------------------------------------------------------
-- The panel's Rulesets row
-- ---------------------------------------------------------------------------
function M.cleanName(v)
  if type(v) ~= 'string' then return nil end
  v = v:gsub('%c', ''):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
  if v == '' or #v > M.MAX_NAME then return nil end
  if utf8 and utf8.len and not utf8.len(v) then return nil end
  return v
end

local function notice(pid, msg)
  MP.TriggerClientEvent(pid, 'RM_Notice', Util.JsonEncode({ kind = 'session', msg = 'Rulesets', sub = msg }))
end

local function findSet(name)
  local low = name:lower()
  for i, s in ipairs(sets) do
    if s.name:lower() == low then return i, s end
  end
end

local function who(pid) return tostring(MP.GetPlayerName(pid) or pid) end

-- Idle-locked, as each rule's own switch is.
local function load(pid, want, label)
  if host.underWay() then
    return notice(pid, 'Finish the session before loading other rules.')
  end
  local notes = apply(want)
  host.broadcast()
  local msg = '[RaceManager] ' .. label .. ' loaded by ' .. who(pid)
  MP.SendChatMessage(-1, msg)
  print(msg .. (#notes > 0 and (' (' .. table.concat(notes, ' ') .. ')') or ''))
  notice(pid, label .. ' loaded.' .. (#notes > 0 and (' ' .. table.concat(notes, ' ')) or ''))
end

local OPS = {}

-- Either tier: overwriting a set is undone by saving it again.
function OPS.save(pid, name)
  if not name then return notice(pid, 'A ruleset name is 1 to ' .. M.MAX_NAME .. ' characters.') end
  local i = findSet(name)
  if not i and #sets >= M.MAX_SETS then
    return notice(pid, 'There are ' .. M.MAX_SETS .. ' saved rulesets already: delete one first.')
  end
  local entry = { name = name, rules = M.snapshot() }
  if i then sets[i] = entry else sets[#sets + 1] = entry end
  table.sort(sets, function (a, b) return a.name:lower() < b.name:lower() end)
  local kept = save()
  refreshMatch()
  rebuildWire()
  print('[RaceManager] Ruleset "' .. name .. '" ' .. (i and 'updated' or 'saved') .. ' by ' .. who(pid))
  notice(pid, (i and 'Updated "' or 'Saved "') .. name .. '".'
    .. (kept and '' or ' Data/rules.json could not be written, so it is gone after a restart.'))
  host.pushAdmins()
end

function OPS.load(pid, name)
  if not name then return end
  local _, s = findSet(name)
  if not s then return notice(pid, 'No ruleset is saved as "' .. name .. '".') end
  load(pid, s.rules, 'Ruleset "' .. s.name .. '"')
end

function OPS.defaults(pid)
  load(pid, defaults(), 'The server default rules')
end

-- ADMIN ONLY, like a garage set: nothing puts a deleted one back.
function OPS.delete(pid, name)
  if not host.requireFull(pid) then return end
  if not name then return end
  local i, s = findSet(name)
  if not i then return end
  table.remove(sets, i)
  save()
  refreshMatch()
  rebuildWire()
  print('[RaceManager] Ruleset "' .. s.name .. '" deleted by ' .. who(pid))
  notice(pid, 'Deleted "' .. s.name .. '".')
  host.pushAdmins()
end

function M.handle(pid, raw)
  if not host.requireAuth(pid) then return end
  local ok, d = pcall(Util.JsonDecode, raw or '')
  if not ok or type(d) ~= 'table' then return end
  local op = OPS[d.op]
  if not op then return end
  -- The defaults need no file; everything else would write over a broken one.
  if M.broken and d.op ~= 'defaults' then return notice(pid, M.broken) end
  op(pid, M.cleanName(d.name))
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
-- After applyConfigToRace: the file's rules over config.json's, except where
-- config.json was edited since.
function M.warm()
  loaded, M.broken = false, nil
  sets, written, active, atDefaults, wireCache = {}, {}, nil, false, nil
  local def = defaults()
  local data
  local f = io.open(rulesFile(), 'r')
  if f then
    local text = f:read('*a')
    f:close()
    local ok, t = pcall(host.jsonParse, text)
    if ok and type(t) == 'table' then
      data = t
    else
      M.broken = 'Data/rules.json does not parse, so race rules are not kept over a restart '
        .. 'and rulesets cannot be changed until it is fixed or removed on the server.'
      print('[RaceManager] Rules: ' .. M.broken)
    end
  end
  if data then
    local seen = {}
    for _, s in ipairs(type(data.sets) == 'table' and data.sets or {}) do
      if #sets >= M.MAX_SETS then break end
      local name = type(s) == 'table' and M.cleanName(s.name)
      if name and not seen[name:lower()] and type(s.rules) == 'table' then
        seen[name:lower()] = true
        -- A rule added since the set was saved runs at its default.
        sets[#sets + 1] = { name = name, rules = complete(s.rules, def) }
      end
    end
    table.sort(sets, function (a, b) return a.name:lower() < b.name:lower() end)
    if type(data.live) == 'table' then
      local want = complete(data.live, def)
      local base = type(data.base) == 'table' and data.base or {}
      local edited = {}
      for _, s in ipairs(SPEC) do
        local was = clean(s, base[s[1]])
        if was ~= nil and was ~= def[s[1]] then
          want[s[1]] = def[s[1]]
          edited[#edited + 1] = s[1]
        end
      end
      local notes = apply(complete(want, want))
      print(string.format('[RaceManager] Race rules restored from Data/rules.json (%d saved ruleset%s)%s%s',
        #sets, #sets == 1 and '' or 's',
        #edited > 0 and ('; from config.json, edited since: ' .. table.concat(edited, ', ')) or '',
        #notes > 0 and ('. ' .. table.concat(notes, ' ')) or ''))
    end
  end
  written = M.snapshot()
  loaded = true
  -- Rewritten against this boot's config.json, or an edit after this one
  -- would be judged against an older base.
  if data then save() end
  refreshMatch()
end

-- The RM_onRules global, installed here and not at file scope: see the top.
function M.init(h)
  host, race, CFG = h, h.race, h.CFG
  loaded, dirty = false, false
  sets, written, active, atDefaults, wireCache = {}, {}, nil, false, nil
  function RM_onRules(pid, raw) M.handle(pid, raw) end
end

return M
