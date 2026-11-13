<#
.SYNOPSIS
    Codex / ChatGPT 桌面版 × Proxifier (Windows) 只读自检脚本。

.DESCRIPTION
    Codex 升级、换网络或代理端口变化后，用它判断"当前 Proxifier 配置是否还适用"。
    只读：不修改配置、不重启进程；唯一写入是
    %LOCALAPPDATA%\codex-net-doctor\last-good-version（记录最后一次全部通过的版本）。

    检查七件事：
      1. Proxifier / 驱动 / Codex 进程状态；
      2. 当前 profile 的 DNS-through-proxy、QUIC 阻断、OpenAI 规则与顺序；
      3. 代理端口是否可达、SOCKS5 是否可用、经代理能否拿到境外出口；
      4. 系统层（不带任何代理设置）chatgpt.com 是否为 fake-IP 并真正走代理，
         规则外域名是否仍然直连；
      5. Codex 是否连了已知 DoH 服务商；
      6. 一批 OpenAI 域名的可达性；
      7. Codex 可执行文件路径与版本（升级后最容易变的部分）。

.PARAMETER Quiet
    只输出失败 / 警告项。

.PARAMETER NoRedact
    显示完整 IP 与 profile 名（默认脱敏；fake-IP 不含个人信息，始终显示）。

.PARAMETER Profile
    指定要检查的 .ppx 文件（例如 Proxifier 导出的 profile）。

.PARAMETER ProxyPort
    覆盖 profile 里的端口（临时验证另一个端口时用）。

.EXAMPLE
    ./codex-net-doctor.ps1

.EXAMPLE
    ./codex-net-doctor.ps1 -Quiet

.EXAMPLE
    ./codex-net-doctor.ps1 -Profile "$env:USERPROFILE\Desktop\Codex.ppx"
#>
[CmdletBinding()]
param(
    [switch]$Quiet,
    [switch]$NoRedact,
    [string]$Profile,
    [int]$ProxyPort = 0
)

$ErrorActionPreference = 'Continue'

$script:pass = 0
$script:fail = 0
$script:warn = 0
$script:hints = New-Object System.Collections.ArrayList

function Ok([string]$Text) {
    $script:pass++
    if (-not $Quiet) { Write-Host "  [OK] $Text" -ForegroundColor Green }
}
function Bad([string]$Text) {
    $script:fail++
    Write-Host "  [X]  $Text" -ForegroundColor Red
}
function Note([string]$Text) {
    $script:warn++
    Write-Host "  [!]  $Text" -ForegroundColor Yellow
}
function Hint([string]$Text) { [void]$script:hints.Add($Text) }
function Sec([string]$Text) {
    if (-not $Quiet) { Write-Host ''; Write-Host "== $Text ==" -ForegroundColor Cyan }
}

# ---------- 脱敏 ----------
function Test-FakeIp([string]$Ip) {
    if (-not $Ip) { return $false }
    if ($Ip -like '0.0.*') { return $true }                              # Proxifier v3 (macOS) 风格
    if ($Ip -like '127.*' -and $Ip -ne '127.0.0.1') { return $true }     # Proxifier v4 (Windows) 默认
    if ($Ip -like 'fd00:696e:6974:6578:*') { return $true }              # v4 fake IPv6
    if ($Ip -like '::ffff:127.*') { return $true }
    return $false
}
function Redact-Ip([string]$Ip) {
    if (-not $Ip) { return '<无>' }
    if ($NoRedact) { return $Ip }
    if (Test-FakeIp $Ip) { return $Ip }
    return '<redacted>'
}
function Redact-Name([string]$Name) { if ($NoRedact) { return $Name } else { return '<redacted>' } }

# ---------- 外部命令封装 ----------
$script:HasCurl = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)

function Invoke-CurlText([string[]]$CurlArgs) {
    if (-not $script:HasCurl) { return $null }
    $out = & curl.exe @CurlArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out -join "`n")
}

function Get-Trace([string[]]$CurlArgs) {
    $text = Invoke-CurlText $CurlArgs
    $ip = $null; $loc = $null
    if ($text) {
        foreach ($line in ($text -split "`n")) {
            if ($line -match '^\s*ip=(.+?)\s*$') { $ip = $Matches[1] }
            if ($line -match '^\s*loc=(.+?)\s*$') { $loc = $Matches[1] }
        }
    }
    return [pscustomobject]@{ Ip = $ip; Loc = $loc; Raw = $text }
}

function Get-HttpCode([string]$Url, [string[]]$ProxyCurlArgs) {
    if (-not $script:HasCurl) { return 'n/a' }
    $a = @('-s', '-m', '12', '-o', 'NUL', '-w', '%{http_code}')
    if ($ProxyCurlArgs) { $a += $ProxyCurlArgs } else { $a += @('--noproxy', '*') }
    $a += $Url
    $code = & curl.exe @a 2>$null
    if ($LASTEXITCODE -ne 0 -and -not $code) { return '000' }
    return ("$code").Trim()
}

function Get-ProxyCurlArgs([string]$Type, [string]$Addr, [int]$Port) {
    if ($Type -eq 'SOCKS5') { return @('--socks5-hostname', "$Addr`:$Port") }
    return @('-x', "http://$Addr`:$Port")
}

function Resolve-A([string]$Name) {
    $r = Resolve-DnsName -Name $Name -Type A -DnsOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress } | Select-Object -First 1
    if ($r) { return "$($r.IPAddress)" }
    return $null
}

function Test-Socks5([string]$Addr, [int]$Port) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        if (-not $c.ConnectAsync($Addr, $Port).Wait(2500)) { return 'timeout' }
        $s = $c.GetStream()
        $s.ReadTimeout = 2500
        $greet = [byte[]](5, 1, 0)
        $s.Write($greet, 0, 3)
        $buf = New-Object byte[] 2
        $n = $s.Read($buf, 0, 2)
        $c.Close()
        if ($n -lt 2 -or $buf[0] -ne 5) { return 'bad' }
        if ($buf[1] -eq 0) { return 'ok' }
        if ($buf[1] -eq 255) { return 'auth' }
        return "method=$($buf[1])"
    } catch {
        return "err: $($_.Exception.Message)"
    }
}

$DohIps = @('1.1.1.1', '1.0.0.1', '8.8.8.8', '8.8.4.4', '9.9.9.9', '149.112.112.112', '2606:4700:4700::1111')
$ProbeHosts = @('openai.com', 'chatgpt.com', 'auth.openai.com', 'api.openai.com', 'cdn.oaistatic.com', 'ab.chatgpt.com', 'www.chatgpt.com')

$ProfileDir = Join-Path $env:APPDATA 'Proxifier4\Profiles'
$SettingsKey = 'HKCU:\Software\Initex\Proxifier\Settings'
$ExeCandidates = @('C:\Program Files (x86)\Proxifier\Proxifier.exe', 'C:\Program Files\Proxifier\Proxifier.exe')
$Exe = $ExeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$StateDir = Join-Path $env:LOCALAPPDATA 'codex-net-doctor'
$StateFile = Join-Path $StateDir 'last-good-version'

if (-not $NoRedact) { Write-Host '提示：输出已脱敏（-NoRedact 显示完整 IP）' -ForegroundColor Cyan }

# ---------- 1. 进程 ----------
Sec '1. 进程'
if (Get-Process Proxifier -ErrorAction SilentlyContinue) {
    Ok 'Proxifier 在运行'
} else {
    Bad 'Proxifier 没有运行'
    Hint '启动 Proxifier（它不在前台也没关系，托盘图标在即可）；Proxifier 没跑时 DNS 不会被接管。'
}

$drv = Get-Service -Name 'ProxifierDrv' -ErrorAction SilentlyContinue
if ($drv) {
    if ($drv.Status -eq 'Running') { Ok 'ProxifierDrv 驱动在运行' }
    else { Bad "ProxifierDrv 驱动未运行（$($drv.Status)）"; Hint '以管理员身份重启 Proxifier，或重新安装它的驱动。' }
} else {
    Note '找不到 ProxifierDrv 服务（便携版/服务模式可能不同）'
}

$codexProcs = @(Get-Process -Name 'codex' -ErrorAction SilentlyContinue)
if ($codexProcs.Count -gt 0) {
    Ok "Codex 在运行（$($codexProcs.Count) 个进程）"
    $withProxy = @()
    foreach ($p in $codexProcs) {
        $cmd = $null
        try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction Stop).CommandLine } catch { }
        if ($cmd -and $cmd -match '--proxy-server') { $withProxy += $p.Id }
    }
    if ($withProxy.Count -gt 0) {
        Note "Codex 启动参数里带了 --proxy-server（双通道模式，Proxifier 域名规则对它不参与）：pid $($withProxy -join ',')"
        Hint '想完全交给 Proxifier，可去掉启动脚本/快捷方式里的 --proxy-server 与 *_PROXY 环境变量。'
    }
} else {
    Note 'Codex 未运行（不影响其余检查）'
}

