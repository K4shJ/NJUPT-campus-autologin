<#
.SYNOPSIS
    南京邮电大学校园网自动登录（中国移动 @cmcc）
.DESCRIPTION
    开机/登录 Windows 后自动检测是否已在线；若未在线，则向校园网认证网关提交
    账号 YOUR_ACCOUNT@cmcc 完成登录。可重复运行，已在线时会在 1 秒内退出。
.NOTES
    账号密码保存在同目录的 cred.xml（Windows DPAPI 加密，仅当前用户可解密）。
#>

#Requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ======================== 可修改配置 ========================
$PortalHost   = 'https://p.njupt.edu.cn:804'
$PortalApi    = "$PortalHost/eportal/portal"
$PageUrl      = 'https://p.njupt.edu.cn/a79.htm'
$UserAgent    = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'
$JsVersion    = '4.5'
$Account      = 'YOUR_ACCOUNT'
$Suffix       = '@cmcc'          # 中国移动；校园网为 ''，电信为 '@njxy'
$CredentialFile = Join-Path $PSScriptRoot 'cred.xml'
$SettingsFile = Join-Path $PSScriptRoot 'settings.ini'
$LogDir       = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin'
$LogFile      = Join-Path $LogDir 'autologin.log'
$PortalOpenMarker = Join-Path $LogDir 'last-portal-open.txt'
$MaxLogBytes  = 512KB
$OpenPortalOnFailure = $true    # 登录失败时自动打开认证页，方便手动登录
# ============================================================

# 可选：settings.ini 可覆盖账号与运营商后缀，方便以后切换（校园网留空，电信 @njxy）
if (Test-Path -LiteralPath $SettingsFile) {
    try {
        foreach ($line in Get-Content -LiteralPath $SettingsFile -Encoding UTF8) {
            if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
            $key, $value = $line.Split('=', 2)
            switch ($key.Trim()) {
                'Account' { $Account = $value.Trim() }
                'Suffix'  { $Suffix  = $value.Trim() }
            }
        }
    } catch { }
}

# 确保日志目录存在
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    try {
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt $MaxLogBytes)) {
            Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.old') -Force
        }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch { }
}

function New-QueryString {
    param([System.Collections.IDictionary]$Params)
    $parts = foreach ($key in $Params.Keys) {
        '{0}={1}' -f [Uri]::EscapeDataString([string]$key), [Uri]::EscapeDataString([string]$Params[$key])
    }
    return ($parts -join '&')
}

function Invoke-PortalRequest {
    <#
        使用 HttpWebRequest 直连（显式禁用系统代理），避免 Clash 等代理软件
        把校园网内网请求劫持走代理导致认证失败。
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSeconds = 15
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.Proxy = $null
    $request.Timeout = $TimeoutSeconds * 1000
    $request.ReadWriteTimeout = $TimeoutSeconds * 1000
    $request.UserAgent = $UserAgent
    $request.Accept = '*/*'
    $request.Referer = $PageUrl
    $request.KeepAlive = $false

    $response = $null
    try {
        $response = $request.GetResponse()
        $contentType = [string]$response.ContentType
        $stream = $response.GetResponseStream()
        $memory = New-Object System.IO.MemoryStream
        $stream.CopyTo($memory)
        $bytes = $memory.ToArray()
        $memory.Dispose()
        $stream.Dispose()

        # 门户有些接口返回 UTF-8，有些返回 GBK/GB2312，按响应头解码
        $charset = ''
        if ($contentType -match 'charset\s*=\s*([^;]+)') { $charset = $matches[1].Trim().Trim('"') }
        if ($charset -match 'utf-?8') {
            return [Text.Encoding]::UTF8.GetString($bytes)
        }
        if ($charset -match 'gbk|gb2312|gb18030') {
            return [Text.Encoding]::GetEncoding(936).GetString($bytes)
        }
        try {
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            return $strictUtf8.GetString($bytes)
        } catch {
            return [Text.Encoding]::GetEncoding(936).GetString($bytes)
        }
    } finally {
        if ($response) { $response.Dispose() }
    }
}

function ConvertFrom-Jsonp {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $first = $Text.IndexOf('(')
    $last  = $Text.LastIndexOf(')')
    if ($first -ge 0 -and $last -gt $first) {
        $json = $Text.Substring($first + 1, $last - $first - 1)
    } else {
        $json = $Text
    }
    try { return $json | ConvertFrom-Json } catch { return $null }
}

