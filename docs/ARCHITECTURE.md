# Architecture

How Race Manager is put together, and why it is split the way it is.
For using the mod, see the [README](../README.md).

[← Back to the README](../README.md)

The BeamMP server has no physics access, so the mod is split in three:

| Part | Path | Runtime | Role |
|------|------|---------|------|
| Server plugin | `server/RaceManager/main.lua` | BeamMP server (Lua 5.3, `MP.*` API) | Authoritative race state machine: grid, countdown, one shared clock, finish timestamps, broadcasts the driver table |
| Mod entry point | `scripts/raceManager/modScript.lua` | In-game (runs at mod mount) | Loads the client bridge - BeamNG **never** auto-loads GE extensions shipped in a mod zip |
| Client bridge | `lua/ge/extensions/raceManager.lua` | In-game GE Lua (LuaJIT / 5.1) | Waypoint editor, local finish-line detection (the server has no physics), the drag christmas tree and its reaction timing, relays server broadcasts to the UI |
| UI app | `ui/modules/apps/RaceManager/` | In-game UI (Angular) | Race controls, live driver table, waypoint editor panel |
| Lights app | `ui/modules/apps/RaceManagerLights/` | In-game UI (Angular, no bindings) | Start lights, flags and the drag tree in a box of their own. Draws the one light `raceManager/lights.lua` pushes on change, which also plays the start sounds |
| Radar app | `ui/modules/apps/RaceManagerRadar/` | In-game UI (Angular, no bindings) | The cars around this driver's car, in its frame, with outline-to-outline gaps. `raceManager/radar.lua` scans four times a second alone and pushes twenty times a second only while a car is in range |

Event flow: local car crosses the start/finish gate → `RM_QualiLap`/`RM_Lap`
to server → server scores it on its own clock → `RM_Update` broadcast to all
clients → UI.

`RM_Update` is the timing push, sent about three times a second while a session
runs, so anything that changes rarely does not ride it. The Garage List goes out
as `RM_Garage` when it changes and to each client that asks for state, numbered
so a late copy cannot replace a newer one.

## What the server keeps

Everything durable lives beside the plugin in `Resources/Server/PhoenixRM Server/`,
written as JSON on every change through one small codec in `main.lua` (the
network payloads use BeamMP's `Util.JsonEncode`; persistence gets its own strict
one so the headless tests exercise the real file format).

| File | Holds | Cleared by |
|------|-------|-----------|
| `layouts.json` | Saved track layouts per map: gates, joker route, branch gates, starting grid | Overwriting a name |
| `derbyArenas.json` | Saved derby arenas per map | Deleting an arena |
| `dragLadder.json` | The drag tournament in progress: rules, entrants, records, every round drawn so far | Clear Ladder |
| `garage.json` | Approved vehicles/setups and the enforcement switch | Clear Garage |
| `roster.json` | Saved drivers: the display names an admin has assigned | Deleting a driver |
| `cup.json` | Cup scoring rules, standings, per-round breakdown, adjustments | End Cup |
| `results/*.txt` | One results file per finished session, while Save results is on for the server (`saveResultsOnServer` in `config.json`, off as shipped) | Clear Results Cache |
| `mapSwitch.json` | A map switch waiting for its restart, so the next boot can say whether it took | The next boot |
| `mapNames.json` | Display names for maps, by level name | Renaming each map back |
| `update/last.json` | The last in-game update: from, to, when, by whom, and the `_attic` folder holding the old files | The next update |
| `discord.json` | The Discord webhook and which results it posts | Removing the webhook |
| `Lap Records/<map>.json` | Each driver's best lap per saved layout on that map | Clear Board, or deleting the file |

`roster.json` and `cup.json` are deliberately **not** under `results/`: Clear
Results Cache deletes every `.txt` it finds there, and a championship that
routine housekeeping can destroy is not persistent in any sense that matters.

## Modules inside the server plugin

Eight parts of the plugin are self-contained: **Demo Derby**, **drag racing**,
**map switching**, **lap records**, **updates**, **Discord**, the **driver
roster** and the **cup**. Each has its own state tables, its own `RM_*` event
namespace and its own broadcast channel, and none of them is reachable from the
racing state machine except through a handful of named functions declared at
the top of the file.

