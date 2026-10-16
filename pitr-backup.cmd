@echo off
setlocal
set "PITR_ENTRY=%~dp0src\backup\Entry.ps1"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%PITR_ENTRY%" %*
exit /b %errorlevel%
