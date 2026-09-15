@echo off
rem ---------------------------------------------------------------------------
rem  Double-click launcher for Fix-CodexReconnect.ps1
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
rem  The script backs up config.toml and the current system proxy before writing
rem  anything, and refuses to write a dead proxy port into the system settings.
rem  Undo with Rollback.cmd.
rem ---------------------------------------------------------------------------
setlocal
set "HERE=%~dp0"
set "TARGET=%HERE%scripts\Fix-CodexReconnect.ps1"

if not exist "%TARGET%" (
    echo [ERROR] Not found: "%TARGET%"
    echo         Run this file from inside the codex-reconnect-fix folder.
    echo.
    pause
    exit /b 1
)

echo ============================================================
echo  Codex Reconnect - FIX   (backs up first, refuses unsafe changes)
echo ============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath '%TARGET%' -ErrorAction SilentlyContinue" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" %*
set "RC=%ERRORLEVEL%"
echo.
echo Exit code %RC%   -   0 applied, 1 Codex home missing, 3 write failed, 4 refused
echo.
pause
exit /b %RC%
