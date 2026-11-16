#!/bin/bash
# Phoenix Race Manager @VERSION@: the installer for a BeamMP server on Linux.
#
#   bash PRM-Install.sh                  the server in this folder
#   bash PRM-Install.sh /path/to/server  that server
#
# ONE FILE: the release is packed onto the end of this script (build.sh). It
# copies what it replaces into _attic/, writes "Resources/Client/PhoenixRM
# Client.zip" and the plugin's files in "Resources/Server/PhoenixRM Server",
# and never touches what is in that folder's Data. The rules are the in-game
# updater's (server/RaceManager/update.lua). An install from before 0.24.0, in
# Resources/Server/RaceManager and RaceManager.zip, has its Data moved across
# and the rest moved to _attic/.
#
# Run it with bash, never piped into bash: it reads its own file to find the
# release. No set -u: bash before 4.4 calls an empty array unbound.
VERSION='@VERSION@'

say() { printf '%s\n' "$*"; }
die() { printf 'PRM: %s\n' "$*" >&2; exit 1; }

# A server folder: its config, or its binary before a first run writes the config.
is_server() { [ -f "$1/ServerConfig.toml" ] || [ -f "$1/BeamMP-Server" ]; }

server=$1
if [ -z "$server" ]; then
  for d in "$PWD" "$(cd "$(dirname "$0")" && pwd)"; do
    if is_server "$d"; then server=$d; break; fi
  done
fi
if [ -z "$server" ]; then
  found=$(find "$HOME" /opt /srv /home -maxdepth 3 -name ServerConfig.toml 2>/dev/null \
    | while read -r f; do dirname "$f"; done | sort -u)
  count=$(printf '%s\n' "$found" | grep -c .)
  if [ "$count" -eq 1 ]; then
    server=$found
  elif [ "$count" -gt 1 ]; then
    die "several BeamMP servers found. Run it with the one to install into:
$(printf '%s\n' "$found" | sed "s|^|  bash $0 |")"
  else
    die "no BeamMP server here. Run it in the server's folder, or: bash $0 /path/to/server"
  fi
fi
[ -d "$server" ] || die "$server is not a folder"
is_server "$server" || die "$server is not a BeamMP server folder: it has neither ServerConfig.toml nor BeamMP-Server"
server=$(cd "$server" && pwd)

# BeamMP reloads a changed plugin on the spot, which ends any session in
# progress, and keeps offering the old client until it restarts. -x: a
# server folder called BeamMP-Server puts the name in this script's own path.
if command -v pgrep >/dev/null 2>&1; then
  for pid in $(pgrep -x BeamMP-Server 2>/dev/null); do
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
    if [ "$cwd" = "$server" ] || [ "${exe%/*}" = "$server" ]; then
      die "the BeamMP server in $server is running (pid $pid). Stop it, then run this again."
    fi
  done
fi