$inet = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
if ($inet -and $inet.ProxyEnable -eq 1 -and $inet.ProxyServer) {
    Note "系统代理（WinINET）开着：$($inet.ProxyServer)"
    Hint 'Proxifier 与系统代理同时用会双重代理；把 Windows「设置 → 网络 → 代理」关掉，交给 Proxifier。'
} else {
    Ok '系统代理未启用（不会与 Proxifier 双重代理）'
}

$envProxyNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')
$envProxySet = @()
foreach ($n in $envProxyNames) {
    if ([Environment]::GetEnvironmentVariable($n)) { $envProxySet += $n }
}
if ($envProxySet.Count -gt 0) {
    Note "代理环境变量已设置：$($envProxySet -join ', ')（走环境变量的应用会绕过 Proxifier）"
    Hint '想统一交给 Proxifier，就清掉启动脚本/系统里的 HTTP(S)_PROXY、ALL_PROXY。'
} else {
    Ok '没有代理环境变量干扰'
}

# ---------- 2. Proxifier 配置 ----------
Sec '2. Proxifier 配置'
$PpxPath = $null
$activeName = $null
if ($Profile) {
    if (Test-Path $Profile) {
        $PpxPath = (Resolve-Path $Profile).Path
        Ok "使用指定 profile：$(Redact-Name (Split-Path $PpxPath -Leaf))"
    } else {
        Bad "指定的 profile 不存在：$Profile"
    }
} else {
    try { $activeName = (Get-ItemProperty -Path $SettingsKey -Name ActiveProfile4 -ErrorAction Stop).ActiveProfile4 } catch { }
    if ($activeName) {
        $candidate = Join-Path $ProfileDir "$activeName.ppx"
        if (Test-Path $candidate) {
            $PpxPath = $candidate
            Ok "当前 profile：$(Redact-Name $activeName)"
        }
    }
    if (-not $PpxPath) {
        $newest = Get-ChildItem -Path $ProfileDir -Filter '*.ppx' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest) {
            $PpxPath = $newest.FullName
            Note "读不到 ActiveProfile4，按最新文件判断：$(Redact-Name $newest.Name)"
        } else {
            Bad "找不到 Proxifier profile（$ProfileDir）"
            Hint '先运行 ./codex-apply-proxifier.ps1 生成 profile，或用 Proxifier 的 File → Export 导出后加 -Profile 检查。'
        }
    }
}

$ProxyAddress = $null
$ProxyPortFound = 0
$ProxyType = $null

