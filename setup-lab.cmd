@echo off
setlocal EnableExtensions EnableDelayedExpansion
title setup-lab.cmd  -  %~n0

rem ===========================================================================
rem  setup-lab.cmd  --  one-click lab build for this scenario folder
rem
rem    setup-lab.cmd                create / update the lab, then open the browser
rem    setup-lab.cmd reset          remove containers, volume and data views, rebuild
rem    setup-lab.cmd regen-compose  rewrite docker-compose.yml, then set up
rem    setup-lab.cmd nolaunch       set up but do not open the browser
rem    setup-lab.cmd -?             this list
rem
rem  Every Docker object name is derived from the folder name, so this lab can
rem  live next to other scenario labs on one machine without colliding, and so
rem  teardown.cmd can prove exactly what it is allowed to delete.
rem
rem  There is a Linux / macOS twin of this file, setup-lab.sh, in the same
rem  folder. It does exactly the same thing in exactly the same order. If you
rem  change one, change the other, or a Windows lab and a Mac lab quietly stop
rem  being the same lab.
rem ===========================================================================

rem ------------------------------------------------------------------ settings
set "ESPORT=9200"
set "KBPORT=5601"
set "ESIMAGE=docker.elastic.co/elasticsearch/elasticsearch:9.1.0"
set "KBIMAGE=docker.elastic.co/kibana/kibana:9.1.0"

set "IDXSUF=2026.09.22"
set "AUTHDOCS=271"
set "NETDOCS=149"

rem  The three literals the guided walkthrough tells the student to read out of
rem  their own results and then use.  They are here only so the verification
rem  pass can replay the exact queries the guide quotes; the guide never hands
rem  them over before the student has found them.
set "VICTIM=sec-win-05"
set "VICTIMIP=10.0.4.30"
set "POOLIP=198.51.100.77"
set "POOLPORT=3333"

rem  One expected count per query the walkthrough quotes, in the order the
rem  walkthrough asks for them.  Every one of these is asserted against the live
rem  index below, so a lab that reaches "ready" is a lab whose numbers can be
rem  trusted.
set "D1=21"   rem  event.code: 4688                               the estate's whole day
set "D2=51"   rem  event.code: 4625                               failed logons, the dead end
set "D3=5"    rem  event.code: 4688 and process.name: powershell   the sharper trap
set "D4=1"    rem  event.code: 4624 + svc_backup + the victim      the entry point
set "D5=2"    rem  event.code: 4688 and host.name: the victim      the one-shot, the chain
set "D6=32"   rem  event.action: dns_query                        the day's lookups
set "D7=4"    rem  the recurring pool sessions                    the heartbeat
set "DQ1=1"   rem  rule 1's own query, which has to agree with the alert it raises
set "DQ2=1"   rem  rule 2's own query, which has to agree with the alert it raises
set "DQ3=4"   rem  rule 3's own query: four keepalives, one ongoing operation

rem ------------------------------------------------------------------ accounts
rem  Security has to be on. A detection rule cannot be created against a
rem  cluster that has it off: Elasticsearch has no rule API in that mode and
rem  Kibana refuses the rule call, so the Alerts page would always be empty.
rem  These two accounts are throwaway lab credentials. They are printed on
rem  screen and typed into curl by the student; they protect nothing.
rem  ESBOOT is only used once, to create the account Kibana runs as. Kibana
rem  refuses to run as the built-in elastic superuser, and a plain superuser
rem  cannot create the .kibana* saved-object indices, so the account also
rem  carries the built-in kibana_system role.
set "ESBOOT=LabElastic001"
set "ESUSER=elastic"
set "ESPASS=LabElastic001"
set "KBUSER=lab_kibana"
set "KBPASS=LabKibana001"

rem  the three detection rules, and the number of alerts each must produce
set "RULENAME1=PowerShell started by a remote-execution service"
set "RULENAME2=Known cryptominer binary started on a server"
set "RULENAME3=Tiny outbound keepalives on a single non-standard port"
set "RULEALERTS1=1"
set "RULEALERTS2=1"
set "RULEALERTS3=4"
set "RULEALERTS=6"
set "RULEKQL=event.code: 4688 and process.name: \"powershell.exe\" and process.parent.name: \"wmiprvse.exe\""

rem ------------------------------------------------------ identity from folder
for %%I in ("%~dp0.") do set "SCEN=%%~nI"
set "LABDIR=%~dp0"
if "%LABDIR:~-1%"=="\" set "LABDIR=%LABDIR:~0,-1%"
set "VOL=%SCEN%_esdata"
set "WORK=%TEMP%\elklab-%SCEN%"
set "ESURL=http://127.0.0.1:%ESPORT%"
set "KBURL=http://127.0.0.1:%KBPORT%"
set "COMPOSEFILE=%LABDIR%\docker-compose.yml"

rem  every Elasticsearch call is made as the bootstrap superuser, every Kibana
rem  call as the account Kibana itself runs as. Both are kept in variables so
rem  that a password containing a character cmd likes to argue about - ! ^ & -
rem  only ever has to be fixed in one place.
set "ESAUTH=-u %ESUSER%:%ESPASS%"
set "KBAUTH=-u %KBUSER%:%KBPASS%"

set "MODE=setup"
set "LAUNCH=1"
:parseargs
if not "%~1"=="" (
  set "A=%~1"
  if /i "!A!"=="reset"          set "MODE=reset"
  if /i "!A!"=="regen-compose"  set "MODE=regen"
  if /i "!A!"=="nolaunch"       set "LAUNCH=0"
  if /i "!A!"=="-?"             goto :usage
  if /i "!A!"=="--help"         goto :usage
  if /i "!A!"=="help"           goto :usage
  shift
  goto :parseargs
)
goto :start

rem ------------------------------------------------------------------- usage
:usage
echo.
echo  ==============================================================
echo   setup-lab.cmd  -  build the "%SCEN%" lab
echo  ==============================================================
echo.
echo    setup-lab.cmd                create or update the lab, open the browser
echo    setup-lab.cmd reset          remove containers, volume and data views, rebuild
echo    setup-lab.cmd regen-compose  rewrite docker-compose.yml, then set up
echo    setup-lab.cmd nolaunch       set up but do not open the browser
echo    setup-lab.cmd -?             this list
echo.
echo  Docker images are downloaded once and then kept, so the second run of
echo  this script is fast. Nothing outside this scenario is ever touched.
echo.
pause
exit /b 0