# ResourceFolder from ServerConfig.toml: a server may have renamed it.
res=$(sed -n 's/^[[:space:]]*ResourceFolder[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$server/ServerConfig.toml" 2>/dev/null | head -n 1)
res=${res:-Resources}
case $res in /*) ;; *) res="$server/$res" ;; esac
client="$res/Client"
plugin="$res/Server/PhoenixRM Server"
# Where the plugin lived before 0.24.0.
old_plugin="$res/Server/RaceManager"

tmp=$(mktemp -d 2>/dev/null) || die "could not make a temporary folder"
trap 'rm -rf "$tmp"' EXIT
start=$(awk '/^__PRM_PAYLOAD__$/ { print NR + 1; exit }' "$0")
[ -n "$start" ] || die "this installer has no release in it. Download it again."
tail -n +"$start" "$0" | base64 -d 2>/dev/null | tar -xzf - -C "$tmp" 2>/dev/null \
  || die "this installer is damaged. Download it again."
[ -f "$tmp/Client/PhoenixRM Client.zip" ] && [ -f "$tmp/Server/PhoenixRM Server/main.lua" ] \
  || die "this installer is damaged. Download it again."

old=$(sed -n "s/^local RM_BUILD = '\([^']*\)'.*/\1/p" "$plugin/main.lua" 2>/dev/null | head -n 1)
[ -n "$old" ] || old=$(sed -n "s/^local RM_BUILD = '\([^']*\)'.*/\1/p" "$old_plugin/main.lua" 2>/dev/null | head -n 1)
attic="$server/_attic/install-${old:-none}-to-${VERSION}_$(date +%Y-%m-%d_%H-%M-%S)"
mkdir -p "$attic/Client" "$attic/Server/PhoenixRM Server" "$client" "$plugin" \
  || die "could not make folders in $server"

# Every change is recorded so a failure can put each file back.
kinds=(); froms=(); tos=()
written=(); moved=(); notes=()
remember() { kinds+=("$1"); froms+=("$2"); tos+=("$3"); }
rollback() {
  local i lost=0
  for (( i = ${#kinds[@]} - 1; i >= 0; i-- )); do
    if [ "${kinds[i]}" = restore ]; then cp -p "${froms[i]}" "${tos[i]}" 2>/dev/null || lost=1
    elif [ "${kinds[i]}" = moveback ]; then mv "${tos[i]}" "${froms[i]}" 2>/dev/null || lost=1
    else rm -f "${tos[i]}" 2>/dev/null || lost=1; fi
  done
  return $lost
}
fail() {
  if rollback; then die "$1. Everything was put back as it was."
  else die "$1. Some files could not be put back: copy them from $attic."; fi
}

# Write one file, backing up what it replaces. Read back: a full disk writes
# short without saying so.
put() {
  if [ -f "$2" ]; then
    cp -p "$2" "$3" 2>/dev/null || fail "could not back up $2"
    remember restore "$3" "$2"
  else
    remember remove "" "$2"
  fi
  { cp "$1" "$2" && cmp -s "$1" "$2"; } 2>/dev/null || fail "could not write $2"
  written+=("${2#"$server"/}")
}

# THE DATA OF AN INSTALL FROM BEFORE 0.24.0 comes across first, whole, before
# the old folder is moved out below: tracks, cup, garage, settings, results.
# Only into a folder that has no Data yet.
data_moved=''
if [ ! -e "$plugin/Data" ] && [ -d "$old_plugin/Data" ]; then
  mv "$old_plugin/Data" "$plugin/Data" 2>/dev/null \
    || fail "could not move ${old_plugin#"$server"/}/Data to ${plugin#"$server"/}/Data"
  remember moveback "$old_plugin/Data" "$plugin/Data"
  data_moved=1
fi

put "$tmp/Client/PhoenixRM Client.zip" "$client/PhoenixRM Client.zip" "$attic/Client/PhoenixRM Client.zip"
for f in "$tmp/Server/PhoenixRM Server"/*.lua; do
  put "$f" "$plugin/${f##*/}" "$attic/Server/PhoenixRM Server/${f##*/}"
done
# The LICENSE travels in the plugin's folder (BeamMP loads only .lua files).
if [ -f "$tmp/Server/PhoenixRM Server/LICENSE" ]; then
  put "$tmp/Server/PhoenixRM Server/LICENSE" "$plugin/LICENSE" "$attic/Server/PhoenixRM Server/LICENSE"
fi
# A plugin file this release no longer has: BeamMP runs every .lua in the
# folder, so it would keep running beside the new ones.
for f in "$plugin"/*.lua; do
  [ -f "$f" ] || continue
  n=${f##*/}
  [ -f "$tmp/Server/PhoenixRM Server/$n" ] && continue
  cp -p "$f" "$attic/Server/PhoenixRM Server/$n" 2>/dev/null || fail "could not back up $f"
  remember restore "$attic/Server/PhoenixRM Server/$n" "$f"
  rm -f "$f" 2>/dev/null || fail "could not remove $f"
  moved+=("${f#"$server"/} (not part of PRM $VERSION)")
done

# Older copies of PRM that would run beside this one, moved, never deleted.
move_out() {
  if mkdir -p "$(dirname "$2")" && mv "$1" "$2" 2>/dev/null; then moved+=("${1#"$server"/} ($3)")
  else notes+=("Could not move ${1#"$server"/} ($3): move it out yourself."); fi
}
# Unzip or Python reads what is inside; with neither, the name has to do.
holds_client() {
  if command -v unzip >/dev/null 2>&1; then
    unzip -Z1 "$1" 2>/dev/null | grep -qx 'lua/ge/extensions/raceManager.lua'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, zipfile; sys.exit("lua/ge/extensions/raceManager.lua" not in zipfile.ZipFile(sys.argv[1]).namelist())' "$1" 2>/dev/null
  fi
}
# A second client zip: BeamMP sends every zip in Client to every player. The
# one from before 0.24.0, RaceManager.zip, is one of them now.
shopt -s nocaseglob nullglob
for z in "$client"/RaceManager*.zip "$client"/PhoenixRM*.zip; do
  [ "${z##*/}" = "PhoenixRM Client.zip" ] && continue
  holds_client "$z" && move_out "$z" "$attic/Client/${z##*/}" "an older or second copy of the PRM client"
done
shopt -u nocaseglob
# Another plugin folder: BeamMP runs every folder in Server.
for d in "$res"/Server/*/; do
  d=${d%/}
  [ "$d" -ef "$plugin" ] && continue
  if [ "$d" -ef "$old_plugin" ]; then what="the install from before 0.24.0"; else what="another Race Manager plugin"; fi
  [ -f "$d/main.lua" ] && grep -q 'RM_BUILD' "$d/main.lua" && grep -qF '[RaceManager]' "$d/main.lua" \
    && move_out "$d" "$attic/Server/${d##*/}" "$what"
done
# Packages up to 0.6.0 spelled the folders in lower case, which BeamMP never reads.
if [ -d "$res/server/RaceManager" ] && ! [ "$res/server" -ef "$res/Server" ]; then
  move_out "$res/server/RaceManager" "$attic/server/RaceManager" "an old install in the lower-case folder"
fi
if [ -f "$res/client/RaceManager.zip" ] && ! [ "$res/client" -ef "$res/Client" ]; then
  move_out "$res/client/RaceManager.zip" "$attic/client/RaceManager.zip" "an old install in the lower-case folder"
fi
shopt -u nullglob

{
  if [ -z "$old" ]; then was=''; elif [ "$old" = "$VERSION" ]; then was=' (installed again)'; else was=" (it was $old)"; fi
  say "Phoenix Race Manager $VERSION is installed in $server$was."
  say ""
  say "Written:"
  for w in "${written[@]}"; do say "  $w"; done
  if [ ${#moved[@]} -gt 0 ]; then
    say "Moved out:"
    for m in "${moved[@]}"; do say "  $m"; done
  fi
  for n in "${notes[@]}"; do say "$n"; done
  say "Anything replaced is in ${attic#"$server"/}."
  if [ -n "$data_moved" ]; then
    say "Tracks, results and settings were moved from ${old_plugin#"$server"/}/Data to ${plugin#"$server"/}/Data."
  else
    say "Tracks, results and settings in ${plugin#"$server"/}/Data were not touched."
  fi
  say ""
  say "Next:"
  say "  1. Start the server, or restart it if it is running."
  say "  2. Players get PRM as they join. Each driver adds Phoenix Race Manager (PRM)"
  say "     once from HUD Apps (search PRM)."
  if [ -z "$old" ]; then
    say "  3. Log in on the app's admin bar with the password from the README, then set"
    say "     your own on the Admin tab."
  fi
  say "Later releases install from the app's Admin tab: Update and restart."
} | tee "$attic/install.log"
exit 0
