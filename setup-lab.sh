#!/usr/bin/env bash
# ===========================================================================
#  setup-lab.sh  --  one-click lab build for this scenario folder
#
#  This is the Linux / macOS twin of setup-lab.cmd. The two do exactly the
#  same thing in exactly the same order, and they are kept side by side on
#  purpose: if you change one, change the other, or a Windows lab and a Mac
#  lab will quietly stop being the same lab.
#
#    ./setup-lab.sh                create / update the lab, then open the browser
#    ./setup-lab.sh reset          remove containers, volume and data views, rebuild
#    ./setup-lab.sh regen-compose  rewrite docker-compose.yml, then set up
#    ./setup-lab.sh nolaunch       set up but do not open the browser
#    ./setup-lab.sh -?             this list
#
#  Every Docker object name is derived from the folder name, so this lab can
#  live next to other scenario labs on one machine without colliding, and so
#  teardown.sh can prove exactly what it is allowed to delete.
#
#  Written for bash 3.2, which is what macOS still ships, so there are no
#  associative arrays and no ${var^^} here on purpose.
# ===========================================================================

# ------------------------------------------------------------------ settings
ESPORT=9200
KBPORT=5601
ESIMAGE=docker.elastic.co/elasticsearch/elasticsearch:9.1.0
KBIMAGE=docker.elastic.co/kibana/kibana:9.1.0

IDXSUF=2026.09.22
AUTHDOCS=271
NETDOCS=149

#  The three literals the guided walkthrough tells the student to read out of
#  their own results and then use.  They are here only so the verification pass
#  can replay the exact queries the guide quotes; the guide never hands them over
#  before the student has found them.
VICTIM=sec-win-05
VICTIMIP=10.0.4.30
POOLIP=198.51.100.77
POOLPORT=3333

#  One expected count per query the walkthrough quotes, in the order the walkthrough
#  asks for them.  Every one of these is asserted against the live index below, so
#  a lab that reaches "ready" is a lab whose numbers can be trusted.
D1=21   # event.code: 4688                                the estate's whole day
D2=51   # event.code: 4625                                failed logons, the dead end
D3=5    # event.code: 4688 and process.name: powershell    the sharper trap
D4=1    # event.code: 4624 + svc_backup + the victim       the entry point
D5=2    # event.code: 4688 and host.name: the victim       the one-shot, the chain
D6=32   # event.action: dns_query                         the day's lookups
D7=4    # the recurring pool sessions                     the heartbeat
DQ1=1   # rule 1's own query, which has to agree with the alert it raises
DQ2=1   # rule 2's own query, which has to agree with the alert it raises
DQ3=4   # rule 3's own query: four keepalives, one ongoing operation

# ------------------------------------------------------------------ accounts
#  Security has to be on. A detection rule cannot be created against a
#  cluster that has it off: Elasticsearch has no rule API in that mode and
#  Kibana refuses the rule call, so the Alerts page would always be empty.
#  These two accounts are throwaway lab credentials. They are printed on
#  screen and typed into curl by the student; they protect nothing.
#  ESBOOT is only used once, to create the account Kibana runs as. Kibana
#  refuses to run as the built-in elastic superuser, and a plain superuser
#  cannot create the .kibana* saved-object indices, so the account also
#  carries the built-in kibana_system role.
ESBOOT=LabElastic001
ESUSER=elastic
ESPASS=LabElastic001
KBUSER=lab_kibana
KBPASS=LabKibana001

#  the three detection rules, and the number of alerts each must produce
RULENAME1='PowerShell started by a remote-execution service'
RULENAME2='Known cryptominer binary started on a server'
RULENAME3='Tiny outbound keepalives on a single non-standard port'
RULEALERTS1=1
RULEALERTS2=1
RULEALERTS3=4
RULEALERTS=6
RULECOL=76
RULEKQL1L1='event.code: 4688 and process.name: "powershell.exe"'
RULEKQL1L2='and process.parent.name: "wmiprvse.exe"'
RULEKQL2L1='event.code: 4688 and process.name: "xmrig.exe"'
RULEKQL3L1="event.action: \"network_connection\" and destination.port: $POOLPORT"
RULEKQL3L2='and network.bytes < 2048'

