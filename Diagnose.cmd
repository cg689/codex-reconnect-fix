@echo off
rem ---------------------------------------------------------------------------
rem  Double-click launcher for Diagnose-CodexReconnect.ps1
rem
rem  Why this wrapper exists
rem    1. Windows blocks .ps1 files by default (execution policy "Restricted").
rem    2. A .ps1 that came out of a downloaded ZIP is flagged as unsafe and is
rem       refused even when the policy does allow local scripts.
rem  The two commands below clear both obstacles, so no system setting has to be
rem  changed:
rem    1. Unblock-File drops the "came from the Internet" mark.
rem    2. -ExecutionPolicy Bypass runs the script despite the default policy.
rem
rem  If you already have a PowerShell window open and know your execution policy,
rem  calling the .ps1 directly is equivalent - this is the double-click path.
rem ---------------------------------------------------------------------------
setlocal
set "HERE=%~dp0"
set "TARGET=%HERE%scripts\Diagnose-CodexReconnect.ps1"

if not exist "%TARGET%" (
    echo [ERROR] Not found: "%TARGET%"
    echo         Run this file from inside the codex-reconnect-fix folder.
    echo.
    pause
    exit /b 1
)

echo ============================================================
echo  Codex Reconnect - DIAGNOSE   (read-only, changes nothing)
echo ============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%HERE%scripts' -Filter *.ps1 -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" %*
set "RC=%ERRORLEVEL%"
echo.
echo Exit code %RC%   -   0 healthy, 1 problem found, 2 Codex home not found
echo.
pause
exit /b %RC%
