@echo off
set "BRAINTRACE_CLI=%~dp0BrainTrace.ps1"
if exist "%~dp0src\BrainTrace.ps1" set "BRAINTRACE_CLI=%~dp0src\BrainTrace.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BRAINTRACE_CLI%" Diagnose -Environment DEV
set "BRAINTRACE_EXIT=%ERRORLEVEL%"
echo.
if not "%BRAINTRACE_EXIT%"=="0" echo BrainTrace diagnosis encountered an error. Review the details above.
pause
exit /b %BRAINTRACE_EXIT%
