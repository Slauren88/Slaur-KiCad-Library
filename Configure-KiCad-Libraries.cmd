@echo off
setlocal
title Configure KiCad Libraries

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-KiCad-Libraries.ps1"
set "result=%errorlevel%"

echo.
if not "%result%"=="0" echo KiCad library configuration did not complete. Review the message above.
pause
exit /b %result%

