@echo off
rem ---------------------------------------------------------------------------
rem  Double-click launcher for Rollback-CodexReconnect.ps1
rem
rem  Restores config.toml and the Windows system proxy from the most recent
rem  backup created by Fix-CodexReconnect.ps1, and removes the proxy
rem  environment variables if the fix added them.
rem
rem  See Fix.cmd for why this wrapper exists at all. In short: Unblock-File drops
rem  the "came from the Internet" mark, and -ExecutionPolicy Bypass runs the
rem  script despite the default policy that blocks every .ps1.
rem ---------------------------------------------------------------------------
setlocal
set "HERE=%~dp0"
set "TARGET=%HERE%scripts\Rollback-CodexReconnect.ps1"

if not exist "%TARGET%" (
    echo [ERROR] Not found: "%TARGET%"
    echo         Run this file from inside the codex-reconnect-fix folder.
    echo.
    pause
    exit /b 1
)

echo ============================================================
echo  Codex Reconnect - ROLLBACK   (undoes the last FIX)
echo ============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath '%TARGET%' -ErrorAction SilentlyContinue" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" %*
set "RC=%ERRORLEVEL%"
echo.
echo Exit code %RC%   -   0 restored, 1 no backup found, 3 restore failed
echo.
pause
exit /b %RC%