:start
echo.
echo  ==============================================================
echo   Scenario lab   :  %SCEN%
echo   Elasticsearch  :  %ESURL%
echo   Kibana         :  %KBURL%
echo   Scratch folder :  %WORK%
echo  ==============================================================
echo.

rem ---------------------------------------------------------------- preflight
call :preflight
if errorlevel 1 exit /b 1

if "!MODE!"=="reset" goto :do_reset
if "!MODE!"=="regen" goto :do_regen
goto :do_setup

rem ===========================================================================
rem  reset
rem ===========================================================================
:do_reset
echo  [reset] removing whatever a previous run of this lab left behind
if exist "%COMPOSEFILE%" docker compose -f "%COMPOSEFILE%" down -v --remove-orphans >nul 2>&1
docker volume rm -f "%VOL%" >nul 2>&1
docker rm -f "%SCEN%-elasticsearch" "%SCEN%-kibana" >nul 2>&1
echo  [reset] done.
echo.

rem ===========================================================================
rem  compose generation
rem ===========================================================================
:do_regen
echo  [compose] rewriting docker-compose.yml from the settings in this script
call :mkcompose
if errorlevel 1 exit /b 1
goto :do_setup

:do_setup
if exist "%COMPOSEFILE%" (
  echo  [compose] docker-compose.yml already present, reusing it
) else (
  call :mkcompose
  if errorlevel 1 exit /b 1
)

rem --------------------------------------------- refuse a cluster we did not make
call :guardcluster
if errorlevel 1 exit /b 1

rem --------------------------------------- warn, never destroy, on a moved copy
call :checkmoved
if errorlevel 1 exit /b 1

rem =========================================================== 1. bring up ES
rem     Elasticsearch first, on its own. Kibana needs the lab account to exist
rem     before it starts: it refuses to boot against a cluster it cannot
rem     authenticate to, and it refuses to run as the elastic superuser, so
rem     there is no order in which compose could start both and have Kibana
rem     wait. Splitting the two is the only way this works unattended.
echo  [1/10] starting Elasticsearch in Docker
docker compose -f "%COMPOSEFILE%" up -d elasticsearch
if errorlevel 1 (
  call :fail "docker compose up failed" "No data was changed."
  exit /b 1
)
echo.

rem ============================================================= 2. wait: ES
echo  [2/10] waiting for Elasticsearch to answer
set "ESOK="
for /l %%i in (1,1,60) do (
  if not defined ESOK (
    call :docurl -s -o "%WORK%\eshealth.json" %ESAUTH% "%ESURL%/_cluster/health"
    rem  Exclamation marks here, not percent signs.  cmd.exe expands a percent
    rem  variable once, when it parses this whole block, and then runs the
    rem  frozen text on every iteration.  The status code is produced by
    rem  :docurl INSIDE the block, so a percent read would keep comparing the
    rem  code from before the loop started -- always stale, and on a first run
    rem  always "no connection", which made a perfectly healthy Elasticsearch
    rem  look like it had failed to start.  Delayed expansion is re-evaluated
    rem  on each pass, which is what is wanted here.
    if "!CURLCODE!"=="200" findstr /c:"%SCEN%" "%WORK%\eshealth.json" >nul 2>&1 && set "ESOK=1"
    if not defined ESOK (
      ping -n 3 127.0.0.1 >nul 2>&1
      if %%i gtr 2 if %%i lss 60 echo       still starting, attempt %%i of 60
    )
  )
)
if not defined ESOK (
  call :dumpeslog
  call :fail "Elasticsearch did not become ready in time" "The containers are still running so you can inspect them:  docker logs %SCEN%-elasticsearch"
  exit /b 1
)
echo       Elasticsearch is ready.
echo.

rem ================================================== 3. the lab account
echo  [3/10] creating the lab account that Kibana and curl both use
call :mkaccount
if errorlevel 1 exit /b 1
echo.

rem ====================================================== 4. bring up Kibana
echo  [4/10] starting Kibana in Docker
docker compose -f "%COMPOSEFILE%" up -d kibana
if errorlevel 1 (
  call :fail "docker compose up kibana failed" "The log data has not been touched."
  exit /b 1
)
echo.

rem ========================================================== 5. wait: Kibana
echo  [5/10] waiting for Kibana to finish starting
set "KBOK="
for /l %%i in (1,1,150) do (
  if not defined KBOK (
    call :docurl -s -o "%WORK%\kbstatus.json" %KBAUTH% "%KBURL%/api/status"
    if "!CURLCODE!"=="200" findstr /c:"available" "%WORK%\kbstatus.json" >nul 2>&1 && set "KBOK=1"
    if not defined KBOK (
      ping -n 4 127.0.0.1 >nul 2>&1
      if %%i gtr 2 if %%i lss 150 echo       still starting, attempt %%i of 150
    )
  )
)
if not defined KBOK (
  call :dumpkblog
  call :fail "Kibana did not become ready in time" "The containers are still running so you can inspect them:  docker logs %SCEN%-kibana"
  exit /b 1
)
echo       Kibana is available.
echo.

rem ======================================================= 6. index templates
echo  [6/10] installing the index templates, which is what fixes the field types
call :puttemplate auth
if errorlevel 1 exit /b 1
call :puttemplate network
if errorlevel 1 exit /b 1
echo.

rem ============================================================ 7. import data
echo  [7/10] checking the datasets
if not exist "%LABDIR%\auth.ndjson"   (call :fail "auth.ndjson is missing from %LABDIR%"   "Nothing was changed." & exit /b 1)
if not exist "%LABDIR%\network.ndjson" (call :fail "network.ndjson is missing from %LABDIR%" "Nothing was changed." & exit /b 1)
call :importone auth   %AUTHDOCS%
if errorlevel 1 exit /b 1
call :importone network %NETDOCS%
if errorlevel 1 exit /b 1
echo.

rem ============================================================= 8. data views
echo  [8/10] creating the Kibana data views
call :mkdataview "%SCEN%-auth"    "auth-*"     auth    %AUTHDOCS%
if errorlevel 1 exit /b 1
call :mkdataview "%SCEN%-network" "network-*"  network %NETDOCS%
if errorlevel 1 exit /b 1
echo.

rem ================================================ 9. the detection rules
echo  [9/10] installing the three detection rules, so the Alerts page has something
call :mkrule
if errorlevel 1 exit /b 1
echo.

rem ============================================== 10. end-to-end truth verify
call :verify
if errorlevel 1 exit /b 1

