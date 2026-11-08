#Requires -Version 5.1
<#
    校园网 - 本地设置页服务
    只监听 127.0.0.1，供 settings.html 读写账号、密码、运营商。
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Port          = 8765
$Root          = $PSScriptRoot
$HtmlFile      = Join-Path $Root 'settings.html'
$SettingsFile  = Join-Path $Root 'settings.ini'
$CredFile      = Join-Path $Root 'cred.xml'
$AutoLog       = Join-Path $Root 'autologin.log'
$UiLog         = Join-Path $Root 'ui.log'
$IdleMinutes   = 30

function Write-UiLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $UiLog -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    } catch { }
}

function Send-Bytes {
    param($Context, [byte[]]$Bytes, [string]$ContentType, [int]$StatusCode = 200)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentEncoding = [Text.Encoding]::UTF8
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Context.Response.Close()
}

function Send-Json {
    param($Context, $Object, [int]$StatusCode = 200)
    $json = $Object | ConvertTo-Json -Compress -Depth 6
    Send-Bytes -Context $Context -Bytes ([Text.Encoding]::UTF8.GetBytes($json)) `
        -ContentType 'application/json; charset=utf-8' -StatusCode $StatusCode
}

function Send-Error {
    param($Context, [int]$StatusCode, [string]$Message)
    Send-Json -Context $Context -Object @{ ok = $false; message = $Message } -StatusCode $StatusCode
}

function Get-SavedSettings {
    $account = ''
    $suffix = ''
    $mode = 'auto'
    $portalUrl = ''
    $service = ''
    if (Test-Path -LiteralPath $SettingsFile) {
        foreach ($line in Get-Content -LiteralPath $SettingsFile -Encoding UTF8) {
            if ($line -match '^\s*Account\s*=\s*(.*)$') { $account = $matches[1].Trim() }
            elseif ($line -match '^\s*Suffix\s*=\s*(.*)$') { $suffix = $matches[1].Trim() }
            elseif ($line -match '^\s*Mode\s*=\s*(.*)$') { $mode = $matches[1].Trim() }
            elseif ($line -match '^\s*PortalUrl\s*=\s*(.*)$') { $portalUrl = $matches[1].Trim() }
            elseif ($line -match '^\s*Service\s*=\s*(.*)$') { $service = $matches[1].Trim() }
        }
    }
    if ($mode -notin @('auto', 'njupt', 'drcom')) { $mode = 'auto' }
    return [pscustomobject]@{ Account = $account; Suffix = $suffix; Mode = $mode; PortalUrl = $portalUrl; Service = $service }
}

function Test-SavedPassword {
    if (-not (Test-Path -LiteralPath $CredFile)) { return $false }
    try {
        $null = (Import-Clixml -LiteralPath $CredFile).GetNetworkCredential().Password
        return $true
    } catch { return $false }
}

function Save-Credential {
    param([string]$Account, [string]$Password)
    $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($Account, $secure)
    $cred | Export-Clixml -LiteralPath $CredFile -Force
}

function Save-Settings {
    param([string]$Account, [string]$Suffix, [string]$Mode, [string]$PortalUrl, [string]$Service)
    $lines = @(
        '# 校园网自动登录配置',
        '# Mode: auto / njupt / drcom',
        '# 新版门户：Suffix=@cmcc（移动） / @njxy（电信） / 留空（校园网）',
        '# 通用 Dr.COM：PortalUrl=http://1.1.1.1/，Service 可留空',
        "Mode=$Mode",
        "PortalUrl=$PortalUrl",
        "Service=$Service",
        "Account=$Account",
        "Suffix=$Suffix"
    )
    Set-Content -LiteralPath $SettingsFile -Value $lines -Encoding UTF8
}

function Open-SettingsPage {
    $url = "http://127.0.0.1:$Port/"
    $browsers = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($browser in $browsers) {
        if (Test-Path -LiteralPath $browser) {
            try {
                Start-Process -FilePath $browser -ArgumentList @(
                    "--app=$url",
                    '--window-size=1060,820',
                    '--window-position=120,60'
                ) | Out-Null
                return
            } catch { }
        }
    }
    Start-Process $url | Out-Null
}

function Invoke-TestLogin {
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $script = Join-Path $Root 'campus_autologin.ps1'
    $proc = Start-Process -FilePath $ps -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$script`""
    ) -WindowStyle Hidden -Wait -PassThru

    $log = ''
    if (Test-Path -LiteralPath $AutoLog) {
        $log = (Get-Content -LiteralPath $AutoLog -Tail 3 -ErrorAction SilentlyContinue) -join "`n"
    }
    return [pscustomobject]@{ ok = ($proc.ExitCode -eq 0); log = $log }
}

# ---------------- 启动 ----------------
if (-not (Test-Path -LiteralPath $HtmlFile)) {
    Write-UiLog "找不到页面文件：$HtmlFile"
    exit 1
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
} catch {
    # 已经有一个设置页服务在运行：直接打开它
    Open-SettingsPage
    exit 0
}