if ($PpxPath) {
    try {
        [xml]$doc = Get-Content -LiteralPath $PpxPath -Raw -Encoding UTF8
        $root = $doc.ProxifierProfile
        if (-not $root) { throw '不是 Proxifier profile（缺少 ProxifierProfile 根节点）' }

        $resolve = $root.Options.Resolve
        $viaProxy = $null
        if ($resolve -and $resolve.ViaProxy) { $viaProxy = $resolve.ViaProxy.enabled }
        if ($viaProxy -eq 'true') { Ok '域名解析走代理（ViaProxy=on）' }
        else {
            Bad "ViaProxy 没开（当前=$viaProxy）"
            Hint 'Proxifier → Profile → Name Resolution → 选 Resolve hostnames through proxy，并关闭 Detect settings automatically。'
        }

        if ($resolve -and $resolve.AutoModeDetection -and $resolve.AutoModeDetection.enabled -eq 'true') {
            Note 'AutoModeDetection 仍开着，DNS 模式可能随网络漂移'
            Hint 'Name Resolution 里取消 Detect DNS settings automatically。'
        } else {
            Ok '自动 DNS 探测已关闭'
        }

        $udpMode = $null
        if ($root.Options.Udp) { $udpMode = $root.Options.Udp.mode }
        if ($udpMode -eq 'mode_block_443') { Ok '已阻断 QUIC（Udp mode=mode_block_443）' }
        elseif ($udpMode -eq 'mode_block_all') { Note '所有 UDP 都被阻断（Udp mode=mode_block_all），可能影响其他应用' }
        else { Note "未阻断 QUIC（Udp mode=$udpMode），Chromium 可能尝试 HTTP/3"; Hint 'Profile → Advanced → UDP Traffic 选 Block UDP port 443 (QUIC)。' }

        $rules = @()
        if ($root.RuleList) { $rules = @($root.RuleList.Rule) | Where-Object { $_ } }
        $defaultIdx = -1
        $openaiIdx = -1
        for ($i = 0; $i -lt $rules.Count; $i++) {
            $name = "$($rules[$i].Name)"
            $targets = "$($rules[$i].Targets)"
            $actionType = "$($rules[$i].Action.type)"
            if ($name -eq 'Default') { $defaultIdx = $i }
            if ($actionType -eq 'Proxy' -and $targets -match 'openai\.com|chatgpt\.com' -and $openaiIdx -lt 0) {
                $openaiIdx = $i
            }
        }
        if ($openaiIdx -ge 0) {
            if ($defaultIdx -lt 0 -or $openaiIdx -lt $defaultIdx) {
                Ok "OpenAI 域名规则存在，且在 Default 之前（第 $($openaiIdx + 1) 条）"
            } else {
                Bad 'OpenAI 规则在 Default 之后，永远不会命中'
                Hint '把 OpenAI 规则拖到 Default 规则上面。'
            }
        } else {
            Bad '没有覆盖 openai.com / chatgpt.com 的代理规则'
            Hint '新增规则：Targets = openai.com; *.openai.com; chatgpt.com; *.chatgpt.com; *.oaistatic.com; *.oaiusercontent.com；Action = 你的代理。'
        }

        $hasLocalhost = $false
        if ($rules.Count -gt 0 -and "$($rules[0].Targets)" -match '127\.0\.0\.1') { $hasLocalhost = $true }
        if ($hasLocalhost) { Ok '第一条是本机/内网直连规则' }
        else { Note '规则列表第一条不是 Localhost 直连规则，注意本机回环流量被代理' }

        $proxies = @()
        if ($root.ProxyList) { $proxies = @($root.ProxyList.Proxy) | Where-Object { $_ } }
        if ($proxies.Count -eq 0) {
            Bad 'profile 里没有任何代理条目'
            Hint 'Profile → Proxy Servers 添加你的 SOCKS5 代理。'
        } else {
            $chosen = $proxies | Where-Object { $_.type -eq 'SOCKS5' } | Select-Object -First 1
            if (-not $chosen) { $chosen = $proxies | Select-Object -First 1 }
            if ($chosen) {
                if ($chosen.type -eq 'SOCKS5' -or $chosen.type -eq 'HTTPS') {
                    Ok "代理配置：$($chosen.type) $($chosen.Address):$($chosen.Port)"
                    $ProxyType = "$($chosen.type)"
                    $ProxyAddress = "$($chosen.Address)"
                    $ProxyPortFound = [int]$chosen.Port
                } else {
                    Note "代理类型是 $($chosen.type)（只支持 HTTP 明文的代理无法处理 HTTPS，不建议）"
                    $ProxyType = "$($chosen.type)"
                    $ProxyAddress = "$($chosen.Address)"
                    $ProxyPortFound = [int]$chosen.Port
                }
            }
        }
    } catch {
        Bad "profile 解析失败：$($_.Exception.Message)"
    }
}

if ($ProxyPort -gt 0) { $ProxyPortFound = $ProxyPort }

# ---------- 3. 本地代理可用性 ----------
Sec '3. 代理可用性'
$proxyTrace = $null
if (-not $ProxyAddress -or $ProxyPortFound -le 0) {
    Bad '没有可用的代理地址/端口，跳过连通性检查'
} else {
    $tcpOk = Test-NetConnection -ComputerName $ProxyAddress -Port $ProxyPortFound -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($tcpOk) { Ok "$ProxyAddress`:$ProxyPortFound TCP 可达" }
    else {
        Bad "$ProxyAddress`:$ProxyPortFound 连不上"
        Hint '检查代理客户端是否在跑、端口是否写对（profile 里端口变了是最常见的故障）。'
    }

    if ($tcpOk -and $ProxyType -eq 'SOCKS5') {
        $handshake = Test-Socks5 $ProxyAddress $ProxyPortFound
        if ($handshake -eq 'ok') { Ok 'SOCKS5 握手正常（无需认证）' }
        elseif ($handshake -eq 'auth') { Note 'SOCKS5 需要认证，脚本未带凭据；请确认 profile 里已保存账号密码' }
        else { Bad "SOCKS5 握手异常：$handshake" }
    }

    if ($tcpOk) {
        $pa = Get-ProxyCurlArgs $ProxyType $ProxyAddress $ProxyPortFound
        $proxyTrace = Get-Trace ($pa + @('-s', '-m', '20', 'https://chatgpt.com/cdn-cgi/trace'))
        if ($proxyTrace.Loc -and $proxyTrace.Loc -ne 'CN') {
            Ok "经代理解析可达：ip=$(Redact-Ip $proxyTrace.Ip) loc=$($proxyTrace.Loc)"
        } elseif ($proxyTrace.Loc -eq 'CN') {
            Bad "代理出口在国内（loc=CN，ip=$(Redact-Ip $proxyTrace.Ip)）"
            Hint '换一个境外节点；代理本身出不去的话，Proxifier 配得再对也没用。'
        } else {
            Bad '经代理访问 chatgpt.com 失败'
            Hint '先用 curl --socks5-hostname 手动验证代理，再回到 Proxifier。'
        }
    }
}

