@echo off
rem Double-click: removes the Build Tools setup. Shows the plan and asks before deleting
rem anything; logs to bt-uninstall.log. Your projects are never touched.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { .\bt-setup.ps1 uninstall *>&1 | Tee-Object -FilePath .\bt-uninstall.log }"
echo.
pause
