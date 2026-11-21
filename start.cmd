@echo off
setlocal
node "%~dp0scripts\start-native.mjs" %*
set "NEKO_EXIT=%ERRORLEVEL%"
if not "%NEKO_EXIT%"=="0" if "%~1"=="" pause
exit /b %NEKO_EXIT%
