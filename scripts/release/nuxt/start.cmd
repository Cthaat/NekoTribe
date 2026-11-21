@echo off
setlocal
pushd "%~dp0" || exit /b 1
node scripts\package-nuxt.mjs --prepare .
if errorlevel 1 goto finish
node scripts\run-nuxt.mjs start %*
:finish
set "NEKO_EXIT=%ERRORLEVEL%"
popd
if not "%NEKO_EXIT%"=="0" if "%~1"=="" pause
exit /b %NEKO_EXIT%
