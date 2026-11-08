@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\CampusAutoLogin\campus_autologin.ps1"
echo.
if exist "%LOCALAPPDATA%\CampusAutoLogin\autologin.log" (
    echo 最近日志：
    powershell.exe -NoProfile -Command "Get-Content -LiteralPath '%LOCALAPPDATA%\CampusAutoLogin\autologin.log' -Tail 6"
)
echo.
timeout /t 5 >nul