The first six are separate FILES (`derby.lua`, `drag.lua`, `maps.lua`,
`records.lua`, `update.lua`, `discord.lua`) required as siblings; the other two
are `do ... end` blocks inside `main.lua`.
Same isolation either way, reached two different ways for the same reason:
Lua's 200-local ceiling.

**BeamMP runs every `.lua` in the plugin folder on its own**, alphabetically,
before `main.lua` requires any of them. `derby.lua` and `drag.lua` sort before
`main.lua`, so the copy `main.lua` initialises is the one whose global handlers
win. `maps.lua`, `records.lua` and `update.lua` sort after, so they define
nothing global at file scope: their `RM_Map*`, `RM_Records*` and `RM_Update*`
handlers are installed by `init()`, and each one's test checks that loading the
file alone defines nothing. A new module must do the same
unless its name sorts before `main`.

**Map switching is instant when the map is already loaded, and a restart
otherwise.** BeamMP hands each joiner the map in its settings, and `MP.Set`
changes that in the running server (`MP.Get` reads it back, 3.6+); but it lists
and hashes `Resources/Client` only at startup. So `maps.lua` keeps what the
process started with (`boot()`: the map and the zips in `Resources/Client`,
taken once and kept on the module across hot reloads). A stock level or one of
those zips is `MP.Set`, verified, then a kick, with `host.mapChanged` clearing
the old map's track and arena. Anything else moves zips between `custom_maps/`
and `Resources/Client/` (the Management Tool's layout), rewrites only the `Map`
value in `ServerConfig.toml`, and restarts by whichever means is available: the
Management Tool's config watch, a detached helper that waits for this process to
exit and starts it again, or `exit()` for a service manager or a game panel's
crash restart. A game panel rewrites `Map` at every start, so a map chosen in
game is pinned (`Data/mapPin.json`, against the map the process started on) and
set again at the next start only if the panel put that one back. See [Switching
maps](REFERENCE.md#switching-maps).

**Hot reload runs onInit again in the same Lua state**, whenever a plugin file
changes on a running server: required modules stay cached, and BeamMP does not
de-duplicate timers. Every timer is cancelled before it is created, or guarded
by its module's `ticking` flag.

**Updates restart the server the same way**, through `maps.lua`'s helper, its
`exit()` or the Management Tool's config watch. The release comes from GitHub, or
from an admin's PC: `upload.lua` on the client sends it in numbered base64
pieces on `RM_UpdateUpload`, paced and windowed against the server's count on
`prmUpdate`, and it joins the same check and swap held in memory until Install.
Three choices in `update.lua` are load-bearing:

- **Downloads run in a process of their own** (curl, or wget on Linux) that
  leaves a `.done` file holding its exit code, polled once a second, so the Lua
  state never waits on the network. On Windows it is started through
  `Start-Process`, which hands it none of the server's sockets.
- **The zip is read in plain Lua**: SHA-256 against the digest GitHub lists,
  CRC-32 per entry and inflate, about a second for a release, because many Linux
  hosts have no `unzip`. It installs only `Client/PhoenixRM Client.zip` and top-level
  `Server/PhoenixRM Server/*.lua` (and the LICENSE beside them), and refuses a release with any other path rather
  than install half of one. The package workflow fails a release that has one.
- **Its state rides each admin's own `RM_Update`** (`prmUpdate`, from
  `broadcastState(pid)`), not an event of its own. A client binds its server
  events once per game session, so an event added in a new release would not
  reach an admin who rejoined after updating without restarting the game.

**The installers apply the same rules from outside the game.**
`installer/windows` is a C# 5 WinForms program built with the compiler that is
part of .NET Framework 4.x, so building it and running it need nothing
installed; the release zip is embedded in the exe. `installer/linux` is a bash
script with the package appended as a base64 tarball, because tar and base64
are on every Linux and unzip is not. Each has a test (`test.ps1`, `test.sh`)
that the package workflow runs against scratch server folders before anything
is published.

**Discord is an add-on: nothing depends on it.** `main.lua` loads it with
`pcall` and every call site checks `race.discordPost` first, so a missing or
broken `discord.lua` costs the posts and nothing else. It is a consumer of
results too: `finishSession`, `finishDerby` and the drag ladder's
`finishTournament` each hand it one snapshot as the session closes, with the
results text itself (the server may keep no file of it), and the
post is sent from its own 1 second tick by curl in a process of its own, the
way `update.lua` downloads. Two rules hold it together: the webhook URL never
leaves the server (the panel gets the last digits of its id, and curl reads it
from a config file, not its command line), and only a URL rebuilt from checked
parts is stored, so nothing an admin types reaches a shell.

**The broadcast feed is the client's, so it works on any host.** Overlay
software wants the race pushed to it live, and the server has no way to push
anything: no HTTP client, and the one way out (curl in a process of its own) is
what got a server cut off on a rented host (`onlineFeatures`). But every client
already holds the race: `RM_Update` arrives about three times a second while a
session runs. So `lua/ge/extensions/raceManager/feed.lua` serves it on the
streamer's own PC with LuaSocket (the library BeamMP's own client mod talks to
its launcher with), non-blocking and polled from `onUpdate`: one comparison a
frame while it is off. Four rules hold it together:

