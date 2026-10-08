@echo off
setlocal EnableExtensions EnableDelayedExpansion
title teardown.cmd  -  %~n0

rem ===========================================================================
rem  teardown.cmd  --  remove exactly what setup-lab.cmd created, and nothing else
rem
rem    teardown.cmd          list what will go, ask, then remove it
rem    teardown.cmd --yes    remove without asking, for scripts
rem    teardown.cmd -?       this list
rem
rem  Every name below is derived from the folder name using the same expression
rem  as setup-lab.cmd, which is what makes this script provably safe: it can
rem  only ever name objects that belong to this scenario.
rem
rem  There is a Linux / macOS twin of this file, teardown.sh, in the same
rem  folder. It removes exactly the same things. If you change one, change the
rem  other.
rem ===========================================================================

for %%I in ("%~dp0.") do set "SCEN=%%~nI"
set "LABDIR=%~dp0"
if "%LABDIR:~-1%"=="\" set "LABDIR=%LABDIR:~0,-1%"
set "VOL=%SCEN%_esdata"
set "WORK=%TEMP%\elklab-%SCEN%"
set "KBPORT=5601"
set "COMPOSEFILE=%LABDIR%\docker-compose.yml"

set "ASSUME=0"
if /i "%~1"=="--yes" set "ASSUME=1"
if /i "%~1"=="-y"   set "ASSUME=1"
if /i "%~1"=="-?"   goto :usage
if /i "%~1"=="--help" goto :usage
if /i "%~1"=="help" goto :usage

echo.
echo  ==============================================================
echo   teardown.cmd  -  remove the "%SCEN%" lab
echo  ==============================================================
echo.

rem ------------------------------------------------ is there anything to remove
set "HADES=0"
set "HADKB=0"
set "HADVOL=0"
set "DOCKEROK=0"

where docker >nul 2>&1
if not errorlevel 1 (
  docker version --format "{{.Server.Version}}" >nul 2>&1
  if not errorlevel 1 set "DOCKEROK=1"
)

if "%DOCKEROK%"=="1" (
  docker inspect "%SCEN%-elasticsearch" >nul 2>&1 && set "HADES=1"
  docker inspect "%SCEN%-kibana"         >nul 2>&1 && set "HADKB=1"
  docker volume inspect "%VOL%"          >nul 2>&1 && set "HADVOL=1"
)

if "%HADES%%HADKB%%HADVOL%"=="000" (
  if "%DOCKEROK%"=="1" (
    echo  Nothing to remove. There is no container and no volume named after
    echo    this scenario, so there is nothing to do.
  ) else (
    echo  Docker is not available, but there is nothing named after this
    echo    scenario to remove either.
  )
  call :cleanwork
  echo.
echo  Lab state : already clean
echo  Nothing was deleted.
echo.
echo  To build the lab again :  setup-lab.cmd
echo.
pause
exit /b 0
)

rem ------------------------------------------- state the exact list, then ask
echo  The following will be REMOVED. Nothing else will be touched.
echo.
if "%HADES%"=="1" echo    container   %SCEN%-elasticsearch
if "%HADKB%"=="1"  echo    container   %SCEN%-kibana
if "%HADVOL%"=="1"  echo    volume      %VOL%      (this holds ALL the lab data, the detection rule included)
if exist "%COMPOSEFILE%" echo    file       %COMPOSEFILE%   (the generated compose file)
if exist "%WORK%"        echo    folder     %WORK%         (scratch files only)
echo.
echo  This cannot be undone. The volume holds the imported logs, so removing it
echo  means the next setup-lab.cmd has to import the data again.
echo.
echo  Deliberately KEPT, always:
echo    - all Docker images, so the next setup is fast and offline
echo    - every other container, volume and image on this machine
echo    - the files in %LABDIR%  (ndjson, templates, rule.json, the scripts, the guide)
echo.
echo  This script never runs "docker system prune" and never removes an image.
echo.

if "%ASSUME%"=="0" (
  choice /c YN /n /m "  Remove these now?  [Y]=yes  [N]=no : "
  if errorlevel 2 goto :declined
)

rem ------------------------------------------------------------------ remove
echo.
echo  Removing...

if "%DOCKEROK%"=="0" (
  echo.
  echo  Docker is not running, so containers and the data volume CANNOT be
  echo  removed right now. A stopped Docker engine cannot delete anything.
  echo    What is being cleaned up instead:
  if exist "%WORK%"        echo      folder   %WORK%   removed
  echo      container %SCEN%-elasticsearch   STILL PRESENT, cannot remove it
  echo      container %SCEN%-kibana         STILL PRESENT, cannot remove it
  echo      volume    %VOL%                 STILL PRESENT, cannot remove it
  if exist "%COMPOSEFILE%" echo      file     %COMPOSEFILE%   kept, so you can still run
  echo                    "docker compose -f docker-compose.yml down" later
  if exist "%WORK%" rmdir /s /q "%WORK%" >nul 2>&1
  echo.
  echo  To finish, start Docker Desktop and run teardown.cmd again.
  echo.
  pause
  exit /b 1
)

