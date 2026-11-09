<#
.SYNOPSIS
    校园网自动登录
.DESCRIPTION
    支持两类 Dr.COM 认证门户：
      1. 新版门户：GET /eportal/portal/login（JSONP）
      2. 旧版门户：POST /InterFace.do?method=login（含 RSA 密码）
    登录 Windows 后自动检测一次；未在线则认证。可重复运行。

    配置保存在同目录 settings.ini，密码用 Windows DPAPI 加密保存在 cred.xml。
#>

#Requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Numerics

# ======================== 默认配置 ========================
$NjuptHost      = 'https://p.njupt.edu.cn:804'
$NjuptApi       = "$NjuptHost/eportal/portal"
$NjuptPageUrl   = 'https://p.njupt.edu.cn/a79.htm'
$DefaultDrcomUrl = 'http://1.1.1.1/'
$UserAgent      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'
$JsVersion      = '4.5'

$Mode           = 'auto'          # auto / njupt / drcom
$PortalUrl      = ''              # 旧版门户认证页；留空用 http://1.1.1.1/
$Service        = ''              # 旧版门户服务名；留空用门户默认
$Account        = 'YOUR_ACCOUNT'
$Suffix         = '@cmcc'         # 新版门户：中国移动 @cmcc，电信 @njxy，校园网留空

$CredentialFile = Join-Path $PSScriptRoot 'cred.xml'
$SettingsFile   = Join-Path $PSScriptRoot 'settings.ini'
$LogDir         = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin'
$LogFile        = Join-Path $LogDir 'autologin.log'
$PortalOpenMarker = Join-Path $LogDir 'last-portal-open.txt'
$MaxLogBytes    = 512KB
$OpenPortalOnFailure = $true
# ==========================================================

# 读取 settings.ini
if (Test-Path -LiteralPath $SettingsFile) {
    try {
        foreach ($line in Get-Content -LiteralPath $SettingsFile -Encoding UTF8) {
            if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
            $key, $value = $line.Split('=', 2)
            $value = $value.Trim()
            switch ($key.Trim()) {
                'Mode'      { $Mode = $value.ToLower() }
                'PortalUrl' { $PortalUrl = $value }
                'Service'   { $Service = $value }
                'Account'   { $Account = $value }
                'Suffix'    { $Suffix = $value }
            }
        }
    } catch { }
}
if ($Mode -notin @('auto', 'njupt', 'drcom')) { $Mode = 'auto' }
$PortalUrl = $PortalUrl.Trim()
$Service = $Service.Trim()

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

function Convert-BytesToText {
    param([byte[]]$Bytes, [string]$ContentType)
    $charset = ''
    if ($ContentType -match 'charset\s*=\s*([^;]+)') {
        $charset = $matches[1].Trim().Trim('"').Trim("'")
    }
    if (-not $charset -and $Bytes.Length -gt 0) {
        $headLen = [Math]::Min(2048, $Bytes.Length)
        $head = [Text.Encoding]::ASCII.GetString($Bytes, 0, $headLen)
        if ($head -match '<meta[^>]+charset\s*=\s*["'']?([^"'' />]+)') {
            $charset = $matches[1].Trim()
        }
    }
    if ($charset -match 'utf-?8') { return [Text.Encoding]::UTF8.GetString($Bytes) }
    if ($charset -match 'gbk|gb2312|gb18030') { return [Text.Encoding]::GetEncoding(936).GetString($Bytes) }
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        return $strictUtf8.GetString($Bytes)
    } catch {
        return [Text.Encoding]::GetEncoding(936).GetString($Bytes)
    }
}

