@echo off
setlocal EnableExtensions

cd /d "%~dp0"
set "SCRIPT=%~dp0Install-SogouNetworkBlock.ps1"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%SCRIPT%" (
    echo [ERROR] Install-SogouNetworkBlock.ps1 was not found beside this CMD file.
    pause
    exit /b 2
)

if not exist "%PS_EXE%" set "PS_EXE=powershell.exe"
set "SOGOU_BLOCKER_SCRIPT=%SCRIPT%"
set "SOGOU_BLOCKER_PS=%PS_EXE%"

fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator permission...
    "%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
        "$scriptPath = $env:SOGOU_BLOCKER_SCRIPT; Start-Process -FilePath $env:SOGOU_BLOCKER_PS -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-Mode','Install') -Verb RunAs" 
    if errorlevel 1 (
        echo [ERROR] Could not request administrator permission.
        pause
        exit /b 1
    )
    exit /b 0
)

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode Install
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if "%EXIT_CODE%"=="0" (
    echo Sogou network blocking has been installed or refreshed.
) else (
    echo [ERROR] Installation failed with exit code %EXIT_CODE%.
)
pause
exit /b %EXIT_CODE%