function Get-PortalConfig {
    param([string]$ClientIp)
    $ipB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ClientIp))
    $url = "$PortalApi/page/loadConfig?callback=dr1001&jsVersion=$JsVersion" +
           "&wlan_user_ip=$([Uri]::EscapeDataString($ipB64))" +
           "&wlan_user_mac=000000000000&wlan_user_ipv6=&wlan_user_ssid=&wlan_user_areaid=" +
           "&wlan_ac_ip=&wlan_ap_mac=000000000000&gw_id=000000000000&lang=zh"
    $text = Invoke-PortalRequest -Url $url
    $json = ConvertFrom-Jsonp -Text $text
    if (-not $json -or $json.code -ne 1) {
        throw "读取门户配置失败：$($text.Substring(0, [Math]::Min(200, $text.Length)))"
    }
    return $json.data
}

function Get-OnlineState {
    param([string]$ClientIp, [object]$Config)
    $ipB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ClientIp))
    $url = "$PortalApi/online_list?callback=dr1002" +
           "&user_account=&user_password=&wlan_user_mac=000000000000" +
           "&wlan_user_ip=$([Uri]::EscapeDataString($ipB64))&wlan_user_ipv6=" +
           "&jsVersion=$JsVersion&program_index=$($Config.program_index)" +
           "&page_index=$($Config.page_index)&lang=zh"
    $text = Invoke-PortalRequest -Url $url
    $json = ConvertFrom-Jsonp -Text $text
    $online = $false
    $account = ''
    if ($json -and $json.result -eq 1) {
        $list = @($json.list)
        if ($list.Count -gt 0) {
            $online = $true
            $account = [string]$list[0].user_account
        }
    }
    return [pscustomobject]@{
        Online  = $online
        Account = $account
        Raw     = $text
    }
}

function Invoke-PortalLogin {
    param([string]$ClientIp, [object]$Config, [string]$Password)

    $fullAccount = $Account + $Suffix
    # 门户 account_prefix=1：PC 端 user_account 前需要加 ",0,"
    $prefix = if ([string]$Config.account_prefix -eq '1') { ',0,' } else { '' }
    $prefixedAccount = $prefix + $fullAccount
    # login_method=0 时门户走旧的 /drcom/login 接口
    $loginBase = if ([int]$Config.login_method -eq 0) { "$PortalHost/drcom" } else { $PortalApi }

    $params = [ordered]@{
        callback        = 'dr1003'
        DDDDD           = $fullAccount
        upass           = $Password
        '0MKKey'        = '123456'
        R1              = '0'
        R2              = '0'
        R3              = '0'
        R6              = '0'
        para            = '00'
        v6ip            = ''
        R7              = '0'
        user_account    = $prefixedAccount
        user_password   = $Password
        wlan_user_ip    = $ClientIp
        wlan_user_ipv6  = ''
        authex_enable   = ''
        wlan_user_mac   = '000000000000'
        wlan_ac_name    = ''
        jsVersion       = $JsVersion
        terminal_type   = '1'
        lang            = 'zh-cn'
        user_agent      = $UserAgent
        enable_r3       = '0'
        mac_type        = '0'
        rcn             = [string]$Config.rcn
        operate         = 'portal_login'
        business_type   = '0'
        program_index   = [string]$Config.program_index
        page_index      = [string]$Config.page_index
        v               = [string](Get-Random -Minimum 500 -Maximum 9999)
    }

    $url = "$loginBase/login?" + (New-QueryString -Params $params)
    $text = Invoke-PortalRequest -Url $url
    $json = ConvertFrom-Jsonp -Text $text
    return [pscustomobject]@{
        Success = ($json -and ($json.result -eq 1 -or $json.result -eq 'ok'))
        Message = if ($json) { [string]$json.msg } else { $text }
        Raw     = $text
    }
}

function Get-CandidateClientIps {
    <#
        返回可能承载校园网的 IPv4 地址，默认路由所在的网卡优先。
        过滤掉回环、169.254、虚拟网卡。
    #>
    $list = New-Object System.Collections.ArrayList
    $seen = @{}

    $add = {
        param($ip, $metric)
        if ([string]::IsNullOrWhiteSpace($ip)) { return }
        # 南邮校园网使用 10.x 地址；家里/热点通常是 192.168.x，直接跳过
        if ($ip -notlike '10.*') { return }
        if ($ip -like '169.254.*' -or $ip -eq '127.0.0.1') { return }
        if ($seen.ContainsKey($ip)) { return }
        $seen[$ip] = $true
        [void]$list.Add([pscustomobject]@{ IP = $ip; Metric = $metric })
    }

    # 1) 默认路由所在网卡
    try {
        $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                  Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' }
        foreach ($route in $routes) {
            $adapter = Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue
            if (-not $adapter -or $adapter.Virtual -or $adapter.Status -ne 'Up') { continue }
            $iface = Get-NetIPInterface -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $ifMetric = if ($iface) { [int]$iface.InterfaceMetric } else { 9999 }
            $addr = Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
                    Select-Object -First 1
            if ($addr) { & $add $addr.IPAddress ([int]$route.RouteMetric + $ifMetric) }
        }
    } catch { }

    # 2) 其他处于 Up 状态、持有 10.x 地址的物理网卡（应对默认路由尚未建立的情况）
    try {
        $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
        foreach ($adapter in $adapters) {
            $addr = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -like '10.*' -and $_.IPAddress -notlike '169.254.*' } |
                    Select-Object -First 1
            if ($addr) { & $add $addr.IPAddress 5000 }
        }
    } catch { }

    return @($list | Sort-Object Metric)
}