# ------------------------------------------------------ identity from folder
SELF=$0
case "$SELF" in
  */*) LABDIR=$(cd "$(dirname "$SELF")" && pwd) ;;
  *)   LABDIR=$(cd "$(dirname "$(command -v "$SELF")")" && pwd) ;;
esac
SCEN=$(basename "$LABDIR")
VOL="${SCEN}_esdata"
WORK="${TMPDIR:-/tmp}/elklab-$SCEN"
WORK=${WORK%/}
ESURL="http://127.0.0.1:$ESPORT"
KBURL="http://127.0.0.1:$KBPORT"
COMPOSEFILE="$LABDIR/docker-compose.yml"

#  every Elasticsearch call is made as the bootstrap superuser, every Kibana
#  call as the account Kibana itself runs as. Both are kept in variables so
#  that a password only ever has to be fixed in one place.
ESAUTH=(-u "$ESUSER:$ESPASS")
KBAUTH=(-u "$KBUSER:$KBPASS")

MODE=setup
LAUNCH=1
NOPAUSE=0
DC=""

# ------------------------------------------------------------------ helpers
say()  { printf '%s\n' "$*"; }
#  Print one "query ............. = count" line, padded to a fixed column.  The
#  query text lives in a variable, so the padding has to be worked out from its
#  real length as it prints, otherwise the column drifts the moment a query
#  changes length and the counts stop lining up under each other.
saycount() { say "$(printf '%-*s = %s' "$RULECOL" "$1" "$2")"; }
# The .cmd uses "pause" at the end of a run. A script has no keypress to wait
# for, and blocking forever would be worse, so this only waits when a human
# is actually sitting there. Set LAB_NOPAUSE=1 to skip it even then.
pause() {
  [ "$NOPAUSE" = "1" ] && return 0
  [ -t 0 ] || return 0
  printf '  Press Enter to close this window...'
  read -r _ || true
  printf '\n'
}

openbrowser() { # $1 url
  [ "$LAUNCH" = "1" ] || return 0
  if command -v open >/dev/null 2>&1; then open "$1"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1
  fi
}

# ------------------------------------------------------------------ arguments
usage() {
  say ""
  say " =============================================================="
  say "  setup-lab.sh  -  build the \"$SCEN\" lab"
  say " =============================================================="
  say ""
  say "   ./setup-lab.sh                create or update the lab, open the browser"
  say "   ./setup-lab.sh reset          remove containers, volume and data views, rebuild"
  say "   ./setup-lab.sh regen-compose  rewrite docker-compose.yml, then set up"
  say "   ./setup-lab.sh nolaunch       set up but do not open the browser"
  say "   ./setup-lab.sh -?             this list"
  say ""
  say " Docker images are downloaded once and then kept, so the second run of"
  say " this script is fast. Nothing outside this scenario is ever touched."
  say ""
  pause
  exit 0
}

for a in "$@"; do
  case "$a" in
    reset)          MODE=reset ;;
    regen-compose)  MODE=regen ;;
    nolaunch)       LAUNCH=0 ;;
    -\?|--help|-h|help) usage ;;
  esac
done

# ------------------------------------------------------------------- banner
if [ -t 1 ]; then printf '\033]0;setup-lab.sh - %s\007' "$(basename "$0")"; fi
say ""
say " =============================================================="
say "  Scenario lab   :  $SCEN"
say "  Elasticsearch  :  $ESURL"
say "  Kibana         :  $KBURL"
say "  Scratch folder :  $WORK"
say " =============================================================="
say ""

# ---------------------------------------------------------------- preflight
preflight() {
  mkdir -p "$WORK" 2>/dev/null || true
  if [ ! -d "$WORK" ]; then
    fail "cannot create the scratch folder $WORK" "Nothing was changed."
  fi
  if ! command -v docker >/dev/null 2>&1; then
    say " ERROR: \"docker\" was not found on this computer."
    say ""
    say "   This lab runs Elasticsearch and Kibana inside Docker containers."
    say "   Install Docker Desktop (macOS) or Docker Engine (Linux), start it,"
    say "   wait until the engine is running, then run this file again."
    say ""
    fail "" "Nothing was changed."
  fi
  #  Compose v2 is "docker compose"; v1 was a separate "docker-compose" binary.
  #  Both are accepted so an older Linux box is not turned away.
  if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
  else
    say " ERROR: docker is installed but the Compose plugin is missing."
    say ""
    say "   This script builds the lab with a Compose file, so it needs the"
    say "   Compose plugin (the \"docker compose\" command)."
    say ""
    fail "" "Nothing was changed."
  fi
  local dver
  dver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
  if [ -z "$dver" ]; then
    say " ERROR: Docker is installed but the engine is not responding."
    say ""
    say "   Start Docker Desktop (or the Docker service) and wait until it is"
    say "   running, then run this file again."
    say ""
    fail "" "Nothing was changed."
  fi
  say " [preflight] docker engine version $dver"
  say " [preflight] compose command: $DC"
  say " [preflight] every object will be named from the folder name \"$SCEN\""
}

# =========================================================== do_reset
do_reset() {
  say " [reset] removing whatever a previous run of this lab left behind"
  [ -f "$COMPOSEFILE" ] && $DC -f "$COMPOSEFILE" down -v --remove-orphans >/dev/null 2>&1
  docker volume rm -f "$VOL" >/dev/null 2>&1
  docker rm -f "$SCEN-elasticsearch" "$SCEN-kibana" >/dev/null 2>&1
  say " [reset] done."
  say ""
}

# ======================================================= compose generation
mkcompose() {
  cat > "$COMPOSEFILE" <<EOF
# Generated by setup-lab.sh
# Every name and port below is derived from the folder this file
# lives in, so the file is safe to delete and regenerate:
#     ./setup-lab.sh regen-compose
name: $SCEN
services:
  elasticsearch:
    image: $ESIMAGE
    container_name: $SCEN-elasticsearch
    environment:
      - node.name=es01
      - cluster.name=$SCEN
      - discovery.type=single-node
      - bootstrap.memory_lock=true
      - xpack.security.enabled=true
      - ELASTIC_PASSWORD=$ESBOOT
      - xpack.ml.enabled=false
      - ingest.geoip.downloader.enabled=false
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    ulimits:
      memlock:
        soft: -1
        hard: -1
    volumes:
      - "$VOL:/usr/share/elasticsearch/data"
    ports:
      - "$ESPORT:9200"
    healthcheck:
      test: ["CMD-SHELL","curl -s -u $ESUSER:$ESBOOT -o /dev/null http://localhost:9200/_cluster/health || exit 1"]
      interval: 10s
      timeout: 6s
      retries: 40
    networks:
      - lab
  kibana:
    image: $KBIMAGE
    container_name: $SCEN-kibana
    depends_on:
      elasticsearch:
        condition: service_healthy
    environment:
      - ELASTICSEARCH_HOSTS=["http://elasticsearch:9200"]
      - ELASTICSEARCH_USERNAME=$KBUSER
      - ELASTICSEARCH_PASSWORD=$KBPASS
      - SERVER_HOST=0.0.0.0
      - SERVER_PUBLICBASEURL=http://localhost:$KBPORT
      - TELEMETRY_ENABLED=false
      - SECURITY_SHOWINSECURECLUSTERWARNING=false
      - XPACK_REPORTING_ENABLED=false
      - I18N_LOCALE=en
      - XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=${SCEN}labencryptedsavedobjects000001
      - XPACK_SECURITY_ENCRYPTIONKEY=${SCEN}labsecurityencryptionkey0000001
    ports:
      - "$KBPORT:5601"
    healthcheck:
      test: ["CMD-SHELL","curl -s http://localhost:5601/api/status | grep -q available || exit 1"]
      interval: 10s
      timeout: 6s
      retries: 60
    networks:
      - lab
networks:
  lab:
    driver: bridge
volumes:
  "$VOL":
    name: "$VOL"
EOF
  #  Kibana will not start a detection rule at all without an encryption key
  #  for its saved objects, and it throws one away on every restart, so the
  #  rule just installed would vanish the next time the container is
  #  recreated. Both keys are fixed above for that reason.
  if [ ! -f "$COMPOSEFILE" ]; then
    fail "could not write docker-compose.yml" "Nothing else was started."
  fi
  say " [compose] wrote $COMPOSEFILE"
}

# ------------------------------------------- refuse somebody else's cluster
guardcluster() {
  if [ ! -f "$COMPOSEFILE" ]; then
    fail "docker-compose.yml is missing" "Run  ./setup-lab.sh regen-compose  to rewrite it."
  fi
  docurl -o "$WORK/guard.json" "${ESAUTH[@]}" "$ESURL/_cluster/health"
  if [ "$CURLCODE" = "000" ]; then return 0; fi
  if [ "$CURLCODE" = "401" ]; then return 0; fi
  if grep -q -F -- "$SCEN" "$WORK/guard.json" 2>/dev/null; then return 0; fi
  say " ERROR: something else is already using port $ESPORT."
  say ""
  say "   An Elasticsearch is answering on $ESURL, but it is not the cluster"
  say "   this lab created, so its name is not \"$SCEN\". This script will not"
  say "   touch a cluster it did not start, and it has changed nothing."
  say ""
  say "   Fix it one of these ways"
  say "     - stop the other stack, find it with   docker ps"
  say "     - change ESPORT and KBPORT at the top of setup-lab.sh and re-run"
  say "     - run teardown.sh inside the folder that owns the other cluster"
  say ""
  say "   For the record, that other cluster says:"
  grep -o -F 'cluster_name' "$WORK/guard.json" >/dev/null 2>&1 && \
    grep -o '"cluster_name":"[^"]*"' "$WORK/guard.json" 2>/dev/null | sed 's/^/     /'
  say ""
  fail "another lab is already using port $ESPORT" "Nothing was changed."
}

# ------------------------------- warn, never destroy, on a moved copy of self
checkmoved() {
  local moved
  moved=$(docker inspect "$SCEN-elasticsearch" \
            --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' \
            2>/dev/null) || return 0
  [ -z "$moved" ] && return 0
  #  A trailing slash on the recorded path is the same folder, not a move.
  moved=${moved%/}
  [ "$moved" = "$LABDIR" ] && return 0
  say " WARNING: a container called \"$SCEN-elasticsearch\" already exists, and it"
  say "           was created from a different folder."
  say ""
  say "   existing container : $SCEN-elasticsearch"
  say "   created from       : $moved"
  say "   this folder        : $LABDIR"
  say ""
  docker inspect "$SCEN-elasticsearch" --format '    status {{.State.Status}}   image {{.Config.Image}}' 2>&1 | sed 's/^/ /'
  docker inspect "$SCEN-elasticsearch" --format '    volume {{range .Mounts}}{{.Name}}{{end}}' 2>&1 | sed 's/^/ /'
  docker inspect "$SCEN-elasticsearch" --format '    ports  {{range $p, $c := .NetworkSettings.Ports}}{{$p}}->{{$c}}{{println}}{{end}}' 2>&1 | sed 's/^/ /'
  say ""
  say "   This usually means the lab folder was copied. setup-lab.sh will NOT"
  say "   destroy the other copy. To start over on purpose, remove it yourself:"
  say ""
  say "     docker rm -f \"$SCEN-elasticsearch\" \"$SCEN-kibana\""
  say "     docker volume rm -f \"$VOL\""
  say ""
  say "   or run  teardown.sh  which lists and confirms before it deletes."
  say ""
  fail "" "Nothing was deleted."
}

# ---------------------------------------------------------------- lab account
#  Kibana will not run as the built-in elastic account, and an account that
#  only has the superuser role still cannot create the .kibana* saved-object
#  indices, so the lab account carries superuser together with the built-in
#  kibana_system role. Creating it is safe to repeat: the second run finds
#  the account and rewrites the same password, which is what makes a changed
#  KBPASS at the top of this file take effect.
mkaccount() {
  printf '{"password":"%s","roles":["superuser","kibana_system"]}\n' "$KBPASS" > "$WORK/acct.json"
  docurl -o "$WORK/acct-resp.json" -X PUT "$ESURL/_security/user/$KBUSER" \
         -H "Content-Type: application/json" "${ESAUTH[@]}" --data-binary "@$WORK/acct.json"
  if [ "$CURLCODE" != "200" ] && [ "$CURLCODE" != "201" ]; then
    fail "could not create the lab account $KBUSER, HTTP $CURLCODE" \
         "Nothing was deleted. The Elasticsearch log says why:  docker logs $SCEN-elasticsearch"
  fi
  say "      account $KBUSER ready"
}

# --------------------------------------------------------- the detection rules
#  This is the whole point of the rule: without a fired rule the Alerts page
#  renders nothing at all, so a walkthrough that opens Alerts would be a dead
#  end. The rules are installed through Kibana rather than through
#  Elasticsearch's own rule API, because Kibana is what actually runs the
#  alerting engine and what writes the alerts the page reads.
#
#  Three rules, not one, because that is what a detection estate looks like and
#  because a single rule raising a single alert teaches a student nothing about triage,
#  and three narrow rules raising six describe a real triage queue without burying it.
#  Two of them sit on the process side and one on the network side, which is the
#  split a real SOC uses: name-based and behaviour-based detection on the host,
#  beaconing detection on the wire.  Together they produce six alerts.
#
#  Each rule is deliberately idempotent by name.  The create route always mints
#  a new rule id and there is no update-by-id route in this build, so a second
#  run would install a second copy and every alert would be counted twice.
#
#  $1 is the rule file, $2 the display name, $3 the alerts that rule must make.
mkone() {
  RF=$1; RN=$2; RE=$3
  if [ ! -f "$LABDIR/$RF" ]; then
    fail "$RF is missing from $LABDIR" \
         "The rest of the lab is fine. Put it back and re-run to get the Alerts page working."
  fi
  #  A match_phrase on the rule's name is case-insensitive, so the name can be
  #  written here exactly as it is written in the rule file.
  printf '{"query":{"match_phrase":{"alert.name":"%s"}}}\n' "$RN" > "$WORK/rulefind.json"
  esdocount ".kibana_alerting_cases*" RULEN "$WORK/rulefind.json"
  if [ "${RULEN:-0}" != "0" ]; then
    say "      already installed, leaving it alone: $RN"
  else
    #  Kibana answers /api/status a moment before it will accept a rule
    #  creation: for a short window after start-up it refuses internal APIs
    #  and answers "not available with the current configuration".  Waiting for
    #  the status page is therefore not enough on its own, so the call is
    #  retried a few times before it is called a failure.
    RULEOK=0
    i=1
    while [ "$i" -le 6 ]; do
      docurl -o "$WORK/rule-resp.json" -X POST "$KBURL/api/detection_engine/rules" \
             -H "kbn-xsrf: true" -H "Content-Type: application/json" \
             "${KBAUTH[@]}" --data-binary "@$LABDIR/$RF"
      if [ "$CURLCODE" = "200" ]; then RULEOK=1; break; fi
      [ "$i" -lt 6 ] && say "      Kibana is not accepting rules yet, retry $i of 6"
      sleep 5
      i=$((i+1))
    done
    if [ "$RULEOK" != "1" ]; then
      fail "Kibana refused the detection rule $RN, HTTP $CURLCODE" \
           "The log data is still loaded. The reason is in $WORK/rule-resp.json and in  docker logs $SCEN-kibana"
    fi
    say "      installed: $RN"
  fi
  #  The alert count is NOT checked here.  It cannot be: the other two rules are
  #  not installed yet, so the total is still incomplete.  mkrule() polls once,
  #  after all three are in, and insists on the combined total.
}

#  Install all three, then wait for the combined alert count.  The order matters:
#  polling inside the per-rule installer would make rule 1 wait for alerts that
#  rules 2 and 3 have not been given the chance to raise yet.
waitalerts() {
  #  The rules run on a one minute schedule, so the first alerts cannot exist
  #  for up to a minute.  Rather than guess, poll the index the Alerts page
  #  reads and insist on the total the walkthrough quotes.  If this passes, the
  #  page cannot be empty or short, whatever Kibana's UI decides to render.
  ALERTOK=0
  i=1
  while [ "$i" -le 30 ]; do
    docurl -o "$WORK/alerts.json" "${ESAUTH[@]}" "$ESURL/.alerts-security.alerts-default/_count?filter_path=count"
    if [ "$CURLCODE" = "200" ]; then
      n=$(sed 's/[^0-9]//g' < "$WORK/alerts.json" 2>/dev/null || true)
      [ "$n" = "$RULEALERTS" ] && ALERTOK=1
    fi
    if [ "$ALERTOK" = "1" ]; then break; fi
    [ "$i" -gt 1 ] && [ "$i" -lt 30 ] && say "      still waiting for the rules, wait $i of 30"
    sleep 6
    i=$((i+1))
  done
  if [ "$ALERTOK" != "1" ]; then
    fail "the rules are installed but between them have not produced $RULEALERTS alerts" \
         "Nothing was deleted. Check  docker logs $SCEN-kibana  for the rules' execution status, and remember they only match data from the last 365 days."
  fi
}

mkrule() {
  mkone rule.json   "$RULENAME1" "$RULEALERTS1"
  mkone rule-2.json "$RULENAME2" "$RULEALERTS2"
  mkone rule-3.json "$RULENAME3" "$RULEALERTS3"
  waitalerts
  say "      all three rules have fired: $RULEALERTS alerts from 3 rules are on the Alerts page"
}

# ------------------------------------------------------ one index template
puttemplate() {
  TPL=$1
  if [ ! -f "$LABDIR/$TPL.json" ]; then
    fail "the index template $TPL.json is missing" "Nothing was changed."
  fi
  docurl -o "$WORK/tpl-$TPL.json" -X PUT "$ESURL/_index_template/$TPL" \
         -H "Content-Type: application/json" "${ESAUTH[@]}" --data-binary "@$LABDIR/$TPL.json"
  if [ "$CURLCODE" != "200" ] && [ "$CURLCODE" != "201" ]; then
    fail "the index template for $TPL was not accepted, HTTP $CURLCODE" \
         "No data was imported. Fix $TPL.json and run this file again."
  fi
  say "      $TPL template accepted"
}

# ------------------------------------------- import one dataset, idempotent
importone() {
  DS=$1; EXP=$2
  esdocount "$DS-$IDXSUF*" NDC
  if [ "${NDC:-0}" = "0" ]; then
    say "      $DS: no documents loaded yet, importing $EXP documents"
    dopost
  elif [ "${NDC:-0}" = "$EXP" ]; then
    say "      $DS: already fully loaded at $NDC documents, nothing to import"
  elif [ "${NDC:-0}" -gt "$EXP" ]; then
    say "      $DS: index holds $NDC documents, more than the $EXP this lab ships"
    say "      leaving it alone rather than guessing"
  else
    say " ERROR: the $DS index holds $NDC documents but this lab ships $EXP."
    say ""
    say "   Importing now would create duplicates and every count in the"
    say "   walkthrough would be wrong. This script will not import on top of a"
    say "   partial load, and it has deleted nothing."
    say ""
    say "   To rebuild this dataset from scratch"
    say "     ./setup-lab.sh reset"
    say "   or delete the index by hand"
    say "     curl -XDELETE ${ESAUTH[*]} $ESURL/$DS-$IDXSUF"
    say ""
    fail "" "Nothing was deleted."
  fi
  esdocount "$DS-$IDXSUF*" NDC2
  if [ "${NDC2:-0}" != "$EXP" ]; then
    fail "$DS should hold $EXP documents after import but holds ${NDC2:-0}" \
         "Nothing was deleted. The next run will detect this and stop rather than duplicate data."
  fi
  say "      $DS: verified $NDC2 documents in $DS-$IDXSUF"
}

# -------------------------------------------------------- the bulk import
dopost() {
  NDJ="$WORK/bulk-$DS.ndjson"
  : > "$NDJ"
  #  printf, not echo.  Some log lines contain escaped quotes; in a shell whose
  #  echo treats a backslash as an escape (zsh) that silently corrupts a
  #  document and Elasticsearch rejects it.  printf prints the line exactly.
  while IFS= read -r L || [ -n "$L" ]; do
    printf '{"index":{"_index":"%s-%s"}}\n%s\n' "$DS" "$IDXSUF" "$L" >> "$NDJ"
  done < "$LABDIR/$DS.ndjson"
  #  filter_path=errors makes Elasticsearch answer with exactly
  #  {"errors":false} and nothing else - sixteen bytes, with no trailing
  #  newline - so the check is a byte comparison against a file this script
  #  wrote.  The expected file is written without a newline for that reason;
  #  printing one here makes a healthy import look like a failed one.
  docurl -o "$WORK/bulk-$DS.json" -X POST "$ESURL/_bulk?refresh=wait_for&filter_path=errors" \
         -H "Content-Type: application/x-ndjson" "${ESAUTH[@]}" --data-binary "@$NDJ"
  printf '{"errors":false}' > "$WORK/bulkok.txt"
  if ! cmp -s "$WORK/bulkok.txt" "$WORK/bulk-$DS.json"; then
    fail "the bulk import for $DS reported errors, see $WORK/bulk-$DS.json" \
         "No documents were deleted. Run  ./setup-lab.sh reset  and try again."
  fi
  say "      $DS: $EXP documents accepted by Elasticsearch"
}

# ----------------------------------------- create a data view, read it back
#  $1 saved object id   $2 index pattern   $3 file-name-safe spelling
#  $3 exists because * is not a legal character in a path.
mkdataview() {
  DVNAME=$1; DVPAT=$2
  printf '{"attributes":{"title":"%s","timeFieldName":"@timestamp"},"references":[]}\n' "$DVPAT" > "$WORK/dv-$3.json"
  docurl -o "$WORK/dv-resp.json" -X POST "$KBURL/api/saved_objects/index-pattern/$DVNAME?overwrite=true" \
         -H "kbn-xsrf: true" -H "Content-Type: application/json" \
         "${KBAUTH[@]}" --data-binary "@$WORK/dv-$3.json"
  if [ "$CURLCODE" != "200" ]; then
    fail "Kibana refused to create the data view $DVPAT, HTTP $CURLCODE" \
         "The log data is still loaded. Check  docker logs $SCEN-kibana  and run this file again."
  fi
  docurl -o "$WORK/dv-find.json" "${KBAUTH[@]}" \
         "$KBURL/api/saved_objects/_find?type=index-pattern&search_fields=title&search=$DVPAT&fields=title&per_page=50"
  if ! grep -q -F -- "$DVPAT" "$WORK/dv-find.json" 2>/dev/null; then
    say " ERROR: the data view was created but the pattern \"$DVPAT\" was not stored."
    say ""
    say "   A data view with an empty index pattern matches no index at all, so"
    say "   Discover would show zero fields and no results and there would be no"
    say "   visible reason why. That is the most confusing failure mode of this"
    say "   lab, so it is checked here instead of being left for you to find."
    say ""
    say "   Fix it with"
    say "     ./setup-lab.sh reset"
    say ""
    fail "" "The log data was not touched."
  fi
  say "      data view \"$DVPAT\" verified, time field @timestamp"
}

# ---------------------------------------- final end-to-end truth verification
verify() {
  say " [verify] reading every walkthrough count back out of Elasticsearch"
  #  Every KQL string is written to its own file first and handed to vqcount as
  #  a file name.  That is deliberate and it is the whole reason this works:
  #  cmd.exe has no backslash escape, so a double quote inside a quoted argument
  #  to CALL comes out of the argument with its quotes eaten and its backslashes
  #  kept, which silently turns the JSON into something Elasticsearch answers
  #  with 400.  A file has no such problem, and the quotes have to be
  #  backslash-escaped for the JSON string anyway.
  printf 'match_all\n'                                                            > "$WORK/k0.txt"
  printf 'event.code: 4688 and process.name: \\"powershell.exe\\" and process.parent.name: \\"wmiprvse.exe\\"\n' > "$WORK/kq1.txt"
  printf 'event.code: 4688 and process.name: \\"xmrig.exe\\"\n'                     > "$WORK/kq2.txt"
  printf 'event.action: \\"network_connection\\" and destination.port: %s and network.bytes < 2048\n' "$POOLPORT"                                          > "$WORK/kq3.txt"
  printf 'event.code: 4688\n'                                                      > "$WORK/k1.txt"
  printf 'event.code: 4625\n'                                                      > "$WORK/k2.txt"
  printf 'event.code: 4688 and process.name: \\"powershell.exe\\"\n'               > "$WORK/k3.txt"
  printf 'event.code: 4624 and user.name: \\"svc_backup\\" and host.name: \\"%s\\"\n' "$VICTIM"   > "$WORK/k4.txt"
  printf 'event.code: 4688 and host.name: \\"%s\\"\n'                 "$VICTIM"   > "$WORK/k5.txt"
  printf 'event.action: \\"dns_query\\"\n'                                          > "$WORK/k6.txt"
  printf 'source.ip: \\"%s\\" and destination.ip: \\"%s\\" and destination.port: %s\n' \
         "$VICTIMIP" "$POOLIP" "$POOLPORT"                                         > "$WORK/k7.txt"
  vqcount "auth-*"    "every document in the auth data view"    "$AUTHDOCS" k0.txt || return 1
  vqcount "network-*" "every document in the network data view" "$NETDOCS"  k0.txt || return 1
  vqcount "auth-*"    "rule 1's own query, and so its alert"    "$DQ1"    kq1.txt || return 1
  vqcount "auth-*"    "rule 2's own query, and so its alert"    "$DQ2"    kq2.txt || return 1
  vqcount "network-*" "rule 3's own query, and so its alerts"   "$DQ3"    kq3.txt || return 1
  vqcount "auth-*"    "query 1  the estate's whole day"           "$D1"     k1.txt || return 1
  vqcount "auth-*"    "query 2  the failed-logon dead end"       "$D2"     k2.txt || return 1
  vqcount "auth-*"    "query 3  every powershell start"          "$D3"     k3.txt || return 1
  vqcount "auth-*"    "query 4  the entry point"                 "$D4"     k4.txt || return 1
  vqcount "auth-*"    "query 5  the delivery chain"              "$D5"     k5.txt || return 1
  vqcount "network-*" "query 6  the day's dns lookups"           "$D6"     k6.txt || return 1
  vqcount "network-*" "query 7  the pool heartbeat"              "$D7"     k7.txt || return 1
  verifyviews || return 1
  say " [verify] every number the walkthrough quotes matches the live index."
  say ""
}

# ------------------- assert one count, so no number is typed in two places
#  $4 is a file in $WORK holding one KQL string, with its inner double quotes
#  already backslash-escaped for the JSON string they land in.
vqcount() {
  VQIDX=$1; VQLBL=$2; VQEXP=$3; VQKQ=""
  VQKQ=$(cat "$WORK/$4")
  #  The literal word match_all means "count everything in the index".  KQL
  #  happens to treat a bare "*" the same way, so either spelling returns the
  #  same count; the explicit word is here so that "count everything" is stated
  #  as a match_all query and does not depend on a wildcard in a fieldless
  #  position staying meaningful.
  if [ -z "$VQKQ" ] || [ "$VQKQ" = "match_all" ]; then
    printf '{"size":0,"track_total_hits":true,"query":{"match_all":{}}}\n' > "$WORK/vq.json"
  else
    printf '{"size":0,"track_total_hits":true,"query":{"kql":{"query":"%s"}}}\n' "$VQKQ" > "$WORK/vq.json"
  fi
  eskqlcount "$VQIDX" VQCNT || return 1
  if [ "${VQCNT:-0}" != "$VQEXP" ]; then
    say " MISMATCH  $VQLBL"
    say "           expected $VQEXP but the index reports ${VQCNT:-0}"
    fail "a count quoted in the walkthrough does not match the loaded data" \
         "Nothing was deleted. Run  ./setup-lab.sh reset  to rebuild the data exactly as shipped."
  fi
  say "      $VQLBL   =  $VQCNT"
}

# ------------------------------- both data views must actually serve fields
#  This is the strongest check available over a public API. It asks Kibana's
#  own data view service to resolve the saved object against Elasticsearch,
#  which is the same resolution Discover performs. A pattern that matched
#  nothing would come back 404 here, because the data view is created with
#  allowNoIndex switched off on purpose.
verifyviews() {
  vdcheck auth    "auth-*"    "process.name" || return 1
  vdcheck network "network-*" "network.protocol" || return 1
}

vdcheck() {
  docurl -o "$WORK/vd-$1.json" "${KBAUTH[@]}" "$KBURL/api/data_views/data_view/$SCEN-$1" -H "kbn-xsrf: true"
  if [ "$CURLCODE" != "200" ]; then
    say ""
    say " ERROR: Kibana cannot resolve the \"$2\" data view, HTTP $CURLCODE."
    say ""
    say "   The saved object exists but its index pattern matches no index, or"
    say "   Kibana cannot read the mapping. Discover would show zero fields and"
    say "   no results and there would be no visible reason why."
    say ""
    say "   Rebuild it with"
    say "     ./setup-lab.sh reset"
    say ""
    fail "" "The log data was not touched."
  fi
  #  These three checks look for a bare word rather than for a quoted JSON key.
  #  In the .cmd twin that is also how it is done, because cmd.exe has no
  #  backslash escape and findstr /c:"\"title\":..." never matches.  Each bare
  #  word occurs in this response only when the thing it names is really there:
  #  the pattern appears once, in the title; the time field key appears once;
  #  the field name appears only inside the resolved mapping.
  if ! grep -q -F -- "$2" "$WORK/vd-$1.json" 2>/dev/null; then
    fail "the $2 data view did not resolve to the pattern $2" \
         "The log data was not touched. Run  ./setup-lab.sh reset  to rebuild the data view."
  fi
  if ! grep -q -F -- "timeFieldName" "$WORK/vd-$1.json" 2>/dev/null; then
    fail "the $2 data view has no @timestamp time field" \
         "The log data was not touched. Run  ./setup-lab.sh reset  to rebuild the data view."
  fi
  if ! grep -q -F -- "$3" "$WORK/vd-$1.json" 2>/dev/null; then
    fail "the $2 data view does not expose the field $3 to Discover" \
         "The log data was not touched. Run  ./setup-lab.sh reset  to rebuild the data view."
  fi
  say "      data view $2 resolves, time field @timestamp, field $3 present"
}

# --------------------------- ES helper: document count of one dataset
#  The refresh is not optional.  A bulk write is not visible to a count until
#  the index refreshes, so without this a successful import reads back as zero
#  and a re-run would import the data a second time.
#  $3 is an optional query body.  Without it this is a plain count of
#  everything in the index; with one it counts only what matches, which is how
#  mkrule asks "is this rule already installed".
esdocount() {
  EDIDX=$1; EDVAR=$2; EDQ=${3:-}
  EDCNTURL="$ESURL/$EDIDX/_count?allow_no_indices=true&filter_path=count"
  docurl -o /dev/null -X POST "${ESAUTH[@]}" "$ESURL/$EDIDX/_refresh"
  if [ -n "$EDQ" ]; then
    docurl -o "$WORK/cnt.json" "${ESAUTH[@]}" -X POST -H "Content-Type: application/json" --data-binary "@$EDQ" "$EDCNTURL"
  else
    docurl -o "$WORK/cnt.json" "${ESAUTH[@]}" "$EDCNTURL"
  fi
  if [ "$CURLCODE" != "200" ]; then
    fail "could not read the document count of $EDIDX, HTTP $CURLCODE" "Nothing was changed."
  fi
  EDVAL=$(sed 's/[^0-9]//g' < "$WORK/cnt.json" 2>/dev/null || true)
  [ -z "$EDVAL" ] && EDVAL=0
  eval "$EDVAR=\$EDVAL"
}

# ------------- ES helper: total hits for the query body in $WORK/vq.json
#  filter_path collapses the reply to {"hits":{"total":{"value":N}}}
eskqlcount() {
  EKIDX=$1; EKVAR=$2
  docurl -o /dev/null -X POST "${ESAUTH[@]}" "$ESURL/$EKIDX/_refresh"
  docurl -o "$WORK/vq.json.out" "${ESAUTH[@]}" "$ESURL/$EKIDX/_search?filter_path=hits.total.value" \
         -X POST -H "Content-Type: application/json" --data-binary "@$WORK/vq.json"
  if [ "$CURLCODE" != "200" ]; then
    fail "a verification query against $EKIDX was rejected, HTTP $CURLCODE" \
         "Nothing was deleted. The query text is in $WORK/vq.json"
  fi
  EKVAL=$(sed 's/[^0-9]//g' < "$WORK/vq.json.out" 2>/dev/null || true)
  [ -z "$EKVAL" ] && EKVAL=0
  eval "$EKVAR=\$EKVAL"
}

# ------------ HTTP helper that captures the status code, so every call asserts
#  Same argument shape as the .cmd version: the caller supplies -o itself, so
#  the body lands wherever the caller asked and only the status code comes back
#  on stdout.  CURLCODE is set to 000 when curl could not reach the server at
#  all, which is the case the guards in this script care about most.
docurl() {
  local code
  code=$(curl -s -w '%{http_code}' "$@" 2>/dev/null) || true
  case "$code" in
    [0-9][0-9][0-9]) CURLCODE=$code ;;
    *)               CURLCODE=000 ;;
  esac
}

# ------------------------------------------------------------ log dumps
dumpeslog() {
  say ""
  say " ---- last 40 lines of the Elasticsearch log ----"
  docker logs --tail 40 "$SCEN-elasticsearch" 2>&1
  say " -----------------------------------------------------"
}

dumpkblog() {
  say ""
  say " ---- last 40 lines of the Kibana log ----"
  docker logs --tail 40 "$SCEN-kibana" 2>&1
  say " -----------------------------------------------------"
}

# ------------------------------------------------------ one honest failure
fail() {
  say ""
  say " =============================================================="
  say "  FAILED:  $1"
  say ""
  [ -n "$2" ] && say "  $2"
  say ""
  say "  Nothing outside this $SCEN lab was touched, and no data was deleted."
  say "  Docker images were kept, so the next run starts faster."
  say ""
  say "  Scratch files :  $WORK"
  say "  What is running:  docker ps -a"
  say "  Compose file :  $COMPOSEFILE"
  say ""
  say " =============================================================="
  say ""
  pause
  exit 1
}

# ===========================================================================
#  M A I N
# ===========================================================================
preflight

case "$MODE" in
  reset) do_reset ;;
  regen) mkcompose ;;
  setup)
    if [ -f "$COMPOSEFILE" ]; then
      say " [compose] docker-compose.yml already present, reusing it"
    else
      mkcompose
    fi
    ;;
esac

guardcluster
checkmoved

# =========================================================== 1. bring up ES
#  Elasticsearch first, on its own. Kibana needs the lab account to exist
#  before it starts: it refuses to boot against a cluster it cannot
#  authenticate to, and it refuses to run as the elastic superuser, so there
#  is no order in which compose could start both and have Kibana wait.
#  Splitting the two is the only way this works unattended.
say " [1/10] starting Elasticsearch in Docker"
$DC -f "$COMPOSEFILE" up -d elasticsearch || fail "docker compose up failed" "No data was changed."
say ""

# ============================================================= 2. wait: ES
say " [2/10] waiting for Elasticsearch to answer"
ESOK=0
i=1
while [ "$i" -le 60 ]; do
  if [ "$ESOK" = "0" ]; then
    docurl -o "$WORK/eshealth.json" "${ESAUTH[@]}" "$ESURL/_cluster/health"
    if [ "$CURLCODE" = "200" ] && grep -q -F -- "$SCEN" "$WORK/eshealth.json" 2>/dev/null; then
      ESOK=1; break
    else
      sleep 3
      [ "$i" -gt 2 ] && [ "$i" -lt 60 ] && say "      still starting, attempt $i of 60"
    fi
  fi
  i=$((i+1))
done
if [ "$ESOK" != "1" ]; then
  dumpeslog
  fail "Elasticsearch did not become ready in time" \
       "The containers are still running so you can inspect them:  docker logs $SCEN-elasticsearch"
fi
say "      Elasticsearch is ready."
say ""

# ================================================== 3. the lab account
say " [3/10] creating the lab account that Kibana and curl both use"
mkaccount
say ""

# ====================================================== 4. bring up Kibana
say " [4/10] starting Kibana in Docker"
$DC -f "$COMPOSEFILE" up -d kibana || fail "docker compose up kibana failed" "The log data has not been touched."
say ""

# ========================================================== 5. wait: Kibana
say " [5/10] waiting for Kibana to finish starting"
KBOK=0
i=1
while [ "$i" -le 150 ]; do
  if [ "$KBOK" = "0" ]; then
    docurl -o "$WORK/kbstatus.json" "${KBAUTH[@]}" "$KBURL/api/status"
    if [ "$CURLCODE" = "200" ] && grep -q -F -- "available" "$WORK/kbstatus.json" 2>/dev/null; then
      KBOK=1; break
    else
      sleep 4
      [ "$i" -gt 2 ] && [ "$i" -lt 150 ] && say "      still starting, attempt $i of 150"
    fi
  fi
  i=$((i+1))
done
if [ "$KBOK" != "1" ]; then
  dumpkblog
  fail "Kibana did not become ready in time" \
       "The containers are still running so you can inspect them:  docker logs $SCEN-kibana"
fi
say "      Kibana is available."
say ""

# ======================================================= 6. index templates
say " [6/10] installing the index templates, which is what fixes the field types"
puttemplate auth
puttemplate network
say ""

# ============================================================ 7. import data
say " [7/10] checking the datasets"
[ -f "$LABDIR/auth.ndjson" ]   || fail "auth.ndjson is missing from $LABDIR"   "Nothing was changed."
[ -f "$LABDIR/network.ndjson" ] || fail "network.ndjson is missing from $LABDIR" "Nothing was changed."
importone auth   "$AUTHDOCS"
importone network "$NETDOCS"
say ""

# ============================================================= 8. data views
say " [8/10] creating the Kibana data views"
mkdataview "$SCEN-auth"    "auth-*"    auth
mkdataview "$SCEN-network" "network-*" network
say ""

# ================================================ 9. the detection rules
say " [9/10] installing the three detection rules, so the Alerts page has something"
mkrule
say ""

# ============================================== 10. end-to-end truth verify
verify

# ================================================================== done
say " =============================================================="
say "   The lab is ready."
say ""
say "   Elasticsearch : $ESURL"
say "   Kibana        : $KBURL"
say "   data view \"auth\"     index pattern auth-*"
say "   data view \"network\"  index pattern network-*"
say ""
say "   The stack has security switched on, so there are two things to type."
say "   They are lab credentials. They protect nothing."
say ""
say "     Kibana login   $KBUSER  /  $KBPASS"
say "     in curl        -u $KBUSER:$KBPASS"
say ""
say "   Times in the data are stored in UTC. Kibana prints them in your own"
say "   computer's timezone, so read the clock times off your own screen and"
say "   judge the gaps between events, not the absolute numbers."
say ""
say " ---------------- the investigation queries, in order ---------------"
say ""
say "   Data view   auth-*"
saycount "     1   event.code: 4688" "$D1"
saycount "     2   event.code: 4625" "$D2"
saycount "     3   event.code: 4688 and process.name: \"powershell.exe\"" "$D3"
say "     4   event.code: 4624 and user.name: \"svc_backup\""
saycount "        and host.name: \"$VICTIM\"" "$D4"
saycount "     5   event.code: 4688 and host.name: \"$VICTIM\"" "$D5"
say ""
say "   Data view   network-*"
saycount "     6   event.action: \"dns_query\"" "$D6"
say "     7   source.ip: \"$VICTIMIP\" and destination.ip: \"$POOLIP\""
saycount "        and destination.port: $POOLPORT" "$D7"
say ""
say "   Time range for every query"
say "     2026-09-22 00:00:00.000  to  2026-09-22 23:59:59.999   (UTC)"
say ""
say "   The three rules that fired, and the queries they ran"
say "     Security -> Alerts                     $RULEALERTS alerts from 3 rules"
say ""
say "     1  $RULENAME1"
say "          $RULEKQL1L1"
saycount "            $RULEKQL1L2" "$RULEALERTS1"
say ""
say "     2  $RULENAME2"
saycount "          $RULEKQL2L1" "$RULEALERTS2"
say ""
say "     3  $RULENAME3"
say "          $RULEKQL3L1"
saycount "            $RULEKQL3L2" "$RULEALERTS3"
say " ---------------------------------------------------------------------"
say ""
say "   Stop the lab but keep the data"
say "     $DC -f docker-compose.yml down"
say ""
say "   Remove the lab completely"
say "     ./teardown.sh"
say ""
say " =============================================================="
say ""

if [ "$LAUNCH" = "1" ]; then
  say " Opening Kibana in your default browser..."
  say " Log in with  $KBUSER  /  $KBPASS"
  openbrowser "$KBURL/app/security/alerts"
fi
pause
exit 0
