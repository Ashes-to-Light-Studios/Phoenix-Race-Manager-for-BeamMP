-- Race Manager: THE LIGHTS, client side.
--
-- One light for the Race Lights (PRM) app, decided here from the session, the
-- countdown, this driver's own flag edges and the drag tree, and pushed on
-- RaceManagerLights only when it changes: a handful of times a race. The one
-- exception is a lift being served, whose meter is pushed up to ten times a
-- second, and only when what it shows moved. The app draws what it is told and
-- binds nothing, so it adds nothing to the digest the main panel already pays
-- for.
--
-- The SOUNDS play from here, on the same transitions, so a driver hears them
-- whether or not the Lights app is on screen.

local D = { soundOn = true }
-- KEPT, OFF: GET READY used to beep, the countdown's own beep, and drivers
-- went on it. true brings it back.
D.READY_BEEP = false
local host

-- What was last pushed, the countdown number showing (3..1), and the drag
-- tree's payload while it is lit.
local lightShown = 'off'
local countdownNum = nil
local treeLit = nil

-- The game's own race beeps, as BeamJoy plays them.
local SOUND = {
  beep = 'event:UI_Countdown1',
  go   = 'event:UI_CountdownGo',
  stop = 'event:>UI>Main>Cancel',
}

-- Seconds a moment holds before the app falls back to the standing light. The
-- app keeps the time, so nothing here runs on a clock.
local HOLD = {
  go = 3, green = 4, white = 4, checkered = 6, blue = 4,
  liftServed = 2, blackServed = 3, dsq = 6,
}

-- THE LIFT METER. The serve window arrives three times a second (cpRow.window)
-- and is counted down here between, paused when the server pauses it. `k*` is
-- what the app last got, so a frame that changes nothing pushes nothing.
local METER_EVERY = 0.1
local meter = {
  win = nil, age = 0, due = 0, was = false,
  kLeft = -1, kWin = -1, kSt = nil, kMore = -1,
}
-- The black flag last pushed: a second one moves the lap without a new light.
local blackShown = { sec = nil, by = nil }

-- The standing lights a race is HELD under. Leaving one for plain racing is the
-- green flag, whichever way it happened: pace lap, restart, red lifted.
local HELD = {
  pace = true, ready = true, readyRestart = true, restart = true, caution = true,
  cautionBack = true, yellow = true, red = true,
}

function D.init(h)
  host = h
end

local function play(which)
  if not D.soundOn then return end
  local audio = Engine and Engine.Audio
  if audio and audio.playOnce then pcall(audio.playOnce, 'AudioGui', SOUND[which]) end
end

local function running()
  local p = host.session.phase
  return p == 'racing' or p == 'qualifying'
end

-- The standing light. ORDER IS PRIORITY: red stops everything, a countdown
-- beats the flags, and GET READY beats the caution or pace lap it is ending.
-- GET READY is two lights, one per yellow it ends, so the app can keep that
-- yellow's lamps and change only the words: nothing moves before the green.
local function standing()
  local s = host.session
  if treeLit then return 'tree' end
  if running() and s.raceFlag == 'red' then return 'red' end
  if countdownNum then return 'count' .. countdownNum end
  if not running() then
    return (s.phase == 'grid' or s.phase == 'countdown') and 'grid' or 'off'
  end
  if s.greenReady and s.pacing then return 'ready' end
  if s.greenReady and s.restartPending then return 'readyRestart' end
  if s.restartPending then return 'restart' end
  if s.cautionPending then return 'cautionBack' end
  if s.caution then return 'caution' end
  if s.pacing then return 'pace' end
  -- A hazard yellow too: every light about the whole field outranks this
  -- driver's own penalties. The HUD line still counts a lift down under it.
  if s.raceFlag == 'yellow' then return 'yellow' end
  if s.lift.active then return 'lift' end
  if s.black and not s.spectatorLock then return 'black' end
  return 'off'
end

-- What a driver races under once a held light goes: nothing, or a penalty of
-- their own. Leaving a held light for any of them is the green flag.
local RACING = { off = true, lift = true, black = true }

local function windowLeft()
  if not meter.win then return nil end
  local w = meter.win - meter.age
  return w > 0 and w or 0
end

