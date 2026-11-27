-- Race Manager: SAVED OVERLAY LOOKS, by name, for every streamer on the server.
--
-- The broadcast overlay's look (feedstyle.lua) lives on each streamer's own PC.
-- A league runs one look on formula nights and another on rallycross, so a look
-- is kept here under a name and loaded into any streamer's style editor, where
-- nothing changes on stream until they press Save there.
--
-- KEPT AS GIVEN. The feed that loads a look checks every value again
-- (Style.clean), so nothing here knows the style's keys: a look is a JSON
-- object under a size cap, and that is all this file checks.
--
-- Listing and loading are open to everyone: a look only fills the asker's own
-- editor. Saving takes a login, either tier; deleting is admin only, as a
-- ruleset's is.
--
-- NOTHING GLOBAL AT FILE SCOPE, as rules.lua: RM_onLooks comes from init().

local M = {}
local host

M.MAX_LOOKS = 30
M.MAX_NAME = 32
M.MAX_BYTES = 16384  -- a whole RM_Looks save; a full style is about 4 KB
M.broken = nil       -- why Data/looks.json could not be read, or nil

local looks = {}     -- { { name, style, by, at } }, sorted by name

local function looksFile() return host.DATA_DIR .. '/looks.json' end

function M.cleanName(v)
  if type(v) ~= 'string' then return nil end
  v = v:gsub('%c', ''):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
  if v == '' or #v > M.MAX_NAME then return nil end
  if utf8 and utf8.len and not utf8.len(v) then return nil end
  return v
end

local function findLook(name)
  local low = name:lower()
  for i, l in ipairs(looks) do
    if l.name:lower() == low then return i, l end
  end
end

local function sortLooks()
  table.sort(looks, function (a, b) return a.name:lower() < b.name:lower() end)
end

local function save()
  if M.broken then return false end
  if host.ensureDir then host.ensureDir() end
  local list = {}
  for i, l in ipairs(looks) do list[i] = { name = l.name, by = l.by, at = l.at, style = l.style } end
  local ok, err = host.writeFile(looksFile(), host.jsonStringify({ version = 1, looks = list }))
  if not ok then
    print('[RaceManager] Looks: could not write ' .. looksFile() .. ': ' .. tostring(err))
    return false
  end
  return true
end

local function reply(pid, t) MP.TriggerClientEvent(pid, 'RM_Looks', Util.JsonEncode(t)) end

local function names()
  local out = {}
  for i, l in ipairs(looks) do out[i] = { name = l.name, by = l.by, at = l.at } end
  return out
end

local function who(pid) return tostring(MP.GetPlayerName(pid) or pid) end

local OPS = {}

function OPS.list(pid)
  reply(pid, { op = 'list', looks = names(), broken = M.broken })
end

function OPS.get(pid, name, d)
  local l = nil
  if name then l = select(2, findLook(name)) end
  if not l then
    return reply(pid, { op = 'error', ticket = d.ticket, msg = 'No look is saved as "' .. tostring(name) .. '".' })
  end
  reply(pid, { op = 'get', ticket = d.ticket, name = l.name, style = l.style })
end

-- Either tier: overwriting a look is undone by saving it again.
function OPS.save(pid, name, d)
  if not host.isAuthed(pid) then
    return reply(pid, { op = 'error', ticket = d.ticket, msg = 'Saving a look takes an admin or moderator login.' })
  end
  if not name then
    return reply(pid, { op = 'error', ticket = d.ticket, msg = 'A look\'s name is 1 to ' .. M.MAX_NAME .. ' characters.' })
  end
  if type(d.style) ~= 'table' then
    return reply(pid, { op = 'error', ticket = d.ticket, msg = 'That is not a look.' })
  end
  local i = findLook(name)
  if not i and #looks >= M.MAX_LOOKS then
    return reply(pid, { op = 'error', ticket = d.ticket,
      msg = 'There are ' .. M.MAX_LOOKS .. ' saved looks already: delete one first.' })
  end
  local entry = { name = name, style = d.style, by = who(pid), at = os.time() }
  if i then looks[i] = entry else looks[#looks + 1] = entry end
  sortLooks()
  local kept = save()
  print('[RaceManager] Look "' .. name .. '" ' .. (i and 'updated' or 'saved') .. ' by ' .. who(pid))
  reply(pid, { op = 'saved', ticket = d.ticket, name = name, replaced = i ~= nil, kept = kept })
  reply(-1, { op = 'list', looks = names() })
end

-- ADMIN ONLY, like a ruleset: nothing puts a deleted one back.
function OPS.delete(pid, name, d)
  if not host.isFull(pid) then
    return reply(pid, { op = 'error', ticket = d.ticket, msg = 'Deleting a look takes the admin login.' })
  end
  local i, l = nil, nil
  if name then i, l = findLook(name) end
  if not i then
    return reply(pid, { op = 'error', ticket = d.ticket, msg = 'No look is saved as "' .. tostring(name) .. '".' })
  end
  table.remove(looks, i)
  save()
  print('[RaceManager] Look "' .. l.name .. '" deleted by ' .. who(pid))
  reply(pid, { op = 'deleted', ticket = d.ticket, name = l.name })
  reply(-1, { op = 'list', looks = names() })
end

function M.handle(pid, raw)
  if type(raw) ~= 'string' or #raw > M.MAX_BYTES then
    return reply(pid, { op = 'error', msg = 'That look is too big to keep on the server.' })
  end
  local ok, d = pcall(Util.JsonDecode, raw)
  if not ok or type(d) ~= 'table' then return end
  local op = OPS[d.op]
  if not op then return end
  if type(d.ticket) ~= 'number' then d.ticket = nil end
  -- Reading needs no file; writing would go over a broken one.
  if M.broken and (d.op == 'save' or d.op == 'delete') then
    return reply(pid, { op = 'error', ticket = d.ticket, msg = M.broken })
  end
  op(pid, M.cleanName(d.name), d)
end

-- Boot: the looks kept so far.
function M.warm()
  looks, M.broken = {}, nil
  local f = io.open(looksFile(), 'r')
  if not f then return end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(host.jsonParse, text)
  if not ok or type(data) ~= 'table' then
    M.broken = 'Data/looks.json does not parse, so looks cannot be saved until it is fixed '
      .. 'or removed on the server.'
    print('[RaceManager] Looks: ' .. M.broken)
    return
  end
  local seen = {}
  for _, l in ipairs(type(data.looks) == 'table' and data.looks or {}) do
    if #looks >= M.MAX_LOOKS then break end
    local name = type(l) == 'table' and M.cleanName(l.name)
    if name and not seen[name:lower()] and type(l.style) == 'table' then
      seen[name:lower()] = true
      looks[#looks + 1] = { name = name, style = l.style,
        by = type(l.by) == 'string' and l.by or '?', at = tonumber(l.at) or 0 }
    end
  end
  sortLooks()
  print(string.format('[RaceManager] %d saved look%s from Data/looks.json', #looks, #looks == 1 and '' or 's'))
end

-- The RM_onLooks global, installed here and not at file scope: see the top.
function M.init(h)
  host = h
  looks, M.broken = {}, nil
  function RM_onLooks(pid, raw) M.handle(pid, raw) end
end

return M
