@echo off
setlocal
pushd "%~dp0" || exit /b 1
node serve-web.mjs %*
set "NEKO_EXIT=%ERRORLEVEL%"
popd
if not "%NEKO_EXIT%"=="0" if "%~1"=="" pause
exit /b %NEKO_EXIT%
