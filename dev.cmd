@echo off
setlocal
node "%~dp0scripts\startup.mjs" dev
set "NEKO_EXIT=%ERRORLEVEL%"
if not "%NEKO_EXIT%"=="0" echo Startup failed. See the error above.
pause
exit /b %NEKO_EXIT%