function Test-NetworkPending {
    # 网卡已启用但还没有有效 IPv4（DHCP 尚未完成）时，等待网络就绪
    try {
        $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
        foreach ($adapter in $adapters) {
            $addrs = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                       Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' })
            if ($addrs.Count -eq 0) { return $true }
        }
    } catch { }
    return $false
}

function Get-CredentialFromFile {
    if (-not (Test-Path -LiteralPath $CredentialFile)) {
        throw "找不到凭据文件 $CredentialFile，请先运行 install.ps1"
    }
    $cred = Import-Clixml -LiteralPath $CredentialFile
    return $cred.GetNetworkCredential().Password
}

# ============================== 主流程 ==============================
$mutex = New-Object System.Threading.Mutex($false, 'Local\NJUPT_CampusAutoLogin')
$hasLock = $false
try {
    try { $hasLock = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $hasLock = $true }
    if (-not $hasLock) { return }

    $password = Get-CredentialFromFile
    Write-Log '自动登录检查开始。'

    # 开机后网络可能还没就绪，最多等待约 60 秒
    $clientIp = $null
    for ($wait = 0; $wait -lt 12; $wait++) {
        $candidates = @(Get-CandidateClientIps)
        if ($candidates.Count -gt 0) { break }
        if (-not (Test-NetworkPending)) { break }
        Start-Sleep -Seconds 5
    }
    if ($candidates.Count -eq 0) {
        # 没有 10.x 校园网地址（例如在家里/手机热点），静默退出，避免刷日志
        exit 0
    }
    Write-Log ("候选网卡地址：" + (($candidates | ForEach-Object { $_.IP }) -join ', '))

    $lastError = ''
    foreach ($candidate in $candidates) {
        $ip = $candidate.IP
        try {
            $config = Get-PortalConfig -ClientIp $ip
        } catch {
            $lastError = "无法连接校园网认证网关（$ip）：$($_.Exception.Message)"
            continue
        }

        $state = Get-OnlineState -ClientIp $ip -Config $config
        if ($state.Online) {
            if ($state.Account -and $state.Account -ne ($Account + $Suffix)) {
                Write-Log "当前已在线，但在线账号为 $($state.Account)（期望 $Account$Suffix）。" 'WARN'
            } else {
                Write-Log "已在线（$ip，账号 $($state.Account)），无需登录。"
            }
            exit 0
        }

        Write-Log "检测到未在线（$ip），正在登录 $Account$Suffix ..."
        $login = Invoke-PortalLogin -ClientIp $ip -Config $config -Password $password
        if ($login.Success) {
            Write-Log "登录请求成功：$($login.Message)"
        } else {
            Write-Log "登录返回：$($login.Message)（$($login.Raw.Trim())）" 'WARN'
        }

        # 登录接口有时返回异常但实际已上线，以在线状态为准
        for ($i = 0; $i -lt 6; $i++) {
            Start-Sleep -Seconds 2
            try {
                $verify = Get-OnlineState -ClientIp $ip -Config $config
                if ($verify.Online) {
                    Write-Log "登录成功并已确认在线（$ip，账号 $($verify.Account)）。"
                    exit 0
                }
            } catch { }
        }

        $lastError = "登录后仍检测为离线：$($login.Message)"
    }

    Write-Log "自动登录失败：$lastError" 'ERROR'
    if ($OpenPortalOnFailure) {
        # 30 分钟内最多弹一次认证页，避免反复打扰
        $shouldOpen = $true
        if (Test-Path -LiteralPath $PortalOpenMarker) {
            $lastOpen = (Get-Item -LiteralPath $PortalOpenMarker).LastWriteTime
            if (((Get-Date) - $lastOpen).TotalMinutes -lt 30) { $shouldOpen = $false }
        }
        if ($shouldOpen) {
            try {
                Set-Content -LiteralPath $PortalOpenMarker -Value (Get-Date -Format 'o') -Encoding UTF8
                Start-Process $PageUrl | Out-Null
            } catch { }
        }
    }
    exit 1
} catch {
    Write-Log "脚本异常：$($_.Exception.Message)" 'ERROR'
    exit 1
} finally {
    if ($hasLock) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}