rem ================================================================= 11. done
echo  ==============================================================
echo    The lab is ready.
echo.
echo    Elasticsearch : %ESURL%
echo    Kibana        : %KBURL%
echo    data view "auth"     index pattern auth-*
echo    data view "network"  index pattern network-*
echo.
echo    The stack has security switched on, so there are two things to type.
echo    They are lab credentials. They protect nothing.
echo.
echo      Kibana login   %KBUSER%  /  %KBPASS%
echo      in curl        -u %KBUSER%:%KBPASS%
echo.
echo    Times in the data are stored in UTC. Kibana prints them in your own
echo    computer's timezone, so read the clock times off your own screen and
echo    judge the gaps between events, not the absolute numbers.
echo.
echo  ---------------- the investigation queries, in order ---------------
echo.
echo    Data view   auth-*
echo      1   event.code: 4688                                                     = %D1%
echo      2   event.code: 4625                                                     = %D2%
echo      3   event.code: 4688 and process.name: "powershell.exe"                  = %D3%
echo      4   event.code: 4624 and user.name: "svc_backup"
echo         and host.name: "%VICTIM%"                                             = %D4%
echo      5   event.code: 4688 and host.name: "%VICTIM%"                           = %D5%
echo.
echo    Data view   network-*
echo      6   event.action: "dns_query"                                            = %D6%
echo      7   source.ip: "%VICTIMIP%" and destination.ip: "%POOLIP%"
echo         and destination.port: %POOLPORT%                                      = %D7%

echo    Time range for every query
echo      2026-09-22 00:00:00.000  to  2026-09-22 23:59:59.999   (UTC)
echo.
echo    The three rules that fired, and the queries they ran
echo      Security -^> Alerts                     %RULEALERTS% alerts from 3 rules
echo.
echo      1  %RULENAME1%
echo           event.code: 4688 and process.name: "powershell.exe"
echo             and process.parent.name: "wmiprvse.exe"                           = %RULEALERTS1%
echo.
echo      2  %RULENAME2%
echo           event.code: 4688 and process.name: "xmrig.exe"                      = %RULEALERTS2%
echo.
echo      3  %RULENAME3%
echo           event.action: "network_connection" and destination.port: %POOLPORT%
echo             and network.bytes < 2048                                          = %RULEALERTS3%
echo  ---------------------------------------------------------------------
echo.
echo    Stop the lab but keep the data
echo      docker compose -f docker-compose.yml down
echo.
echo    Remove the lab completely
echo      teardown.cmd
echo.
echo  ==============================================================
echo.

if "%LAUNCH%"=="1" (
  echo  Opening Kibana in your default browser...
  echo  Log in with  %KBUSER%  /  %KBPASS%
  start "" "%KBURL%/app/security/alerts"
)
echo  Press any key to close this window.
pause >nul
exit /b 0


rem ===========================================================================
rem  S U B R O U T I N E S
rem ===========================================================================

rem ---------------------------------------------------------------- preflight
:preflight
if not exist "%WORK%" mkdir "%WORK%" >nul 2>&1
if not exist "%WORK%" (
  call :fail "cannot create the scratch folder %WORK%" "Nothing was changed."
  exit /b 1
)
where docker >nul 2>&1
if errorlevel 1 (
  echo  ERROR: "docker" was not found on this computer.
  echo.
  echo    This lab runs Elasticsearch and Kibana inside Docker containers.
  echo    Install Docker Desktop, start it, wait until it says "Engine running",
  echo    then run this file again.
  echo.
  call :fail "" "Nothing was changed."
  exit /b 1
)
set "DVER="
for /f "usebackq delims=" %%v in (`docker version --format "{{.Server.Version}}" 2^>nul`) do if not defined DVER set "DVER=%%v"
if not defined DVER (
  echo  ERROR: Docker is installed but the engine is not responding.
  echo.
  echo    Open Docker Desktop and wait until it says "Engine running", then run
  echo    this file again.
  echo.
  call :fail "" "Nothing was changed."
  exit /b 1
)
echo  [preflight] docker engine version !DVER!
echo  [preflight] every object will be named from the folder name "%SCEN%"
exit /b 0

rem ------------------------------------------- refuse somebody else's cluster
:guardcluster
if not exist "%COMPOSEFILE%" (
  call :fail "docker-compose.yml is missing" "Run  setup-lab.cmd regen-compose  to rewrite it."
  exit /b 1
)
call :docurl -s -o "%WORK%\guard.json" %ESAUTH% "%ESURL%/_cluster/health"
if "%CURLCODE%"=="000" exit /b 0
if "%CURLCODE%"=="401" exit /b 0
findstr /c:"%SCEN%" "%WORK%\guard.json" >nul 2>&1
if not errorlevel 1 exit /b 0
echo  ERROR: something else is already using port %ESPORT%.
echo.
echo    An Elasticsearch is answering on %ESURL%, but it is not the cluster
echo    this lab created, so its name is not "%SCEN%". This script will not
echo    touch a cluster it did not start, and it has changed nothing.
echo.
echo    Fix it one of these ways
echo      - stop the other stack, find it with   docker ps
echo      - change ESPORT and KBPORT at the top of setup-lab.cmd and re-run
echo      - run teardown.cmd inside the folder that owns the other cluster
echo.
echo    For the record, that other cluster says:
type "%WORK%\guard.json" | findstr /c:"cluster_name"
echo.
call :fail "another lab is already using port %ESPORT%" "Nothing was changed."
exit /b 1

rem ------------------------------- warn, never destroy, on a moved copy of self
:checkmoved
docker inspect "%SCEN%-elasticsearch" --format "{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}" >"%WORK%\moved.txt" 2>&1
if errorlevel 1 exit /b 0
set "MOVED="
for /f "usebackq delims=" %%v in ("%WORK%\moved.txt") do if not defined MOVED set "MOVED=%%v"
if not defined MOVED exit /b 0
if /i "!MOVED!"=="%LABDIR%" exit /b 0
echo  WARNING: a container called "%SCEN%-elasticsearch" already exists, and it
echo            was created from a different folder.
echo.
echo    existing container : %SCEN%-elasticsearch
echo    created from       : !MOVED!
echo    this folder        : %LABDIR%
echo.
docker inspect "%SCEN%-elasticsearch" --format "    status {{.State.Status}}   image {{.Config.Image}}" 2>&1
docker inspect "%SCEN%-elasticsearch" --format "    volume {{range .Mounts}}{{.Name}}{{end}}" 2>&1
docker inspect "%SCEN%-elasticsearch" --format "    ports  {{range $p, $c := .NetworkSettings.Ports}}{{$p}}->{{$c}}{{println}}{{end}}" 2>&1
echo.
echo    This usually means the lab folder was copied. setup-lab.cmd will NOT
echo    destroy the other copy. To start over on purpose, remove it yourself:
echo.
echo      docker rm -f "%SCEN%-elasticsearch" "%SCEN%-kibana"
echo      docker volume rm -f "%VOL%"
echo.
echo    or run  teardown.cmd  which lists and confirms before it deletes.
echo.
call :fail "" "Nothing was deleted."
exit /b 1