function Invoke-Http {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Method = 'GET',
        [string]$Body = $null,
        [string]$ContentType = 'application/x-www-form-urlencoded; charset=UTF-8',
        [int]$TimeoutSeconds = 15,
        [switch]$InsecureCert,
        [System.Net.CookieContainer]$CookieContainer = $null,
        [string]$Referer = ''
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $previousCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    if ($InsecureCert) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { param($a, $b, $c, $d) $true }
    }

    $response = $null
    try {
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.Method = $Method
        $request.Proxy = $null
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.UserAgent = $UserAgent
        $request.Accept = '*/*'
        $request.KeepAlive = $false
        $request.AllowAutoRedirect = $true
        if ($Referer) { $request.Referer = $Referer }
        if ($CookieContainer) { $request.CookieContainer = $CookieContainer }
        else { $request.CookieContainer = New-Object Net.CookieContainer }

        if (-not [string]::IsNullOrEmpty($Body)) {
            $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $request.ContentType = $ContentType
            $request.ContentLength = $bodyBytes.Length
            $stream = $request.GetRequestStream()
            $stream.Write($bodyBytes, 0, $bodyBytes.Length)
            $stream.Close()
        }

        try {
            $response = $request.GetResponse()
        } catch [Net.WebException] {
            if ($_.Exception.Response) { $response = $_.Exception.Response } else { throw }
        }

        $status = [int]$response.StatusCode
        $contentType = [string]$response.ContentType
        $finalUrl = $response.ResponseUri.AbsoluteUri
        $stream = $response.GetResponseStream()
        $memory = New-Object System.IO.MemoryStream
        $stream.CopyTo($memory)
        $bytes = $memory.ToArray()
        $memory.Dispose()
        $stream.Dispose()
        $text = Convert-BytesToText -Bytes $bytes -ContentType $contentType

        if ($status -ge 400) {
            throw "HTTP $status：$($text.Substring(0, [Math]::Min(300, $text.Length)))"
        }

        return [pscustomobject]@{
            Content     = $text
            FinalUrl    = $finalUrl
            StatusCode  = $status
            ContentType = $contentType
        }
    } finally {
        if ($response) { $response.Dispose() }
        if ($InsecureCert) {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
        }
    }
}

function ConvertFrom-JsonSafe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $clean = $Text.Trim().TrimStart([char]0xFEFF)
    try { return $clean | ConvertFrom-Json } catch { }
    $first = $clean.IndexOf('(')
    $last = $clean.LastIndexOf(')')
    if ($first -ge 0 -and $last -gt $first) {
        try { return $clean.Substring($first + 1, $last - $first - 1) | ConvertFrom-Json } catch { }
    }
    $first = $clean.IndexOf('{')
    $last = $clean.LastIndexOf('}')
    if ($first -ge 0 -and $last -gt $first) {
        try { return $clean.Substring($first, $last - $first + 1) | ConvertFrom-Json } catch { }
    }
    return $null
}

function ConvertTo-JsUriComponent {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $s = [Uri]::EscapeDataString($Text)
    # 与 JavaScript encodeURIComponent 保持一致
    $s = $s.Replace('%21', '!').Replace('%27', "'").Replace('%28', '(').Replace('%29', ')').Replace('%2A', '*')
    return $s
}

function ConvertTo-DoubleEncoded {
    param([string]$Text)
    return ConvertTo-JsUriComponent (ConvertTo-JsUriComponent $Text)
}

# ======================== 新版门户 ========================
function ConvertFrom-Jsonp {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $first = $Text.IndexOf('(')
    $last = $Text.LastIndexOf(')')
    if ($first -ge 0 -and $last -gt $first) {
        $json = $Text.Substring($first + 1, $last - $first - 1)
    } else {
        $json = $Text
    }
    try { return $json | ConvertFrom-Json } catch { return $null }
}

