@echo off
rem Usage: run.bat [name]   (default: rainstorm)
rem Builds src\<name>.asm -> bin\<name>.a26 via build.ps1 and opens it in Stella.
rem Double-click to launch the current game.
setlocal
set "NAME=%~1"
if "%NAME%"=="" set "NAME=rainstorm"
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %NAME%
if errorlevel 1 (
    echo.
    echo Build failed.
    pause
    exit /b 1
)

set "STELLA=C:\Program Files\Stella\Stella.exe"
if not exist "%STELLA%" (
    echo Stella not found at "%STELLA%".
    echo Install it with:  winget install TheStellaTeam.Stella
    pause
    exit /b 1
)

start "" "%STELLA%" "%~dp0bin\%NAME%.a26"
endlocal