rem ------------------------------- write docker-compose.yml from this script
:mkcompose
>  "%COMPOSEFILE%" echo # Generated by setup-lab.cmd
>  "%COMPOSEFILE%" echo # Every name and port below is derived from the folder this file
>  "%COMPOSEFILE%" echo # lives in, so the file is safe to delete and regenerate:
>  "%COMPOSEFILE%" echo #     setup-lab.cmd regen-compose
>> "%COMPOSEFILE%" echo name: %SCEN%
>> "%COMPOSEFILE%" echo services:
>> "%COMPOSEFILE%" echo   elasticsearch:
>> "%COMPOSEFILE%" echo     image: %ESIMAGE%
>> "%COMPOSEFILE%" echo     container_name: %SCEN%-elasticsearch
>> "%COMPOSEFILE%" echo     environment:
>> "%COMPOSEFILE%" echo       - node.name=es01
>> "%COMPOSEFILE%" echo       - cluster.name=%SCEN%
>> "%COMPOSEFILE%" echo       - discovery.type=single-node
  >> "%COMPOSEFILE%" echo       - bootstrap.memory_lock=true
  >> "%COMPOSEFILE%" echo       - xpack.security.enabled=true
  >> "%COMPOSEFILE%" echo       - ELASTIC_PASSWORD=%ESBOOT%
  >> "%COMPOSEFILE%" echo       - xpack.ml.enabled=false

>> "%COMPOSEFILE%" echo       - ingest.geoip.downloader.enabled=false
>> "%COMPOSEFILE%" echo       - ES_JAVA_OPTS=-Xms1g -Xmx1g
>> "%COMPOSEFILE%" echo     ulimits:
>> "%COMPOSEFILE%" echo       memlock:
>> "%COMPOSEFILE%" echo         soft: -1
>> "%COMPOSEFILE%" echo         hard: -1
>> "%COMPOSEFILE%" echo     volumes:
>> "%COMPOSEFILE%" echo       - "%VOL%:/usr/share/elasticsearch/data"
>> "%COMPOSEFILE%" echo     ports:
>> "%COMPOSEFILE%" echo       - "%ESPORT%:9200"
  >> "%COMPOSEFILE%" echo     healthcheck:
  >> "%COMPOSEFILE%" echo       test: ["CMD-SHELL","curl -s -u %ESUSER%:%ESBOOT% -o /dev/null http://localhost:9200/_cluster/health || exit 1"]

>> "%COMPOSEFILE%" echo       interval: 10s
>> "%COMPOSEFILE%" echo       timeout: 6s
>> "%COMPOSEFILE%" echo       retries: 40
>> "%COMPOSEFILE%" echo     networks:
>> "%COMPOSEFILE%" echo       - lab
>> "%COMPOSEFILE%" echo   kibana:
>> "%COMPOSEFILE%" echo     image: %KBIMAGE%
>> "%COMPOSEFILE%" echo     container_name: %SCEN%-kibana
>> "%COMPOSEFILE%" echo     depends_on:
>> "%COMPOSEFILE%" echo       elasticsearch:
>> "%COMPOSEFILE%" echo         condition: service_healthy
  >> "%COMPOSEFILE%" echo     environment:
  >> "%COMPOSEFILE%" echo       - ELASTICSEARCH_HOSTS=["http://elasticsearch:9200"]
  >> "%COMPOSEFILE%" echo       - ELASTICSEARCH_USERNAME=%KBUSER%
  >> "%COMPOSEFILE%" echo       - ELASTICSEARCH_PASSWORD=%KBPASS%
  >> "%COMPOSEFILE%" echo       - SERVER_HOST=0.0.0.0
  >> "%COMPOSEFILE%" echo       - SERVER_PUBLICBASEURL=http://localhost:%KBPORT%
  >> "%COMPOSEFILE%" echo       - TELEMETRY_ENABLED=false
  >> "%COMPOSEFILE%" echo       - SECURITY_SHOWINSECURECLUSTERWARNING=false
  >> "%COMPOSEFILE%" echo       - XPACK_REPORTING_ENABLED=false
  >> "%COMPOSEFILE%" echo       - I18N_LOCALE=en
  rem  Kibana will not start a detection rule at all without an encryption key
  rem  for its saved objects, and it throws one away on every restart, so the
  rem  rule you just installed would vanish the next time the container is
  rem  recreated. Both keys are fixed here for that reason.
  >> "%COMPOSEFILE%" echo       - XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=%SCEN%labencryptedsavedobjects000001
  >> "%COMPOSEFILE%" echo       - XPACK_SECURITY_ENCRYPTIONKEY=%SCEN%labsecurityencryptionkey0000001

>> "%COMPOSEFILE%" echo     ports:
>> "%COMPOSEFILE%" echo       - "%KBPORT%:5601"
>> "%COMPOSEFILE%" echo     healthcheck:
>> "%COMPOSEFILE%" echo       test: ["CMD-SHELL","curl -s http://localhost:5601/api/status | grep -q available || exit 1"]
>> "%COMPOSEFILE%" echo       interval: 10s
>> "%COMPOSEFILE%" echo       timeout: 6s
>> "%COMPOSEFILE%" echo       retries: 60
>> "%COMPOSEFILE%" echo     networks:
>> "%COMPOSEFILE%" echo       - lab
>> "%COMPOSEFILE%" echo networks:
>> "%COMPOSEFILE%" echo   lab:
>> "%COMPOSEFILE%" echo     driver: bridge
>> "%COMPOSEFILE%" echo volumes:
>> "%COMPOSEFILE%" echo   "%VOL%":
>> "%COMPOSEFILE%" echo     name: "%VOL%"
if not exist "%COMPOSEFILE%" (
  call :fail "could not write docker-compose.yml" "Nothing else was started."
  exit /b 1
)
echo  [compose] wrote %COMPOSEFILE%
exit /b 0

