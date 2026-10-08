#!/usr/bin/env bash
# ===========================================================================
#  teardown.sh  --  remove exactly what setup-lab.sh created, and nothing else
#
#  This is the Linux / macOS twin of teardown.cmd. The two do exactly the same
#  thing in exactly the same order, and they are kept side by side on purpose:
#  if you change one, change the other.
#
#    ./teardown.sh          list what will go, ask, then remove it
#    ./teardown.sh --yes    remove without asking, for scripts
#    ./teardown.sh -?       this list
#
#  Every name below is derived from the folder name using the same expression
#  as setup-lab.sh, which is what makes this script provably safe: it can only
#  ever name objects that belong to this scenario.
#
#  Written for bash 3.2, which is what macOS still ships.
# ===========================================================================

LABDIR=$(cd "$(dirname "$0")" && pwd)
SCEN=$(basename "$LABDIR")
VOL="${SCEN}_esdata"
WORK="${TMPDIR:-/tmp}/elklab-$SCEN"
WORK=${WORK%/}
COMPOSEFILE="$LABDIR/docker-compose.yml"
ASSUME=0
DC=""

if [ -t 1 ]; then printf '\033]0;teardown.sh - %s\007' "$(basename "$0")"; fi

say() { printf '%s\n' "$*"; }

pause() {
  [ "$LAB_NOPAUSE" = "1" ] && return 0
  [ -t 0 ] || return 0
  printf '  Press Enter to close this window...'
  read -r _ || true
  printf '\n'
}

usage() {
  say ""
  say " =============================================================="
  say "  teardown.sh  -  remove the \"$SCEN\" lab"
  say " =============================================================="
  say ""
  say "   ./teardown.sh          list what will be removed, ask, then remove it"
  say "   ./teardown.sh --yes    remove without asking, for scripts"
  say "   ./teardown.sh -?       this list"
  say ""
  say "  What it removes, and only this:"
  say "    the containers  $SCEN-elasticsearch  and  $SCEN-kibana"
  say "    the volume      $VOL   which holds the imported log data and the rule"
  say "    the generated   docker-compose.yml  in this folder"
  say "    the scratch     $WORK  folder in the temp directory"
  say ""
  say "  What it never touches:"
  say "    any Docker image, so the next setup is fast"
  say "    any other container or volume on this machine"
  say "    any file in this folder other than the generated docker-compose.yml"
  say ""
  say "  It never runs \"docker system prune\" and never removes an image."
  say ""
  pause
  exit 0
}

for a in "$@"; do
  case "$a" in
    --yes|-y) ASSUME=1 ;;
    -\?|--help|-h|help) usage ;;
  esac
done

say ""
say " =============================================================="
say "  teardown.sh  -  remove the \"$SCEN\" lab"
say " =============================================================="
say ""

# ------------------------------------------------- is there anything to remove
HADES=0; HADKB=0; HADVOL=0; DOCKEROK=0

if command -v docker >/dev/null 2>&1; then
  if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    DOCKEROK=1
    if docker compose version >/dev/null 2>&1; then
      DC="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
      DC="docker-compose"
    fi
  fi
fi

if [ "$DOCKEROK" = "1" ]; then
  docker inspect "$SCEN-elasticsearch" >/dev/null 2>&1 && HADES=1
  docker inspect "$SCEN-kibana"         >/dev/null 2>&1 && HADKB=1
  docker volume inspect "$VOL"          >/dev/null 2>&1 && HADVOL=1
fi

if [ "$HADES$HADKB$HADVOL" = "000" ]; then
  if [ "$DOCKEROK" = "1" ]; then
    say " Nothing to remove. There is no container and no volume named after"
    say "   this scenario, so there is nothing to do."
  else
    say " Docker is not available, but there is nothing named after this"
    say "   scenario to remove either."
  fi
  [ -d "$WORK" ] && rm -rf "$WORK"
  say ""
  say " Lab state : already clean"
  say " Nothing was deleted."
  say ""
  say " To build the lab again :  ./setup-lab.sh"
  say ""
  pause
  exit 0
fi

# ------------------------------------------- state the exact list, then ask
say " The following will be REMOVED. Nothing else will be touched."
say ""
[ "$HADES" = "1" ]  && say "   container   $SCEN-elasticsearch"
[ "$HADKB" = "1" ]  && say "   container   $SCEN-kibana"
[ "$HADVOL" = "1" ] && say "   volume      $VOL      (this holds ALL the lab data, the detection rule included)"
[ -f "$COMPOSEFILE" ] && say "   file       $COMPOSEFILE   (the generated compose file)"
[ -d "$WORK" ]        && say "   folder     $WORK         (scratch files only)"
say ""
say " This cannot be undone. The volume holds the imported logs, so removing it"
say " means the next setup-lab.sh has to import the data again."
say ""
say " Deliberately KEPT, always:"
say "   - all Docker images, so the next setup is fast and offline"
say "   - every other container, volume and image on this machine"
say "   - the files in $LABDIR  (ndjson, templates, rule.json, the scripts, the guide)"
say ""
say " This script never runs \"docker system prune\" and never removes an image."
say ""