function Get-NjuptConfig {
    param([string]$ClientIp, [int]$TimeoutSeconds = 15, [string]$WlanMac = '000000000000')
    $ipB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ClientIp))
    $url = "$NjuptApi/page/loadConfig?callback=dr1001&jsVersion=$JsVersion" +
           "&wlan_user_ip=$([Uri]::EscapeDataString($ipB64))" +
           "&wlan_user_mac=$WlanMac&wlan_user_ipv6=&wlan_user_ssid=&wlan_user_areaid=" +
           "&wlan_ac_ip=&wlan_ap_mac=000000000000&gw_id=000000000000&lang=zh"
    $res = Invoke-Http -Url $url -TimeoutSeconds $TimeoutSeconds -Referer $NjuptPageUrl
    $json = ConvertFrom-Jsonp -Text $res.Content
    if (-not $json -or $json.code -ne 1) {
        throw "读取新版门户配置失败：$($res.Content.Substring(0, [Math]::Min(160, $res.Content.Length)))"
    }
    return $json.data
}

function Get-NjuptOnlineState {
    param([string]$ClientIp, [object]$Config, [string]$WlanMac = '000000000000')
    $ipB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ClientIp))
    $url = "$NjuptApi/online_list?callback=dr1002" +
           "&user_account=&user_password=&wlan_user_mac=$WlanMac" +
           "&wlan_user_ip=$([Uri]::EscapeDataString($ipB64))&wlan_user_ipv6=" +
           "&jsVersion=$JsVersion&program_index=$($Config.program_index)" +
           "&page_index=$($Config.page_index)&lang=zh"
    $res = Invoke-Http -Url $url -Referer $NjuptPageUrl
    $json = ConvertFrom-Jsonp -Text $res.Content
    $online = $false
    $account = ''
    if ($json -and $json.result -eq 1) {
        $list = @($json.list)
        if ($list.Count -gt 0) {
            $online = $true
            $account = [string]$list[0].user_account
        }
    }
    return [pscustomobject]@{ Online = $online; Account = $account; Raw = $res.Content }
}

function Invoke-NjuptLogin {
    param([string]$ClientIp, [object]$Config, [string]$Password, [string]$WlanMac = '000000000000')
    $fullAccount = $Account + $Suffix
    $prefix = if ([string]$Config.account_prefix -eq '1') { ',0,' } else { '' }
    $prefixedAccount = $prefix + $fullAccount
    $loginBase = if ([int]$Config.login_method -eq 0) { "$NjuptHost/drcom" } else { $NjuptApi }

    $params = [ordered]@{
        callback = 'dr1003'; DDDDD = $fullAccount; upass = $Password; '0MKKey' = '123456'
        R1 = '0'; R2 = '0'; R3 = '0'; R6 = '0'; para = '00'; v6ip = ''
        R7 = '0'; user_account = $prefixedAccount; user_password = $Password
        wlan_user_ip = $ClientIp; wlan_user_ipv6 = ''; authex_enable = ''
        wlan_user_mac = $WlanMac; wlan_ac_name = ''; jsVersion = $JsVersion
        terminal_type = '1'; lang = 'zh-cn'; user_agent = $UserAgent
        enable_r3 = '0'; mac_type = '0'; rcn = [string]$Config.rcn
        operate = 'portal_login'; business_type = '0'
        program_index = [string]$Config.program_index; page_index = [string]$Config.page_index
        v = [string](Get-Random -Minimum 500 -Maximum 9999)
    }
    $pairs = foreach ($key in $params.Keys) {
        '{0}={1}' -f [Uri]::EscapeDataString([string]$key), [Uri]::EscapeDataString([string]$params[$key])
    }
    $url = "$loginBase/login?" + ($pairs -join '&')
    $res = Invoke-Http -Url $url -TimeoutSeconds 20 -Referer $NjuptPageUrl
    $json = ConvertFrom-Jsonp -Text $res.Content
    return [pscustomobject]@{
        Success = ($json -and ($json.result -eq 1 -or $json.result -eq 'ok'))
        Message = if ($json) { [string]$json.msg } else { $res.Content }
        Raw     = $res.Content
    }
}

