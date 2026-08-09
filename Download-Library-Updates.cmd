@echo off
setlocal
title Download KiCad Library Updates

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Download-KiCad-Libraries.ps1"
set "result=%errorlevel%"

echo.
if not "%result%"=="0" echo The download did not complete for every repository. Review the message above.
pause
exit /b %result%