rem ------------------------------------------------- create the lab account
rem  Kibana will not run as the built-in elastic account, and an account that
rem  only has the superuser role still cannot create the .kibana* saved-object
rem  indices, so the lab account carries superuser together with the built-in
rem  kibana_system role. Creating it is safe to repeat: the second run finds
rem  the account and rewrites the same password, which is what makes a changed
rem  KBPASS at the top of this file take effect.
:mkaccount
rem  No parentheses and no full_name in the body: a round bracket is a cmd
rem  metacharacter and this line is an unquoted echo, so keeping the body free
rem  of them removes a whole class of surprise for no loss.
>  "%WORK%\acct.json" echo {"password":"!KBPASS!","roles":["superuser","kibana_system"]}
call :docurl -s -o "%WORK%\acct-resp.json" -X PUT "%ESURL%/_security/user/%KBUSER%" -H "Content-Type: application/json" %ESAUTH% --data-binary "@%WORK%\acct.json"
if not "%CURLCODE%"=="200" if not "%CURLCODE%"=="201" (
  call :fail "could not create the lab account %KBUSER%, HTTP %CURLCODE%" "Nothing was deleted. The Elasticsearch log says why:  docker logs %SCEN%-elasticsearch"
  exit /b 1
)
echo       account %KBUSER% ready
exit /b 0

rem ------------------------------------------ install the three detection rules
rem  This is the whole point of the rules: without fired rules the Alerts page
rem  renders nothing at all, so a walkthrough that opens Alerts would be a dead
rem  end. The rules are installed through Kibana rather than through
rem  Elasticsearch's own rule API, because Kibana is what actually runs the
rem  alerting engine and what writes the alerts the page reads.
rem
rem  Three rules, not one, because that is what a detection estate looks like and
rem  because a single rule raising a single alert teaches a student nothing about triage,
rem  and three narrow rules raising six describe a real triage queue without burying it.
rem  Two sit on the process side and one on the network side, which is the split a
rem  real SOC uses: name-based and behaviour-based detection on the host, beaconing
rem  detection on the wire. Together they produce six alerts.
rem
rem  Each rule is deliberately idempotent by name.  The create route always mints
rem  a new rule id and this build has no update-by-id route, so a second run would
rem  install a second copy and every alert would be counted twice.  Counting
rem  first is cheap and needs only a single number back, which is the one thing a
rem  batch file can parse without ceremony.
rem
rem  %1 rule file   %2 display name   %3 alerts that rule must make
:mkone
set "RF=%~1"
set "RN=%~2"
set "RE=%~3"
if not exist "%LABDIR%\%~1" (
  call :fail "%~1 is missing from %LABDIR%" "The rest of the lab is fine. Put it back and re-run to get the Alerts page working."
  exit /b 1
)
rem  A match_phrase on the rule's name is used rather than a term on its
rem  keyword subfield.  The keyword subfield is normalised to lower case, and
rem  cmd.exe has no way to lower-case a string without a loop that is easy to
rem  get wrong; an analysed text match is already case-insensitive, so the
rem  name can be written here exactly as it is written in the rule file.
>  "%WORK%\rulefind.json" echo {"query":{"match_phrase":{"alert.name":"%~2"}}}
call :esdocount ".kibana_alerting_cases*" "RULEN" "%WORK%\rulefind.json"
if errorlevel 1 exit /b 1
if not "!RULEN!"=="0" (
  echo       already installed, leaving it alone: %~2
  goto :rulecheck
)
rem  Kibana answers /api/status a moment before it will accept a rule
rem  creation: for a short window after start-up it refuses internal APIs and
rem  answers "not available with the current configuration".  Waiting for the
rem  status page is therefore not enough on its own, so the call is retried a
rem  few times before it is called a failure.  Anything else here is a real
rem  problem and is reported on the first attempt.
set "RULEOK="
for /l %%i in (1,1,6) do (
  if not defined RULEOK (
    call :docurl -s -o "%WORK%\rule-resp.json" -X POST "%KBURL%/api/detection_engine/rules" -H "kbn-xsrf: true" -H "Content-Type: application/json" %KBAUTH% --data-binary "@%LABDIR%\%~1"
    if "!CURLCODE!"=="200" set "RULEOK=1"
    if not defined RULEOK (
      ping -n 5 127.0.0.1 >nul 2>&1
      if %%i lss 6 echo       Kibana is not accepting rules yet, retry %%i of 6
    )
  )
)
if not defined RULEOK (
  call :fail "Kibana refused the detection rule %~2, HTTP %CURLCODE%" "The log data is still loaded. The reason is in %WORK%\rule-resp.json and in  docker logs %SCEN%-kibana"
  exit /b 1
)
echo       installed: %~2
:rulecheck
rem  The rules run on a one minute schedule, so the first alerts cannot exist
rem  for up to a minute.  Rather than guess, poll the index the Alerts page reads
rem  and insist on the total the walkthrough quotes.  If this passes, the page
rem  cannot be empty or short, whatever Kibana's UI decides to render.
set "ALERTOK="
for /l %%i in (1,1,30) do (
  if not defined ALERTOK (
    call :docurl -s -o "%WORK%\alerts.json" %ESAUTH% "%ESURL%/.alerts-security.alerts-default/_count?filter_path=count"
    if "!CURLCODE!"=="200" (
      for /f "tokens=2 delims=:,{}" %%a in ('type "%WORK%\alerts.json"') do if not defined ALERTOK if "%%a"=="%RULEALERTS%" set "ALERTOK=1"
    )
    if not defined ALERTOK (
      ping -n 6 127.0.0.1 >nul 2>&1
      if %%i gtr 1 if %%i lss 30 echo       still waiting for the rules, wait %%i of 30
    )
  )
)
if not defined ALERTOK (
  call :fail "the rules are installed but between them have not produced %RULEALERTS% alerts" "Nothing was deleted. Check  docker logs %SCEN%-kibana  for the rules' execution status, and remember they only match data from the last 365 days."
  exit /b 1
)
exit /b 0

:mkrule
call :mkone rule.json   "%RULENAME1%" "%RULEALERTS1%"
if errorlevel 1 exit /b 1
call :mkone rule-2.json "%RULENAME2%" "%RULEALERTS2%"
if errorlevel 1 exit /b 1
call :mkone rule-3.json "%RULENAME3%" "%RULEALERTS3%"
if errorlevel 1 exit /b 1
echo       all three rules have fired: %RULEALERTS% alerts from 3 rules are on the Alerts page
exit /b 0