function Get-CandidateClientIps {
    <#
        返回可能承载校园网的 IPv4 地址，默认路由所在的网卡优先。
        支持 10.x / 172.16-31.x / 192.168.x；过滤回环、169.254、虚拟网卡。
    #>
    $list = New-Object System.Collections.ArrayList
    $seen = @{}
    $add = {
        param($ip, $metric)
        if ([string]::IsNullOrWhiteSpace($ip)) { return }
        if ($ip -eq '127.0.0.1' -or $ip -like '169.254.*') { return }
        $isPrivate = ($ip -match '^10\.') -or ($ip -match '^172\.(1[6-9]|2[0-9]|3[01])\.') -or ($ip -match '^192\.168\.')
        if (-not $isPrivate) { return }
        if ($seen.ContainsKey($ip)) { return }
        $seen[$ip] = $true
        [void]$list.Add([pscustomobject]@{ IP = $ip; Metric = $metric })
    }

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

    try {
        $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
        foreach ($adapter in $adapters) {
            $addr = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notlike '169.254.*' } |
                    Select-Object -First 1
            if ($addr) { & $add $addr.IPAddress 5000 }
        }
    } catch { }

    return @($list | Sort-Object Metric)
}

function Get-MacForIp {
    param([string]$ClientIp)
    try {
        $addr = Get-NetIPAddress -IPAddress $ClientIp -AddressFamily IPv4 -ErrorAction Stop |
                Select-Object -First 1
        $adapter = Get-NetAdapter -InterfaceIndex $addr.InterfaceIndex -ErrorAction Stop
        $mac = ($adapter.MacAddress -replace '[-:]', '').ToUpper()
        if ($mac) { return $mac }
    } catch { }
    return '000000000000'
}

function Test-Internet {
    param([int]$TimeoutSeconds = 2)
    try {
        $res = Invoke-Http -Url 'http://www.msftconnecttest.com/connecttest.txt' -TimeoutSeconds $TimeoutSeconds
        return ($res.Content.Trim() -eq 'Microsoft Connect Test')
    } catch {
        return $false
    }
}

function Wait-NjuptOnline {
    param(
        [string]$ClientIp,
        [object]$Config,
        [string]$WlanMac = '000000000000',
        [int]$Rounds = 6,
        [int]$DelayMs = 250,
        [switch]$CheckInternet
    )
    for ($i = 0; $i -lt $Rounds; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds $DelayMs }
        try {
            $v = Get-NjuptOnlineState -ClientIp $ClientIp -Config $Config -WlanMac $WlanMac
            if ($v.Online) { return $v }
        } catch { }
        if ($CheckInternet -and $i -ge 1) {
            if (Test-Internet) {
                return [pscustomobject]@{ Online = $true; Account = '(internet)'; Raw = '' }
            }
        }
    }
    return $null
}

