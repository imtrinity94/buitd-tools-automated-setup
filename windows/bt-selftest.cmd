@echo off
rem Double-click: builds and signs a throwaway project to prove the toolchain works
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { .\bt-setup.ps1 selftest *>&1 | Tee-Object -FilePath .\bt-selftest.log }"
echo.
pause
