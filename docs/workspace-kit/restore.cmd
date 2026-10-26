@echo off
node "%~dp0restore-workspace.mjs" %*
exit /b %errorlevel%
