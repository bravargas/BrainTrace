@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Deploy-DEV.ps1"
set "BRAINTRACE_EXIT=%ERRORLEVEL%"
echo.
if not "%BRAINTRACE_EXIT%"=="0" echo BrainTrace deployment failed. Review the message above.
pause
exit /b %BRAINTRACE_EXIT%