function Invoke-NjuptFlow {
    param([switch]$Probe)
    $handled = $false
    $candidates = @(Get-CandidateClientIps)
    $probeTimeout = if ($Probe) { 5 } else { 15 }

    foreach ($candidate in $candidates) {
        $ip = $candidate.IP
        $wlanMac = Get-MacForIp $ip
        try {
            $config = Get-NjuptConfig -ClientIp $ip -TimeoutSeconds $probeTimeout -WlanMac $wlanMac
        } catch {
            continue
        }
        $handled = $true
        Write-Log "识别为新版门户（$ip）。"

        try {
            $state = Get-NjuptOnlineState -ClientIp $ip -Config $config -WlanMac $wlanMac
            if ($state.Online) {
                Write-Log "已在线（$ip，账号 $($state.Account)），无需登录。"
                exit 0
            }
        } catch { }

        Write-Log "检测到未在线（$ip），正在登录 $Account$Suffix ..."
        $lastMessage = ''

        for ($attempt = 1; $attempt -le 3; $attempt++) {
            if ($attempt -gt 1) {
                Start-Sleep -Milliseconds 600
                try { $config = Get-NjuptConfig -ClientIp $ip -TimeoutSeconds 10 -WlanMac $wlanMac } catch { }
            }

            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                $login = Invoke-NjuptLogin -ClientIp $ip -Config $config -Password $script:Password -WlanMac $wlanMac
            } catch {
                $sw.Stop()
                $lastMessage = $_.Exception.Message
                Write-Log "第 $attempt 次登录请求异常（$([Math]::Round($sw.Elapsed.TotalSeconds, 1))s）：$lastMessage" 'WARN'
                continue
            }
            $sw.Stop()
            $lastMessage = $login.Message
            $elapsed = [Math]::Round($sw.Elapsed.TotalSeconds, 1)

            if ($login.Success) {
                Write-Log "登录请求成功（$elapsed s）：$($login.Message)"
            } else {
                Write-Log "第 $attempt 次登录返回（$elapsed s）：$($login.Message)" 'WARN'
            }

            $verify = Wait-NjuptOnline -ClientIp $ip -Config $config -WlanMac $wlanMac -Rounds 6 -DelayMs 250 -CheckInternet
            if ($verify) {
                $account = if ($verify.Account) { $verify.Account } else { $Account + $Suffix }
                Write-Log "登录成功并已确认在线（$ip，账号 $account）。"
                exit 0
            }

            if ($login.Success) {
                Write-Log "登录请求已成功，门户状态暂未刷新，按成功处理（$ip）。"
                exit 0
            }
        }

        Write-Log "新版门户在 $ip 登录失败：$lastMessage" 'ERROR'
        # 继续尝试下一个网卡/IP
    }

    if ($handled) {
        if ($OpenPortalOnFailure) { Open-PortalPage $NjuptPageUrl }
        exit 1
    }
    return $false
}

# ======================== 旧版门户 ========================
function Get-BaseUrl {
    param([string]$Url)
    $uri = [Uri]$Url
    $base = $uri.GetLeftPart([UriPartial]::Authority) + $uri.AbsolutePath
    if (-not $base.EndsWith('/')) {
        $idx = $base.LastIndexOf('/')
        if ($idx -ge 0) { $base = $base.Substring(0, $idx + 1) }
    }
    return $base
}

function Get-HtmlInputValue {
    param([string]$Html, [string]$Id)
    $pattern = '<input\b[^>]*(?:id|name)\s*=\s*["'']' + [regex]::Escape($Id) + '["''][^>]*>'
    $tag = [regex]::Match($Html, $pattern, 'IgnoreCase')
    if (-not $tag.Success) { return '' }
    $value = [regex]::Match($tag.Value, '\bvalue\s*=\s*["'']([^"'']*)["'']', 'IgnoreCase')
    if (-not $value.Success) { return '' }
    return [Net.WebUtility]::HtmlDecode($value.Groups[1].Value)
}

function Get-DrcomPage {
    param([string]$Url)
    $cookies = New-Object Net.CookieContainer
    $res = Invoke-Http -Url $Url -TimeoutSeconds 18 -InsecureCert -CookieContainer $cookies
    return [pscustomobject]@{
        Html     = $res.Content
        FinalUrl = $res.FinalUrl
        BaseUrl  = (Get-BaseUrl $res.FinalUrl)
        Cookies  = $cookies
    }
}