# ---------- 4. 系统层 ----------
Sec '4. 系统层（不带任何代理设置）'
$dnsIp = Resolve-A 'chatgpt.com'
if (-not $dnsIp) {
    Bad 'chatgpt.com 解析失败'
    Hint 'ipconfig /flushdns 后重试；若仍失败，检查系统 DNS 与 Proxifier 的 Name Resolution。'
} elseif (Test-FakeIp $dnsIp) {
    Ok "chatgpt.com -> $(Redact-Ip $dnsIp)（fake-IP，DNS 已被接管）"
} else {
    Bad "chatgpt.com -> $(Redact-Ip $dnsIp)（真实/污染 IP，未被 fake-IP 接管）"
    Hint '先 ipconfig /flushdns；再确认 Proxifier 正在运行且 ViaProxy=on。'
}

$probeHost = "probe$((Get-Random -Maximum 99999)).chatgpt.com"
$freshIp = Resolve-A $probeHost
if (Test-FakeIp $freshIp) {
    Ok "未缓存的新域名也被接管（$probeHost -> $(Redact-Ip $freshIp)）"
} else {
    Note "新域名没拿到 fake-IP（$probeHost -> $(Redact-Ip $freshIp)）"
    Hint '检查 Proxifier 的 DNS 模式是否被自动切换；刷新 DNS 后重试。'
}

$sysTrace = Get-Trace @('-s', '-m', '20', '--noproxy', '*', 'https://chatgpt.com/cdn-cgi/trace')
if ($sysTrace.Loc -and $sysTrace.Loc -ne 'CN') {
    Ok "系统层访问 chatgpt.com 走代理：ip=$(Redact-Ip $sysTrace.Ip) loc=$($sysTrace.Loc)"
} else {
    Bad "系统层访问 chatgpt.com 没走代理（loc=$($sysTrace.Loc)，ip=$(Redact-Ip $sysTrace.Ip)）"
    Hint '检查 OpenAI 规则顺序、fake-IP 是否生效；必要时 ipconfig /flushdns 并重启 Codex。'
}

$apiCode = Get-HttpCode 'https://api.openai.com/v1/models' $null
if ($apiCode -and $apiCode -ne '000' -and $apiCode -ne 'n/a') { Ok "api.openai.com 可达（HTTP $apiCode）" }
else { Bad 'api.openai.com 不可达' }

# 规则外域名必须仍然直连：用 Cloudflare trace 的出口 IP 与代理出口对比
if ($proxyTrace -and $proxyTrace.Ip) {
    $cfTrace = Get-Trace @('-s', '-m', '20', '--noproxy', '*', 'https://www.cloudflare.com/cdn-cgi/trace')
    if ($cfTrace.Ip) {
        if ($cfTrace.Ip -eq $proxyTrace.Ip) {
            Bad "规则外域名也被代走了（www.cloudflare.com 出口 = 代理出口 $(Redact-Ip $cfTrace.Ip)）"
            Hint '检查是否有过宽的规则（例如把 Default 设成了代理，或 Targets 写了 *）。'
        } else {
            Ok "规则外域名仍直连（www.cloudflare.com loc=$($cfTrace.Loc)，出口 $(Redact-Ip $cfTrace.Ip)）"
        }
    } else {
        Note '规则外域名直连测试失败（可能是本地网络限制），不影响 Codex 判断'
    }
} else {
    Note '代理出口 IP 未知，跳过"是否误伤直连流量"的对比'
}