- **A schema, not the wire format.** The document is rebuilt from `RM_Update`
  through fixed key lists (`SESSION_KEYS`, `DRIVER_KEYS`...) by the module's own
  encoder (fixed key order, explicit `null`, `[]` for an empty list). Nothing off
  those lists leaves the game, so an admin's targeted fields never do.
  `tests/feed_test.lua` checks that and that REFERENCE names every key;
  `tests/ui_bindings_test.lua` checks every row field it reads is on the wire.
- **No new event.** What the feed needed from the server (`lastLap`,
  `lastLapOn`, `pitStops`) rides `DRIVER_WIRE_FIELDS`, for the same bind-once
  reason as update state.
- **Events are differences.** A lap, the joker, a pit stop, a flag: found by
  comparing consecutive snapshots, each on its own field, so one that lands
  between two broadcasts is still caught. None from the first snapshot.
- **Its port outlives nothing.** The listener sits in a `_G` slot a reloaded
  copy closes before binding, `onExtensionUnloaded` closes it, and BeamMP
  unloads the mod on leaving a server. `reuseaddr` is never set on Windows,
  where it lets two programs share a port.

**Lap records are a consumer of results, like the cup.** `finishSession` calls
them once per session through `race.recordsSession`, after the joker ruling.
The file on disk is the board: every read opens it and every write reads it
first, so a hand edit is never overwritten by a copy held in memory.

**Drag racing reads two things from the racing state and writes neither**:
`race.startPositions`, which is where the lanes are, and `race.slotCount`,
which is how it knows the loaded layout has a finish line. Both are properties
of the loaded TRACK rather than of a session. That is the whole reuse: a drag
strip is a point-to-point layout, its start positions are the lanes and its
last gate is the finish, so there is no second track editor and no second
layout store. Three names cross back the other way, and all three hang off
`race` rather than taking a local: `dragUnderWay`, `dragEntryChanged`,
`dragWarm`.

**Where the timing happens is split differently from everywhere else.** A
reaction time is decided in the third decimal place, so the christmas tree runs
on each CLIENT against its own clock -- the server sends the shape of the tree
and every client measures its own launch against its own green. A tree driven
from server ticks would measure the network. The server still owns the bracket,
the ranking and the result.

That is enforced rather than promised - the roster and cup live inside one
installer function, so the only names crossing the boundary are the ones
forward-declared outside it. (There is a second reason: Lua allows 200 locals
per function, and this chunk is close enough to that ceiling that a module
written at file level would not compile.)

The cup is a **consumer of results**. It is entered from exactly two places
the end of `finishSession` and the end of `finishDerby` - and reads the same
classification the results file is built from. Nothing cup-shaped runs while
cars are on track, which `tests/stress_test.lua` asserts by counting messages
rather than by timing.

Client and server obey **different rules**:

- **Client (BeamNG.drive)**: mods are zips mounted into the virtual
  filesystem. A UI app requires all four files (`app.js`, `app.html`,
  `app.json`, `app.png`) or it won't appear in the app selector, and GE
  extensions only load if `scripts/<name>/modScript.lua` loads them.
  Events use `AddEventHandler(name, fn)` / `TriggerServerEvent(name, str)`.
- **Server (BeamMP)**: Lua 5.3, no game/physics access. Handlers must be
  **global** functions registered by name string via
  `MP.RegisterEvent(event, "fnName")`; broadcast with
  `MP.TriggerClientEvent(-1, event, jsonString)`.
