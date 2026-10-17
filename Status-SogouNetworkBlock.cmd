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

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode Status
set "EXIT_CODE=%ERRORLEVEL%"
pause
exit /b %EXIT_CODE%