rem ------------------------------------------------- install one index template
:puttemplate
set "TPL=%~1"
if not exist "%LABDIR%\%~1.json" (
  call :fail "the index template %~1.json is missing" "Nothing was changed."
  exit /b 1
)
call :docurl -s -o "%WORK%\tpl-%TPL%.json" -X PUT "%ESURL%/_index_template/%TPL%" -H "Content-Type: application/json" %ESAUTH% --data-binary "@%LABDIR%\%TPL%.json"
if not "%CURLCODE%"=="200" if not "%CURLCODE%"=="201" (
  call :fail "the index template for %TPL% was not accepted, HTTP %CURLCODE%" "No data was imported. Fix %TPL%.json and run this file again."
  exit /b 1
)
echo       %TPL% template accepted
exit /b 0

rem --------------------------------------------- import one dataset, idempotent
:importone
set "DS=%~1"
set "EXP=%~2"
call :esdocount "%DS%-%IDXSUF%*" NDC
if errorlevel 1 exit /b 1
if "!NDC!"=="0" (
  echo       %DS%: no documents loaded yet, importing %EXP% documents
  call :dopost
  if errorlevel 1 exit /b 1
  goto :recount
)
if "!NDC!"=="%EXP%" (
  echo       %DS%: already fully loaded at !NDC! documents, nothing to import
  goto :recount
)
if !NDC! gtr %EXP% (
  echo       %DS%: index holds !NDC! documents, more than the %EXP% this lab ships
  echo       leaving it alone rather than guessing
  goto :recount
)
echo  ERROR: the %DS% index holds !NDC! documents but this lab ships %EXP%.
echo.
echo    Importing now would create duplicates and every count in the
echo    walkthrough would be wrong. This script will not import on top of a
echo    partial load, and it has deleted nothing.
echo.
echo    To rebuild this dataset from scratch
echo      setup-lab.cmd reset
echo    or delete the index by hand
echo      curl -XDELETE %ESURL%/%DS%-%IDXSUF%
echo.
call :fail "" "Nothing was deleted."
exit /b 1
:recount
call :esdocount "%DS%-%IDXSUF%*" NDC2
if errorlevel 1 exit /b 1
if not "!NDC2!"=="%EXP%" (
  call :fail "%DS% should hold %EXP% documents after import but holds !NDC2!" "Nothing was deleted. The next run will detect this and stop rather than duplicate data."
  exit /b 1
)
echo       %DS%: verified !NDC2! documents in %DS%-%IDXSUF%
exit /b 0

rem -------------------------------------------------------- the bulk import
:dopost
set "NDJ=%WORK%\bulk-%DS%.ndjson"
type nul > "%NDJ%"
for /f "usebackq delims=" %%L in ("%LABDIR%\!DS!.ndjson") do (
  >> "%NDJ%" echo {"index":{"_index":"!DS!-%IDXSUF%"}}
  >> "%NDJ%" echo %%L
)
rem     filter_path=errors makes Elasticsearch answer with exactly
rem     {"errors":false} and nothing else - sixteen bytes, with no trailing
rem     newline - so the check is a byte comparison against a file this script
rem     wrote.  The expected file is written with <nul set /p and deliberately
rem     without a line ending; a plain echo appends CRLF, which makes a healthy
rem     import look like a failed one.
call :docurl -s -o "%WORK%\bulk-%DS%.json" -X POST "%ESURL%/_bulk?refresh=wait_for&filter_path=errors" -H "Content-Type: application/x-ndjson" %ESAUTH% --data-binary "@%NDJ%"
<nul set /p "={"errors":false}" > "%WORK%\bulkok.txt"
fc /b "%WORK%\bulkok.txt" "%WORK%\bulk-%DS%.json" >nul 2>&1
if errorlevel 1 (
  call :fail "the bulk import for %DS% reported errors, see %WORK%\bulk-%DS%.json" "No documents were deleted. Run  setup-lab.cmd reset  and try again."
  exit /b 1
)
echo       %DS%: %EXP% documents accepted by Elasticsearch
exit /b 0

rem ------------------------------ create a data view, then read the pattern back
:mkdataview
set "DVNAME=%~1"
set "DVPAT=%~2"
rem %~3 is a file-name-safe spelling of the pattern, because * is not a legal
rem character in a path
set "DVFILE=%WORK%\dv-%~3.json"
> "%DVFILE%" echo {"attributes":{"title":"!DVPAT!","timeFieldName":"@timestamp"},"references":[]}
call :docurl -s -o "%WORK%\dv-resp.json" -X POST "%KBURL%/api/saved_objects/index-pattern/!DVNAME!?overwrite=true" -H "kbn-xsrf: true" -H "Content-Type: application/json" %KBAUTH% --data-binary "@%DVFILE%"
if not "%CURLCODE%"=="200" (
  call :fail "Kibana refused to create the data view !DVPAT!, HTTP %CURLCODE%" "The log data is still loaded. Check  docker logs %SCEN%-kibana  and run this file again."
  exit /b 1
)
rem the four ampersands here are deliberately bare - see the note on :esdocount
rem about why a caret in front of them would be doubled by CALL and sent to
rem Kibana as ^^&, which makes this lookup miss the data view it just created.
call :docurl -s -o "%WORK%\dv-find.json" %KBAUTH% "%KBURL%/api/saved_objects/_find?type=index-pattern&search_fields=title&search=!DVPAT!&fields=title&per_page=50"
findstr /c:"!DVPAT!" "%WORK%\dv-find.json" >nul 2>&1
if errorlevel 1 (
  echo  ERROR: the data view was created but the pattern "!DVPAT!" was not stored.
  echo.
  echo    A data view with an empty index pattern matches no index at all, so
  echo    Discover would show zero fields and no results and there would be no
  echo    visible reason why. That is the most confusing failure mode of this
  echo    lab, so it is checked here instead of being left for you to find.
  echo.
  echo    Fix it with
  echo      setup-lab.cmd reset
  echo.
  call :fail "" "The log data was not touched."
  exit /b 1
)
echo       data view "!DVPAT!" verified, time field @timestamp
exit /b 0

