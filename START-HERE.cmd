@echo off
setlocal DisableDelayedExpansion
set "PITR_ENTRY=%~dp0src\backup\Entry.ps1"
set "PITR_MAIN=%~dp0pitr-config.cmd"
if not "%~1"=="" goto :cli
rem The full app owns its single elevation attempt and visible error handling.
if not exist "%PITR_MAIN%" goto :missingmain
rem Transfer to the original launcher without CALL's second filename expansion.
"%PITR_MAIN%"
exit /b %errorlevel%
:missingmain
echo PITR could not open: pitr-config.cmd is missing. Extract the entire ZIP.
pause
exit /b 3
:cli
rem Explicit backup/recovery CLI calls remain non-pausing and never self-elevate.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%PITR_ENTRY%" %*
exit /b %errorlevel%
