<#
.SYNOPSIS
    卸载“南邮校园网开机自动登录”任务。
#>

#Requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$TaskName   = 'NJUPT-CampusAutoLogin'
$InstallDir = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin'

Write-Host '正在卸载南邮校园网自动登录...' -ForegroundColor Cyan

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "  已删除计划任务：$TaskName"
} else {
    Write-Host "  计划任务不存在：$TaskName"
}

$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) '校园网立即登录.lnk'
if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Host "  已删除桌面快捷方式：$shortcutPath"
}

if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host "  已删除安装目录：$InstallDir"
}

Write-Host '卸载完成。' -ForegroundColor Green
