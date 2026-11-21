@echo off
setlocal
pushd "%~dp0" || exit /b 1
node package-native.mjs --verify .
if errorlevel 1 goto finish
node start-native.mjs %*
:finish
set "NEKO_EXIT=%ERRORLEVEL%"
popd
if not "%NEKO_EXIT%"=="0" if "%~1"=="" pause
exit /b %NEKO_EXIT%