-- What the meter shows, noted as shown.
local function liftData()
  local s = host.session
  local L = s.lift
  local left, win, st, owed = math.max(L.left or 0, 0), windowLeft(), L.state(), L.owed()
  meter.kLeft = math.floor(left * 10 + 0.5)
  meter.kWin  = win and math.ceil(win) or -1
  meter.kSt, meter.kMore = st, owed
  return { left = left, full = s.cpSkip.liftSec, win = win, more = math.max(owed - 1, 0), st = st }
end

local function blackData()
  local b = host.session.black
  blackShown.sec, blackShown.by = b.sec, b.by
  return { sec = b.sec, by = b.by }
end

local function push(moment)
  guihooks.trigger('RaceManagerLights', {
    light = lightShown, tree = treeLit, moment = moment,
    hold = moment and HOLD[moment] or nil,
    lift = lightShown == 'lift' and liftData() or nil,
    black = lightShown == 'black' and blackData() or nil,
  })
end

-- Work the light out again and push it if it moved. A moment always pushes.
local function settle(moment)
  local light = standing()
  local was = lightShown
  if light == was and not moment then return end
  lightShown = light
  if light ~= was then
    if (light == 'ready' or light == 'readyRestart') and D.READY_BEEP then
      play('beep')
    elseif light == 'red' then
      play('stop')
    elseif RACING[light] and HELD[was] and running() and not moment then
      moment = 'green'
      play('go')
    end
  end
  push(moment)
end

-- After every state broadcast. A black flag stacked on one already out keeps
-- the light and moves the lap, so it is pushed too.
function D.lightsSync()
  local s = host.session
  meter.win, meter.age = s.cpRow.window, 0
  local b = s.black
  if lightShown == 'black' and b and standing() == 'black'
     and (b.sec ~= blackShown.sec or b.by ~= blackShown.by) then
    push()
    return
  end
  settle()
end

-- Every frame: one comparison unless a lift is being served.
function D.lightsUpdate(dt)
  local s = host.session
  local active = s.lift.active
  if active ~= meter.was then
    meter.was = active
    settle()
  end
  if lightShown ~= 'lift' then return end
  if not (s.caution or s.cautionPending or s.pacing or s.raceFlag == 'red') then
    meter.age = meter.age + dt
  end
  meter.due = meter.due - dt
  if meter.due > 0 then return end
  local L = s.lift
  local w = windowLeft()
  if math.floor(math.max(L.left or 0, 0) * 10 + 0.5) == meter.kLeft
     and (w and math.ceil(w) or -1) == meter.kWin
     and L.state() == meter.kSt and L.owed() == meter.kMore then
    return
  end
  meter.due = METER_EVERY
  push()
end

-- 3, 2, 1, then 0 for GO, or -1 for a countdown called off. `derby` is set
-- for the derby's countdown, which the race's pace-lap rule has nothing to do with.
function D.lightsCountdown(n, derby)
  n = tonumber(n)
  if n and n > 0 then
    countdownNum = math.floor(n)
    play('beep')
    settle()
    return
  end
  countdownNum = nil
  if n == 0 then
    -- A START BEHIND THE PACE CAR IS NOT A GREEN. The lights go out and the
    -- pace lap's yellow follows on the next broadcast; green here would tell
    -- the field to race the formation lap.
    if not derby and host.pacedStart() then
      play('beep')
      settle()
    else
      play('go')
      settle('go')
    end
    return
  end
  settle()
end

-- This driver's own flags: 'white', 'checkered', 'blue', and the penalty
-- moments: 'liftServed', 'blackServed', 'dsq'.
function D.lightsMoment(kind)
  if HOLD[kind] then settle(kind) end
end

-- The drag tree, as drag.lua pushes it to the panel. The bulbs move inside one
-- standing light, so every change is pushed rather than only a new light.
function D.lightsTree(t)
  local stage = type(t) == 'table' and t.stage or 'off'
  local was = treeLit and treeLit.stage or 'off'
  treeLit = (stage ~= 'off') and t or nil
  if stage ~= was then
    if stage == 'amber1' or stage == 'amber2' or stage == 'amber3' then
      play('beep')
    elseif stage == 'green' then
      play('go')
    end
  end
  lightShown = standing()
  push()
end

-- The app asking for the light it missed (it loaded, or the UI reloaded).
-- Without the moment: one that is already over must not replay.
function D.lightsResend()
  push()
end

function D.lightsSetSound(on)
  D.soundOn = on ~= false
end

return D
