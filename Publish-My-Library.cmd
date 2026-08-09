@echo off
setlocal
title Publish Slaur KiCad Library

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Publish-Slaur-Library.ps1"
set "result=%errorlevel%"

echo.
if not "%result%"=="0" echo Nothing was published. Review the message above.
pause
exit /b %result%

