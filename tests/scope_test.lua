-- Static check: nothing uses a top-level local before it is declared.
--
-- Why this exists: it is the one mistake in these files that compiles perfectly
-- and then fails only when the code actually runs, which in a race mod means it
-- fails in front of a full grid.
--
-- Lua resolves an identifier at COMPILE time. A function body that names
-- something whose `local` appears later in the file does not get an upvalue --
-- it gets a global read, and that global is nil. There is no warning, no load
-- error, and nothing wrong with the file until the moment that line executes:
--
--     local function clearEverything()
--       editorMsg('cleared')          -- nil global: throws when pressed
--     end
--     ...five thousand lines...
--     local function editorMsg(msg) ... end
--
-- Both big files are long enough that "is this declared above me?" is not a
-- question anybody can answer by looking, and it has been got wrong repeatedly:
-- reaching for the derby module from the top of the extension, and for
-- editorMsg from the track-clearing code, both of which are thousands of lines
-- out of order.
--
-- The check is exact rather than heuristic. Any textual use of the name before
-- its declaration line is a global read, because scope in Lua is lexical and
-- runs from the declaration to the end of the block -- it does not matter
-- whether the enclosing function is called before or after the local exists.
--
-- Run from the repo root: lua5.3 tests/scope_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local FILES = {
  'lua/ge/extensions/raceManager.lua',
  'lua/ge/extensions/raceManager/derby.lua',
  'lua/ge/extensions/raceManager/render.lua',
  'lua/ge/extensions/raceManager/maps.lua',
  'lua/ge/extensions/raceManager/records.lua',
  'lua/ge/extensions/raceManager/lights.lua',
  'lua/ge/extensions/raceManager/radar.lua',
  'lua/ge/extensions/raceManager/props.lua',
  'lua/ge/extensions/raceManager/splash.lua',
  'lua/ge/extensions/raceManager/feed.lua',
  'lua/ge/extensions/raceManager/feedstyle.lua',
  'lua/ge/extensions/raceManager/upload.lua',
  'lua/ge/extensions/raceManager/stock.lua',
  'lua/ge/extensions/raceManager/share.lua',
  'server/RaceManager/main.lua',
  'server/RaceManager/derby.lua',
  'server/RaceManager/maps.lua',
  'server/RaceManager/records.lua',
  'server/RaceManager/update.lua',
  'server/RaceManager/discord.lua',
  'server/RaceManager/teams.lua',
}

-- Each host file, and the modules split out of it. Used by the orphan check
-- below; add a module here when it is created and both checks cover it.
--
-- BOTH SIDES, because both are splitting the same way for the same reason and
-- the mistake is identical on either. The server pair arrived second and the
-- server made it immediately.
local HOSTS = {
  { host = 'lua/ge/extensions/raceManager.lua', modules = {
      'lua/ge/extensions/raceManager/derby.lua',
      'lua/ge/extensions/raceManager/render.lua',
      'lua/ge/extensions/raceManager/maps.lua',
      'lua/ge/extensions/raceManager/records.lua',
      'lua/ge/extensions/raceManager/lights.lua',
      'lua/ge/extensions/raceManager/radar.lua',
      'lua/ge/extensions/raceManager/props.lua',
      'lua/ge/extensions/raceManager/splash.lua',
      'lua/ge/extensions/raceManager/feed.lua',
      'lua/ge/extensions/raceManager/upload.lua',
      'lua/ge/extensions/raceManager/stock.lua',
      'lua/ge/extensions/raceManager/share.lua',
    } },
  { host = 'server/RaceManager/main.lua', modules = {
      'server/RaceManager/derby.lua',
      'server/RaceManager/maps.lua',
      'server/RaceManager/records.lua',
      'server/RaceManager/update.lua',
      'server/RaceManager/discord.lua',
      'server/RaceManager/teams.lua',
    } },
}

-- Comments and string literals are stripped first. Without that, a name
-- mentioned in the prose above its own declaration reads as a use of it, and
-- these files carry more comment than code in places.
local function stripped(line)
  local s = line:gsub('%-%-.*$', '')
  s = s:gsub('"[^"]*"', '""')
  s = s:gsub("'[^']*'", "''")
  return s
end

