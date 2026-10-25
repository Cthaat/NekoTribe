@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-web.ps1"
set "NEKO_EXIT=%ERRORLEVEL%"
pause
exit /b %NEKO_EXIT%
