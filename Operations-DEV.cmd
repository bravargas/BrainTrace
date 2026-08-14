@echo off
set "BRAINTRACE_PORTAL=%~dp0Operations-Portal.ps1"
if exist "%~dp0src\Operations-Portal.ps1" set "BRAINTRACE_PORTAL=%~dp0src\Operations-Portal.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BRAINTRACE_PORTAL%"
set "BRAINTRACE_EXIT=%ERRORLEVEL%"
echo.
if not "%BRAINTRACE_EXIT%"=="0" echo BrainTrace Operations failed. Review the message above.
pause
exit /b %BRAINTRACE_EXIT%
