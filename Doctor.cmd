@echo off
setlocal
title Codex Usage Sidebar - Doctor
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Doctor.ps1" -ProjectRoot "%~dp0." %*
set "sidebar_exit=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %sidebar_exit%
