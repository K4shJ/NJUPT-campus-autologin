@echo off
chcp 65001 >nul
echo 正在安装校园网开机自动登录...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause

