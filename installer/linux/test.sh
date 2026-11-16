#!/bin/bash
# Runs PRM-Install.sh against scratch BeamMP server folders: a fresh install,
# an update over an old install with leftovers, a renamed resources folder, a
# running server, a write that fails, and a folder that is not a server. The
# release workflow runs it on every build; Git Bash on Windows runs most of it.
#
#   bash installer/linux/test.sh dist/PRM-Install.sh package
installer=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
pkg=$(cd "$2" && pwd)
checks=0; fails=0
check() { checks=$((checks + 1)); if ! eval "$1"; then fails=$((fails + 1)); echo "FAIL: $2"; fi; }

root=$(mktemp -d)
trap 'chmod -R u+w "$root" 2>/dev/null; rm -rf "$root"' EXIT
config=$'Port = 30814\nMap = "/levels/gridmap_v2/info.json"\n'
new_server() { mkdir -p "$1"; printf '%s' "$2" > "$1/ServerConfig.toml"; }
# Every file the release has, at the same bytes, under one resources folder.
installed() {
  cmp -s "$pkg/Client/PhoenixRM Client.zip" "$1/Client/PhoenixRM Client.zip" || return 1
  cmp -s "$pkg/Server/PhoenixRM Server/LICENSE" "$1/Server/PhoenixRM Server/LICENSE" || return 1
  for f in "$pkg/Server/PhoenixRM Server"/*.lua; do cmp -s "$f" "$1/Server/PhoenixRM Server/${f##*/}" || return 1; done
}
zip_with() {
  local py; py=$(command -v python3 || command -v python)
  "$py" -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
for n in sys.argv[2:]: z.writestr(n, "x")
z.close()' "$@"
}
run() { bash "$installer" "$1" > "$root/out.txt" 2>&1; }

# --- A fresh server ----------------------------------------------------------
fresh="$root/fresh server"
new_server "$fresh" "$config"
check 'run "$fresh"' 'a fresh server installs'
check 'installed "$fresh/Resources"' 'with every file the release has'
check 'ls "$fresh"/_attic/install-none-to-*/install.log >/dev/null 2>&1' 'and a log of what it did'

# --- An update over an install from before 0.24.0 ------------------------------
# The plugin was Resources/Server/RaceManager and the client RaceManager.zip.
up="$root/update"
new_server "$up" "$config"
res="$up/Resources"; old="$res/Server/RaceManager"; plugin="$res/Server/PhoenixRM Server"
mkdir -p "$old/Data/results" "$res/Client" "$res/Server/RaceManager_old" "$res/Server/OtherPlugin"
zip_with "$res/Client/RaceManager.zip" lua/ge/extensions/raceManager.lua scripts/raceManager/modScript.lua
printf -- "-- old\nlocal RM_BUILD = '0.0.1'\nprint('[RaceManager] loaded')\n" > "$old/main.lua"
printf -- '-- an old module' > "$old/maps.lua"
printf '{"adminPassword": "theirs"}' > "$old/Data/config.json"
printf 'P1 somebody' > "$old/Data/results/race.txt"
printf "local RM_BUILD = '0.0.0'\nprint('[RaceManager] loaded')" > "$res/Server/RaceManager_old/main.lua"
printf "print('RM_ is not ours')" > "$res/Server/OtherPlugin/main.lua"
zip_with "$res/Client/RaceManager-v0.19.0.zip" lua/ge/extensions/raceManager.lua scripts/raceManager/modScript.lua
zip_with "$res/Client/RaceManager-cars.zip" vehicles/buggy/buggy.jbeam
check 'run "$up"' 'an install from before 0.24.0 updates'
check 'installed "$res"' 'to every file the release has, under the new names'
check '[ "$(cat "$plugin/Data/config.json")" = "{\"adminPassword\": \"theirs\"}" ] && [ "$(cat "$plugin/Data/results/race.txt")" = "P1 somebody" ]' 'its Data is moved into PhoenixRM Server'
check '! [ -e "$old" ]' 'the old plugin folder is moved out: BeamMP would run it beside the new one'
check '! [ -e "$res/Client/RaceManager.zip" ]' 'and so is the old client zip: players would be sent both'
check '! [ -e "$res/Client/RaceManager-v0.19.0.zip" ]' 'a second copy of the client is moved out'
check '[ -e "$res/Client/RaceManager-cars.zip" ]' 'a zip that only shares the name stays'
check '! [ -e "$res/Server/RaceManager_old" ] && [ -e "$res/Server/OtherPlugin/main.lua" ]' 'another Race Manager plugin moves out, other plugins stay'
attic=$(ls -d "$up"/_attic/install-0.0.1-to-* 2>/dev/null | head -n 1)
check '[ -n "$attic" ]' 'the attic folder names both versions'
check '[ -e "$attic/Client/RaceManager.zip" ] && [ -e "$attic/Server/RaceManager/main.lua" ] && [ -e "$attic/Server/RaceManager/maps.lua" ] && [ -e "$attic/Client/RaceManager-v0.19.0.zip" ] && [ -e "$attic/Server/RaceManager_old/main.lua" ]' 'and holds everything it replaced or moved'
check 'grep -q "were moved from Resources/Server/RaceManager/Data" "$root/out.txt"' 'and says the data was moved'
printf -- '-- gone from the release' > "$plugin/stale.lua"
check 'run "$up"' 'installing the same release again works'
check '! [ -e "$plugin/stale.lua" ]' 'a plugin file the release no longer has is moved out'
check '[ "$(cat "$plugin/Data/results/race.txt")" = "P1 somebody" ]' 'and Data is left alone'

# --- A renamed resources folder ----------------------------------------------
renamed="$root/renamed"
new_server "$renamed" "$config"$'ResourceFolder = "Res"\n'
check 'run "$renamed" && installed "$renamed/Res"' 'ResourceFolder in ServerConfig.toml is followed'
check '! [ -e "$renamed/Resources" ]' 'and nothing goes to Resources'

# --- A running server (Linux only: it needs pgrep and /proc) -------------------
if command -v pgrep >/dev/null 2>&1 && [ -d /proc/self ]; then
  running="$root/running"
  new_server "$running" "$config"
  # A renamed bash, not sleep: newer coreutils is one program that refuses to
  # run under another name. Two commands, or bash execs sleep and the process
  # stops being called BeamMP-Server.
  cp "$(command -v bash)" "$running/BeamMP-Server"
  (cd "$running" && exec ./BeamMP-Server -c 'sleep 30; true') &
  fake=$!
  sleep 0.5
  check 'pgrep -x BeamMP-Server >/dev/null' 'the stand-in server is running under its name'
  check '! run "$running"' 'a server that is running is refused'
  check '! [ -e "$running/Resources" ]' 'and nothing is written'
  pkill -P "$fake" 2>/dev/null; kill "$fake" 2>/dev/null; wait "$fake" 2>/dev/null
else
  echo "(skipped the running-server check: no pgrep here)"
fi

# --- A write that fails (not as root, which writes anywhere) --------------------
if [ "$(id -u)" != 0 ]; then
  locked="$root/locked"
  new_server "$locked" "$config"
  lres="$locked/Resources"
  lplug="$lres/Server/PhoenixRM Server"
  mkdir -p "$lplug" "$lres/Client"
  printf 'OLD CLIENT' > "$lres/Client/PhoenixRM Client.zip"
  printf "local RM_BUILD = '0.0.1'" > "$lplug/main.lua"
  printf -- '-- old maps' > "$lplug/maps.lua"
  chmod a-w "$lplug/maps.lua"
  if ! ( : > "$lplug/maps.lua" ) 2>/dev/null; then
    check '! run "$locked"' 'a file that cannot be written stops the install'
    check '[ "$(cat "$lres/Client/PhoenixRM Client.zip")" = "OLD CLIENT" ] && [ "$(cat "$lplug/main.lua")" = "local RM_BUILD = '"'"'0.0.1'"'"'" ]' 'and every file is put back'
  else
    echo "(skipped the failed-write check: this system writes read-only files)"
  fi
  chmod u+w "$lplug/maps.lua"
fi

# --- Not a server ----------------------------------------------------------------
empty="$root/empty"
mkdir -p "$empty"
check '! run "$empty"' 'a folder that is not a BeamMP server is refused'
check '[ -z "$(ls -A "$empty")" ]' 'and left empty'

echo "installer test: $checks checks, $fails failures"
[ "$fails" -eq 0 ]