# ---------- 5. DoH ----------
Sec '5. DoH 检测（应用是否绕过系统解析）'
$dohHit = 0
$myProcs = @(Get-Process -Name 'codex' -ErrorAction SilentlyContinue)
if ($myProcs.Count -eq 0) {
    Note 'Codex 未运行，跳过 DoH 检测'
} else {
    foreach ($p in $myProcs) {
        $conns = Get-NetTCPConnection -OwningProcess $p.Id -ErrorAction SilentlyContinue |
            Where-Object { $_.RemotePort -eq 443 -and $DohIps -contains $_.RemoteAddress }
        foreach ($c in $conns) {
            $dohHit++
            Note "pid $($p.Id) 连到了 DoH 服务商：$($c.RemoteAddress):443"
        }
    }
    if ($dohHit -eq 0) { Ok '未发现 Codex 连接已知 DoH 服务商' }
    else {
        Bad '检测到 DoH 连接，域名规则可能失效'
        Hint '关掉 Codex 内置的安全 DNS（Secure DNS / DoH），或改用 TUN 模式（sing-box / Mihomo fake-IP）。'
    }
}

# ---------- 6. 域名覆盖抽查 ----------
Sec '6. 域名覆盖抽查'
foreach ($h in $ProbeHosts) {
    $code = Get-HttpCode "https://$h/" $null
    if ($code -and $code -ne '000') { Ok "$h（HTTP $code）" }
    else { Bad "$h 不可达（000）" }
}

# ---------- 7. 版本与路径 ----------
Sec '7. 版本与路径（升级后重点看这里）'
$codexCandidates = @()
$binDir = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
if (Test-Path $binDir) {
    $codexCandidates = Get-ChildItem -Path $binDir -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'codex.exe' } |
        Where-Object { Test-Path $_ } |
        Sort-Object { (Get-Item $_).LastWriteTime } -Descending
}
$codexPath = $codexCandidates | Select-Object -First 1
$codexVer = $null
if ($codexPath) {
    $vi = (Get-Item $codexPath).VersionInfo
    $codexVer = $vi.FileVersion
    if (-not $codexVer) { $codexVer = $vi.ProductVersion }
    Ok "Codex 可执行文件：$codexPath"
    if ($codexVer) {
        Ok "Codex 版本：$codexVer"
    } else {
        # Electron 单文件不带版本资源，退回到 config.toml 里记录的 App 版本
        $cfg = Join-Path $env:USERPROFILE '.codex\config.toml'
        if (Test-Path $cfg) {
            $m = Select-String -Path $cfg -Pattern 'BROWSER_USE_CODEX_APP_VERSION\s*=\s*"([^"]+)"' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($m) {
                $codexVer = $m.Matches[0].Groups[1].Value
                Note "exe 不带版本资源，版本取自 config.toml：$codexVer"
            }
        }
        if (-not $codexVer) { Note '读不到 Codex 版本信息' }
    }
} else {
    Bad "找不到 Codex 可执行文件（$binDir\*\codex.exe）"
    Hint 'Codex 可能换了安装结构；检查规则里引用的应用路径，或改用纯域名规则。'
}

if (Test-Path $StateFile) {
    $oldVer = (Get-Content -LiteralPath $StateFile -Raw).Trim()
    if ($oldVer -and $codexVer -and $oldVer -ne $codexVer) {
        Note "版本变化：$oldVer -> $codexVer（建议重跑本脚本确认）"
    }
}

if ($script:fail -eq 0 -and $codexVer) {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
    [System.IO.File]::WriteAllText($StateFile, $codexVer, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------- 结果 ----------
if (-not $Quiet) {
    Write-Host ''
    Write-Host '== 结果 ==' -ForegroundColor Cyan
}
Write-Host ("  通过 {0} / 失败 {1} / 警告 {2}" -f $script:pass, $script:fail, $script:warn)

if ($script:hints.Count -gt 0) {
    Write-Host ''
    Write-Host '建议：' -ForegroundColor Yellow
    foreach ($h in $script:hints) { Write-Host "  - $h" }
}

if ($script:fail -gt 0) {
    Write-Host ''
    Write-Host '结论：当前配置不适用于 Codex 的连接路径，按上面建议处理。' -ForegroundColor Red
    exit 1
} elseif ($script:warn -gt 0) {
    Write-Host ''
    Write-Host '结论：基本可用，但有警告项。' -ForegroundColor Yellow
    exit 2
} else {
    Write-Host ''
    Write-Host '结论：Proxifier 配置仍然适用，Codex 应能正常连接。' -ForegroundColor Green
    exit 0
}
