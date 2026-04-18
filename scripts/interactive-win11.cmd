@echo off
setlocal

powershell.exe -ExecutionPolicy Bypass -File "%~dp0interactive-win11.ps1" %*
exit /b %ERRORLEVEL%