if [ "$ASSUME" = "0" ]; then
  if [ -t 0 ]; then
    printf '  Remove these now?  [y/N] : '
    a=""
    read -r a || true
    case "$a" in y|Y|yes|YES) ;; *)
      say ""
      say " Nothing was removed. The lab is still exactly as it was."
      say ""
      pause
      exit 0
      ;;
    esac
  else
    say " Not running interactively, so nothing was removed."
    say " Re-run with --yes if you meant it."
    say ""
    pause
    exit 0
  fi
fi

# ------------------------------------------------------------------ remove
say ""
say " Removing..."

if [ "$DOCKEROK" = "0" ]; then
  say ""
  say " Docker is not running, so containers and the data volume CANNOT be"
  say " removed right now. A stopped Docker engine cannot delete anything."
  say "   What is being cleaned up instead:"
  [ -d "$WORK" ] && say "     folder   $WORK   removed"
  say "     container $SCEN-elasticsearch   STILL PRESENT, cannot remove it"
  say "     container $SCEN-kibana         STILL PRESENT, cannot remove it"
  say "     volume    $VOL                 STILL PRESENT, cannot remove it"
  [ -f "$COMPOSEFILE" ] && say "     file     $COMPOSEFILE   kept, so you can still run"
  say "                  \"$DC -f docker-compose.yml down\" later"
  [ -d "$WORK" ] && rm -rf "$WORK" 2>/dev/null
  say ""
  say " To finish, start Docker and run teardown.sh again."
  say ""
  pause
  exit 1
fi

# down -v first while the compose file is still here, because that is the clean
# path.  Explicit removals follow so the script still works if the folder was
# moved and docker-compose.yml went missing.
if [ -f "$COMPOSEFILE" ] && [ -n "$DC" ]; then
  if $DC -f "$COMPOSEFILE" down -v --remove-orphans >/dev/null 2>&1; then
    say "   compose down -v completed"
  else
    say "   \"compose down\" did not complete cleanly, removing the objects by name"
  fi
fi

docker rm -f "$SCEN-elasticsearch" >/dev/null 2>&1
docker rm -f "$SCEN-kibana"         >/dev/null 2>&1
docker volume rm -f "$VOL"          >/dev/null 2>&1

[ -f "$COMPOSEFILE" ] && rm -f "$COMPOSEFILE"
[ -d "$WORK" ]        && rm -rf "$WORK" 2>/dev/null

# ----------------------------------------------------- honest closing state
say ""
say " Verifying..."
GADES=0; GADKB=0; GADVOL=0; GCOMPOSE=0; GWORK=0
docker inspect "$SCEN-elasticsearch" >/dev/null 2>&1 || GADES=1
docker inspect "$SCEN-kibana"         >/dev/null 2>&1 || GADKB=1
docker volume inspect "$VOL"          >/dev/null 2>&1 || GADVOL=1
[ -f "$COMPOSEFILE" ] || GCOMPOSE=1
[ -d "$WORK" ]        || GWORK=1

[ "$GADES" = "1" ]  && say "   gone      container $SCEN-elasticsearch"
[ "$HADES" = "0" ]  && say "   absent    container $SCEN-elasticsearch   (there was nothing to remove)"
[ "$GADES" = "0" ]  && say "   WARNING   container $SCEN-elasticsearch   still exists and could not be removed"
[ "$GADKB" = "1" ]  && say "   gone      container $SCEN-kibana"
[ "$HADKB" = "0" ]  && say "   absent    container $SCEN-kibana         (there was nothing to remove)"
[ "$GADKB" = "0" ]  && say "   WARNING   container $SCEN-kibana         still exists and could not be removed"
[ "$GADVOL" = "1" ] && say "   gone      volume    $VOL"
[ "$HADVOL" = "0" ] && say "   absent    volume    $VOL               (there was nothing to remove)"
[ "$GADVOL" = "0" ] && say "   WARNING   volume    $VOL               still exists, $VOL may still be holding data"
[ "$GCOMPOSE" = "1" ] && say "   gone      file      $COMPOSEFILE"
[ "$GWORK" = "1" ]    && say "   gone      folder    $WORK"
say ""

if [ "$GADES$GADKB$GADVOL" = "111" ]; then
  say " =============================================================="
  say "   The \"$SCEN\" lab has been removed."
  say ""
  say "   Kept on purpose: every Docker image, and every other container and"
  say "   volume on this machine. The log files and templates in this folder"
  say "   are also untouched, so nothing was lost from disk here."
  say ""
  say "   To build the lab again from scratch :  ./setup-lab.sh"
  say " =============================================================="
else
  say " =============================================================="
  say "   Partly removed. Read the WARNING lines above."
  say ""
  say "   The usual cause is Docker not running, or the containers having"
  say "   been started by hand rather than through compose."
  say "   Start Docker and run teardown.sh again, or remove the named"
  say "   objects by hand:"
  say "     docker rm -f \"$SCEN-elasticsearch\" \"$SCEN-kibana\""
  say "     docker volume rm -f \"$VOL\""
  say " =============================================================="
fi
say ""
pause
exit 0
