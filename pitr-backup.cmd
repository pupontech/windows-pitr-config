@echo off
setlocal DisableDelayedExpansion
set "PITR_ENTRY=%~dp0src\backup\Entry.ps1"
if not "%~1"=="" goto :cli
rem Explorer/double-click: keep a failed startup visible instead of disappearing.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%PITR_ENTRY%"
set "PITR_EXIT=%errorlevel%"
if "%PITR_EXIT%"=="0" exit /b 0
echo.
echo PITR could not open the backup/restore window. Read the error above.
echo Extract the entire ZIP and keep START-HERE.cmd beside the src folder.
pause
exit /b %PITR_EXIT%
:cli
rem Explicit CLI calls must never pause or prompt for elevation.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%PITR_ENTRY%" %*
exit /b %errorlevel%