-- Only uses that look like a CALL or a field access (`name(`, `name.`,
-- `name:`). A bare mention is usually the name being assigned or passed and
-- is not worth the false positives. ONE PASS over the identifiers: matching a
-- pattern per declared name per line took minutes on the two big files.
-- `uses` takes a name after `:` too (the declaration check always has);
-- `plain` does not (the orphan check, where `obj:name()` is a method).
local function useIndex(code)
  local uses, plain = {}, {}
  for i, l in ipairs(code) do
    for s, name, e in l:gmatch('()([%a_][%w_]*)()') do
      if l:find('^%s*[%(%.:]', e) then
        local before = s > 1 and l:sub(s - 1, s - 1) or ''
        if not before:find('[%w_%.]') then
          local t = uses[name]
          if not t then t = {}; uses[name] = t end
          if t[#t] ~= i then t[#t + 1] = i end
          if before ~= ':' then
            local p = plain[name]
            if not p then p = {}; plain[name] = p end
            if p[#p] ~= i then p[#p + 1] = i end
          end
        end
      end
    end
  end
  return uses, plain
end

-- Each file once: the orphan check asks about the same host many times.
local scanned = {}

local function scan(path)
  if scanned[path] then
    local r = scanned[path]
    return r.bad, r.declAt, r.code, r.plain
  end
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local src = f:read('*a')
  f:close()

  local code = {}
  for line in (src .. '\n'):gmatch('([^\n]*)\n') do
    code[#code + 1] = stripped(line)
  end

  -- TOP-LEVEL declarations only, anchored at column 0. An indented `local` is
  -- inside some function and has its own scope, which this check has no opinion
  -- about: a name shadowed in a nested block is a different question.
  local declAt = {}
  for i, l in ipairs(code) do
    local fn = l:match('^local function ([%w_]+)')
    if fn and not declAt[fn] then declAt[fn] = i end
    local v = l:match('^local ([%w_]+)%s*=')
    if v and not declAt[v] then declAt[v] = i end
  end

  local uses, plain = useIndex(code)
  local bad = {}
  for name, declLine in pairs(declAt) do
    for _, i in ipairs(uses[name] or {}) do
      if i < declLine then
        bad[#bad + 1] = string.format('%s:%d uses "%s", which is declared at line %d',
          path, i, name, declLine)
      end
    end
  end
  scanned[path] = { bad = bad, declAt = declAt, code = code, plain = plain }
  return bad, declAt, code, plain
end

for _, path in ipairs(FILES) do
  local bad = scan(path)
  if #bad > 0 then
    for _, line in ipairs(bad) do print('  ' .. line) end
  end
  check(#bad == 0, path .. ' has no use of a top-level local before its '
    .. 'declaration (found ' .. #bad .. '). Each one compiles fine and reads a '
    .. 'nil global at runtime: move the declaration up, or reach the value '
    .. 'through a global RM_* handler, which resolves when it is called')
end

-- ---------------------------------------------------------------------------
-- ORPHANS: names the extension still calls after they moved into a module
-- ---------------------------------------------------------------------------
-- The same nil-global crash as above, arrived at from the other direction, and
-- the check above cannot see it. That one asks "is this declared LATER?"; this
-- asks "is it declared AT ALL?". When a block of code moves into a module, a
-- call site left behind names something that is now declared in a different
-- file -- so it is not a use-before-declaration, it is a use-before-nothing.
--
-- This is not hypothetical. Extracting the renderer left exactly one:
--
--     labelCache.route = {}      -- in setPointToPoint
--
-- labelCache went with the renderer. The line compiled, the whole suite stayed
-- green, and the editor's sprint/circuit toggle would have thrown the moment an
-- admin pressed it -- because nothing covered that toggle, and a crash needs a
-- test to walk into it. A static check does not.
--
-- Every future extraction can leave one of these, which is what makes it worth
-- a test rather than a careful read.
local function orphans(EXTENSION, MODULES)
  local _, declared, _, hostUses = scan(EXTENSION)

  local found = {}
  for _, mod in ipairs(MODULES) do
    for name in pairs(select(2, scan(mod))) do
      -- A name the module owns and the host does not declare. Bare uses only:
      -- `render.palette` is the module's public surface and correct.
      if not declared[name] then
        for _, i in ipairs(hostUses[name] or {}) do
          found[#found + 1] = string.format(
            '%s:%d calls "%s", which now lives in %s',
            EXTENSION, i, name, mod:match('([%w_]+)%.lua$'))
        end
      end
    end
  end
  return found
end

for _, pair in ipairs(HOSTS) do
  local orphaned = orphans(pair.host, pair.modules)
  for _, line in ipairs(orphaned) do print('  ' .. line) end
  check(#orphaned == 0, pair.host .. ' calls nothing that moved into a module '
    .. '(found ' .. #orphaned .. '). Reach it through the module table, or '
    .. 'expose it as a function on the module if the host genuinely needs it')
end

-- The check has to be able to FAIL, or a broken pattern would report every file
-- as clean forever. A file that is wrong on purpose, scanned the same way.
local sample = {
  'local function top()',
  '  helper()',
  'end',
  'local function helper() end',
}
local tmp = os.tmpname()
local w = assert(io.open(tmp, 'w'))
w:write(table.concat(sample, '\n'))
w:close()
local caught = scan(tmp)
os.remove(tmp)
check(#caught == 1, 'the scanner detects a use-before-declaration when there is one '
  .. '(found ' .. #caught .. ')')

-- ...and the orphan check, on a host still calling what moved out. A method
-- call of the same name is the module's business, not an orphan.
local hostTmp, modTmp = os.tmpname(), os.tmpname()
w = assert(io.open(hostTmp, 'w'))
w:write('local function top()\n  movedOut()\n  obj:movedOut()\nend\n')
w:close()
w = assert(io.open(modTmp, 'w'))
w:write('local function movedOut() end\n')
w:close()
local orphaned = orphans(hostTmp, { modTmp })
os.remove(hostTmp)
os.remove(modTmp)
check(#orphaned == 1, 'the orphan check detects a call left behind in the host '
  .. '(found ' .. #orphaned .. ')')

print(string.format('scope_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