rem ---------------------------------------- final end-to-end truth verification
:verify
echo  [verify] reading every walkthrough count back out of Elasticsearch
rem  Every KQL string below is written to its own file first and handed to
rem  :vqcount as a file name.  That is deliberate and it is the whole reason
rem  this works: cmd.exe has no backslash escape, so a double quote inside a
rem  quoted argument to CALL comes out of the argument with its quotes eaten
rem  and its backslashes kept, which silently turns this JSON into something
rem  Elasticsearch answers with 400.  A file has no such problem, and the
rem  quotes have to be backslash-escaped for the JSON string anyway.
>  "%WORK%\k0.txt" echo match_all
>  "%WORK%\kq1.txt" echo event.code: 4688 and process.name: \"powershell.exe\" and process.parent.name: \"wmiprvse.exe\"
>  "%WORK%\kq2.txt" echo event.code: 4688 and process.name: \"xmrig.exe\"
>  "%WORK%\kq3.txt" echo event.action: \"network_connection\" and destination.port: %POOLPORT% and network.bytes < 2048
>  "%WORK%\k1.txt" echo event.code: 4688
>  "%WORK%\k2.txt" echo event.code: 4625
>  "%WORK%\k3.txt" echo event.code: 4688 and process.name: \"powershell.exe\"
>  "%WORK%\k4.txt" echo event.code: 4624 and user.name: \"svc_backup\" and host.name: \"%VICTIM%\"
>  "%WORK%\k5.txt" echo event.code: 4688 and host.name: \"%VICTIM%\"
>  "%WORK%\k6.txt" echo event.action: \"dns_query\"
>  "%WORK%\k7.txt" echo source.ip: \"%VICTIMIP%\" and destination.ip: \"%POOLIP%\" and destination.port: %POOLPORT%
call :vqcount "auth-*"    "every document in the auth data view"    %AUTHDOCS% k0.txt
if errorlevel 1 exit /b 1
call :vqcount "network-*" "every document in the network data view" %NETDOCS%  k0.txt
if errorlevel 1 exit /b 1
call :vqcount "auth-*"    "rule 1's own query, and so its alert"    %DQ1%    kq1.txt
if errorlevel 1 exit /b 1
call :vqcount "auth-*"    "rule 2's own query, and so its alert"    %DQ2%    kq2.txt
if errorlevel 1 exit /b 1
call :vqcount "network-*" "rule 3's own query, and so its alerts"   %DQ3%    kq3.txt
if errorlevel 1 exit /b 1
call :vqcount "auth-*"    "query 1  the estate's whole day"           %D1%     k1.txt
if errorlevel 1 exit /b 1
call :vqcount "auth-*"    "query 2  the failed-logon dead end"       %D2%     k2.txt
if errorlevel 1 exit /b 1
call :vqcount "auth-*"    "query 3  every powershell start"          %D3%     k3.txt
if errorlevel 1 exit /b 1
call :vqcount "auth-*"    "query 4  the entry point"                 %D4%     k4.txt
if errorlevel 1 exit /b 1
call :vqcount "auth-*"    "query 5  the delivery chain"              %D5%     k5.txt
if errorlevel 1 exit /b 1
call :vqcount "network-*" "query 6  the day's dns lookups"           %D6%     k6.txt
if errorlevel 1 exit /b 1
call :vqcount "network-*" "query 7  the pool heartbeat"              %D7%     k7.txt
if errorlevel 1 exit /b 1
call :verifyviews
if errorlevel 1 exit /b 1
echo  [verify] every number the walkthrough quotes matches the live index.
echo.
exit /b 0

rem -------------------- assert one count, so no number is typed in two places
rem     %~4 is a file in %WORK% holding one KQL string, with its inner double
rem     quotes already backslash-escaped for the JSON string they land in.
:vqcount
set "VQIDX=%~1"
set "VQLBL=%~2"
set "VQEXP=%~3"
set "VQF=%WORK%\vq.json"
set "VQK=%WORK%\%~4"
set "VQKQ="
set /p VQKQ=<"%VQK%"
rem  The literal word match_all means "count everything in the index" and is
rem  turned into a real match_all query.  A bare * would be turned into a
rem  fieldless wildcard instead, which currently returns the same count but
rem  says "everything" by accident rather than on purpose.
if /i "!VQKQ!"=="match_all" (
  > "%VQF%" echo {"size":0,"track_total_hits":true,"query":{"match_all":{}}}
  goto :vqgo
)
> "%VQF%" echo {"size":0,"track_total_hits":true,"query":{"kql":{"query":"!VQKQ!"}}}
:vqgo
call :eskqlcount "!VQIDX!" VQCNT
if errorlevel 1 exit /b 1
if not "!VQCNT!"=="%VQEXP%" (
  echo  MISMATCH  !VQLBL!
  echo            expected %VQEXP% but the index reports !VQCNT!
  call :fail "a count quoted in the walkthrough does not match the loaded data" "Nothing was deleted. Run  setup-lab.cmd reset  to rebuild the data exactly as shipped."
  exit /b 1
)
echo       !VQLBL!   =  !VQCNT!
exit /b 0

rem ------------------------------- both data views must actually serve fields
rem     This is the strongest check available over a public API. It asks
rem     Kibana's own data view service to resolve the saved object against
rem     Elasticsearch, which is the same resolution Discover performs. A
rem     pattern that matched nothing would come back 404 here, because the
rem     data view is created with allowNoIndex switched off on purpose.
:verifyviews
call :vdcheck auth    "auth-*"    "process.name"
if errorlevel 1 exit /b 1
call :vdcheck network "network-*" "network.protocol"
if errorlevel 1 exit /b 1
exit /b 0

