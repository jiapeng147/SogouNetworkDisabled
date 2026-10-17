@echo off
setlocal EnableExtensions

cd /d "%~dp0"
set "SCRIPT=%~dp0Install-SogouNetworkBlock.ps1"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" set "PS_EXE=powershell.exe"

if not exist "%SCRIPT%" (
    echo [ERROR] Install-SogouNetworkBlock.ps1 was not found beside this CMD file.
    pause
    exit /b 2
)

fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator permission...
    set "SOGOU_BLOCKER_SCRIPT=%SCRIPT%"
    set "SOGOU_BLOCKER_PS=%PS_EXE%"
    "%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
        "$scriptPath = $env:SOGOU_BLOCKER_SCRIPT; Start-Process -FilePath $env:SOGOU_BLOCKER_PS -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-Mode','Uninstall') -Verb RunAs"
    exit /b %ERRORLEVEL%
)

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode Uninstall
set "EXIT_CODE=%ERRORLEVEL%"
pause
exit /b %EXIT_CODE%