function Get-DrcomPortalInfo {
    param([object]$Page, [string]$ServiceOverride)
    $html = $Page.Html

    $passwordEncrypt = Get-HtmlInputValue -Html $html -Id 'passwordEncrypt'
    $publicKeyExponent = Get-HtmlInputValue -Html $html -Id 'publicKeyExponent'
    $publicKeyModulus = Get-HtmlInputValue -Html $html -Id 'publicKeyModulus'
    $queryString = ''
    if ($Page.FinalUrl -match '\?(.+)$') { $queryString = $matches[1] }
    if (-not $queryString) { $queryString = Get-HtmlInputValue -Html $html -Id 'queryString' }

    $prefixValue = Get-HtmlInputValue -Html $html -Id 'prefixValue'
    if (-not $prefixValue) {
        $m = [regex]::Match($html, '(?:var\s+)?prefixValue\s*=\s*["'']([^"'']*)["'']', 'IgnoreCase')
        if ($m.Success) { $prefixValue = $m.Groups[1].Value }
    }

    $service = $ServiceOverride
    if (-not $service) {
        $select = [regex]::Match($html, '<select[^>]*(?:id|name)\s*=\s*["'']net_access_type["''][^>]*>(.*?)</select>', 'Singleline,IgnoreCase')
        if ($select.Success) {
            $options = [regex]::Matches($select.Groups[1].Value, '<option[^>]*value\s*=\s*["'']([^"'']*)["''][^>]*>(.*?)</option>', 'Singleline,IgnoreCase')
            foreach ($opt in $options) {
                $val = [Net.WebUtility]::HtmlDecode($opt.Groups[1].Value).Trim()
                if ($val -ne '') { $service = $val; break }
            }
        }
    }

    $mac = ''
    if ($Page.FinalUrl -match '[?&]mac=([^&]+)') { $mac = [Uri]::UnescapeDataString($matches[1]) }
    if (-not $mac) { $mac = '111111111' }

    return [pscustomobject]@{
        BaseUrl            = $Page.BaseUrl
        FinalUrl           = $Page.FinalUrl
        Cookies            = $Page.Cookies
        PasswordEncrypt    = ($passwordEncrypt.Trim().ToLower() -eq 'true')
        PublicKeyExponent  = $publicKeyExponent
        PublicKeyModulus   = $publicKeyModulus
        PrefixValue        = $prefixValue
        QueryString        = $queryString
        Service            = $service
        Mac                = $mac
    }
}

function Convert-HexToBigInt {
    param([string]$Hex)
    $Hex = $Hex.Trim()
    if ($Hex.StartsWith('0x')) { $Hex = $Hex.Substring(2) }
    if ($Hex.Length -eq 0) { return [Numerics.BigInteger]::Zero }
    return [Numerics.BigInteger]::Parse('0' + $Hex, [Globalization.NumberStyles]::AllowHexSpecifier)
}

function Get-BigIntBitLength {
    param([Numerics.BigInteger]$Value)
    $b = $Value.ToByteArray()
    $i = $b.Length - 1
    while ($i -ge 0 -and $b[$i] -eq 0) { $i-- }
    if ($i -lt 0) { return 0 }
    $bits = $i * 8
    $top = $b[$i]
    while ($top -gt 0) { $bits++; $top = $top -shr 1 }
    return $bits
}

function Convert-BytesToBigIntLE {
    param([byte[]]$Bytes)
    $withZero = New-Object byte[] ($Bytes.Length + 1)
    [Array]::Copy($Bytes, 0, $withZero, 0, $Bytes.Length)
    return [Numerics.BigInteger]::new($withZero)
}

function Invoke-RsaRaw {
    param([string]$Text, [string]$ExponentHex, [string]$ModulusHex)
    $mod = Convert-HexToBigInt $ModulusHex
    $e = Convert-HexToBigInt $ExponentHex
    $bitLen = Get-BigIntBitLength $mod
    $chunkSize = 2 * [Math]::Floor(($bitLen - 1) / 16)
    if ($chunkSize -le 0) { throw '无效的 RSA 模数' }

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $blocks = [Math]::Ceiling($bytes.Length / $chunkSize)
    if ($blocks -lt 1) { $blocks = 1 }
    $padded = New-Object byte[] ($blocks * $chunkSize)
    [Array]::Copy($bytes, 0, $padded, 0, $bytes.Length)

    $parts = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $padded.Length; $i += $chunkSize) {
        $chunk = New-Object byte[] $chunkSize
        [Array]::Copy($padded, $i, $chunk, 0, $chunkSize)
        $m = Convert-BytesToBigIntLE $chunk
        $c = [Numerics.BigInteger]::ModPow($m, $e, $mod)
        [void]$parts.Add($c.ToString('x'))
    }
    return ($parts -join ' ')
}