rem down -v first while the compose file is still here, because that is the
rem clean path.  Explicit removals follow so the script still works if the
rem folder was moved and docker-compose.yml went missing.
if exist "%COMPOSEFILE%" (
  docker compose -f "%COMPOSEFILE%" down -v --remove-orphans
  if errorlevel 1 (
    echo    "docker compose down" did not complete cleanly, removing the objects by name
  ) else (
    echo    compose down -v completed
  )
)

docker rm -f "%SCEN%-elasticsearch" >nul 2>&1
docker rm -f "%SCEN%-kibana"         >nul 2>&1
docker volume rm -f "%VOL%"          >nul 2>&1

if exist "%COMPOSEFILE%" del /q "%COMPOSEFILE%" >nul 2>&1
call :cleanwork

rem ----------------------------------------------------- honest closing state
echo.
echo  Verifying...
set "GADES=0"
set "GADKB=0"
set "GADVOL=0"
set "GCOMPOSE=0"
set "GWORK=0"
docker inspect "%SCEN%-elasticsearch" >nul 2>&1 || set "GADES=1"
docker inspect "%SCEN%-kibana"         >nul 2>&1 || set "GADKB=1"
docker volume inspect "%VOL%"          >nul 2>&1 || set "GADVOL=1"
if not exist "%COMPOSEFILE%" set "GCOMPOSE=1"
if not exist "%WORK%"        set "GWORK=1"

if "%GADES%"=="1"  echo    gone      container %SCEN%-elasticsearch
if "%HADES%"=="0"  echo    absent    container %SCEN%-elasticsearch   (there was nothing to remove)
if "%GADES%"=="0"  echo    WARNING   container %SCEN%-elasticsearch   still exists and could not be removed
if "%GADKB%"=="1"  echo    gone      container %SCEN%-kibana
if "%HADKB%"=="0"  echo    absent    container %SCEN%-kibana         (there was nothing to remove)
if "%GADKB%"=="0"  echo    WARNING   container %SCEN%-kibana         still exists and could not be removed
if "%GADVOL%"=="1"  echo    gone      volume    %VOL%
if "%HADVOL%"=="0"  echo    absent    volume    %VOL%               (there was nothing to remove)
if "%GADVOL%"=="0"  echo    WARNING   volume    %VOL%               still exists, %VOL% bytes may still be held
if "%GCOMPOSE%"=="1" echo    gone      file      %COMPOSEFILE%
if "%GWORK%"=="1"    echo    gone      folder    %WORK%
echo.

if "%GADES%%GADKB%%GADVOL%"=="111" (
  echo  ==============================================================
  echo    The "%SCEN%" lab has been removed.
  echo.
  echo    Kept on purpose: every Docker image, and every other container and
  echo    volume on this machine. The log files and templates in this folder
  echo    are also untouched, so nothing was lost from disk here.
  echo.
  echo    To build the lab again from scratch :  setup-lab.cmd
  echo    To rebuild and open the browser too:  setup-lab.cmd
  echo  ==============================================================
) else (
  echo  ==============================================================
  echo    Partly removed. Read the WARNING lines above.
  echo.
  echo    The usual cause is Docker Desktop not running, or the containers
  echo    having been started by hand rather than through docker-compose.
  echo    Start Docker Desktop and run teardown.cmd again, or remove the
  echo    named objects by hand:
  echo      docker rm -f "%SCEN%-elasticsearch" "%SCEN%-kibana"
  echo      docker volume rm -f "%VOL%"
  echo  ==============================================================
)
echo.
pause
exit /b 0

:declined
echo.
echo  Nothing was removed. The lab is still exactly as it was.
echo.
pause
exit /b 0

:cleanwork
if exist "%WORK%" rmdir /s /q "%WORK%" >nul 2>&1
exit /b 0

:usage
echo.
echo  ==============================================================
echo   teardown.cmd  -  remove the "%SCEN%" lab
echo  ==============================================================
echo.
echo    teardown.cmd          list what will be removed, ask, then remove it
echo    teardown.cmd --yes    remove without asking, for scripts
echo    teardown.cmd -?       this list
echo.
echo  What it removes, and only this:
echo    the containers  %SCEN%-elasticsearch  and  %SCEN%-kibana
echo    the volume      %VOL%   which holds the imported log data
echo    the generated   docker-compose.yml  in this folder
echo    the scratch     %WORK%  folder in TEMP
echo.
echo  What it never touches:
echo    any Docker image, so the next setup is fast
echo    any other container or volume on this machine
echo    any file in this folder other than the generated docker-compose.yml
echo.
echo  It never runs "docker system prune" and never removes an image.
echo.
pause
exit /b 0