$token = [guid]::NewGuid().ToString('N')
$html = Get-Content -LiteralPath $HtmlFile -Raw -Encoding UTF8
$html = $html.Replace('__TOKEN__', $token)

Write-UiLog "settings server started on 127.0.0.1:$Port"
Open-SettingsPage

$started = Get-Date
$running = $true

while ($running) {
    $async = $listener.BeginGetContext($null, $null)
    while (-not $async.AsyncWaitHandle.WaitOne(500)) {
        if (((Get-Date) - $started).TotalMinutes -gt $IdleMinutes) {
            $running = $false
            break
        }
    }
    if (-not $running) { break }

    try {
        $context = $listener.EndGetContext($async)
    } catch {
        continue
    }

    try {
        $path = $context.Request.Url.AbsolutePath

        if ($path -eq '/' -or $path -eq '/index.html') {
            Send-Bytes -Context $context -Bytes ([Text.Encoding]::UTF8.GetBytes($html)) `
                -ContentType 'text/html; charset=utf-8'
            continue
        }

        if ($context.Request.Headers['X-Token'] -ne $token) {
            Send-Error -Context $context -StatusCode 403 -Message '无效的访问令牌，请重新打开设置页。'
            continue
        }

        if ($path -eq '/api/status') {
            $saved = Get-SavedSettings
            Send-Json -Context $context -Object @{
                ok          = $true
                account     = $saved.Account
                suffix      = $saved.Suffix
                mode        = $saved.Mode
                portalUrl   = $saved.PortalUrl
                service     = $saved.Service
                hasPassword = (Test-SavedPassword)
            }
            continue
        }

        if ($path -eq '/api/save') {
            $reader = New-Object System.IO.StreamReader($context.Request.InputStream, [Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd()
            $reader.Dispose()
            if ([string]::IsNullOrWhiteSpace($body)) { throw '请求内容为空' }

            $data = $body | ConvertFrom-Json
            $account = [string]$data.account
            $password = [string]$data.password
            $suffix = [string]$data.suffix
            $mode = [string]$data.mode
            $portalUrl = [string]$data.portalUrl
            $service = [string]$data.service
            if ($null -eq $account) { $account = '' }
            if ($null -eq $password) { $password = '' }
            if ($null -eq $suffix) { $suffix = '' }
            if ($null -eq $mode) { $mode = 'auto' }
            if ($null -eq $portalUrl) { $portalUrl = '' }
            if ($null -eq $service) { $service = '' }
            $account = $account.Trim()
            $suffix = $suffix.Trim()
            $mode = $mode.Trim().ToLower()
            $portalUrl = $portalUrl.Trim()
            $service = $service.Trim()

            if (-not $account) { throw '请输入学号或账号' }
            if ($account.Length -gt 64) { throw '账号过长' }
            if ($account -notmatch '^[A-Za-z0-9@._-]+$') { throw '账号只能包含字母、数字和 @ . _ -' }
            if ($suffix -notin @('', '@cmcc', '@njxy')) { throw '不支持的运营商' }
            if ($mode -notin @('auto', 'njupt', 'drcom')) { throw '不支持的认证方式' }
            if ($portalUrl) {
                if ($portalUrl.Length -gt 300) { throw '认证页地址过长' }
                if ($portalUrl -notmatch '^https?://') { throw '认证页地址需要以 http:// 或 https:// 开头' }
            }
            if ($service.Length -gt 64) { throw '服务名过长' }

            if ($password) {
                if ($password.Length -gt 128) { throw '密码过长' }
                Save-Credential -Account $account -Password $password
            } else {
                if (-not (Test-Path -LiteralPath $CredFile)) { throw '第一次使用，请输入密码' }
                $old = (Import-Clixml -LiteralPath $CredFile).GetNetworkCredential().Password
                Save-Credential -Account $account -Password $old
            }

            Save-Settings -Account $account -Suffix $suffix -Mode $mode -PortalUrl $portalUrl -Service $service
            Write-UiLog "settings saved: account=$account mode=$mode suffix=$suffix portal=$portalUrl service=$service"
            Send-Json -Context $context -Object @{ ok = $true }
            continue
        }

        if ($path -eq '/api/test') {
            $result = Invoke-TestLogin
            Send-Json -Context $context -Object @{ ok = $result.ok; log = $result.log }
            continue
        }

        if ($path -eq '/api/close') {
            Send-Json -Context $context -Object @{ ok = $true }
            $running = $false
            continue
        }

        Send-Error -Context $context -StatusCode 404 -Message '接口不存在'
    } catch {
        Write-UiLog "request error: $($_.Exception.Message)"
        try {
            Send-Error -Context $context -StatusCode 500 -Message $_.Exception.Message
        } catch { }
    }
}

try { $listener.Stop() } catch { }
try { $listener.Close() } catch { }
Write-UiLog 'settings server stopped'