function Invoke-DrcomApi {
    param([object]$Info, [string]$Method, [string]$Body)
    $url = $Info.BaseUrl + 'InterFace.do?method=' + $Method
    $res = Invoke-Http -Url $url -Method POST -Body $Body `
        -ContentType 'application/x-www-form-urlencoded; charset=UTF-8' `
        -TimeoutSeconds 20 -InsecureCert -CookieContainer $Info.Cookies -Referer $Info.FinalUrl
    return [pscustomobject]@{
        Json = (ConvertFrom-JsonSafe $res.Content)
        Raw  = $res.Content
    }
}

function Test-DrcomOnline {
    param([object]$Info)
    try {
        $body = 'queryString=' + (ConvertTo-DoubleEncoded $Info.QueryString)
        $result = Invoke-DrcomApi -Info $Info -Method 'pageInfo' -Body $body
        $json = $result.Json
        if ($json -and $json.userIndex) { return $true }
        if ($json -and ([string]$json.result -eq 'success') -and ([string]$json.message -match '在线|已登录')) { return $true }
    } catch { }
    return $false
}

function Invoke-DrcomLogin {
    param([object]$Info, [string]$LoginAccount, [string]$LoginPassword)
    $userId = $Info.PrefixValue + $LoginAccount
    $password = $LoginPassword
    $encryptFlag = 'false'

    if ($Info.PasswordEncrypt) {
        if (-not $Info.PublicKeyExponent -or -not $Info.PublicKeyModulus) {
            throw '门户启用了密码加密，但页面里没有找到 RSA 公钥'
        }
        $raw = $LoginPassword + '>' + $Info.Mac
        $reversed = -join ($raw.ToCharArray()[($raw.Length - 1)..0])
        $password = Invoke-RsaRaw -Text $reversed -ExponentHex $Info.PublicKeyExponent -ModulusHex $Info.PublicKeyModulus
        $encryptFlag = 'true'
    }

    $body = @(
        ('userId=' + (ConvertTo-DoubleEncoded $userId)),
        ('password=' + (ConvertTo-DoubleEncoded $password)),
        ('service=' + (ConvertTo-DoubleEncoded ([string]$Info.Service))),
        ('queryString=' + (ConvertTo-DoubleEncoded ([string]$Info.QueryString))),
        'operatorPwd=',
        'operatorUserId=',
        'validcode=',
        ('passwordEncrypt=' + (ConvertTo-DoubleEncoded $encryptFlag))
    ) -join '&'

    $result = Invoke-DrcomApi -Info $Info -Method 'login' -Body $body
    $json = $result.Json
    $success = $false
    $message = $result.Raw
    if ($json) {
        $message = [string]$json.message
        if ([string]$json.result -eq 'success' -or [string]$json.result -eq '1' -or [string]$json.result -eq 'ok') { $success = $true }
        if ([string]$json.message -match '成功|已在线|already') { $success = $true }
    }
    return [pscustomobject]@{
        Success = $success
        Message = $message
        Raw     = $result.Raw
    }
}

