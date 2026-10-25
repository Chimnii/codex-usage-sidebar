@echo off
setlocal
title Codex Usage Sidebar - Launch
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Entry.ps1" -Action Launch -ProjectRoot "%~dp0." %*
set "sidebar_exit=%ERRORLEVEL%"
if not "%sidebar_exit%"=="0" pause
exit /b %sidebar_exit%
