@echo off
REM ============================================================
REM  LKM unified dev server launcher (Windows)
REM
REM  Usage:
REM    dev.bat            start ALL: SSR frontend + backend
REM                       (single window, realtime interleaved logs, Ctrl+C to stop)
REM    dev.bat front      start SSR frontend only (Astro, :4321)
REM    dev.bat back       start backend only (uvicorn :8000)
REM
REM  Note (PowerShell): run as .\dev.bat
REM  Note (encoding):   this file is pure ASCII. The real logic lives
REM                      in dev.ps1 (delegated via -ExecutionPolicy Bypass).
REM ============================================================

setlocal

set "SCRIPT_DIR=%~dp0"
set "MODE=%~1"
if "%MODE%"=="" set "MODE=all"

powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%SCRIPT_DIR%dev.ps1" -Mode "%MODE%"

exit /b %ERRORLEVEL%