:vdcheck
call :docurl -s -o "%WORK%\vd-%~1.json" %KBAUTH% "%KBURL%/api/data_views/data_view/%SCEN%-%~1" -H "kbn-xsrf: true"
if not "%CURLCODE%"=="200" (
  echo.
  echo  ERROR: Kibana cannot resolve the "%~2" data view, HTTP %CURLCODE%.
  echo.
  echo    The saved object exists but its index pattern matches no index, or
  echo    Kibana cannot read the mapping. Discover would show zero fields and
  echo    no results and there would be no visible reason why.
  echo.
  echo    Rebuild it with
  echo      setup-lab.cmd reset
  echo.
  call :fail "" "The log data was not touched."
  exit /b 1
)
rem  The three checks below look for a bare word rather than for a quoted JSON
rem  key, and that is on purpose.  cmd.exe has no backslash escape, so
rem  findstr /c:"\"title\":..." is not a dependable way to ask for a quote
rem  character: the backslashes reach findstr as literal backslashes and the
rem  search silently never matches, which would report a healthy lab as broken.
rem  Each bare word below occurs in this response only when the thing it names
rem  is really there - the pattern appears once, in the title; the time field
rem  key appears once; the field name appears only inside the resolved mapping.
findstr /c:"%~2" "%WORK%\vd-%~1.json" >nul 2>&1
if errorlevel 1 (
  call :fail "the %~2 data view did not resolve to the pattern %~2" "The log data was not touched. Run  setup-lab.cmd reset  to rebuild the data view."
  exit /b 1
)
findstr /c:"timeFieldName" "%WORK%\vd-%~1.json" >nul 2>&1
if errorlevel 1 (
  call :fail "the %~2 data view has no @timestamp time field" "The log data was not touched. Run  setup-lab.cmd reset  to rebuild the data view."
  exit /b 1
)
findstr /c:"%~3" "%WORK%\vd-%~1.json" >nul 2>&1
if errorlevel 1 (
  call :fail "the %~2 data view does not expose the field %~3 to Discover" "The log data was not touched. Run  setup-lab.cmd reset  to rebuild the data view."
  exit /b 1
)
echo       data view %~2 resolves, time field @timestamp, field %~3 present
exit /b 0

rem ------------------------------- ES helper: document count of one dataset
rem     the refresh is not optional.  A bulk write is not visible to a count
rem     until the index refreshes, so without this a successful import reads
rem     back as zero and a re-run would import the data a second time.
rem
rem     %~3 is an optional query body.  Without it this is a plain count of
rem     everything in the index; with one it counts only what matches, which is
rem     how :mkrule asks "is this rule already installed" without needing a
rem     response it would then have to take apart in batch.
rem
rem     The count URL is written out in full on each call line below, with plain
rem     ampersands.  Do not move it into a variable, and do not escape those
rem     ampersands with a caret.  CALL parses its command line a second time,
rem     so a caret written here arrives at curl doubled:
rem
rem         written here   set "U=.._count?allow_no_indices=true^&filter_path=count"
rem         curl receives  .._count?allow_no_indices=true^^&filter_path=count
rem
rem     and Elasticsearch refuses the count with HTTP 400,
rem         Could not convert [allow_no_indices] to boolean
rem         Failed to parse value [true^^] as only [true] or [false] are allowed
rem
rem     which aborts the run before the detection rule is installed and leaves
rem     the Alerts page empty.  A bare & inside the quoted argument survives
rem     both parses intact, which is what the call lines below rely on - the
rem     same style already used by the _bulk URL above.  setup-lab.sh has no
rem     second parse, so it works there either way; do not copy a caret back
rem     into the shell version.
:esdocount
set "EDIDX=%~1"
set "EDVAR=%~2"
set "EDQ=%~3"
call :docurl -s -o nul -X POST %ESAUTH% "%ESURL%/%EDIDX%/_refresh"
if defined EDQ (
  call :docurl -s -o "%WORK%\cnt.json" %ESAUTH% -X POST -H "Content-Type: application/json" --data-binary "@%EDQ%" "%ESURL%/%EDIDX%/_count?allow_no_indices=true&filter_path=count"
) else (
  call :docurl -s -o "%WORK%\cnt.json" %ESAUTH% "%ESURL%/%EDIDX%/_count?allow_no_indices=true&filter_path=count"
)
if not "%CURLCODE%"=="200" (
  call :fail "could not read the document count of %EDIDX%, HTTP %CURLCODE%" "Nothing was changed."
  exit /b 1
)
set "EDVAL="
for /f "tokens=2 delims=:,{}" %%a in ('type "%WORK%\cnt.json"') do if not defined EDVAL set "EDVAL=%%a"
if not defined EDVAL set "EDVAL=0"
set "%EDVAR%=%EDVAL%"
exit /b 0

rem ------------- ES helper: total hits for the query body in %WORK%\vq.json
rem     filter_path collapses the reply to  {"hits":{"total":{"value":N}}}
:eskqlcount
set "EKIDX=%~1"
set "EKVAR=%~2"
call :docurl -s -o nul -X POST %ESAUTH% "%ESURL%/!EKIDX!/_refresh"
call :docurl -s -o "%WORK%\vq.json.out" %ESAUTH% "%ESURL%/!EKIDX!/_search?filter_path=hits.total.value" -X POST -H "Content-Type: application/json" --data-binary "@%WORK%\vq.json"
if not "%CURLCODE%"=="200" (
  call :fail "a verification query against !EKIDX! was rejected, HTTP %CURLCODE%" "Nothing was deleted. The query text is in %WORK%\vq.json"
  exit /b 1
)
set "EKVAL="
for /f "tokens=4 delims=:,{}" %%a in ('type "%WORK%\vq.json.out"') do if not defined EKVAL set "EKVAL=%%a"
set "EKVAL=%EKVAL:}=%"
if not defined EKVAL set "EKVAL=0"
set "%EKVAR%=%EKVAL%"
exit /b 0

rem ------------ HTTP helper that captures the status code, so every call asserts
:docurl
set "CURLCODE="
type nul > "%WORK%\reqhdr.txt"
curl.exe -D "%WORK%\reqhdr.txt" %* >nul 2>&1
for /f "tokens=2" %%a in ('findstr /b HTTP/ "%WORK%\reqhdr.txt"') do if not defined CURLCODE set "CURLCODE=%%a"
if not defined CURLCODE set "CURLCODE=000"
exit /b

rem ---------------------------------------------------- log dumps on timeout
:dumpeslog
echo.
echo  ---- last 40 lines of the Elasticsearch log ----
docker logs --tail 40 "%SCEN%-elasticsearch" 2>&1
echo  -----------------------------------------------------
exit /b 0

:dumpkblog
echo.
echo  ---- last 40 lines of the Kibana log ----
docker logs --tail 40 "%SCEN%-kibana" 2>&1
echo  -----------------------------------------------------
exit /b 0

rem ------------------------------------------------------ one honest failure
:fail
echo.
echo  ==============================================================
echo   FAILED:  %~1
echo.
if not "%~2"=="" echo   %~2
echo.
echo   Nothing outside this %SCEN% lab was touched, and no data was deleted.
echo   Docker images were kept, so the next run starts faster.
echo.
echo   Scratch files :  %WORK%
echo   What is running:  docker ps -a
echo   Compose file :  %COMPOSEFILE%
echo.
echo  ==============================================================
echo.
pause
exit /b 1
