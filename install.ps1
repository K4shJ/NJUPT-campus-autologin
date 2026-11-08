<#
.SYNOPSIS
    安装“南邮校园网开机自动登录”任务。
.DESCRIPTION
    1. 把主脚本复制到 %LOCALAPPDATA%\CampusAutoLogin
    2. 用 Windows DPAPI 加密保存账号密码（仅当前 Windows 用户可解密）
    3. 注册计划任务：登录 Windows 时自动运行一次（无定时检查）
    4. 立即运行一次并显示结果
.NOTES
    需要以当前用户身份运行，不需要管理员权限。
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Account  = 'YOUR_ACCOUNT',
    [string]$Suffix   = '@cmcc',
    [string]$Password = ''
)

if ($Account -eq 'YOUR_ACCOUNT') {
    $Account = Read-Host '请输入你的学号（不含 @cmcc 等后缀）'
}
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$TaskName    = 'NJUPT-CampusAutoLogin'
$InstallDir  = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin'
$ScriptSrc   = Join-Path $PSScriptRoot 'campus_autologin.ps1'
$ScriptDst   = Join-Path $InstallDir 'campus_autologin.ps1'
$CredFile    = Join-Path $InstallDir 'cred.xml'
$HiddenLauncher = Join-Path $InstallDir 'run_hidden.vbs'
$UiServer    = Join-Path $InstallDir 'settings_server.ps1'
$UiHtml      = Join-Path $InstallDir 'settings.html'
$UiLauncher  = Join-Path $InstallDir '打开设置.vbs'
$UserId      = "$env:USERDOMAIN\$env:USERNAME"

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

Write-Host '南京邮电大学校园网 - 开机自动登录安装程序' -ForegroundColor Green
Write-Host "账号：$Account$Suffix"

if (-not (Test-Path -LiteralPath $ScriptSrc)) {
    throw "找不到主脚本：$ScriptSrc"
}
foreach ($name in @('settings.html', 'settings_server.ps1', '打开设置.vbs', 'run_hidden.vbs')) {
    $p = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $p)) {
        throw "找不到安装文件：$p"
    }
}

Write-Step '创建安装目录'
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Write-Host "    $InstallDir"

Write-Step '复制主脚本和设置页'
Copy-Item -LiteralPath $ScriptSrc -Destination $ScriptDst -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'settings.html') -Destination $UiHtml -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'settings_server.ps1') -Destination $UiServer -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '打开设置.vbs') -Destination $UiLauncher -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run_hidden.vbs') -Destination $HiddenLauncher -Force
Write-Host "    $ScriptDst"
Write-Host "    $UiHtml"
Write-Host "    $UiServer"

Write-Step '写入运营商配置'
$settingsFile = Join-Path $InstallDir 'settings.ini'
@(
    '# 南邮校园网自动登录配置',
    "# 校园网（不填后缀）：Suffix=",
    "# 中国电信：Suffix=@njxy",
    "# 中国移动：Suffix=@cmcc",
    "Account=$Account",
    "Suffix=$Suffix"
) | Set-Content -LiteralPath $settingsFile -Encoding UTF8
Write-Host "    $settingsFile（$Account$Suffix）"

Write-Step '加密保存账号密码（DPAPI，仅当前用户可解密）'
function Test-CredentialFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $null = (Import-Clixml -LiteralPath $Path).GetNetworkCredential().Password
        return $true
    } catch { return $false }
}

$credReady = $false
if ($Password) {
    $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
    $cred   = New-Object System.Management.Automation.PSCredential($Account, $secure)
    $cred | Export-Clixml -LiteralPath $CredFile -Force
    Write-Host "    已用 -Password 参数写入新密码：$CredFile"
    $credReady = $true
} elseif (Test-CredentialFile $CredFile) {
    Write-Host "    沿用已有加密凭据：$CredFile"
    $credReady = $true
} elseif (Test-CredentialFile (Join-Path $PSScriptRoot 'cred.xml')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'cred.xml') -Destination $CredFile -Force
    Write-Host "    已复制随附的加密凭据：$CredFile"
    $credReady = $true
}

if (-not $credReady) {
    Write-Host '    没有可用的加密凭据（可能是换了电脑或 Windows 用户），请重新输入密码。' -ForegroundColor Yellow
    $secure = Read-Host '    请输入校园网密码' -AsSecureString
    $cred   = New-Object System.Management.Automation.PSCredential($Account, $secure)
    $cred | Export-Clixml -LiteralPath $CredFile -Force
    Write-Host "    已保存：$CredFile"
}

Write-Step '注册计划任务'
$action = New-ScheduledTaskAction `
    -Execute "$env:SystemRoot\System32\wscript.exe" `
    -Argument "`"$HiddenLauncher`""

$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $UserId
$triggerLogon.Delay = 'PT15S'

$principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$settings.DisallowStartIfOnBatteries = $false
$settings.StopIfGoingOnBatteries = $false

Register-ScheduledTask -TaskName $TaskName `
    -Action $action `
    -Trigger $triggerLogon `
    -Principal $principal `
    -Settings $settings `
    -Description '登录 Windows 后自动连接南邮校园网；只运行一次，不进行定时检查。' `
    -Force | Out-Null

Write-Host "    任务名称：$TaskName"
Write-Host '    触发时机：登录 Windows 后 15 秒，仅运行一次（无定时检查）'
Write-Host '    运行方式：wscript 隐藏启动，不会闪现命令行窗口'

Write-Step '创建桌面快捷方式'
$desktop = [Environment]::GetFolderPath('Desktop')
$wsh = New-Object -ComObject WScript.Shell

$shortcutPath = Join-Path $desktop '校园网立即登录.lnk'
$lnk = $wsh.CreateShortcut($shortcutPath)
$lnk.TargetPath = "$env:SystemRoot\System32\wscript.exe"
$lnk.Arguments = "`"$HiddenLauncher`""
$lnk.WorkingDirectory = $InstallDir
$lnk.WindowStyle = 1
$lnk.Description = '立即登录南邮校园网（后台静默运行）'
$lnk.Save()
Write-Host "    $shortcutPath"

$settingsShortcut = Join-Path $desktop '校园网设置.lnk'
$lnk2 = $wsh.CreateShortcut($settingsShortcut)
$lnk2.TargetPath = "$env:SystemRoot\System32\wscript.exe"
$lnk2.Arguments = "`"$UiLauncher`""
$lnk2.WorkingDirectory = $InstallDir
$lnk2.WindowStyle = 1
$lnk2.Description = '打开南邮校园网设置页'
$lnk2.Save()
Write-Host "    $settingsShortcut"

Write-Step '立即测试运行'
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $ScriptDst
$code = $LASTEXITCODE
if ($code -eq 0) {
    Write-Host '    测试结果：已在线 / 登录成功' -ForegroundColor Green
} else {
    Write-Host "    测试结果：返回码 $code，请查看日志" -ForegroundColor Yellow
}

$logFile = Join-Path $InstallDir 'autologin.log'
if (Test-Path -LiteralPath $logFile) {
    Write-Host ''
    Write-Host '最近日志：' -ForegroundColor Cyan
    Get-Content -LiteralPath $logFile -Tail 10 | ForEach-Object { Write-Host "    $_" }
}

Write-Host ''
Write-Host '安装完成。下次开机登录 Windows 后会自动联网。' -ForegroundColor Green
Write-Host "日志文件：$logFile"
Write-Host '桌面已生成两个快捷方式：校园网设置 / 校园网立即登录'
Write-Host '如需卸载，运行同目录下的 uninstall.ps1。'
