@echo off
rem Double-click: installs the Build Tools toolchain (logs to bt-setup.log)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { .\bt-setup.ps1 install *>&1 | Tee-Object -FilePath .\bt-setup.log }"
echo.
pause
