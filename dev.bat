@echo off
REM ============================================================
REM  LKM unified dev server launcher (Windows)
REM
REM  Usage:
REM    dev.bat            start ALL: SSR frontend + backend
REM                       (single window, realtime interleaved logs, Ctrl+C to stop)
REM    dev.bat front      start SSR frontend only (Astro, :4321)
REM    dev.bat back       start backend only (uvicorn :8000)
REM    dev.bat --no-run   install both sets of dependencies only
REM    dev.bat back --no-run  install backend dependencies only
REM
REM  Note (PowerShell): run as .\dev.bat
REM  Note (encoding):   this file is pure ASCII. The real logic lives
REM                      in dev.ps1 (delegated via -ExecutionPolicy Bypass).
REM ============================================================

setlocal

set "SCRIPT_DIR=%~dp0"
set "MODE=%~1"
set "NO_RUN="
if "%MODE%"=="" set "MODE=all"
if /I "%MODE%"=="--no-run" (
  set "MODE=all"
  set "NO_RUN=-NoRun"
)
if /I "%~2"=="--no-run" set "NO_RUN=-NoRun"
if not "%~2"=="" if /I not "%~2"=="--no-run" (
  echo [lkm:error] Unknown argument: %~2 1>&2
  exit /b 2
)
if not "%~3"=="" (
  echo [lkm:error] Too many arguments. 1>&2
  exit /b 2
)

powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%SCRIPT_DIR%dev.ps1" -Mode "%MODE%" %NO_RUN%

exit /b %ERRORLEVEL%
