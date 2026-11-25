# Phoenix Race Manager (PRM) for BeamNG

A **multiplayer-only** race manager for BeamNG.drive on **BeamMP**: live
standings, lap counts, best and last lap times, and real-time gaps for every
driver on the server.

You place checkpoint gates by driving the track, run a qualifying session, let
it build the starting grid, and keep the results at the flag: on the server, on
your own PC, on Discord, or all three.

| | |
|---|---|
| **[Install](#install)** | One download, open it, start the server |
| **[Run a race night](#run-a-race-night)** | The whole flow, start to finish |
| **[What else it does](#what-else-it-does)** | Reset limits, joker laps, car locking, Demo Derby, drag racing |
| **[Troubleshooting](#troubleshooting)** | Mostly "the app doesn't show up" |

> **This page is the short version.** Every feature in full is in
> **[docs/REFERENCE.md](docs/REFERENCE.md)**. See also
> [Architecture](docs/ARCHITECTURE.md) (how it's built),
> [Compatibility](docs/COMPATIBILITY.md) (what each BeamNG and BeamMP release
> changed) and the [Changelog](CHANGELOG.md).

## Install

You need a **BeamMP server you control**. Racing is multiplayer-only; offline
you get the checkpoint editor and nothing else.

**Windows:** download
**[PRM-Setup.exe](https://github.com/Ashes-to-Light-Studios/Phoenix-Race-Manager-for-BeamMP/releases/latest/download/PRM-Setup.exe)**
and open it. It finds your BeamMP server, installs PRM into it and says what it
did. Windows may warn that it does not recognise the file: press **More info**,
then **Run anyway**.

**Linux:** in the server's folder, run

```bash
curl -fsSLO https://github.com/Ashes-to-Light-Studios/Phoenix-Race-Manager-for-BeamMP/releases/latest/download/PRM-Install.sh && bash PRM-Install.sh
```

**A hosting panel with no shell:** download `RaceManager-vX.Y.Z.zip` from
[Releases](../../releases), upload it into the server's `Resources/` folder and
extract it there.

Then start the server, or restart it. BeamMP pushes `PhoenixRM Client.zip` to everyone
who joins, so **players install nothing by hand**.

Both installers stop if the server is running, keep anything they replace in
the server's `_attic/` folder, move out leftovers of older installs that would
run beside the new one, and never touch your tracks, results or settings. Run
either again to update.

**Updating on a hosting panel:** from 0.28.0 on, use **Install from this PC** on
the **Admin** tab: download the new `RaceManager-vX.Y.Z.zip` on your PC, put it in
the folder the Updates row opens, and press **Send to server**, then **Install
and restart**. Your game sends it over BeamMP's own connection, the server checks
and installs it, and your panel starts it again. The server never goes online.
See [Installing from your PC](docs/REFERENCE.md#installing-from-your-pc).

By hand instead (and for the first move to 0.28.0): stop the server, upload the
zip into `Resources/` and extract it there over the old files, delete the zip and
start the server. Your tracks, results and settings are kept.

**From 0.23.x or older, the folders are renamed** to `Resources/Client/PhoenixRM
Client.zip` and `Resources/Server/PhoenixRM Server/`, so you can see what is
installed. The installers move the old ones across. Updating by hand, the first
start moves your data from `Resources/Server/PhoenixRM Server/Data` into the new
folder and the old copy to `_attic/`, then asks you to **restart once**, because
that start ran both. Update and restart from the game cannot make this jump;
use the zip or an installer once.

**Updating from the game** is off as shipped, because some game hosts cut a
server off the internet when it goes online by itself and every player who
joins is kicked. On a server you run on your own machine, turn **Online
features** on, on the **Admin** tab (or set `"onlineFeatures": true` in
`Resources/Server/PhoenixRM Server/Data/config.json`): the server then looks for
a newer release at each start, and **Update and restart** on the **Admin** tab
installs it. See [Updating from the Admin
tab](docs/REFERENCE.md#updating-from-the-admin-tab).

Building from source instead? `python3 tools/deploy.py` writes the package and
installs both halves onto a BeamMP server it finds, backing up whatever it
replaces and leaving your saved layouts and results alone. Add `--dry-run` to see
what it would do first. The client zip is always
called `PhoenixRM Client.zip`, with no version in the name, so an update overwrites
the old one instead of leaving two copies side by side.

**Three things to get right:**

1. **Installing by hand? Deploy both halves together, and delete the old
   ones.** (The installers do both.) Two versions of the server plugin each run
   their own state machine and take turns broadcasting, which makes the UI
   flicker between two states. The app header shows a version for each piece;
   if they don't match, something didn't copy. A stale file fails *silently*: a
   button just stops doing anything.
2. **Change the admin password before your first public session.** It ships as
   `phoenix`. Log in, then set a new one from the **Admin password** bar on the
   **Admin** panel. There is a second, narrower **moderator** password for whoever
   runs your race nights; it ships empty, which means off. See
   [Two tiers](docs/REFERENCE.md#two-tiers-admin-and-moderator).
3. **Upgrading from 0.6.0 or earlier on Linux?** Those packages spelled the
   folders in lower case. `PRM-Install.sh` moves the old install out; by hand,
   delete any leftover `Resources/client` or `Resources/server`. Windows is
   unaffected.

## Run a race night

Everything happens inside the **Phoenix Race Manager (PRM)** window in game:

```
Build/Load a track  →  Start Quali  →  Start Countdown  →  Qualifying
                    →  Generate Grid  →  Start Countdown  →  Race  →  Results
                                       (or Start Race, behind a pace lap)
```

Qualifying and the race run the **same** lifecycle: form the grid, hold the
field, count down, run, take finished cars off the track, give everybody their
car back. Only the lap target and the scoring differ.

**1. Open the app and log in.** Join the server, open the HUD app menu and add
**Phoenix Race Manager (PRM)** (required; under *Racing* and *Info*). Everyone sees the live timing, but
the editor and race controls stay hidden until you type a master password into
the **Admin Login** bar; anyone who just wants to watch closes it with **✕**.
The same box takes either password: **admin** gets everything, **moderator**
gets everything except changing passwords, clearing the server's results and
deleting layouts.
A welcome window offers this on join: **Open HUD Apps** goes straight to the
app screen with the picker's search filled in. It also tells a new server owner
the default admin password is here, never what it is or whether yours still uses
it. Tick *Don't show this again* to stop it, or `raceManager.splashShow()` in
the console to bring it back.
To sit a session out entirely, press **👁 Spectate** in the Race Entry row: the
field runs without you, your car stays put as a ghost, and you watch with
BeamNG's own camera controls. Streaming the night? **📺 Broadcast** then swaps
the app for a [spectator's board](docs/REFERENCE.md#broadcast-board-spectators):
the whole field, who is out and why, cup standings, and click a name to put the
camera on that car. For your stream's own graphics, **Feed** on the menu bar
serves the race to OBS, vMix or a page of your own from your PC, with a
ready-made overlay included: see [Broadcast feed](docs/REFERENCE.md#broadcast-feed).
It works on a rented server, because nothing runs on the server for it.

**2. Build a track.** Open **Track** on the menu bar, then drive the course. At
each timing gate, drive through it *in the direction of travel* and press
**+ Checkpoint Here**. Gates are flat rectangles standing across your heading,
and what you see drawn in the world **is** the trigger.

- **The last gate you place is the start/finish line.**
- Each gate has a width and two halves of the vertical: **up** is how far the
  gate rises above where it was placed, **down** how far it drops below. They are
  independent, so a gate can stand tall enough to see without an equal amount of
  it hanging under the road. Raise **up** on **banked tracks** so the rectangle
  covers the banking. Click a gate in the list to change its **W**, **Up** and
  **Dn**; the next gate you place takes the same size.
- **Undo**, **Clear** and **Hide/Show Gates** do what you'd expect.

Then switch to the **Grid** tab and drive to each grid slot *facing down
the track*, pressing **+ Place Start Position Here**. Slot 1 is pole. Every slot
stays editable: **Go** to it, **Move Here**, or **✕** to delete. For a grid part
way round the circuit, set **First checkpoint** to the first gate ahead of it, so
the untimed out lap starts there instead of at CP 1.

**3. Save it as a layout.** In **Track Layouts**, type a name and press **Save
As New**. A layout lives on the *server*, survives restarts, and carries the
gates, the joker route, the pit lane, the lanes and the starting grid together.

Once it's saved, the **Layouts ▾** menu lists it with every other track, strip
and arena on the map: click it and it rebuilds on every connected client at
once. **Overwrite** and **Delete** in the editor act on whatever is selected,
and loading selects it, so putting an edited track back takes no retyping. Both ask first. A save can never quietly empty part of a stored
layout; if the client sending it isn't holding a section the saved copy has, the
server refuses and says exactly what would have gone.

**4. Decide who's racing.** **Everyone on the server who is in a car is in the
field**, so there's nothing to do. A driver who'd rather watch presses
**Spectate** and the session runs without them; their car stays put as a ghost,
and **Race**, beside it, puts them back. That's the whole entry system, and it's
the driver's own call, not an admin setting. A one on one is two people racing
and everybody else spectating. Once a session is running the field is fixed: the
way out from there is **Retire**, which keeps a classified position and scores
like any other DNF.

A player with **no car spawned** is left off the grid and off the leaderboard.
Spawning a car afterwards does not put them in. They press **Join** to start
from the back, or an admin uses **Place** or **Add** under **Not in the field**.
See [No car, no grid](docs/REFERENCE.md#no-car-no-grid).

**5. Qualifying.** Press **Start Quali**, then **Start Countdown**. The field
starts from the grid, so the first lap is an **out lap**: not timed, not scored,
and not counted against the allowance. *Three qualifying laps still means three
timed laps*, run after it. Drivers see an **OUT LAP** badge and `NOT TIMED`
instead of a running clock until they cross the line. (A point-to-point stage
is driven once, so it has no out lap.) The table shows everyone's best lap, fastest on top.

Optional, under **Race ▾ → Qualifying**: **Ghost quali** (rivals stop being
obstacles) and **Quali length**, run to **Laps** or **Timed** minutes (a timed
session ends on a proper final lap rather than stopping dead).

**6. Grid and race.** Set **Laps**, pick a **Grid order** (Quali, Reverse,
Random, Points, Points rev or Custom), then **Generate Grid**. Every driver is placed on their slot
and **held** there, so nobody can jump the start. **Start Countdown** gives
everyone a synchronised 3‑2‑1‑**GO!** and releases the whole field on the same
broadcast. The table re-sorts leader-first in real time as places change.
When the winner is home, lapped cars keep racing. Once the number of cars set
in **Race end** have finished, a countdown (60 seconds by default) closes the
race, and anyone still out is classified on the laps they completed.

Once the race is running, **Caution** throws a full-course yellow and the field
**races back to the line**. The leader's crossing makes the caution official and
names the lap; everyone else locks their place as they complete that same lap,
first back to the line first, with the lapped cars at the bottom in their own
order. From there the board holds station, so closing up under the yellow
&mdash; which is what drivers have been told to do &mdash; costs and gains
nobody a place. **Restart** is *called* rather than taken: the green falls as the
leader reaches the line, and **Cancel restart** waves it off until it does. Turn
**Free pass** on and the first car a lap down takes its lap back before the
green, or **Laps back** on and every lapped car takes all its laps back.

Turn on **Pace lap** and Start Countdown becomes **Start Race** instead. The
field is released under a **yellow flag** with no countdown, told to hold
position at 50 MPH or 80 KMH, and runs a formation lap; **GET READY** is called
as the car that started P1 nears the line, and the **green flag** falls at a
random point just before it. The
pace lap is not scored and is not one of your laps &mdash; a 5-lap race behind
the pace car is a formation lap plus 5 racing laps, and the board counts the
racing ones. A red flag holds the green, and the **Green flag** button ends the
pace lap at any time if the field never makes it round.

**7. Results.** At the flag the server builds a results file, ready for league
standings, with the cup round it just banked appended if a cup is running. You
choose where it goes on the **Admin** panel's **Save results** row: **On the
server** (`Resources/Server/PhoenixRM Server/Data/results/`, with the path announced
in chat) and **On admins' PCs**. **Both are off until you turn them on**, so do
that before the first race you want to keep. Discord is its own row.
**Reset** clears the session for the next one.

> Each step has more to it: grid pinning, final-lap rules, what happens to a
> driver who disconnects. It's all in
> **[docs/REFERENCE.md](docs/REFERENCE.md#tutorial-running-a-race-night)**.

## What else it does

All of it is **off by default**, so a plain race night behaves exactly as you'd
expect without touching any of it.

| Feature | What it gives you |
|---|---|
| **[Vehicle reset limits](docs/REFERENCE.md#vehicle-reset-limits)** | Cap resets per driver per session. Past the allowance the reset key genuinely stops working. Can respawn at the last checkpoint instead of in place. |
| **[Checkpoint skips](docs/REFERENCE.md#checkpoint-skips-track-cuts)** | Optional track-cut rule. A driver who crosses a checkpoint ahead of the one they are due is moved on instead of left stuck, gets a set number of warnings, then a penalty: seconds on their race time, a lift off the throttle for a few seconds, or both. Penalties count in the final classification and the results file; a cut lap sets no time. |
| **[Reset ghosting](docs/REFERENCE.md#reset-ghosting)** | A driver who resets is intangible for a few seconds rather than reappearing solid in the racing line. Collisions return only once the space around them is provably clear. |
| **[Branch gates](docs/REFERENCE.md#branch-gates-two-ways-through-a-checkpoint)** | Give a checkpoint a second gate and either one clears it. Split lanes and head-on "suicide" ovals, scored together on one leaderboard, with nothing to assign anyone to. |
| **[Sectors](docs/REFERENCE.md#sectors)** | Define a track's sectors, such as S1 from the line to CP 3 and S2 from CP 3 to CP 6, and drivers are timed on those instead of on every checkpoint. Each sector time shows against the driver's own best for it. |
| **[Layout files](docs/REFERENCE.md#sharing-layouts-as-files)** | Export any or all of a map's layouts to one `.prm.json` file to post or send, and import someone else's in one press. Nothing on the server is ever overwritten, and it works on a rented host. |
| **[Stock tracks](docs/REFERENCE.md#opening-beamngs-own-races-stock-tracks)** | Open any of BeamNG's own time trials, AI races and rally stages on the current map as a starting layout: gates, pole and name filled in, read from your own game. |
| **[Mouse track editing](docs/REFERENCE.md#tutorial-running-a-race-night)** | **✋ Place** mode: click, drag and scroll to move and turn gates from free cam, ctrl+click to place new ones. Works on props, grid slots and derby arenas too. Driving to a gate still works and still builds the track. |
| **[Caution and restart](docs/REFERENCE.md#caution-and-restart)** | A full-course yellow that freezes the running order. By default the field **races back to the line**: the leader's crossing sets the lap, everyone locks their place as they complete it, and lapped cars go to the bottom in their own order. Or **freeze at the call**, where the field stands. Passes under yellow never count, and are shown to the driver and race control and listed in the results. Optional free pass, or laps back for every lapped car. The restart is called and falls at the line, and can be waved off. |
| **[Multi-class racing](docs/REFERENCE.md#multi-class-racing)** | Two car types on one grid, scored as two races. Tag a class on each Garage List entry and every driver in that car is in it: a Class column with per-class positions on the board, and a section per class in the results file. The overall order is unchanged. |
| **[The blue flag](docs/REFERENCE.md#the-blue-flag)** | Lapped traffic gets signalled instead of only displayed: the backmarker is shown blue when a car a lap up closes on them, and the car doing the lapping is told there is one ahead. Measured on the road rather than off the timing sheet, which are different orders once anybody is lapped. |
| **[Heats and transfers](docs/REFERENCE.md#heats-and-transfers)** | Run the night as heats into a feature, with a lap count of their own. The field is split by a serpentine draw off qualifying, the top N from each heat transfer, and the feature grid is built from the results &mdash; winners on the front row, interleaved by heat. |
| **[Pace lap](docs/REFERENCE.md#pace-lap)** | Start the race behind a pace car instead of from the lights: released under yellow, one formation lap at 50 MPH or 80 KMH, GET READY and a green at a random point as the pole-sitter returns to the line. The formation lap is not scored and does not count against the distance. |
| **[Rallycross joker laps](docs/REFERENCE.md#rallycross-joker-laps)** | A second gate route that must be taken exactly once per race. Lap 1 is closed, and the server disqualifies anyone who missed it or took it twice. |
| **[Garage List](docs/REFERENCE.md#vehicle--setup-locking-the-garage-list)** | Lock the session to the approved models only, to exact parts, or to exact parts *and* tunes. Anything else is deleted on spawn and the driver is told why. Give each entry a [name to show](docs/REFERENCE.md#car-names) without changing what it matches. |
| **[Cup points](docs/REFERENCE.md#cup-points)** | Championship points across several events: races, derbies or both. Scoring presets, qualifying points and bonuses, and standings that survive a server restart. |
| **[Nametag display names](docs/REFERENCE.md#display-names-on-the-beammp-nametag)** | Optionally append a driver's display name to the tag over their car. Uses BeamMP's own suffix API, so only the text changes -- fade, color and occlusion stay BeamMP's. |
| **[Display names](docs/REFERENCE.md#display-names)** | Give `Guest_4471` a readable name for the leaderboard and the results file. Saved on the server. |
| **[Time behind](docs/REFERENCE.md#time-behind)** | Gap to the leader and interval to the car ahead on every board, measured off the shared clock at the last checkpoint both cars reached - not estimated from speed or distance. Reads `+1 LAP` once a driver is lapped. |
| **[Live position tracking](docs/REFERENCE.md#live-position-tracking)** | True running order from laps, checkpoints cleared and distance to the next gate, not just the grid order. |
| **[Demo Derby](docs/REFERENCE.md#demo-derby-parallel-game-mode)** | A separate last-man-standing mode with its own arena, timers and results, fully isolated from the racing. |
| **[Ready check](docs/REFERENCE.md#the-ready-check)** | Forming a grid, a derby form-up and a drag pass call the drivers instead of teleporting them into place: each presses **Ready**, and the board shows who has. Admins see the count, can Ready All or place one driver, and are asked before starting without somebody. Not ready at the start sits that session or derby out, and is a no-show on the strip. |
| **[Map switching and votes](docs/REFERENCE.md#switching-maps)** | Change the server's map from the Admin tab, or let drivers vote for one: it passes only at a percentage of the whole lobby you choose, and a race director can lock voting. A map already loaded (a stock level, or a zip in `Resources/Client`) switches with no restart: everyone rejoins straight onto it. Any other map zip moves in from `custom_maps` and the server restarts itself onto it, under the BeamMP Server Management Tool, started by hand, or on a hosting panel, which keeps the map you chose. |
| **[Updates from the game](docs/REFERENCE.md#updating-from-the-admin-tab)** | **Install from this PC**, for any server including a rented one: download the release on your PC and your game sends it to the server, which checks it, shows its SHA-256, keeps the old files, swaps the new ones in and restarts. On your own machine (**Online features** on the Admin tab), **Update and restart** downloads it from GitHub instead. Tracks, the cup and results are untouched. |
| **[Map display names](docs/REFERENCE.md#map-display-names)** | Show `bark_river_sc` as *Bark River International* in the map menus, the vote and the switch. Display only: no file is renamed. |
| **[Lap records](docs/REFERENCE.md#lap-records)** | Each driver's fastest lap on every saved layout, per map, kept across restarts and open to everyone. Scored from qualifying and races. An admin can take a time off or clear a board in game, or edit the JSON on the server. |
| **[Where results go](docs/REFERENCE.md#where-results-go)** | A results file for every race, derby and drag tournament, kept on the server, sent to each admin's PC, both or neither. Two switches on the Admin tab, off until you turn them on. |
| **[Results on Discord](docs/REFERENCE.md#posting-results-to-discord)** | Paste a channel's webhook URL on the Admin tab and every race, derby and drag tournament posts its results there as it closes, with the full results file attached. Qualifying too if you want it. For a server on your own machine (**Online features** on the Admin tab), and off until a webhook is set. |
| **[Drag racing](docs/REFERENCE.md#drag-racing-parallel-game-mode)** | A tournament ladder down a drag strip: single or double elimination, or a points shootout. Two to eight cars a pass with any number going through, a christmas tree with real red lights, reaction times, elapsed times and trap speeds, and dial-in bracket racing. Scores into the cup on a table of its own. The strip is an ordinary point-to-point layout saved with the type Drag, so the track editor already builds one, and a practice pass lets one driver try it before a field turns up. |
| **[Broadcast board](docs/REFERENCE.md#broadcast-board-spectators)** | A spectator's board for streaming: the whole field, the drivers who are out and why, cup standings, and click a name to put the camera on that car in orbit. |
| **[Broadcast feed](docs/REFERENCE.md#broadcast-feed)** | Live race data for your stream's overlay software: positions, the starting grid, laps and last laps, gaps, who has taken the joker, pit stops, flags and a feed of what just happened, as JSON and a live stream on `http://127.0.0.1:8128`, plus a ready-made overlay for an OBS Browser Source, styled in your browser with your league's colors, logos and fonts, and team colors and car numbers from the server's [Teams](docs/REFERENCE.md#teams-and-car-numbers) list. Served by your own game, so it works on a rented server: nothing runs on the server for it. |
| **[Race Lights (PRM)](docs/REFERENCE.md#race-lights-prm)** | An optional second app with the start lights, the flags and the drag tree in a box you place anywhere on screen. GET READY is a steady caption, so the green is the first thing that changes. Start sounds for the countdown, the green and the tree, mutable from the panel. |
| **[Radar (PRM)](docs/REFERENCE.md#radar-prm)** | An optional third app: the cars around you out to 25 m, at their real size and angle, red under 2 m and amber under 6 m with the gap shown, side-by-side spotter bars, ghosts as outlines, and in a race each car's position with lapped cars in blue. Fades away when nobody is near. |
| **[Menu bar](docs/REFERENCE.md#the-menu-bar)** | Practice, records, the garage, the cup and every admin panel open from one row under the title and step out of the way when closed, so the board keeps the room. |
| **[Driver UI](docs/REFERENCE.md#driver-ui-non-admins)** | Non-admins see just the leaderboard. Resizable, fades so it doesn't block the view, and collapses to a single status line. Alerts still get through. |
| **[Admin and moderator](docs/REFERENCE.md#two-tiers-admin-and-moderator)** | Two passwords into one login box. A moderator runs the whole night; changing passwords, clearing the server's results or lap records and deleting a layout, arena, garage set or ruleset stay with the admin, because none of those can be undone. The moderator tier ships off, so nothing changes on a server that never asks for it. |
| **[Garage sets](docs/REFERENCE.md#garage-sets)** | Save the approved car list under a name and load it back in a click. **+ Add Set** merges instead of replacing, so a multi-class field is built from the per-class sets you already keep rather than whitelisted again car by car. |
| **[Rulesets](docs/REFERENCE.md#rulesets)** | The race rules stay as you set them through a map switch and a server restart. Save every rule in Race, Quali and Grid under a name (a sprint, a heat night, an endurance) and load it back in a click between sessions. **Server defaults** puts config.json's rules back. |

## Troubleshooting

**The app doesn't show up:**

- Since BeamNG **v0.39** the app list is called **HUD Apps**, not *UI Apps*, and
  is reached from the Pause menu (*System → HUD Apps*). Phoenix Race Manager (PRM) is under
  **Racing** and **Info**; Race Lights (PRM) and Radar (PRM) are under **Racing**.
  Search *PRM* to see all three.
- The game only scans mods at startup, so **restart BeamNG** after installing or
  updating. If the list is still stale, clear the cache (Launcher →
  *Manage User Folder* → *Clear Cache*).
- Check the zip has `ui/`, `lua/` and `scripts/` at its **root**, with no extra
  top-level folder from zipping the parent directory.
- In singleplayer, confirm the mod is **enabled** in the in-game Mods menu.
- Look for `Race Manager client bridge loaded` in the console (`~`). If it's
  missing, the modScript never ran, meaning the zip wasn't mounted.

**Buttons do nothing, or the UI flickers between two states:** mismatched or
duplicated versions are installed. See [Install](#install).

**Drivers rejected in a car that's plainly on the Garage List:** a BeamNG update
renamed or added vehicle parts, which changes the configuration signature (v0.40
added an occupant slot to every seat). Re-capture the list. See
[Compatibility](docs/COMPATIBILITY.md).

## Support development

Race Manager is free and always will be. If it's improved your race nights and
you'd like to put something toward the hosting and the hours:

- **PayPal**: [krossx13](https://www.paypal.me/krossx13)
- **Cash App**: [$disciplejtmay](https://cash.app/$disciplejtmay)

## License

Released under the [MIT License](LICENSE): use it, fork it, run it on your own
server, ship it in your own mod, so long as the copyright notice travels with it.
Contributions are accepted under the same license.