function Invoke-DrcomFlow {
    $url = if ($PortalUrl) { $PortalUrl } else { $DefaultDrcomUrl }
    try {
        $page = Get-DrcomPage $url
    } catch {
        Write-Log "无法打开旧版门户认证页（$url）：$($_.Exception.Message)" 'WARN'
        return $false
    }
    if ($page.Html -notmatch 'InterFace\.do|passwordEncrypt|login_bch') {
        Write-Log "认证页不是旧版门户（$url）。" 'WARN'
        return $false
    }

    $info = Get-DrcomPortalInfo -Page $page -ServiceOverride $Service
    Write-Log "识别为旧版门户（$($info.FinalUrl)）。"
    if ($info.PasswordEncrypt) { Write-Log '门户启用了 RSA 密码加密，将使用页面公钥加密。' }

    if (Test-DrcomOnline -Info $info) {
        Write-Log '已在线，无需登录。'
        exit 0
    }

    Write-Log "检测到未在线，正在登录 $Account ..."
    try {
        $login = Invoke-DrcomLogin -Info $info -LoginAccount $Account -LoginPassword $script:Password
    } catch {
        Write-Log "旧版门户登录异常：$($_.Exception.Message)" 'ERROR'
        if ($OpenPortalOnFailure) { Open-PortalPage $info.FinalUrl }
        exit 1
    }

    if ($login.Success) {
        Write-Log "登录成功：$($login.Message)"
        exit 0
    }
    if (Test-DrcomOnline -Info $info) {
        Write-Log '登录后已确认在线。'
        exit 0
    }

    Write-Log "旧版门户登录失败：$($login.Message)（$($login.Raw)）" 'ERROR'
    if ($OpenPortalOnFailure) { Open-PortalPage $info.FinalUrl }
    exit 1
}

# ======================== 公共 ========================
function Open-PortalPage {
    param([string]$Url)
    if (-not $Url) { return }
    try {
        $shouldOpen = $true
        if (Test-Path -LiteralPath $PortalOpenMarker) {
            $lastOpen = (Get-Item -LiteralPath $PortalOpenMarker).LastWriteTime
            if (((Get-Date) - $lastOpen).TotalMinutes -lt 30) { $shouldOpen = $false }
        }
        if ($shouldOpen) {
            Set-Content -LiteralPath $PortalOpenMarker -Value (Get-Date -Format 'o') -Encoding UTF8
            Start-Process $Url | Out-Null
        }
    } catch { }
}

function Get-CredentialFromFile {
    if (-not (Test-Path -LiteralPath $CredentialFile)) {
        throw "找不到凭据文件 $CredentialFile，请先运行 install.ps1 或打开设置页"
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

    $script:Password = Get-CredentialFromFile
    Write-Log "自动登录检查开始（模式：$Mode）。"

    $candidates = @(Get-CandidateClientIps)
    if ($candidates.Count -gt 0) {
        Write-Log ("候选网卡地址：" + (($candidates | ForEach-Object { $_.IP }) -join ', '))
    }

    if ($Mode -eq 'njupt') {
        if (-not (Invoke-NjuptFlow)) {
            Write-Log '没有找到新版门户，当前可能不在校园网。' 'ERROR'
            if ($OpenPortalOnFailure) { Open-PortalPage $NjuptPageUrl }
            exit 1
        }
        exit 1
    }

    $drcomFallbackUrl = if ($PortalUrl) { $PortalUrl } else { $DefaultDrcomUrl }

    if ($Mode -eq 'drcom') {
        if (-not (Invoke-DrcomFlow)) {
            Write-Log '没有找到旧版门户，请检查设置里的认证页地址。' 'ERROR'
            if ($OpenPortalOnFailure) { Open-PortalPage $drcomFallbackUrl }
            exit 1
        }
        exit 1
    }

    # auto：如果填了非新版地址，先试旧版门户；否则先试新版门户
    $preferDrcom = $PortalUrl -and ($PortalUrl -notmatch 'p\.njupt\.edu\.cn|a79\.htm')
    if ($preferDrcom) {
        if (Invoke-DrcomFlow) { exit 1 }
        if (-not (Invoke-NjuptFlow -Probe)) {
            Write-Log '没有识别到可用的认证门户。' 'ERROR'
            exit 1
        }
        exit 1
    } else {
        if (Invoke-NjuptFlow -Probe) { exit 1 }
        if (Invoke-DrcomFlow) { exit 1 }
        Write-Log '没有识别到可用的认证门户。' 'ERROR'
        if ($OpenPortalOnFailure) { Open-PortalPage $drcomFallbackUrl }
        exit 1
    }
} catch {
    Write-Log "脚本异常：$($_.Exception.Message)" 'ERROR'
    exit 1
} finally {
    if ($hasLock) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}













