@echo off
rem WSL Bootstrap launcher: double-click to run install.ps1 (no admin needed;
rem steps that need admin raise their own UAC prompt).
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%
