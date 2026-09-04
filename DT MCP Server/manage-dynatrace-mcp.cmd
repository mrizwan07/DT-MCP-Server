@echo off
setlocal
cd /d "%~dp0"

if "%1"=="" set "ACTION=status"
if not "%1"=="" set "ACTION=%1"

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0manage-dynatrace-mcp.ps1" -Action "%ACTION%"
exit /b %ERRORLEVEL%
